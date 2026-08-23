import Darwin
import Foundation
import XCTest
@testable import LighTxt

final class CSVFilterV2Tests: XCTestCase {
    func testContainsAndSelectedValuesComposeAsIntersectionWithORWithinSelection() throws {
        let fixture = try makeFixture(
            "id,fruit,region\r\n"
                + "1,Apple,East\r\n"
                + "2,apricot,East\r\n"
                + "3,Banana,East\r\n"
                + "4,Apple,West\r\n"
        )
        let map = try CSVRowQueryEngine.execute(
            snapshot: fixture.snapshot,
            index: fixture.index,
            query: CSVRowQuery(firstRecord: 1, filters: [
                CSVColumnFilter(
                    column: 1,
                    containsText: "ap",
                    selectedValues: ["Apple", "Banana"]
                ),
                CSVColumnFilter(
                    column: 2,
                    containsText: "",
                    selectedValues: ["East"]
                ),
            ])
        )
        defer { map.close() }

        // Apple/Banana is OR, the contains clause narrows that to Apple, and
        // the independent region column intersects it down to source row 1.
        XCTAssertEqual(try map.records(in: 0..<map.rowCount), [1])
    }

    func testContainsIsCaseInsensitiveWhilePickerSelectionIsExactByDefault() throws {
        let fixture = try makeFixture("value\nA\na\nALPHA\n")
        let exact = try CSVRowQueryEngine.execute(
            snapshot: fixture.snapshot,
            index: fixture.index,
            query: CSVRowQuery(firstRecord: 1, filters: [
                CSVColumnFilter(column: 0, containsText: "a", selectedValues: ["A"]),
            ])
        )
        defer { exact.close() }
        XCTAssertEqual(try exact.records(in: 0..<exact.rowCount), [1])

        let insensitiveSelection = try CSVRowQueryEngine.execute(
            snapshot: fixture.snapshot,
            index: try CSVRowIndex(snapshot: fixture.snapshot),
            query: CSVRowQuery(firstRecord: 1, filters: [
                CSVColumnFilter(
                    column: 0,
                    containsText: "a",
                    selectedValues: ["A"],
                    containsCaseSensitive: false,
                    selectedValuesCaseSensitive: false
                ),
            ])
        )
        defer { insensitiveSelection.close() }
        XCTAssertEqual(
            try insensitiveSelection.records(in: 0..<insensitiveSelection.rowCount),
            [1, 2]
        )
    }

    func testFilteringHandlesBOMQuotedMultilineUnicodeEmptyAndMissingValues() throws {
        var source = Data([0xEF, 0xBB, 0xBF])
        let csv = "id,note,tag\r\n"
            + "1,\"héllo,\n世界\",x\r\n"
            + "2,plain,\r\n"
            + "3,ragged\r\n"
            + "4,\"héllo,\n世界\",y\r\n"
        source.append(Data(csv.utf8))
        let fixture = try makeFixture(source)
        let multiline = try CSVRowQueryEngine.execute(
            snapshot: fixture.snapshot,
            index: fixture.index,
            query: CSVRowQuery(firstRecord: 1, filters: [
                CSVColumnFilter(
                    column: 1,
                    containsText: "世界",
                    selectedValues: ["héllo,\n世界"]
                ),
            ])
        )
        defer { multiline.close() }
        XCTAssertEqual(try multiline.records(in: 0..<multiline.rowCount), [1, 4])

        let emptyOrMissing = try CSVRowQueryEngine.execute(
            snapshot: fixture.snapshot,
            index: try CSVRowIndex(snapshot: fixture.snapshot),
            query: CSVRowQuery(firstRecord: 1, filters: [
                CSVColumnFilter(column: 2, containsText: "", selectedValues: [""]),
            ])
        )
        defer { emptyOrMissing.close() }
        XCTAssertEqual(
            try emptyOrMissing.records(in: 0..<emptyOrMissing.rowCount),
            [2, 3]
        )
    }

    func testCompletedIndexStreamingProjectionMatchesGrowingIndexAcrossRFCEdges() throws {
        var source = Data([0xEF, 0xBB, 0xBF])
        source.append(Data((
            "id;note;group;extra\r\n"
                + "1;\"hello;\"\"world\"\"\r\ncontinued\";East;\r\n"
                + "2;;West\r\n"
                + "3;plain;;tail\r"
                + "4;\"last\nline\";East;tail"
        ).utf8))
        let engine = FileBackedPieceTable(empty: .init())
        try engine.insert(source, at: 0)
        let snapshot = try engine.snapshot()
        let indexConfiguration = CSVRowIndex.Configuration(
            delimiter: 0x3B,
            readChunkByteCount: 7,
            initialCheckpointRecordInterval: 2,
            maximumCheckpointCount: 32,
            allowsAcceleratedScanner: false
        )

        func makeIndex(complete: Bool) throws -> CSVRowIndex {
            let index = try CSVRowIndex(
                snapshot: snapshot,
                configuration: indexConfiguration
            )
            if complete { _ = try index.scanToEnd() }
            return index
        }

        let query = CSVRowQuery(
            firstRecord: 1,
            filters: [
                CSVColumnFilter(column: 2, containsText: "", selectedValues: ["East"]),
            ],
            sortDescriptors: [CSVSortDescriptor(column: 1)]
        )
        let growingMap = try CSVRowQueryEngine.execute(
            snapshot: snapshot,
            index: makeIndex(complete: false),
            query: query,
            configuration: .init(pageRecordCount: 2)
        )
        defer { growingMap.close() }
        let completedMap = try CSVRowQueryEngine.execute(
            snapshot: snapshot,
            index: makeIndex(complete: true),
            query: query,
            configuration: .init(pageRecordCount: 2)
        )
        defer { completedMap.close() }
        XCTAssertEqual(
            try completedMap.records(in: 0..<completedMap.rowCount),
            try growingMap.records(in: 0..<growingMap.rowCount)
        )
        XCTAssertEqual(try completedMap.records(in: 0..<completedMap.rowCount), [1, 4])

        let baseFilters = [CSVColumnFilter(column: 1, predicate: .isNotEmpty)]
        let growingUnique = try CSVUniqueValueProvider.collect(
            snapshot: snapshot,
            index: makeIndex(complete: false),
            column: 2,
            firstRecord: 1,
            baseFilters: baseFilters,
            configuration: .init(pageRecordCount: 2)
        )
        let completedUnique = try CSVUniqueValueProvider.collect(
            snapshot: snapshot,
            index: makeIndex(complete: true),
            column: 2,
            firstRecord: 1,
            baseFilters: baseFilters,
            configuration: .init(pageRecordCount: 2)
        )
        XCTAssertEqual(completedUnique, growingUnique)
        XCTAssertEqual(completedUnique.values, ["", "East"])

        let growingIncludingBOMHeader = try CSVUniqueValueProvider.collect(
            snapshot: snapshot,
            index: makeIndex(complete: false),
            column: 0,
            firstRecord: 0
        )
        let completedIncludingBOMHeader = try CSVUniqueValueProvider.collect(
            snapshot: snapshot,
            index: makeIndex(complete: true),
            column: 0,
            firstRecord: 0
        )
        XCTAssertEqual(completedIncludingBOMHeader, growingIncludingBOMHeader)
        XCTAssertTrue(completedIncludingBOMHeader.values.contains("id"))
    }

    func testCompletedIndexStreamingProjectionMatchesScalarAcrossBackingSlices() throws {
        let sliceBoundary = 1 << 20
        let header = Data("id,note\r\n".utf8)
        let rowPrefix = Data("1,\"".utf8)
        var source = header
        source.append(rowPrefix)

        // Split an escaped quote pair across the first one-MiB backing slice.
        source.append(Data(
            repeating: 0x78,
            count: sliceBoundary - 1 - source.count
        ))
        source.append(contentsOf: [0x22, 0x22])
        XCTAssertEqual(source.count, sliceBoundary + 1)

        // Split an embedded CRLF across the second boundary. It remains field
        // data because the quoted record is still open.
        source.append(Data(
            repeating: 0x79,
            count: (sliceBoundary * 2) - 1 - source.count
        ))
        source.append(contentsOf: [0x0D, 0x0A])
        XCTAssertEqual(source.count, (sliceBoundary * 2) + 1)

        // Split the actual record terminator across the third boundary.
        source.append(Data(
            repeating: 0x7A,
            count: (sliceBoundary * 3) - 2 - source.count
        ))
        source.append(0x22)
        source.append(contentsOf: [0x0D, 0x0A])
        XCTAssertEqual(source.count, (sliceBoundary * 3) + 1)
        source.append(Data("2,tail\r\n".utf8))

        let engine = FileBackedPieceTable(empty: .init())
        try engine.insert(source, at: 0)
        let snapshot = try engine.snapshot()
        let completedIndex = try CSVRowIndex(snapshot: snapshot)
        _ = try completedIndex.scanToEnd()

        let query = CSVRowQuery(firstRecord: 1, filters: [
            CSVColumnFilter(column: 0, predicate: .equals("2", caseSensitive: true)),
        ])
        let completedMap = try CSVRowQueryEngine.execute(
            snapshot: snapshot,
            index: completedIndex,
            query: query
        )
        defer { completedMap.close() }
        let scalarMap = try CSVRowQueryEngine.execute(
            snapshot: snapshot,
            index: try CSVRowIndex(snapshot: snapshot),
            query: query
        )
        defer { scalarMap.close() }
        XCTAssertEqual(
            try completedMap.records(in: 0..<completedMap.rowCount),
            try scalarMap.records(in: 0..<scalarMap.rowCount)
        )
        XCTAssertEqual(try completedMap.records(in: 0..<completedMap.rowCount), [2])

        let completedUnique = try CSVUniqueValueProvider.collect(
            snapshot: snapshot,
            index: completedIndex,
            column: 0,
            firstRecord: 1
        )
        let scalarUnique = try CSVUniqueValueProvider.collect(
            snapshot: snapshot,
            index: try CSVRowIndex(snapshot: snapshot),
            column: 0,
            firstRecord: 1
        )
        XCTAssertEqual(completedUnique, scalarUnique)
        XCTAssertEqual(completedUnique.values, ["1", "2"])
    }

    func testCompletedIndexStreamingProjectionCancelsInsideLargeQuotedRecord() throws {
        var source = Data("id,note\n1,\"".utf8)
        source.append(Data(repeating: 0x78, count: 512 << 10))
        source.append(Data("\"\n2,tail\n".utf8))
        let engine = FileBackedPieceTable(empty: .init())
        try engine.insert(source, at: 0)
        let snapshot = try engine.snapshot()
        let index = try CSVRowIndex(snapshot: snapshot)
        _ = try index.scanToEnd()

        let descriptorsBefore = try openFileDescriptorCount()
        let queryCancellation = CSVFilterV2CancellationProbe(cancelAfterChecks: 10)
        XCTAssertThrowsError(
            try CSVRowQueryEngine.execute(
                snapshot: snapshot,
                index: index,
                query: CSVRowQuery(filters: [
                    CSVColumnFilter(column: 0, predicate: .isNotEmpty),
                ]),
                cancellation: { queryCancellation.shouldCancel() }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertLessThanOrEqual(try openFileDescriptorCount(), descriptorsBefore)

        let uniqueCancellation = CSVFilterV2CancellationProbe(cancelAfterChecks: 10)
        XCTAssertThrowsError(
            try CSVUniqueValueProvider.collect(
                snapshot: snapshot,
                index: index,
                column: 0,
                cancellation: { uniqueCancellation.shouldCancel() }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testUniqueValuesAreExactStableAndExcludeUTF8BOMHeader() throws {
        var source = Data([0xEF, 0xBB, 0xBF])
        source.append(Data("value\r\n10\r\n2\r\nA\r\na\r\n\r\n\"é,clair\"\r\n2\r\n".utf8))
        let fixture = try makeFixture(source)
        let first = try CSVUniqueValueProvider.collect(
            snapshot: fixture.snapshot,
            index: fixture.index,
            column: 0,
            firstRecord: 1
        )
        let second = try CSVUniqueValueProvider.collect(
            snapshot: fixture.snapshot,
            index: try CSVRowIndex(snapshot: fixture.snapshot),
            column: 0,
            firstRecord: 1
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(Set(first.values), ["10", "2", "A", "a", "", "é,clair"])
        XCTAssertEqual(first.values.first, "")
        XCTAssertEqual(first.scannedRecordCount, 7)
        XCTAssertEqual(first.totalRecordCount, 7)
        XCTAssertTrue(first.isCompleteDataset)
        XCTAssertFalse(first.isTruncated)
        XCTAssertNil(first.truncationReason)

        let noHeader = try makeFixture("alpha\nbeta\n")
        let allRows = try CSVUniqueValueProvider.collect(
            snapshot: noHeader.snapshot,
            index: noHeader.index,
            column: 0,
            firstRecord: 0
        )
        XCTAssertEqual(allRows.values, ["alpha", "beta"])
        XCTAssertEqual(allRows.scannedRecordCount, 2)
    }

    func testUniqueValueFacetHonorsOtherColumnsAndExcludesItsOwnFilter() throws {
        let fixture = try makeFixture(
            "region,color\n"
                + "East,Red\n"
                + "East,Blue\n"
                + "West,Green\n"
                + "West,Red\n"
        )
        let filters = [
            CSVColumnFilter(column: 0, containsText: "", selectedValues: ["East"]),
            CSVColumnFilter(column: 1, containsText: "", selectedValues: ["Red"]),
        ]
        let colors = try CSVUniqueValueProvider.collect(
            snapshot: fixture.snapshot,
            index: fixture.index,
            column: 1,
            firstRecord: 1,
            baseFilters: filters
        )
        XCTAssertEqual(Set(colors.values), ["Red", "Blue"])
        XCTAssertEqual(colors.eligibleRecordCount, 2)
        XCTAssertTrue(colors.isCompleteDataset)

        let regions = try CSVUniqueValueProvider.collect(
            snapshot: fixture.snapshot,
            index: try CSVRowIndex(snapshot: fixture.snapshot),
            column: 0,
            firstRecord: 1,
            baseFilters: filters
        )
        XCTAssertEqual(Set(regions.values), ["East", "West"])
        XCTAssertEqual(regions.eligibleRecordCount, 2)
    }

    func testUniqueValueProviderReportsEveryBoundInsteadOfClaimingCompleteness() throws {
        let countFixture = try makeFixture("value\nz3\nz1\nz2\n")
        let countLimited = try CSVUniqueValueProvider.collect(
            snapshot: countFixture.snapshot,
            index: countFixture.index,
            column: 0,
            firstRecord: 1,
            configuration: .init(maximumUniqueValueCount: 2)
        )
        XCTAssertEqual(countLimited.values, ["z1", "z3"])
        XCTAssertEqual(countLimited.truncationReason, .uniqueValueCountLimit)
        XCTAssertTrue(countLimited.isTruncated)
        XCTAssertFalse(countLimited.isCompleteDataset)

        let byteFixture = try makeFixture("value\nabc\ndef\n")
        let bytesLimited = try CSVUniqueValueProvider.collect(
            snapshot: byteFixture.snapshot,
            index: byteFixture.index,
            column: 0,
            firstRecord: 1,
            configuration: .init(
                maximumUniqueValueCount: 10,
                maximumRetainedValueBytes: 5
            )
        )
        XCTAssertEqual(bytesLimited.values, ["abc"])
        XCTAssertEqual(bytesLimited.truncationReason, .retainedValueBytesLimit)

        let valueLimited = try CSVUniqueValueProvider.collect(
            snapshot: byteFixture.snapshot,
            index: try CSVRowIndex(snapshot: byteFixture.snapshot),
            column: 0,
            firstRecord: 1,
            configuration: .init(
                maximumUniqueValueCount: 10,
                maximumValueBytes: 2
            )
        )
        XCTAssertTrue(valueLimited.values.isEmpty)
        XCTAssertEqual(valueLimited.truncationReason, .valueByteLimit)
    }

    func testUniqueDiscoveryCancellationAndFilteredRowMapCleanupAtScale() throws {
        var source = Data("kind,value\n".utf8)
        for row in 0..<30_000 {
            source.append(Data("\(row % 3),value-\(row)\n".utf8))
        }
        let fixture = try makeFixture(source)
        let cancellation = CSVFilterV2CancellationProbe(cancelAfterChecks: 20)
        XCTAssertThrowsError(
            try CSVUniqueValueProvider.collect(
                snapshot: fixture.snapshot,
                index: fixture.index,
                column: 1,
                firstRecord: 1,
                configuration: .init(maximumUniqueValueCount: 10_000),
                cancellation: { cancellation.shouldCancel() }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }

        let descriptorsBefore = try openFileDescriptorCount()
        let queryCancellation = CSVFilterV2CancellationProbe(cancelAfterChecks: 40)
        XCTAssertThrowsError(
            try CSVRowQueryEngine.execute(
                snapshot: fixture.snapshot,
                index: try CSVRowIndex(snapshot: fixture.snapshot),
                query: CSVRowQuery(firstRecord: 1, filters: [
                    CSVColumnFilter(
                        column: 0,
                        containsText: "",
                        selectedValues: ["0", "2"]
                    ),
                ]),
                configuration: .init(pageRecordCount: 512),
                cancellation: { queryCancellation.shouldCancel() }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertLessThanOrEqual(try openFileDescriptorCount(), descriptorsBefore)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(
                atPath: FileManager.default.temporaryDirectory.path
            ).contains { $0.hasPrefix("LighTxt-csv-rows-") }
        )
    }

    func testHighCardinalityDiscoveryStopsImmediatelyAfterProvingTheCap() throws {
        let recordCount = 100_000
        var source = Data("value\n".utf8)
        for row in 0..<recordCount {
            source.append(Data("unique-\(row)\n".utf8))
        }
        let fixture = try makeFixture(source)
        let result = try CSVUniqueValueProvider.collect(
            snapshot: fixture.snapshot,
            index: fixture.index,
            column: 0,
            firstRecord: 1,
            configuration: .init(
                pageRecordCount: 64,
                maximumUniqueValueCount: 32,
                maximumRetainedValueBytes: 4 << 10
            )
        )

        XCTAssertEqual(result.values.count, 32)
        XCTAssertEqual(result.scannedRecordCount, 33)
        XCTAssertEqual(result.truncationReason, .uniqueValueCountLimit)
        XCTAssertFalse(result.isCompleteDataset)
        XCTAssertLessThan(result.scannedRecordCount, Int64(recordCount / 1_000))
    }

    func testUniqueValueProgressIsCoalescedAndAlwaysPublishesInitialAndFinal() throws {
        let recordCount = 5_000
        let fixture = try makeFixture(
            "value\n" + String(repeating: "same\n", count: recordCount)
        )
        let progress = CSVFilterV2ProgressRecorder()
        let result = try CSVUniqueValueProvider.collect(
            snapshot: fixture.snapshot,
            index: fixture.index,
            column: 0,
            firstRecord: 1,
            configuration: .init(
                pageRecordCount: 1,
                maximumUniqueValueCount: 10
            ),
            progress: { progress.observe($0.scannedRecordCount) }
        )

        XCTAssertTrue(result.isCompleteDataset)
        XCTAssertEqual(progress.firstScannedRecordCount, 0)
        XCTAssertEqual(progress.lastScannedRecordCount, Int64(recordCount))
        XCTAssertLessThan(
            progress.callCount,
            recordCount / 100,
            "Progress must be time-coalesced rather than enqueueing one callback per page"
        )
    }

    func testAsyncUniqueValueProviderObservesTaskCancellation() async throws {
        let recordCount = 200_000
        let fixture = try makeFixture(String(repeating: "value\n", count: recordCount))
        let progress = CSVFilterV2ProgressRecorder()
        let task = Task {
            try await CSVUniqueValueProvider.values(
                snapshot: fixture.snapshot,
                index: fixture.index,
                column: 0,
                configuration: .init(maximumUniqueValueCount: 10_000),
                progress: { progress.observe($0.scannedRecordCount) }
            )
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled discovery must not publish a result")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertLessThan(
            progress.maximumScannedRecordCount,
            Int64(recordCount),
            "Cancelling the awaiting task must stop, not orphan, the detached scan"
        )
    }

    private func makeFixture(
        _ string: String
    ) throws -> (snapshot: DocumentSnapshot, index: CSVRowIndex) {
        try makeFixture(Data(string.utf8))
    }

    private func makeFixture(
        _ data: Data
    ) throws -> (snapshot: DocumentSnapshot, index: CSVRowIndex) {
        let engine = FileBackedPieceTable(empty: .init())
        try engine.insert(data, at: 0)
        let snapshot = try engine.snapshot()
        return (snapshot, try CSVRowIndex(snapshot: snapshot))
    }

    private func openFileDescriptorCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    }
}

private final class CSVFilterV2ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedMaximum: Int64 = 0
    private var storedFirst: Int64?
    private var storedLast: Int64 = 0
    private var storedCallCount = 0

    var maximumScannedRecordCount: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return storedMaximum
    }

    var firstScannedRecordCount: Int64? {
        lock.lock()
        defer { lock.unlock() }
        return storedFirst
    }

    var lastScannedRecordCount: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return storedLast
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCallCount
    }

    func observe(_ value: Int64) {
        lock.lock()
        if storedFirst == nil { storedFirst = value }
        storedLast = value
        storedCallCount += 1
        storedMaximum = max(storedMaximum, value)
        lock.unlock()
    }
}

private final class CSVFilterV2CancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelAfterChecks: Int
    private var checks = 0

    init(cancelAfterChecks: Int) {
        self.cancelAfterChecks = cancelAfterChecks
    }

    func shouldCancel() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        checks += 1
        return checks >= cancelAfterChecks
    }
}
