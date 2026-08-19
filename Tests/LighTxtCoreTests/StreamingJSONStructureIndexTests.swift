import XCTest
import Darwin
import LighTxtJSONAccelerator
@testable import LighTxt

final class StreamingJSONStructureIndexTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LighTxtJSONIndexTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }

    func testFullScanAndLazyPagesIncludePrimitiveChildren() throws {
        let source = #"{"na\u006de":"x","items":[1,true,null,{"z":"v"}],"empty":[]}"#
        let index = try makeIndex(source)

        XCTAssertEqual(index.sourceByteCount, Int64(source.utf8.count))
        XCTAssertEqual(index.indexedContainerCount, 4)
        XCTAssertEqual(index.parsedValueCount, 9)
        XCTAssertEqual(index.diagnosticCount, 0)
        XCTAssertFalse(index.containsErrors)
        XCTAssertEqual(index.documentRoot.childCount, 1)

        let roots = try index.children(of: index.documentRoot)
        let object = try XCTUnwrap(roots.nodes.first)
        XCTAssertEqual(object.kind, .object)
        XCTAssertEqual(object.childCount, 3)
        XCTAssertNil(roots.nextCursor)

        let firstPage = try index.children(of: object, limit: 2)
        XCTAssertEqual(firstPage.nodes.count, 2)
        XCTAssertEqual(firstPage.firstChildOrdinal, 0)
        let namePreview = try index.preview(for: firstPage.nodes[0])
        XCTAssertEqual(namePreview.key, "name")
        XCTAssertEqual(namePreview.value, "x")
        XCTAssertFalse(namePreview.keyWasTruncated)

        let array = firstPage.nodes[1]
        XCTAssertEqual(array.kind, .array)
        XCTAssertEqual(array.childCount, 4)
        let secondPage = try index.children(
            of: object,
            cursor: try XCTUnwrap(firstPage.nextCursor),
            limit: 2
        )
        XCTAssertEqual(secondPage.firstChildOrdinal, 2)
        XCTAssertEqual(secondPage.nodes.map(\.kind), [.array])
        XCTAssertNil(secondPage.nextCursor)

        let arrayPage1 = try index.children(of: array, limit: 2)
        XCTAssertEqual(arrayPage1.nodes.map(\.kind), [.number, .boolean])
        let arrayPage2 = try index.children(
            of: array,
            cursor: try XCTUnwrap(arrayPage1.nextCursor),
            limit: 2
        )
        XCTAssertEqual(arrayPage2.firstChildOrdinal, 2)
        XCTAssertEqual(arrayPage2.nodes.map(\.kind), [.null, .object])
        XCTAssertNil(arrayPage2.nextCursor)
    }

    func testAcceleratedMultiKeyObjectPreservesFirstChildAndMonotonicProgress() throws {
        let source = #"{"first":1,"second":{"name":"two"},"third":[true,false]}"#
        var processed: [Int64] = []
        var values: [Int64] = []
        let index = try makeIndex(
            source,
            progress: { update in
                processed.append(update.processedBytes)
                values.append(update.parsedValueCount)
            }
        )
        XCTAssertTrue(index.usedAcceleratedParser)
        XCTAssertEqual(processed, processed.sorted())
        XCTAssertEqual(values, values.sorted())
        let object = try XCTUnwrap(index.children(of: index.documentRoot).nodes.first)
        let children = try index.children(of: object, limit: 10).nodes
        XCTAssertEqual(
            try children.map { try index.preview(for: $0).key },
            ["first", "second", "third"]
        )
        XCTAssertEqual(children.map(\.kind), [.number, .object, .array])
    }

    func testInvalidNumberAndStringEscapeFallBackToDiagnosticParser() throws {
        for source in [#"{"number":01}"#, #"{"string":"bad\q"}"#] {
            let index = try makeIndex(source)
            XCTAssertFalse(index.usedAcceleratedParser)
            XCTAssertTrue(index.containsErrors)
            XCTAssertGreaterThan(index.diagnosticCount, 0)
        }
    }

    func testForcedNative64RejectsEveryMalformedLexicalAndStructuralClass() throws {
        let malformed = [
            "", " ", "[", "{", "]", "}", "[,]", "[,1]", "[1,]", "[1 2]",
            #"{"a":1,}"#, #"{"a" 1}"#, #"{"a":}"#, #"{"a",1}"#,
            #"{"a":1 "b":2}"#, #"{"a":1]"#, "[1}", "true false", #"{1:2}"#,
            "tru", "truex", "fals", "false0", "nul", "nullx",
            "+1", ".1", "1.", "01", "-01", "1e", "1e+", "--1", "NaN",
            "Infinity", "0x1", "1a", #""unterminated"#, #""bad\q"#,
            #""bad\u12x4"#
        ]
        for source in malformed {
            let data = Data(source.utf8)
            let result = forcedNative64Result(data).result
            XCTAssertEqual(
                result.status,
                UInt32(LighTxtJSONAcceleratorInvalidJSON),
                "native64 accepted malformed JSON: \(source.debugDescription)"
            )
            let swift = try makeIndex(
                data,
                configuration: .init(allowsAcceleratedValidJSON: false)
            )
            XCTAssertTrue(swift.containsErrors, "Swift accepted malformed JSON: \(source)")
        }

        let rawControl = Data([0x22, 0x1f, 0x22])
        let invalidUTF8 = Data([0x22, 0xc0, 0xaf, 0x22])
        for data in [rawControl, invalidUTF8] {
            XCTAssertEqual(
                forcedNative64Result(data).result.status,
                UInt32(LighTxtJSONAcceleratorInvalidJSON)
            )
            let swift = try makeIndex(
                data,
                configuration: .init(allowsAcceleratedValidJSON: false)
            )
            XCTAssertTrue(swift.containsErrors)
        }
    }

    func testForcedNative64AcceptsJSONNumberAndStringGrammarEdges() throws {
        let valid = [
            "0", "-0", "1", "-1", "10", "1.0", "-0.125", "1e2", "1E+2",
            "1e-2", #""plain""#, #""escaped\\\"\/\b\f\n\r\t""#,
            #""unicode \u2603""#, #"{"empty":[],"object":{},"values":[true,false,null]}"#
        ]
        for source in valid {
            let data = Data(source.utf8)
            _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            XCTAssertEqual(
                forcedNative64Result(data).result.status,
                UInt32(LighTxtJSONAcceleratorSuccess),
                "native64 rejected valid JSON: \(source)"
            )
        }
    }

    func testForcedNative64MatchesSIMDAndSwiftRecordsOnRandomizedValidJSON() throws {
        var random = JSONTestRandom(seed: 0x64b1_7f00_d15c_a11e)
        for iteration in 0..<100 {
            let value = random.value(depth: 0)
            let data = try JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys, .fragmentsAllowed]
            )
            let native = forcedNative64Result(data)
            XCTAssertEqual(native.result.status, UInt32(LighTxtJSONAcceleratorSuccess))
            let swift = try makeIndex(
                data,
                configuration: .init(allowsAcceleratedValidJSON: false)
            )
            XCTAssertEqual(swift.indexedContainerCount, Int64(native.result.containerCount))
            XCTAssertEqual(swift.parsedValueCount, Int64(native.result.valueCount))
            XCTAssertEqual(swift.maximumNestingDepth, Int64(native.result.maximumDepth))
            let reference = try swiftContainerRecords(in: swift)
            XCTAssertEqual(reference.count, Int(native.result.containerCount))
            for ordinal in reference.indices {
                let left = native.records[ordinal]
                let right = reference[ordinal]
                XCTAssertEqual(left.start, right.start, "iteration \(iteration), record \(ordinal)")
                XCTAssertEqual(left.end, right.end, "iteration \(iteration), record \(ordinal)")
                XCTAssertEqual(left.firstChildStart, right.firstChildStart)
                XCTAssertEqual(left.childCount, right.childCount)
                XCTAssertEqual(left.metadata, right.metadata)
            }
        }
    }

    func testForcedNative64DepthCapacityAndCancellationGuards() {
        let nested = Data((String(repeating: "[", count: 9) + "0"
            + String(repeating: "]", count: 9)).utf8)
        XCTAssertEqual(
            forcedNative64Result(nested, maximumDepth: 8).result.status,
            UInt32(LighTxtJSONAcceleratorUnsupportedSize)
        )

        XCTAssertEqual(
            forcedNative64Result(Data("[[],[]]".utf8), recordCapacity: 1).result.status,
            UInt32(LighTxtJSONAcceleratorInsufficientRecordCapacity)
        )

        let cancellation = NativeJSONCancellationContext()
        let cancelled = acceleratorResult(
            Data(#"{"items":[1,2,3]}"#.utf8),
            forceNative64: true,
            callback: nativeJSONCancellationCallback,
            context: Unmanaged.passUnretained(cancellation).toOpaque()
        )
        XCTAssertEqual(cancelled.result.status, UInt32(LighTxtJSONAcceleratorCancelled))
        XCTAssertGreaterThan(cancellation.callbackCount, 0)
    }

    func testResidentSourceAndIndexCanBePurgedWithoutInvalidatingPages() throws {
        let source = #"{"a":[{"id":1},{"id":2}],"b":"value"}"#
        let index = try makeIndex(source)
        XCTAssertTrue(index.usedAcceleratedParser)
        XCTAssertGreaterThan(index.residentSourceByteCount, 0)
        XCTAssertGreaterThan(index.residentIndexByteCount, 0)
        let reclaimed = try index.purgeResidentMemory()
        XCTAssertGreaterThan(reclaimed, 0)
        XCTAssertEqual(index.residentSourceByteCount, 0)
        XCTAssertEqual(index.residentIndexByteCount, 0)
        let root = try XCTUnwrap(index.children(of: index.documentRoot).nodes.first)
        XCTAssertEqual(try index.children(of: root).nodes.count, 2)
    }

    func testJSONCopyTextIsDeterministicAndBoundedByVisibleCharactersAndSourceBytes() throws {
        let source = "{\"huge\":{\"value\":\""
            + String(repeating: "a", count: 200_000)
            + "\"},\"nothing\":null}"
        let index = try makeIndex(source)
        let root = try XCTUnwrap(index.children(of: index.documentRoot).nodes.first)
        let rootChildren = try index.children(of: root).nodes
        let hugeObject = try XCTUnwrap(rootChildren.first)
        let hugeValue = try XCTUnwrap(index.children(of: hugeObject).nodes.first)
        let nullValue = try XCTUnwrap(rootChildren.last)

        let firstObjectCopy = try index.copyText(for: hugeObject, kind: .containerJSON)
        let secondObjectCopy = try index.copyText(for: hugeObject, kind: .containerJSON)
        XCTAssertEqual(firstObjectCopy, secondObjectCopy)
        XCTAssertEqual(firstObjectCopy.text.count, 10_000)
        XCTAssertTrue(firstObjectCopy.text.hasSuffix("…"))
        XCTAssertTrue(firstObjectCopy.wasTruncated)
        XCTAssertEqual(firstObjectCopy.sourceByteCount, 64 << 10)

        let valueCopy = try index.copyText(for: hugeValue, kind: .scalarValue)
        XCTAssertEqual(valueCopy.text.count, 10_000)
        XCTAssertFalse(valueCopy.text.hasPrefix("\""))
        XCTAssertTrue(valueCopy.text.hasSuffix("…"))
        XCTAssertTrue(valueCopy.wasTruncated)
        XCTAssertEqual(valueCopy.sourceByteCount, 64 << 10)

        let nullCopy = try index.copyText(for: nullValue, kind: .scalarValue)
        XCTAssertEqual(nullCopy.text, "null")
        XCTAssertFalse(nullCopy.wasTruncated)
        XCTAssertLessThanOrEqual(nullCopy.text.count, 10_000)
    }

    func testJSONPathUsesExactSourceKeysAndArrayOrdinalsWithoutDisplayTruncation() throws {
        let longKey = "a display key " + String(repeating: "x", count: 180)
        let object: [String: Any] = [
            longKey: [
                "display key": [
                    ["a.b\"c": 42],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let index = try makeIndex(data)
        let root = try XCTUnwrap(index.children(of: index.documentRoot).nodes.first)
        let longKeyNode = try XCTUnwrap(index.children(of: root).nodes.first)
        let displayKeyNode = try XCTUnwrap(index.children(of: longKeyNode).nodes.first)
        let itemNode = try XCTUnwrap(index.children(of: displayKeyNode).nodes.first)
        let quotedKeyNode = try XCTUnwrap(index.children(of: itemNode).nodes.first)

        let path = try index.jsonPath(for: [
            .member(longKeyNode),
            .member(displayKeyNode),
            .index(0),
            .member(quotedKeyNode),
        ])
        XCTAssertEqual(
            path,
            "$[\"\(longKey)\"][\"display key\"][0][\"a.b\\\"c\"]"
        )
        XCTAssertTrue(path.contains(longKey))

        XCTAssertThrowsError(
            try index.jsonPath(
                for: [.member(longKeyNode)],
                maximumSourceByteCount: 16
            )
        ) { error in
            XCTAssertEqual(error as? JSONStructureIndexError, .copyLimitExceeded)
        }
    }

    func testJSONCopyRejectsWrongKindsForeignNodesAndClosedIndexes() throws {
        let index = try makeIndex(#"{"value":1}"#)
        let root = try XCTUnwrap(index.children(of: index.documentRoot).nodes.first)
        let value = try XCTUnwrap(index.children(of: root).nodes.first)

        XCTAssertThrowsError(try index.copyText(for: root, kind: .scalarValue)) { error in
            XCTAssertEqual(error as? JSONStructureIndexError, .copyUnavailable)
        }
        XCTAssertThrowsError(try index.copyText(for: value, kind: .containerJSON)) { error in
            XCTAssertEqual(error as? JSONStructureIndexError, .copyUnavailable)
        }

        let otherIndex = try makeIndex(#"{"other":2}"#)
        let otherRoot = try XCTUnwrap(otherIndex.children(of: otherIndex.documentRoot).nodes.first)
        let otherValue = try XCTUnwrap(otherIndex.children(of: otherRoot).nodes.first)
        XCTAssertThrowsError(try index.jsonPath(for: [.member(otherValue)])) { error in
            XCTAssertEqual(error as? JSONStructureIndexError, .nodeBelongsToDifferentIndex)
        }

        index.close()
        XCTAssertThrowsError(try index.copyText(for: value, kind: .scalarValue)) { error in
            XCTAssertEqual(error as? JSONStructureIndexError, .closed)
        }
        XCTAssertThrowsError(try index.jsonPath(for: [])) { error in
            XCTAssertEqual(error as? JSONStructureIndexError, .closed)
        }
    }

    func testAcceleratorUsesNative64BitOffsetsBeyondSIMDDocumentBoundary() {
        XCTAssertEqual(
            StreamingJSONStructureIndexer.maximumSIMDDocumentValidationByteCount,
            Int64(UInt32.max)
        )
        XCTAssertGreaterThan(
            StreamingJSONStructureIndexer.maximumAcceleratedSourceByteCount,
            Int64(UInt32.max)
        )
        XCTAssertGreaterThan(StreamingJSONStructureIndexer.acceleratedSourcePaddingByteCount, 0)
        XCTAssertEqual(StreamingJSONStructureIndexer.acceleratedContainerRecordByteCount, 40)
        XCTAssertEqual(
            StreamingJSONStructureIndexer.acceleratedContainerRecordAlignment,
            MemoryLayout<Int64>.alignment
        )
    }

    func testNative64AdmissionUsesMeasuredLowerTransientWithoutAdmitting64GBMac() {
        let source = Int64(16_792_795_534)
        XCTAssertGreaterThanOrEqual(
            JSONAutomaticMemoryBudget.maximumSourceBytes(
                for: source,
                physicalMemory: UInt64(128) << 30,
                availableMemory: Int64(100) << 30
            ),
            source
        )
        XCTAssertLessThan(
            JSONAutomaticMemoryBudget.maximumSourceBytes(
                for: source,
                physicalMemory: UInt64(64) << 30,
                availableMemory: Int64(52) << 30
            ),
            source
        )
        XCTAssertLessThan(
            JSONAutomaticMemoryBudget.maximumSourceBytes(
                for: 3_530_392_986,
                physicalMemory: UInt64(32) << 30,
                availableMemory: Int64(28) << 30
            ),
            Int64(3_530_392_986)
        )
    }

    func testIncompleteJSONProducesExpandablePartialTreeAndDiagnostics() throws {
        let index = try makeIndex(#"{"a":[1,2,"#)
        XCTAssertTrue(index.containsErrors)
        XCTAssertGreaterThan(index.diagnosticCount, 0)

        let rootObject = try XCTUnwrap(index.children(of: index.documentRoot).nodes.first)
        XCTAssertFalse(rootObject.isComplete)
        let array = try XCTUnwrap(index.children(of: rootObject).nodes.first)
        XCTAssertEqual(array.kind, .array)
        XCTAssertFalse(array.isComplete)
        XCTAssertEqual(array.childCount, 2)
        XCTAssertEqual(try index.children(of: array).nodes.map(\.kind), [.number, .number])

        var diagnostics: [JSONStructureDiagnostic] = []
        var cursor: JSONStructureDiagnosticsCursor?
        repeat {
            let page = try index.diagnostics(cursor: cursor, limit: 1)
            diagnostics += page.diagnostics
            cursor = page.nextCursor
        } while cursor != nil
        XCTAssertTrue(diagnostics.contains { $0.kind == .unexpectedEndOfFile })
    }

    func testCancellationAndMonotonicProgress() throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("cancel.json")
        var data = Data("[".utf8)
        data.append(Data(repeating: 0x20, count: 2 << 20))
        data.append(contentsOf: Data("0]".utf8))
        try data.write(to: sourceURL)
        let snapshot = try FileBackedPieceTable(opening: sourceURL).snapshot()
        let token = CancellationToken()
        var updates: [Int64] = []

        XCTAssertThrowsError(
            try StreamingJSONStructureIndexer.build(
                snapshot: snapshot,
                generation: 3,
                configuration: .init(progressIntervalByteCount: 64 << 10),
                cancellation: token,
                progress: { update in
                    updates.append(update.processedBytes)
                    if update.processedBytes >= 128 << 10 { token.cancel() }
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(updates, updates.sorted())
        XCTAssertGreaterThanOrEqual(updates.last ?? 0, 128 << 10)
    }

    func testOldRevisionRemainsReadableUntilExplicitClose() throws {
        let url = temporaryDirectory.appendingPathComponent("revision.json")
        try Data(#"{"key":"old"}"#.utf8).write(to: url)
        let table = try FileBackedPieceTable(opening: url)
        let snapshot = try table.snapshot()
        let index = try StreamingJSONStructureIndexer.build(snapshot: snapshot, generation: 8)
        try table.replace(byteRange: 8..<11, withUTF8: "new")

        XCTAssertFalse(index.isCurrent(revision: try table.snapshot().revision, generation: 8))
        let object = try XCTUnwrap(index.children(of: index.documentRoot).nodes.first)
        let oldValue = try XCTUnwrap(index.children(of: object).nodes.first)
        XCTAssertEqual(try index.preview(for: oldValue).value, "old")

        index.close()
        XCTAssertFalse(index.isOpen)
        XCTAssertEqual(index.residentSourceByteCount, 0)
        XCTAssertEqual(index.residentIndexByteCount, 0)
        XCTAssertThrowsError(try index.children(of: index.documentRoot)) { error in
            XCTAssertEqual(error as? JSONStructureIndexError, .closed)
        }
    }

    func testDiagnosticRetentionHasHardCap() throws {
        let index = try makeIndex("] ] ] ] ]", configuration: .init(maximumStoredDiagnosticCount: 2))
        XCTAssertGreaterThan(index.diagnosticCount, 2)
        XCTAssertEqual(index.storedDiagnosticCount, 2)
        XCTAssertTrue(index.diagnosticsWereTruncated)
        XCTAssertEqual(try index.diagnostics(limit: 20).diagnostics.count, 2)
    }

    func testVirtualSourceBeyondFourGiBPreservesInt64Ranges() throws {
        let valueOffset = (Int64(4) << 30) + 12_345
        let source = VirtualHugeJSONSource(valueOffset: valueOffset)
        var progressOffsets: [Int64] = []
        let index = try StreamingJSONStructureIndexer.build(
            source: source,
            generation: 99,
            configuration: .init(progressIntervalByteCount: 64 << 10),
            progress: { progressOffsets.append($0.processedBytes) }
        )

        XCTAssertGreaterThan(index.sourceByteCount, Int64(UInt32.max))
        XCTAssertEqual(index.diagnosticCount, 0)
        XCTAssertEqual(index.indexedContainerCount, 1)
        XCTAssertEqual(progressOffsets, progressOffsets.sorted())
        XCTAssertEqual(progressOffsets.last, source.byteCount)

        let array = try XCTUnwrap(index.children(of: index.documentRoot).nodes.first)
        XCTAssertEqual(array.byteRange, 0..<source.byteCount)
        XCTAssertEqual(array.childCount, 1)
        let value = try XCTUnwrap(index.children(of: array).nodes.first)
        XCTAssertEqual(value.kind, .number)
        XCTAssertEqual(value.byteRange, valueOffset..<(valueOffset + 1))
    }

    func testContainerRecordsAcrossDirtyPageBoundaryRemainSearchable() throws {
        let childCount = 30_000
        var json = "["
        json.reserveCapacity(childCount * 3 + 1)
        for index in 0..<childCount {
            if index > 0 { json.append(",") }
            json.append("[]")
        }
        json.append("]")
        let index = try makeIndex(json)
        XCTAssertEqual(index.indexedContainerCount, Int64(childCount + 1))
        XCTAssertEqual(
            index.temporaryIndexByteCount,
            Int64(childCount + 1) * 40
        )
        let root = try XCTUnwrap(index.children(of: index.documentRoot).nodes.first)
        var cursor: JSONStructureChildrenCursor?
        var seen = 0
        var last: JSONStructureNode?
        repeat {
            let page = try index.children(of: root, cursor: cursor, limit: 1_024)
            seen += page.nodes.count
            last = page.nodes.last ?? last
            cursor = page.nextCursor
        } while cursor != nil
        XCTAssertEqual(seen, childCount)
        XCTAssertEqual(last?.kind, .array)
        XCTAssertEqual(last?.byteRange.upperBound, Int64(json.utf8.count - 1))
    }

    func testNestingBeyondResidentFrameLimitSpillsAndRestoresExactly() throws {
        let depth = 1_300
        let json = String(repeating: "[", count: depth)
            + "0"
            + String(repeating: "]", count: depth)
        let index = try makeIndex(json)
        XCTAssertFalse(index.usedAcceleratedParser)
        XCTAssertEqual(index.indexedContainerCount, Int64(depth))
        XCTAssertEqual(index.parsedValueCount, Int64(depth + 1))
        XCTAssertEqual(index.maximumNestingDepth, Int64(depth - 1))
        XCTAssertEqual(index.diagnosticCount, 0)
        XCTAssertFalse(index.containsErrors)
        let root = try XCTUnwrap(index.children(of: index.documentRoot).nodes.first)
        XCTAssertEqual(root.byteRange, 0..<Int64(json.utf8.count))
    }

    func testAcceleratorDepthCeilingFallsBackBeforeUnboundedStackGrowth() throws {
        let depth = 9
        let json = String(repeating: "[", count: depth)
            + "0"
            + String(repeating: "]", count: depth)
        let index = try makeIndex(
            json,
            configuration: .init(maximumAcceleratedNestingDepth: 8)
        )
        XCTAssertFalse(index.usedAcceleratedParser)
        XCTAssertFalse(index.containsErrors)
        XCTAssertEqual(index.maximumNestingDepth, Int64(depth - 1))
    }

    func testAcceleratedAndSwiftPathsReportIdenticalContainerDepth() throws {
        let source = #"{"root":[{"child":[{"leaf":1}]}]}"#
        let accelerated = try makeIndex(source)
        let swift = try makeIndex(
            source,
            configuration: .init(allowsAcceleratedValidJSON: false)
        )

        XCTAssertTrue(accelerated.usedAcceleratedParser)
        XCTAssertFalse(swift.usedAcceleratedParser)
        XCTAssertEqual(accelerated.maximumNestingDepth, 4)
        XCTAssertEqual(accelerated.maximumNestingDepth, swift.maximumNestingDepth)
        XCTAssertEqual(accelerated.indexedContainerCount, swift.indexedContainerCount)
        XCTAssertEqual(accelerated.parsedValueCount, swift.parsedValueCount)
    }

    func testRandomizedValidJSONTreeCountsAndRanges() throws {
        var random = JSONTestRandom(seed: 0x7a11_cafe_f00d_beef)
        for iteration in 0..<75 {
            let value = random.value(depth: 0)
            let data = try JSONSerialization.data(
                withJSONObject: value,
                options: [.sortedKeys, .fragmentsAllowed]
            )
            let index = try makeIndex(data)
            XCTAssertEqual(index.diagnosticCount, 0, "iteration \(iteration)")
            XCTAssertFalse(index.containsErrors, "iteration \(iteration)")

            var cursor: JSONStructureChildrenCursor?
            var seen: Int64 = 0
            repeat {
                let page = try index.children(of: index.documentRoot, cursor: cursor, limit: 3)
                seen += Int64(page.nodes.count)
                for node in page.nodes {
                    seen += try countDescendants(of: node, in: index)
                    XCTAssertGreaterThan(node.byteRange.upperBound, node.byteRange.lowerBound)
                    XCTAssertLessThanOrEqual(node.byteRange.upperBound, Int64(data.count))
                }
                cursor = page.nextCursor
            } while cursor != nil
            XCTAssertEqual(seen, index.parsedValueCount, "iteration \(iteration)")
        }
    }

    /// Read-only, opt-in release QA against the user's real multi-gigabyte file.
    func testReleaseQALargeJSONTarget() throws {
        guard let path = ProcessInfo.processInfo.environment["LIGHTXT_JSON_STRUCTURE_TARGET"] else {
            throw XCTSkip("Set LIGHTXT_JSON_STRUCTURE_TARGET for the multi-GB release scan")
        }
        let url = URL(fileURLWithPath: path)
        let attributesBefore = try FileManager.default.attributesOfItem(atPath: path)
        let table = try FileBackedPieceTable(opening: url)
        let snapshot = try table.snapshot()
        let residentBefore = currentResidentBytes()
        let started = ContinuousClock.now
        var previousProgress: Int64 = 0
        var progressCalls = 0
        var peakResident = residentBefore
        let index = try StreamingJSONStructureIndexer.build(
            snapshot: snapshot,
            generation: 1,
            progress: { update in
                XCTAssertGreaterThanOrEqual(update.processedBytes, previousProgress)
                previousProgress = update.processedBytes
                progressCalls += 1
                peakResident = max(peakResident, currentResidentBytes())
            }
        )
        let elapsed = started.duration(to: .now)
        let residentGrowth = max(0, currentResidentBytes() - residentBefore)
        let peakResidentGrowth = max(0, peakResident - residentBefore)

        XCTAssertEqual(previousProgress, snapshot.byteCount)
        XCTAssertGreaterThan(progressCalls, 1)
        XCTAssertFalse(index.containsErrors)
        XCTAssertEqual(index.diagnosticCount, 0)
        let rootPage = try index.children(of: index.documentRoot, limit: 8)
        XCTAssertFalse(rootPage.nodes.isEmpty)
        XCTAssertLessThanOrEqual(rootPage.nodes.first?.byteRange.upperBound ?? 0, snapshot.byteCount)
        if let root = rootPage.nodes.first, root.kind.isContainer {
            _ = try index.children(of: root, limit: 16)
        }
        let residentCeiling = snapshot.byteCount
            + index.temporaryIndexByteCount
            + Int64(512 << 20)
        XCTAssertLessThan(residentGrowth, residentCeiling)
        let attributesAfter = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual(attributesAfter[.size] as? NSNumber, attributesBefore[.size] as? NSNumber)
        XCTAssertEqual(
            attributesAfter[.modificationDate] as? Date,
            attributesBefore[.modificationDate] as? Date
        )
        XCTAssertEqual(attributesAfter[.systemFileNumber] as? NSNumber, attributesBefore[.systemFileNumber] as? NSNumber)
        print(
            "LIGHTXT_JSON_STRUCTURE_QA bytes=\(snapshot.byteCount) elapsed=\(elapsed) "
                + "sourcePreparationSeconds=\(index.sourcePreparationSeconds) "
                + "parserSeconds=\(index.parserSeconds) accelerated=\(index.usedAcceleratedParser) "
                + "nativeRecordBuildSeconds=\(index.nativeRecordBuildSeconds) "
                + "nativeValidationSeconds=\(index.nativeValidationSeconds) "
                + "indexPublicationSeconds=\(index.indexPublicationSeconds) "
                + "containers=\(index.indexedContainerCount) values=\(index.parsedValueCount) "
                + "indexBytes=\(index.temporaryIndexByteCount) maxDepth=\(index.maximumNestingDepth) "
                + "residentSource=\(index.residentSourceByteCount) residentIndex=\(index.residentIndexByteCount) "
                + "residentGrowth=\(residentGrowth) peakResidentGrowth=\(peakResidentGrowth)"
        )

        if ProcessInfo.processInfo.environment["LIGHTXT_JSON_STRUCTURE_PURGE_QA"] == "1" {
            let residentBeforePurge = currentResidentBytes()
            let reportedResidentBeforePurge = index.residentSourceByteCount
                + index.residentIndexByteCount
            let reclaimed = try index.purgeResidentMemory()
            XCTAssertEqual(index.residentSourceByteCount, 0)
            XCTAssertEqual(index.residentIndexByteCount, 0)
            XCTAssertGreaterThanOrEqual(reclaimed, reportedResidentBeforePurge)

            let rootAfterPurge = try XCTUnwrap(
                index.children(of: index.documentRoot, limit: 8).nodes.first
            )
            if rootAfterPurge.kind.isContainer {
                XCTAssertFalse(try index.children(of: rootAfterPurge, limit: 16).nodes.isEmpty)
            }
            let residentAfterPurge = currentResidentBytes()
            XCTAssertLessThan(residentAfterPurge, residentBeforePurge)

            index.close()
            XCTAssertFalse(index.isOpen)
            XCTAssertEqual(index.residentSourceByteCount, 0)
            XCTAssertEqual(index.residentIndexByteCount, 0)
            print(
                "LIGHTXT_JSON_PURGE_QA reclaimed=\(reclaimed) "
                    + "residentBefore=\(residentBeforePurge) residentAfter=\(residentAfterPurge)"
            )
        }
    }

    /// Faster representative benchmark over a real-file prefix. The prefix can
    /// end mid-value; this lane measures the identical scanner/index density and
    /// intentionally accepts the resulting EOF diagnostic.
    func testReleaseQALargeJSONPrefixPerformanceWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["LIGHTXT_JSON_STRUCTURE_PREFIX_TARGET"] else {
            throw XCTSkip("Set LIGHTXT_JSON_STRUCTURE_PREFIX_TARGET for prefix performance QA")
        }
        let requested = Int64(
            ProcessInfo.processInfo.environment["LIGHTXT_JSON_STRUCTURE_PREFIX_BYTES"] ?? ""
        ) ?? (1 << 30)
        let snapshot = try FileBackedPieceTable(opening: URL(fileURLWithPath: path)).snapshot()
        let byteCount = min(snapshot.byteCount, max(1 << 20, requested))
        let source = SnapshotPrefixJSONSource(snapshot: snapshot, byteCount: byteCount)
        let residentBefore = currentResidentBytes()
        var peakResident = residentBefore
        let clock = ContinuousClock()
        let started = clock.now
        let index = try StreamingJSONStructureIndexer.build(
            source: source,
            generation: 1,
            progress: { _ in peakResident = max(peakResident, currentResidentBytes()) }
        )
        let elapsed = started.duration(to: clock.now)
        let seconds = durationSeconds(elapsed)
        XCTAssertEqual(index.sourceByteCount, byteCount)
        XCTAssertGreaterThan(index.indexedContainerCount, 0)
        XCTAssertLessThan(max(0, peakResident - residentBefore), 128 << 20)
        print(
            "LIGHTXT_JSON_PREFIX_QA bytes=\(byteCount) seconds=\(seconds) "
                + "MiBps=\((Double(byteCount) / Double(1 << 20)) / max(0.000_001, seconds)) "
                + "containers=\(index.indexedContainerCount) values=\(index.parsedValueCount) "
                + "indexBytes=\(index.temporaryIndexByteCount) "
                + "peakResidentGrowth=\(max(0, peakResident - residentBefore))"
        )
    }

    private func countDescendants(
        of node: JSONStructureNode,
        in index: JSONStructureIndex
    ) throws -> Int64 {
        guard node.kind.isContainer else { return 0 }
        var result: Int64 = 0
        var cursor: JSONStructureChildrenCursor?
        repeat {
            let page = try index.children(of: node, cursor: cursor, limit: 3)
            result += Int64(page.nodes.count)
            for child in page.nodes { result += try countDescendants(of: child, in: index) }
            cursor = page.nextCursor
        } while cursor != nil
        return result
    }

    private func makeIndex(
        _ text: String,
        configuration: JSONStructureIndexConfiguration = .default,
        progress: ((JSONStructureIndexProgress) -> Void)? = nil
    ) throws -> JSONStructureIndex {
        try makeIndex(Data(text.utf8), configuration: configuration, progress: progress)
    }

    private func makeIndex(
        _ data: Data,
        configuration: JSONStructureIndexConfiguration = .default,
        progress: ((JSONStructureIndexProgress) -> Void)? = nil
    ) throws -> JSONStructureIndex {
        let url = temporaryDirectory.appendingPathComponent("input-\(UUID().uuidString).json")
        try data.write(to: url)
        let snapshot = try FileBackedPieceTable(opening: url).snapshot()
        return try StreamingJSONStructureIndexer.build(
            snapshot: snapshot,
            generation: 1,
            configuration: configuration,
            progress: progress
        )
    }

    private func forcedNative64Result(
        _ data: Data,
        recordCapacity: Int? = nil,
        maximumDepth: UInt64 = 1_024
    ) -> (result: LighTxtJSONAcceleratorResult, records: [LighTxtJSONContainerRecord]) {
        acceleratorResult(
            data,
            forceNative64: true,
            recordCapacity: recordCapacity,
            maximumDepth: maximumDepth
        )
    }

    private func acceleratorResult(
        _ data: Data,
        forceNative64: Bool,
        recordCapacity requestedCapacity: Int? = nil,
        maximumDepth: UInt64 = 1_024,
        callback: LighTxtJSONAcceleratorProgress? = nil,
        context: UnsafeMutableRawPointer? = nil
    ) -> (result: LighTxtJSONAcceleratorResult, records: [LighTxtJSONContainerRecord]) {
        let padding = Int(LighTxtJSONAcceleratorRequiredPadding())
        var source = Array(data)
        source.append(contentsOf: repeatElement(0, count: padding))
        let capacity = max(1, requestedCapacity ?? (data.count / 2 + 2))
        var records = Array(
            repeating: LighTxtJSONContainerRecord(
                start: 0,
                end: 0,
                firstChildStart: 0,
                childCount: 0,
                metadata: 0
            ),
            count: capacity
        )
        let result = source.withUnsafeBufferPointer { sourceBytes in
            records.withUnsafeMutableBufferPointer { recordBytes in
                let function = forceNative64
                    ? LighTxtBuildJSONContainerIndexNative64
                    : LighTxtBuildJSONContainerIndex
                return function(
                    sourceBytes.baseAddress,
                    UInt64(data.count),
                    UInt64(source.count),
                    recordBytes.baseAddress,
                    UInt64(capacity),
                    maximumDepth,
                    callback,
                    context
                )
            }
        }
        return (result, records)
    }

    private func swiftContainerRecords(
        in index: JSONStructureIndex
    ) throws -> [LighTxtJSONContainerRecord] {
        var result: [LighTxtJSONContainerRecord] = []
        func children(of node: JSONStructureNode) throws -> [JSONStructureNode] {
            var result: [JSONStructureNode] = []
            var cursor: JSONStructureChildrenCursor?
            repeat {
                let page = try index.children(of: node, cursor: cursor, limit: 1_024)
                result.append(contentsOf: page.nodes)
                cursor = page.nextCursor
            } while cursor != nil
            return result
        }
        func visit(_ node: JSONStructureNode) throws {
            guard node.kind == .object || node.kind == .array else { return }
            let directChildren = try children(of: node)
            let firstChildStart: Int64
            if let first = directChildren.first {
                firstChildStart = node.kind == .object
                    ? first.keyByteRange?.lowerBound ?? first.byteRange.lowerBound
                    : first.byteRange.lowerBound
            } else {
                firstChildStart = -1
            }
            let metadata = Int64(node.kind.rawValue)
                | (Int64(1) << 8)
                | (node.depth << 16)
            result.append(
                LighTxtJSONContainerRecord(
                    start: node.byteRange.lowerBound,
                    end: node.byteRange.upperBound,
                    firstChildStart: firstChildStart,
                    childCount: node.childCount ?? 0,
                    metadata: metadata
                )
            )
            for child in directChildren { try visit(child) }
        }
        for root in try children(of: index.documentRoot) { try visit(root) }
        return result
    }
}

private final class NativeJSONCancellationContext {
    var callbackCount = 0
}

private let nativeJSONCancellationCallback: LighTxtJSONAcceleratorProgress = {
    context,
    _,
    _,
    _,
    _ in
    guard let context else { return false }
    let state = Unmanaged<NativeJSONCancellationContext>
        .fromOpaque(context)
        .takeUnretainedValue()
    state.callbackCount += 1
    return false
}

private final class VirtualHugeJSONSource: JSONStructureSource, @unchecked Sendable {
    let valueOffset: Int64
    let byteCount: Int64
    let revision: UInt64 = 44

    init(valueOffset: Int64) {
        self.valueOffset = valueOffset
        self.byteCount = valueOffset + 2
    }

    func forEachSegment(_ body: (JSONIndexInputSegment) throws -> Void) throws {
        var opening: UInt8 = 0x5b
        try withUnsafeBytes(of: &opening) { try body(.bytes($0)) }
        try body(.repeatedASCII(byte: 0x20, count: valueOffset - 1))
        var ending: (UInt8, UInt8) = (0x30, 0x5d)
        try withUnsafeBytes(of: &ending) { try body(.bytes($0)) }
    }

    func data(in range: Range<Int64>) throws -> Data {
        guard range.lowerBound >= 0, range.upperBound <= byteCount else {
            throw LighTxtCoreError.invalidByteRange(requested: range, byteCount: byteCount)
        }
        return Data((range.lowerBound..<range.upperBound).map { offset in
            if offset == 0 { return UInt8(0x5b) }
            if offset == valueOffset { return UInt8(0x30) }
            if offset == valueOffset + 1 { return UInt8(0x5d) }
            return UInt8(0x20)
        })
    }
}

private final class SnapshotPrefixJSONSource: JSONStructureSource, @unchecked Sendable {
    let snapshot: DocumentSnapshot
    let byteCount: Int64
    var revision: UInt64 { snapshot.revision }

    init(snapshot: DocumentSnapshot, byteCount: Int64) {
        self.snapshot = snapshot
        self.byteCount = byteCount
    }

    func forEachSegment(_ body: (JSONIndexInputSegment) throws -> Void) throws {
        try snapshot.forEachByteSlice(in: 0..<byteCount) { try body(.bytes($0)) }
    }

    func data(in range: Range<Int64>) throws -> Data {
        guard range.lowerBound >= 0, range.upperBound <= byteCount else {
            throw LighTxtCoreError.invalidByteRange(requested: range, byteCount: byteCount)
        }
        return try snapshot.data(in: range)
    }
}

private struct JSONTestRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    mutating func value(depth: Int) -> Any {
        let choice = depth >= 4 ? Int(next() % 4) : Int(next() % 7)
        switch choice {
        case 0: return NSNull()
        case 1: return (next() & 1) == 0
        case 2: return Int(next() % 10_000)
        case 3: return "s-\(next() % 1_000)-☁️"
        case 4:
            return (0..<Int(next() % 6)).map { _ in value(depth: depth + 1) }
        default:
            var result: [String: Any] = [:]
            for item in 0..<Int(next() % 6) {
                result["k\(item)-\(next() % 100)"] = value(depth: depth + 1)
            }
            return result
        }
    }
}

private func currentResidentBytes() -> Int64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
        }
    }
    return result == KERN_SUCCESS ? Int64(info.resident_size) : 0
}

private func durationSeconds(_ duration: Duration) -> Double {
    let components = duration.components
    return Double(components.seconds) + Double(components.attoseconds) / 1e18
}
