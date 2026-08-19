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

    var maximum: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return storedMaximum
    }

    func observe(_ count: Int64) {
        lock.lock()
        storedMaximum = max(storedMaximum, count)
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
