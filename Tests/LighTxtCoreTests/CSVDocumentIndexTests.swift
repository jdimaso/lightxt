import Foundation
import XCTest
@testable import LighTxt

final class CSVDocumentIndexTests: XCTestCase {
    func testQuotedNewlinesEscapedQuotesAndCRLFAreSingleRecords() throws {
        let source = Data("name,notes\r\nAlice,\"hello,\nworld\"\r\nBob,\"said \"\"hi\"\"\"\n".utf8)
        let engine = FileBackedPieceTable(empty: .init())
        try engine.insert(source, at: 0)
        let snapshot = try engine.snapshot()
        let index = try CSVRowIndex(
            snapshot: snapshot,
            configuration: .init(readChunkByteCount: 7, initialCheckpointRecordInterval: 2)
        )

        let result = try index.scanToEnd()
        XCTAssertEqual(result.stopReason, .completed)
        XCTAssertEqual(result.progress.totalRecordCount, 3)

        let header = try XCTUnwrap(index.recordLocation(forRecord: 0))
        XCTAssertEqual(String(decoding: try snapshot.data(in: header.contentRange), as: UTF8.self), "name,notes")
        XCTAssertEqual(header.completeRange.count, header.contentRange.count + 2)

        let alice = try XCTUnwrap(index.recordLocation(forRecord: 1))
        let parsedAlice = try CSVRecordParser.parse(snapshot: snapshot, location: alice)
        XCTAssertEqual(parsedAlice.fields.map(\.value), ["Alice", "hello,\nworld"])

        let bob = try XCTUnwrap(index.recordLocation(forRecord: 2))
        let parsedBob = try CSVRecordParser.parse(snapshot: snapshot, location: bob)
        XCTAssertEqual(parsedBob.fields.map(\.value), ["Bob", "said \"hi\""])
        XCTAssertNil(try index.recordLocation(forRecord: 3))
    }

    func testNativeAndSwiftScannersMatchAcrossAdversarialChunkBoundaries() throws {
        let fixtures: [(String, Int)] = [
            ("a,b\r\nc,d\r\n", 4),                    // CR | LF split
            ("a,\"x\"\"y\",z\n", 5),              // escaped quote split
            ("a,\"abc\",d\n", 7),                  // closing quote at chunk end
            (String(repeating: "x\r\n", count: 40), 2), // pending CR + checkpoint thinning
            (",,\"\",\r\n", 3),                    // empty fields
            ("a,b\r", 2),
            ("a,b\n", 2),
            ("a,b", 2),
        ]
        for (source, chunkByteCount) in fixtures {
            try assertScannerParity(
                Data(source.utf8),
                readChunkByteCount: chunkByteCount,
                checkpointInterval: 1,
                maximumCheckpointCount: 2
            )
        }

        var random = CSVScannerRandom(seed: 0xc5_51_2026)
        for _ in 0..<80 {
            var source = ""
            for row in 0..<Int(random.next() % 40) {
                if row > 0 { source += random.next().isMultiple(of: 2) ? "\n" : "\r\n" }
                for column in 0..<Int(1 + random.next() % 8) {
                    if column > 0 { source += "," }
                    switch random.next() % 5 {
                    case 0: source += ""
                    case 1: source += "plain-\(random.next() % 1000)"
                    case 2: source += "\"quoted,\(random.next() % 100)\""
                    case 3: source += "\"line\nvalue\""
                    default: source += "\"escaped \"\"quote\"\"\""
                    }
                }
            }
            if random.next().isMultiple(of: 3) {
                source += random.next().isMultiple(of: 2) ? "\n" : "\r"
            }
            try assertScannerParity(
                Data(source.utf8),
                readChunkByteCount: Int(1 + random.next() % 31),
                checkpointInterval: Int64(1 + random.next() % 4),
                maximumCheckpointCount: Int(2 + random.next() % 8)
            )
        }
    }

    func testNativeScannerCancellationRollsBackCurrentChunkAndCanResume() throws {
        let source = Data(repeating: 0x61, count: 256 << 10) + Data("\n".utf8)
        let engine = FileBackedPieceTable(empty: .init())
        try engine.insert(source, at: 0)
        let index = try CSVRowIndex(
            snapshot: try engine.snapshot(),
            configuration: .init(readChunkByteCount: source.count)
        )
        let cancellation = CancellationProbe(cancelAfterChecks: 3)
        let cancelled = try index.scanNextChunk(cancellation: { cancellation.shouldCancel() })
        XCTAssertEqual(cancelled.stopReason, .cancelled)
        XCTAssertEqual(cancelled.progress.indexedByteCount, 0)
        XCTAssertEqual(cancelled.progress.knownRecordCount, 0)

        let completed = try index.scanToEnd()
        XCTAssertEqual(completed.stopReason, .completed)
        XCTAssertEqual(completed.progress.totalRecordCount, 1)
    }

    func testAdaptiveSparseCheckpointsHaveAHardMemoryBound() throws {
        let recordCount: Int64 = 200_000
        let byteCount = recordCount * 2
        let recorder = MaximumReadRecorder()
        let index = try CSVRowIndex(
            byteCount: byteCount,
            configuration: .init(
                readChunkByteCount: 127,
                initialCheckpointRecordInterval: 1,
                maximumCheckpointCount: 8
            ),
            reader: { range in
                recorder.observe(Int64(range.count))
                return Data((range.lowerBound..<range.upperBound).map { $0.isMultiple(of: 2) ? 0x61 : 0x0A })
            }
        )

        let result = try index.scanToEnd()
        XCTAssertEqual(result.progress.totalRecordCount, recordCount)
        XCTAssertLessThanOrEqual(result.progress.checkpointCount, 8)
        XCTAssertLessThanOrEqual(result.progress.checkpointPayloadByteCount, 8 * MemoryLayout<Int64>.stride)
        XCTAssertGreaterThan(result.progress.checkpointRecordInterval, 1)
        XCTAssertLessThanOrEqual(recorder.maximum, 127)

        let last = try XCTUnwrap(index.recordLocation(forRecord: recordCount - 1))
        XCTAssertEqual(last.contentRange, (byteCount - 2)..<(byteCount - 1))
        let page = try index.recordLocations(startingAt: recordCount - 32, limit: 32)
        XCTAssertEqual(page.count, 32)
        XCTAssertEqual(page.first?.record, recordCount - 32)
        XCTAssertEqual(page.last?.record, recordCount - 1)
    }

    func testCellReplacementTouchesOnlyItsExactRawByteRange() throws {
        let original = "id,comment\n1,\"before, value\"\n2,untouched\n"
        let engine = FileBackedPieceTable(empty: .init())
        try engine.insert(Data(original.utf8), at: 0)
        let snapshot = try engine.snapshot()
        let index = try CSVRowIndex(snapshot: snapshot)
        let row = try XCTUnwrap(index.recordLocation(forRecord: 1))
        let parsed = try CSVRecordParser.parse(snapshot: snapshot, location: row)
        let replacement = CSVRecordParser.encodedField("after, \"quoted\"")

        try engine.replace(byteRange: parsed.fields[1].byteRange, with: replacement)
        let edited = try engine.snapshot()
        XCTAssertEqual(
            String(decoding: try edited.data(in: 0..<edited.byteCount), as: UTF8.self),
            "id,comment\n1,\"after, \"\"quoted\"\"\"\n2,untouched\n"
        )
    }

    func testCSVCellEditUndoRedoAndSaveRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LighTxt-CSV-edit-QA-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("editable.csv")
        let original = "id,name,notes\n1,Alice,untouched\n2,Bob,keep me\n"
        try Data(original.utf8).write(to: url)

        let engine = try FileBackedPieceTable(opening: url)
        let before = try engine.snapshot()
        let index = try CSVRowIndex(snapshot: before)
        let location = try XCTUnwrap(index.recordLocation(forRecord: 1))
        let row = try CSVRecordParser.parse(snapshot: before, location: location)
        let replacement = CSVRecordParser.encodedField("Alice, edited")
        try engine.replace(byteRange: row.fields[1].byteRange, with: replacement)

        func contents() throws -> String {
            let snapshot = try engine.snapshot()
            return String(
                decoding: try snapshot.data(in: 0..<snapshot.byteCount),
                as: UTF8.self
            )
        }
        let edited = "id,name,notes\n1,\"Alice, edited\",untouched\n2,Bob,keep me\n"
        XCTAssertEqual(try contents(), edited)
        XCTAssertTrue(engine.undo())
        XCTAssertEqual(try contents(), original)
        XCTAssertTrue(engine.redo())
        XCTAssertEqual(try contents(), edited)
        try engine.save()
        XCTAssertFalse(engine.hasUnsavedChanges)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), edited)
    }

    func testRowPreservingEditRebasesCompletedSparseIndexWithoutRescan() throws {
        let engine = FileBackedPieceTable(empty: .init())
        var source = Data("id,name,value\n".utf8)
        for row in 1...4_096 {
            source.append(Data("\(row),person-\(row),value-\(row)\n".utf8))
        }
        try engine.insert(source, at: 0)
        let before = try engine.snapshot()
        let index = try CSVRowIndex(
            snapshot: before,
            configuration: .init(
                readChunkByteCount: 257,
                initialCheckpointRecordInterval: 16,
                maximumCheckpointCount: 1_024
            )
        )
        let completed = try index.scanToEnd().progress
        let editedRecord: Int64 = 2_048
        let location = try XCTUnwrap(index.recordLocation(forRecord: editedRecord))
        let parsed = try CSVRecordParser.parse(snapshot: before, location: location)
        let editRange = parsed.fields[1].byteRange
        let replacement = CSVRecordParser.encodedField("a substantially longer, edited name")
        try engine.replace(byteRange: editRange, with: replacement)
        let after = try engine.snapshot()

        let rebased = try index.rebased(
            onto: after,
            replacing: editRange,
            insertedByteCount: Int64(replacement.count)
        )
        XCTAssertTrue(rebased.progress.isComplete)
        XCTAssertEqual(rebased.progress.totalRecordCount, completed.totalRecordCount)
        XCTAssertEqual(rebased.progress.indexedByteCount, after.byteCount)
        XCTAssertEqual(rebased.progress.checkpointCount, completed.checkpointCount)

        let editedLocation = try XCTUnwrap(rebased.recordLocation(forRecord: editedRecord))
        let edited = try CSVRecordParser.parse(snapshot: after, location: editedLocation)
        XCTAssertEqual(edited.fields[1].value, "a substantially longer, edited name")
        for record in [Int64(0), editedRecord - 1, editedRecord + 1, Int64(4_096)] {
            let located = try XCTUnwrap(rebased.recordLocation(forRecord: record))
            XCTAssertEqual(located.record, record)
        }
    }

    func testFieldAndColumnLimitsTruncatePresentationNotCoordinates() throws {
        let source = Data("a,123456789,b,c".utf8)
        let engine = FileBackedPieceTable(empty: .init())
        try engine.insert(source, at: 0)
        let snapshot = try engine.snapshot()
        let index = try CSVRowIndex(snapshot: snapshot)
        let location = try XCTUnwrap(index.recordLocation(forRecord: 0))
        let record = try CSVRecordParser.parse(
            snapshot: snapshot,
            location: location,
            limits: .init(maximumFields: 3, maximumPreviewBytesPerField: 4)
        )

        XCTAssertEqual(record.fields.count, 3)
        XCTAssertTrue(record.hadMoreFields)
        XCTAssertEqual(record.fields[1].value, "1234")
        XCTAssertTrue(record.fields[1].wasTruncated)
        XCTAssertEqual(record.fields[1].byteRange, 2..<11)
    }

    func testHeaderDetectionUsesLabelsAndFollowingValueTypes() {
        let first = CSVParsedRecord(fields: [
            CSVFieldValue(byteRange: 0..<2, value: "id", wasTruncated: false),
            CSVFieldValue(byteRange: 3..<7, value: "name", wasTruncated: false),
        ], hadMoreFields: false)
        let second = CSVParsedRecord(fields: [
            CSVFieldValue(byteRange: 8..<10, value: "42", wasTruncated: false),
            CSVFieldValue(byteRange: 11..<16, value: "Jerry", wasTruncated: false),
        ], hadMoreFields: false)
        XCTAssertTrue(CSVHeaderDetector.isLikelyHeader(first: first, second: second))

        let dataFirst = CSVParsedRecord(fields: [
            CSVFieldValue(byteRange: 0..<1, value: "1", wasTruncated: false),
            CSVFieldValue(byteRange: 2..<3, value: "2", wasTruncated: false),
        ], hadMoreFields: false)
        XCTAssertFalse(CSVHeaderDetector.isLikelyHeader(first: dataFirst, second: nil))
    }

    func testHeaderDetectionDoesNotHideFirstAllTextDataRow() {
        let first = CSVParsedRecord(fields: [
            CSVFieldValue(byteRange: 0..<8, value: "New York", wasTruncated: false),
            CSVFieldValue(byteRange: 9..<17, value: "John Doe", wasTruncated: false),
        ], hadMoreFields: false)
        let second = CSVParsedRecord(fields: [
            CSVFieldValue(byteRange: 18..<29, value: "Los Angeles", wasTruncated: false),
            CSVFieldValue(byteRange: 30..<38, value: "Jane Roe", wasTruncated: false),
        ], hadMoreFields: false)
        XCTAssertFalse(CSVHeaderDetector.isLikelyHeader(first: first, second: second))

        let textHeader = CSVParsedRecord(fields: [
            CSVFieldValue(byteRange: 0..<10, value: "First Name", wasTruncated: false),
            CSVFieldValue(byteRange: 11..<20, value: "Last Name", wasTruncated: false),
        ], hadMoreFields: false)
        XCTAssertTrue(CSVHeaderDetector.isLikelyHeader(first: textHeader, second: first))
    }

    func testCancellationStopsBeforeARead() throws {
        let index = try CSVRowIndex(byteCount: 1_000, reader: { _ in
            XCTFail("Cancelled indexing must not read")
            return Data()
        })
        let result = try index.scanNextChunk(cancellation: { true })
        XCTAssertEqual(result.stopReason, .cancelled)
        XCTAssertEqual(result.progress.indexedByteCount, 0)
    }

    func testPresentationParserCancelsInsideOneLargeRecord() throws {
        let engine = FileBackedPieceTable(empty: .init())
        var source = Data("id,\"".utf8)
        source.append(Data(repeating: 0x61, count: 2 << 20))
        source.append(Data("\"".utf8))
        try engine.insert(source, at: 0)
        let snapshot = try engine.snapshot()
        let index = try CSVRowIndex(snapshot: snapshot)
        let location = try XCTUnwrap(index.recordLocation(forRecord: 0))
        let cancellation = CancellationProbe(cancelAfterChecks: 3)

        XCTAssertThrowsError(
            try CSVRecordParser.parse(
                snapshot: snapshot,
                location: location,
                cancellation: { cancellation.shouldCancel() }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertLessThan(cancellation.checkCount, 20)
    }

    func testSelectedFieldsPreserveRFC4180CoordinatesWithoutRetainingOtherColumns() throws {
        let source = Data("skip,\"hello,\n\"\"world\"\"\",tail\r\n".utf8)
        let engine = FileBackedPieceTable(empty: .init())
        try engine.insert(source, at: 0)
        let snapshot = try engine.snapshot()
        let index = try CSVRowIndex(snapshot: snapshot)
        let location = try XCTUnwrap(index.recordLocation(forRecord: 0))

        let selected = try CSVRecordParser.selectedFields(
            snapshot: snapshot,
            location: location,
            columns: [1],
            maximumValueBytesPerField: 128,
            maximumRetainedValueBytes: 128
        )

        XCTAssertEqual(selected.fieldCount, 3)
        XCTAssertEqual(selected.fields.keys.sorted(), [1])
        XCTAssertEqual(selected.fields[1]?.value, "hello,\n\"world\"")
        XCTAssertEqual(
            try snapshot.utf8String(in: XCTUnwrap(selected.fields[1]?.byteRange)),
            "\"hello,\n\"\"world\"\"\""
        )
        XCTAssertFalse(try XCTUnwrap(selected.fields[1]).wasTruncated)
    }

    func testPipeDelimiterFlowsThroughIndexSelectionAndColumnMutation() throws {
        let original = "id|name|note\n1|Ada|\"a|b\"\n2|Lin|calm\n"
        let engine = FileBackedPieceTable(empty: .init())
        try engine.insert(Data(original.utf8), at: 0)
        let snapshot = try engine.snapshot()
        let index = try CSVRowIndex(
            snapshot: snapshot,
            configuration: .init(delimiter: 0x7C)
        )
        let location = try XCTUnwrap(index.recordLocation(forRecord: 1))

        let selected = try CSVRecordParser.selectedFields(
            snapshot: snapshot,
            location: location,
            columns: [1, 2],
            delimiter: index.delimiter,
            maximumValueBytesPerField: 128,
            maximumRetainedValueBytes: 256
        )
        XCTAssertEqual(selected.fieldCount, 3)
        XCTAssertEqual(selected.fields[1]?.value, "Ada")
        XCTAssertEqual(selected.fields[2]?.value, "a|b")

        _ = try engine.applyCSVColumnMutation(
            .insert(CSVColumnInsertion(
                column: 1,
                headerRecord: 0,
                headerValue: "score"
            )),
            snapshot: snapshot,
            index: index,
            delimiter: index.delimiter
        )
        let result = try engine.snapshot()
        XCTAssertEqual(
            try result.utf8String(in: 0..<result.byteCount),
            "id|score|name|note\n1||Ada|\"a|b\"\n2||Lin|calm\n"
        )
    }

    func testFilteredRowMapComposesColumnPredicatesAndSkipsHeader() throws {
        let text = "id,name,amount\r\n"
            + "1,Alice,10\r\n"
            + "2,ALICIA,20\r\n"
            + "3,Bob,30\r\n"
            + "4,,40\r\n"
        let source = Data(text.utf8)
        let engine = FileBackedPieceTable(empty: .init())
        try engine.insert(source, at: 0)
        let snapshot = try engine.snapshot()
        let index = try CSVRowIndex(snapshot: snapshot)

        let result = try CSVRowQueryEngine.execute(
            snapshot: snapshot,
            index: index,
            query: CSVRowQuery(firstRecord: 1, filters: [
                CSVColumnFilter(
                    column: 1,
                    predicate: .beginsWith("ali", caseSensitive: false)
                ),
                CSVColumnFilter(
                    column: 2,
                    predicate: .numeric(.greaterThanOrEqual, 20)
                ),
            ])
        )

        XCTAssertEqual(result.rowCount, 1)
        XCTAssertEqual(try result.record(at: 0), 2)
        XCTAssertEqual(try result.records(in: 0..<20), [2])
        result.close()
        XCTAssertThrowsError(try result.record(at: 0)) { error in
            XCTAssertEqual(error as? CSVDataOperationError, .rowMapClosed)
        }
    }

    func testExactFilterRejectsTruncatedQueryValue() throws {
        let engine = FileBackedPieceTable(empty: .init())
        try engine.insert(Data("value\nabcdefghij\n".utf8), at: 0)
        let snapshot = try engine.snapshot()
        let index = try CSVRowIndex(snapshot: snapshot)

        XCTAssertThrowsError(
            try CSVRowQueryEngine.execute(
                snapshot: snapshot,
                index: index,
                query: CSVRowQuery(firstRecord: 1, filters: [
                    CSVColumnFilter(
                        column: 0,
                        predicate: .contains("j", caseSensitive: true)
                    ),
                ]),
                configuration: .init(
                    pageRecordCount: 1,
                    maximumValueBytesPerField: 4,
                    maximumRetainedValueBytesPerRecord: 4
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? CSVDataOperationError,
                .queryValueTooLarge(record: 1, column: 0, limit: 4)
            )
        }
    }

    func testColumnProfileIsBoundedAndReportsKindsTopValuesAndNumericStats() throws {
        let engine = FileBackedPieceTable(empty: .init())
        try engine.insert(Data("value\n10\n20\n20\ntext\n\n".utf8), at: 0)
        let snapshot = try engine.snapshot()
        let index = try CSVRowIndex(snapshot: snapshot)

        let profile = try CSVColumnProfiler.profile(
            snapshot: snapshot,
            index: index,
            column: 0,
            firstRecord: 1,
            configuration: .init(maximumRecords: 100, topValueCapacity: 4)
        )

        XCTAssertEqual(profile.sampledRecordCount, 5)
        XCTAssertTrue(profile.isCompleteDataset)
        XCTAssertEqual(profile.samplingStrategy, .complete)
        XCTAssertEqual(profile.emptyValueCount, 1)
        XCTAssertEqual(profile.integerValueCount, 3)
        XCTAssertEqual(profile.textValueCount, 1)
        XCTAssertEqual(profile.inferredKind, .mixed)
        XCTAssertEqual(profile.minimumNumericValue, 10)
        XCTAssertEqual(profile.maximumNumericValue, 20)
        XCTAssertEqual(
            try XCTUnwrap(profile.meanNumericValue),
            50.0 / 3.0,
            accuracy: 0.000_001
        )
        XCTAssertEqual(profile.topValues.first?.value, "20")
        XCTAssertEqual(profile.topValues.first?.estimatedCount, 2)
        XCTAssertGreaterThanOrEqual(profile.approximateDistinctValueCount, 3)
    }

    func testCompletedLargeProfileUsesDeterministicStrataAcrossWholeDataset() throws {
        var source = Data("value\n".utf8)
        for record in 0..<1_000 {
            let value: String
            if record < 400 { value = "head" }
            else if record < 600 { value = "middle" }
            else { value = "tail" }
            source.append(Data("\(value)\n".utf8))
        }
        let engine = FileBackedPieceTable(empty: .init())
        try engine.insert(source, at: 0)
        let snapshot = try engine.snapshot()
        let index = try CSVRowIndex(snapshot: snapshot)
        _ = try index.scanToEnd()

        let profile = try CSVColumnProfiler.profile(
            snapshot: snapshot,
            index: index,
            column: 0,
            firstRecord: 1,
            configuration: .init(
                maximumRecords: 30,
                topValueCapacity: 6
            )
        )

        XCTAssertEqual(profile.samplingStrategy, .stratified)
        XCTAssertFalse(profile.isCompleteDataset)
        XCTAssertEqual(profile.sampledRecordCount, 30)
        XCTAssertEqual(profile.totalRecordCount, 1_001)
        XCTAssertEqual(Set(profile.topValues.map(\.value)), ["head", "middle", "tail"])
    }

    func testProfileApproximateDistinctCountHasReasonableAccuracy() throws {
        var source = Data("value\n".utf8)
        for record in 0..<1_000 { source.append(Data("unique-\(record)\n".utf8)) }
        let engine = FileBackedPieceTable(empty: .init())
        try engine.insert(source, at: 0)
        let snapshot = try engine.snapshot()
        let index = try CSVRowIndex(snapshot: snapshot)
        let profile = try CSVColumnProfiler.profile(
            snapshot: snapshot,
            index: index,
            column: 0,
            firstRecord: 1,
            configuration: .init(maximumRecords: 2_000)
        )
        XCTAssertTrue(
            700...1_300 ~= profile.approximateDistinctValueCount,
            "estimate=\(profile.approximateDistinctValueCount)"
        )
    }

    func testFilteringCancellationDoesNotPublishAPartialRowMap() throws {
        let engine = FileBackedPieceTable(empty: .init())
        try engine.insert(Data(String(repeating: "a,b\n", count: 10_000).utf8), at: 0)
        let snapshot = try engine.snapshot()
        let index = try CSVRowIndex(snapshot: snapshot)
        let cancellation = CancellationProbe(cancelAfterChecks: 8)

        XCTAssertThrowsError(
            try CSVRowQueryEngine.execute(
                snapshot: snapshot,
                index: index,
                query: CSVRowQuery(filters: [
                    CSVColumnFilter(column: 0, predicate: .equals("a", caseSensitive: true)),
                ]),
                configuration: .init(pageRecordCount: 512),
                cancellation: { cancellation.shouldCancel() }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testAutomaticSortHasDeterministicStableTotalOrderAndEmptyValuesLast() throws {
        let text = "value\n\n10\n2\napple2\nApple10\n2.0\nbanana\n"
        let engine = FileBackedPieceTable(empty: .init())
        try engine.insert(Data(text.utf8), at: 0)
        let snapshot = try engine.snapshot()

        func sorted(_ order: CSVSortOrder) throws -> [Int64] {
            let index = try CSVRowIndex(snapshot: snapshot)
            let map = try CSVRowQueryEngine.execute(
                snapshot: snapshot,
                index: index,
                query: CSVRowQuery(
                    firstRecord: 1,
                    sortDescriptors: [CSVSortDescriptor(column: 0, order: order)]
                )
            )
            return try map.records(in: 0..<map.rowCount)
        }

        // 2 and 2.0 compare numerically equal and retain source order. Text is
        // numeric-aware/case-insensitive, and empty remains last both ways.
        XCTAssertEqual(try sorted(.ascending), [3, 6, 2, 4, 5, 7, 1])
        XCTAssertEqual(try sorted(.descending), [7, 5, 4, 2, 3, 6, 1])
    }

    func testExternalMergeSortPersistsKeysAndDoesNotRereadSourceRows() throws {
        var source = Data("value\n".utf8)
        for value in stride(from: 4_999, through: 0, by: -1) {
            source.append(Data("\(value)\n".utf8))
        }
        let engine = FileBackedPieceTable(empty: .init())
        try engine.insert(source, at: 0)
        let snapshot = try engine.snapshot()

        func execute(sorted: Bool) throws -> (CSVRowMap, Int) {
            let recorder = MaximumReadRecorder()
            let index = try CSVRowIndex(
                byteCount: snapshot.byteCount,
                configuration: .init(
                    readChunkByteCount: 257,
                    initialCheckpointRecordInterval: 16,
                    maximumCheckpointCount: 1_024,
                    allowsAcceleratedScanner: false
                ),
                reader: { range in
                    recorder.observe(Int64(range.count))
                    return try snapshot.data(in: range)
                }
            )
            let map = try CSVRowQueryEngine.execute(
                snapshot: snapshot,
                index: index,
                query: CSVRowQuery(
                    firstRecord: 1,
                    sortDescriptors: sorted ? [CSVSortDescriptor(column: 0)] : []
                ),
                configuration: .init(
                    pageRecordCount: 128,
                    sortRunMemoryByteCount: 64 << 10,
                    mergeFanIn: 3
                )
            )
            return (map, recorder.readCount)
        }

        let baseline = try execute(sorted: false)
        let sorted = try execute(sorted: true)
        XCTAssertEqual(sorted.0.rowCount, 5_000)
        XCTAssertEqual(try sorted.0.record(at: 0), 5_000)
        XCTAssertEqual(try sorted.0.record(at: 4_999), 1)
        XCTAssertEqual(
            sorted.1,
            baseline.1,
            "External merge passes must consume persisted keys, not sparse source rescans"
        )
    }

    func testRowMutationPlannerPreservesCRLFQuotedNewlinesAndTerminalEmptyRecord() throws {
        let original = "id,note\r\n1,\"a\r\nb\"\r\n\r\n"
        let engine = FileBackedPieceTable(empty: .init())
        try engine.insert(Data(original.utf8), at: 0)
        let before = try engine.snapshot()
        let index = try CSVRowIndex(snapshot: before)

        let insertion = try CSVRowMutationPlanner.insert(
            values: ["2", "x,y"],
            beforeRecord: 2,
            snapshot: before,
            index: index
        )
        try engine.replaceAtomically(edits: [insertion], replacing: before)
        var snapshot = try engine.snapshot()
        XCTAssertEqual(
            try snapshot.utf8String(in: 0..<snapshot.byteCount),
            "id,note\r\n1,\"a\r\nb\"\r\n2,\"x,y\"\r\n\r\n"
        )

        let updatedIndex = try CSVRowIndex(snapshot: snapshot)
        let deletion = try CSVRowMutationPlanner.delete(
            record: 3,
            snapshot: snapshot,
            index: updatedIndex
        )
        try engine.replaceAtomically(edits: [deletion], replacing: snapshot)
        snapshot = try engine.snapshot()
        XCTAssertEqual(
            try snapshot.utf8String(in: 0..<snapshot.byteCount),
            "id,note\r\n1,\"a\r\nb\"\r\n2,\"x,y\"\r\n"
        )
    }

    func testStreamedColumnInsertDeleteIsOneUndoAndPreservesUntouchedBytes() throws {
        let original = "id,name\r\n1,\"A,lice\"\r\n2\r\n,\r\n"
        let inserted = "id,score,name\r\n1,,\"A,lice\"\r\n2,\r\n,,\r\n"
        let engine = FileBackedPieceTable(empty: .init())
        try engine.insert(Data(original.utf8), at: 0)
        // Make the fixture the saved-like baseline for this focused undo test.
        let before = try engine.snapshot()
        let index = try CSVRowIndex(snapshot: before)

        let result = try engine.applyCSVColumnMutation(
            .insert(CSVColumnInsertion(
                column: 1,
                headerRecord: 0,
                headerValue: "score"
            )),
            snapshot: before,
            index: index
        )
        XCTAssertEqual(result.changedRecordCount, 4)
        var snapshot = try engine.snapshot()
        XCTAssertEqual(try snapshot.utf8String(in: 0..<snapshot.byteCount), inserted)
        XCTAssertTrue(engine.undo())
        snapshot = try engine.snapshot()
        XCTAssertEqual(try snapshot.utf8String(in: 0..<snapshot.byteCount), original)
        XCTAssertTrue(engine.redo())
        snapshot = try engine.snapshot()
        XCTAssertEqual(try snapshot.utf8String(in: 0..<snapshot.byteCount), inserted)

        let insertedIndex = try CSVRowIndex(snapshot: snapshot)
        let deletion = try engine.applyCSVColumnMutation(
            .delete(column: 1),
            snapshot: snapshot,
            index: insertedIndex
        )
        XCTAssertEqual(deletion.changedRecordCount, 4)
        snapshot = try engine.snapshot()
        XCTAssertEqual(try snapshot.utf8String(in: 0..<snapshot.byteCount), original)
    }

    func testFirstColumnMutationsPreserveUTF8BOMThroughUndoRedoAndSave() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LighTxt-CSV-BOM-QA-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("excel-export.csv")
        let bom = Data([0xEF, 0xBB, 0xBF])
        let original = bom + Data("name,age\r\nAlice,30\r\n".utf8)
        try original.write(to: url)

        let engine = try FileBackedPieceTable(opening: url)
        var snapshot = try engine.snapshot()
        var index = try CSVRowIndex(snapshot: snapshot)
        let headerLocation = try XCTUnwrap(index.recordLocation(forRecord: 0))
        let dataLocation = try XCTUnwrap(index.recordLocation(forRecord: 1))
        let header = try CSVRecordParser.parse(snapshot: snapshot, location: headerLocation)
        let firstData = try CSVRecordParser.parse(snapshot: snapshot, location: dataLocation)
        XCTAssertEqual(header.fields.map(\.value), ["name", "age"])
        XCTAssertEqual(header.fields.first?.byteRange, 3..<7)
        XCTAssertTrue(CSVHeaderDetector.isLikelyHeader(first: header, second: firstData))

        // A normal View-mode cell replacement uses this exact byte range. It
        // must begin after the BOM and leave the marker at byte zero.
        try engine.replace(
            byteRange: try XCTUnwrap(header.fields.first?.byteRange),
            with: CSVRecordParser.encodedField("full_name")
        )
        snapshot = try engine.snapshot()
        XCTAssertEqual(
            try snapshot.data(in: 0..<snapshot.byteCount),
            bom + Data("full_name,age\r\nAlice,30\r\n".utf8)
        )
        XCTAssertTrue(engine.undo())
        snapshot = try engine.snapshot()
        index = try CSVRowIndex(snapshot: snapshot)

        _ = try engine.applyCSVColumnMutation(
            .insert(CSVColumnInsertion(
                column: 0,
                headerRecord: 0,
                headerValue: "id"
            )),
            snapshot: snapshot,
            index: index
        )
        let inserted = bom + Data("id,name,age\r\n,Alice,30\r\n".utf8)
        snapshot = try engine.snapshot()
        XCTAssertEqual(try snapshot.data(in: 0..<snapshot.byteCount), inserted)

        XCTAssertTrue(engine.undo())
        snapshot = try engine.snapshot()
        XCTAssertEqual(try snapshot.data(in: 0..<snapshot.byteCount), original)

        index = try CSVRowIndex(snapshot: snapshot)
        _ = try engine.applyCSVColumnMutation(
            .delete(column: 0),
            snapshot: snapshot,
            index: index
        )
        let deleted = bom + Data("age\r\n30\r\n".utf8)
        snapshot = try engine.snapshot()
        XCTAssertEqual(try snapshot.data(in: 0..<snapshot.byteCount), deleted)
        XCTAssertTrue(engine.undo())
        XCTAssertTrue(engine.redo())
        try engine.save()
        XCTAssertFalse(engine.hasUnsavedChanges)
        XCTAssertEqual(try Data(contentsOf: url), deleted)
    }

    func testFirstRowInsertAndDeleteKeepUTF8BOMAtFileStart() throws {
        let bom = Data([0xEF, 0xBB, 0xBF])
        let original = bom + Data("first,1\r\nsecond,2\r\n".utf8)
        let engine = FileBackedPieceTable(empty: .init())
        try engine.insert(original, at: 0)
        var snapshot = try engine.snapshot()
        var index = try CSVRowIndex(snapshot: snapshot)

        let insertion = try CSVRowMutationPlanner.insert(
            values: ["new", "0"],
            beforeRecord: 0,
            snapshot: snapshot,
            index: index
        )
        try engine.replaceAtomically(edits: [insertion], replacing: snapshot)
        var expected = bom + Data("new,0\r\nfirst,1\r\nsecond,2\r\n".utf8)
        snapshot = try engine.snapshot()
        XCTAssertEqual(try snapshot.data(in: 0..<snapshot.byteCount), expected)

        XCTAssertTrue(engine.undo())
        snapshot = try engine.snapshot()
        index = try CSVRowIndex(snapshot: snapshot)
        let deletion = try CSVRowMutationPlanner.delete(
            record: 0,
            snapshot: snapshot,
            index: index
        )
        try engine.replaceAtomically(edits: [deletion], replacing: snapshot)
        expected = bom + Data("second,2\r\n".utf8)
        snapshot = try engine.snapshot()
        XCTAssertEqual(try snapshot.data(in: 0..<snapshot.byteCount), expected)
    }

    func testDeletingMissingColumnLeavesRaggedRowByteIdentical() throws {
        let original = "a,b\n1,2\nragged\n"
        let engine = FileBackedPieceTable(empty: .init())
        try engine.insert(Data(original.utf8), at: 0)
        let snapshot = try engine.snapshot()
        let index = try CSVRowIndex(snapshot: snapshot)
        let result = try engine.applyCSVColumnMutation(
            .delete(column: 1),
            snapshot: snapshot,
            index: index
        )
        XCTAssertEqual(result.changedRecordCount, 2)
        let after = try engine.snapshot()
        XCTAssertEqual(try after.utf8String(in: 0..<after.byteCount), "a\n1\nragged\n")
    }

    func testRealLargeCSVIndexReleaseQAWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["LIGHTXT_CSV_TARGET"],
              !path.isEmpty else {
            throw XCTSkip("Set LIGHTXT_CSV_TARGET for the opt-in read-only large CSV release QA")
        }
        let url = URL(fileURLWithPath: path)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        let engine = try FileBackedPieceTable(opening: url)
        let snapshot = try engine.snapshot()
        let configuration = CSVRowIndex.Configuration(
            readChunkByteCount: 1 << 20,
            initialCheckpointRecordInterval: 1_024,
            maximumCheckpointCount: 65_536
        )
        let index = try CSVRowIndex(snapshot: snapshot, configuration: configuration)
        var lastBytes: Int64 = 0
        var lastRows: Int64 = 0
        let clock = ContinuousClock()
        let overallStarted = clock.now
        let firstPageStarted = clock.now
        let firstLocations = try index.recordLocations(startingAt: 0, limit: 64)
        for location in firstLocations {
            _ = try CSVRecordParser.parse(
                snapshot: snapshot,
                location: location,
                limits: .init(maximumFields: 512, maximumPreviewBytesPerField: 64 << 10)
            )
        }
        let firstPageSeconds = durationSeconds(firstPageStarted.duration(to: clock.now))
        XCTAssertEqual(firstLocations.count, 64)
        XCTAssertLessThanOrEqual(index.progress.indexedByteCount, Int64(configuration.readChunkByteCount))
        let result = try index.scanToEnd(progressHandler: { progress in
            XCTAssertGreaterThanOrEqual(progress.indexedByteCount, lastBytes)
            XCTAssertGreaterThanOrEqual(progress.knownRecordCount, lastRows)
            lastBytes = progress.indexedByteCount
            lastRows = progress.knownRecordCount
        })
        let elapsed = overallStarted.duration(to: clock.now)

        XCTAssertEqual(result.stopReason, .completed)
        XCTAssertEqual(result.progress.indexedByteCount, snapshot.byteCount)
        let total = try XCTUnwrap(result.progress.totalRecordCount)
        XCTAssertGreaterThan(total, 0)
        XCTAssertLessThanOrEqual(
            result.progress.checkpointCount,
            configuration.maximumCheckpointCount
        )
        XCTAssertLessThanOrEqual(
            result.progress.checkpointPayloadByteCount,
            configuration.maximumCheckpointCount * MemoryLayout<Int64>.stride
        )

        var randomPageSeconds: [Double] = []
        for record in [Int64(0), total / 2, total - 1] {
            let pageStarted = clock.now
            let location = try XCTUnwrap(index.recordLocation(forRecord: record))
            XCTAssertEqual(location.record, record)
            XCTAssertGreaterThanOrEqual(location.contentRange.lowerBound, 0)
            XCTAssertLessThanOrEqual(location.completeRange.upperBound, snapshot.byteCount)
            let parsed = try CSVRecordParser.parse(
                snapshot: snapshot,
                location: location,
                limits: .init(maximumFields: 512, maximumPreviewBytesPerField: 64 << 10)
            )
            XCTAssertFalse(parsed.fields.isEmpty)
            randomPageSeconds.append(durationSeconds(pageStarted.duration(to: clock.now)))
        }

        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(before[.size] as? NSNumber, after[.size] as? NSNumber)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
        XCTAssertFalse(engine.hasUnsavedChanges)
        print(
            "LighTxt CSV release QA: \(snapshot.byteCount) bytes, \(total) rows, "
                + "\(result.progress.checkpointCount) checkpoints "
                + "(\(result.progress.checkpointPayloadByteCount) payload bytes), \(elapsed), "
                + "firstPageSeconds=\(firstPageSeconds), randomPageSeconds=\(randomPageSeconds)"
        )
    }

    func testRealLargeCSVFilteringReleaseQAWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["LIGHTXT_CSV_FILTER_TARGET"],
              !path.isEmpty else {
            throw XCTSkip(
                "Set LIGHTXT_CSV_FILTER_TARGET for the opt-in read-only CSV filtering release QA"
            )
        }
        let distinctColumn = ProcessInfo.processInfo.environment["LIGHTXT_CSV_FILTER_COLUMN"]
            .flatMap(Int.init) ?? 2
        let npiColumn = ProcessInfo.processInfo.environment["LIGHTXT_CSV_NPI_COLUMN"]
            .flatMap(Int.init) ?? 17
        let url = URL(fileURLWithPath: path)
        let before = try FileManager.default.attributesOfItem(atPath: url.path)
        let engine = try FileBackedPieceTable(opening: url)
        defer { engine.close() }
        let snapshot = try engine.snapshot()
        let index = try CSVRowIndex(snapshot: snapshot)
        let clock = ContinuousClock()

        let indexStarted = clock.now
        let indexResult = try index.scanToEnd()
        let indexSeconds = durationSeconds(indexStarted.duration(to: clock.now))
        let totalRecords = try XCTUnwrap(indexResult.progress.totalRecordCount)
        XCTAssertGreaterThan(totalRecords, 1)

        let legacyDistinctStarted = clock.now
        let legacyDistinct = try CSVUniqueValueProvider.collect(
            snapshot: snapshot,
            index: try CSVRowIndex(snapshot: snapshot),
            column: distinctColumn,
            firstRecord: 1
        )
        let legacyDistinctSeconds = durationSeconds(
            legacyDistinctStarted.duration(to: clock.now)
        )

        let projectedDistinctStarted = clock.now
        let projectedDistinct = try CSVUniqueValueProvider.collect(
            snapshot: snapshot,
            index: index,
            column: distinctColumn,
            firstRecord: 1
        )
        let projectedDistinctSeconds = durationSeconds(
            projectedDistinctStarted.duration(to: clock.now)
        )
        XCTAssertEqual(projectedDistinct, legacyDistinct)
        XCTAssertGreaterThan(projectedDistinct.scannedRecordCount, 0)
        XCTAssertFalse(projectedDistinct.values.isEmpty)

        var npiValue: String?
        var npiRecord: Int64 = 1
        while npiValue == nil, npiRecord < totalRecords {
            let locations = try index.recordLocations(startingAt: npiRecord, limit: 4_096)
            guard !locations.isEmpty else { break }
            for location in locations {
                let selected = try CSVRecordParser.selectedFields(
                    snapshot: snapshot,
                    location: location,
                    columns: [npiColumn],
                    delimiter: index.delimiter,
                    maximumValueBytesPerField: 64 << 10,
                    maximumRetainedValueBytes: 64 << 10
                )
                if let value = selected.fields[npiColumn]?.value, !value.isEmpty {
                    npiValue = value
                    break
                }
            }
            npiRecord = locations[locations.count - 1].record + 1
        }
        let exactNPIValue = try XCTUnwrap(npiValue)
        let npiQuery = CSVRowQuery(firstRecord: 1, filters: [
            CSVColumnFilter(
                column: npiColumn,
                containsText: "",
                selectedValues: [exactNPIValue]
            ),
        ])

        let legacyNPIStarted = clock.now
        let legacyNPIMap = try CSVRowQueryEngine.execute(
            snapshot: snapshot,
            index: try CSVRowIndex(snapshot: snapshot),
            query: npiQuery
        )
        let legacyNPISeconds = durationSeconds(legacyNPIStarted.duration(to: clock.now))
        let legacyNPICount = legacyNPIMap.rowCount
        legacyNPIMap.close()

        let projectedNPIStarted = clock.now
        let projectedNPIMap = try CSVRowQueryEngine.execute(
            snapshot: snapshot,
            index: index,
            query: npiQuery
        )
        let projectedNPISeconds = durationSeconds(projectedNPIStarted.duration(to: clock.now))
        let projectedNPICount = projectedNPIMap.rowCount
        projectedNPIMap.close()
        XCTAssertEqual(projectedNPICount, legacyNPICount)

        let absentStarted = clock.now
        let absentMap = try CSVRowQueryEngine.execute(
            snapshot: snapshot,
            index: index,
            query: CSVRowQuery(firstRecord: 1, filters: [
                CSVColumnFilter(
                    column: distinctColumn,
                    containsText: "__LIGHTXT_BENCHMARK_ABSENT__"
                ),
            ])
        )
        let absentSeconds = durationSeconds(absentStarted.duration(to: clock.now))
        let absentCount = absentMap.rowCount
        absentMap.close()

        let after = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(before[.size] as? NSNumber, after[.size] as? NSNumber)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
        XCTAssertFalse(engine.hasUnsavedChanges)
        print(
            "LighTxt CSV filtering release QA: bytes=\(snapshot.byteCount), "
                + "records=\(totalRecords), distinctColumn=\(distinctColumn), "
                + "npiColumn=\(npiColumn), indexSeconds=\(indexSeconds), "
                + "legacyDistinctSeconds=\(legacyDistinctSeconds), "
                + "projectedDistinctSeconds=\(projectedDistinctSeconds), "
                + "distinctScanned=\(projectedDistinct.scannedRecordCount), "
                + "distinctCount=\(projectedDistinct.values.count), "
                + "legacyExactNPISeconds=\(legacyNPISeconds), "
                + "projectedExactNPISeconds=\(projectedNPISeconds), "
                + "exactNPICount=\(projectedNPICount), "
                + "absentFilterSeconds=\(absentSeconds), absentCount=\(absentCount)"
        )
    }

    private func assertScannerParity(
        _ source: Data,
        readChunkByteCount: Int,
        checkpointInterval: Int64,
        maximumCheckpointCount: Int
    ) throws {
        let engine = FileBackedPieceTable(empty: .init())
        try engine.insert(source, at: 0)
        let snapshot = try engine.snapshot()
        func makeIndex(accelerated: Bool) throws -> CSVRowIndex {
            try CSVRowIndex(
                snapshot: snapshot,
                configuration: .init(
                    readChunkByteCount: readChunkByteCount,
                    initialCheckpointRecordInterval: checkpointInterval,
                    maximumCheckpointCount: maximumCheckpointCount,
                    allowsAcceleratedScanner: accelerated
                )
            )
        }
        let native = try makeIndex(accelerated: true)
        let swift = try makeIndex(accelerated: false)
        let nativeResult = try native.scanToEnd()
        let swiftResult = try swift.scanToEnd()
        XCTAssertEqual(nativeResult.progress, swiftResult.progress)
        let recordCount = nativeResult.progress.totalRecordCount ?? 0
        XCTAssertEqual(
            try native.recordLocations(startingAt: 0, limit: Int(recordCount)),
            try swift.recordLocations(startingAt: 0, limit: Int(recordCount))
        )
    }
}

private final class MaximumReadRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedMaximum: Int64 = 0
    private var storedReadCount = 0

    var maximum: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return storedMaximum
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedReadCount
    }

    func observe(_ count: Int64) {
        lock.lock()
        storedMaximum = max(storedMaximum, count)
        storedReadCount += 1
        lock.unlock()
    }
}

private final class CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelAfterChecks: Int
    private var storedCheckCount = 0

    init(cancelAfterChecks: Int) {
        self.cancelAfterChecks = cancelAfterChecks
    }

    var checkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCheckCount
    }

    func shouldCancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        storedCheckCount += 1
        return storedCheckCount >= cancelAfterChecks
    }
}

private struct CSVScannerRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}

private func durationSeconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
}
