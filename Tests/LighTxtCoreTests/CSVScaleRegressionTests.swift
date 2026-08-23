import Darwin
import Foundation
import XCTest
@testable import LighTxt

final class CSVScaleRegressionTests: XCTestCase {
    func testQuarterMillionRowInteractiveOperationsStayWithinReleaseBudget() throws {
        guard ProcessInfo.processInfo.environment["LIGHTXT_RUN_PERFORMANCE_REGRESSIONS"] == "1" else {
            throw XCTSkip("Full regression mode enables the deterministic Release performance gate")
        }
#if DEBUG
        throw XCTSkip("The interactive latency budget is meaningful only in an optimized build")
#else
        let rowCount = 250_000
        let exactValue = "1982720249"
        let widePayload = String(repeating: "x", count: 640)
        let maximumSeconds = ProcessInfo.processInfo.environment["LIGHTXT_CSV_250K_MAX_SECONDS"]
            .flatMap(Double.init) ?? 5
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LighTxt-csv-performance-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("quarter-million.csv")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let writer = try FileHandle(forWritingTo: url)
        do {
            var buffer = Data()
            buffer.reserveCapacity(1 << 20)
            buffer.append(Data((0..<24).map { "column_\($0)" }.joined(separator: ",").utf8))
            buffer.append(0x0A)
            for row in 0..<rowCount {
                let npi = row == 123_456 ? exactValue : String(1_000_000_000 + row)
                let fields = [
                    "modifier-\(row % 3)",
                    "additional-\(row % 29)-\(widePayload)",
                    "plan-\(row % 4)",
                    "both",
                    "severity-\(row % 8)",
                    "82",
                    npi,
                    "ein",
                    String(20_000_000 + row),
                    "\"Clinic \(row), Department\"",
                    "Aetna Choice POS II",
                    String(1_000 + row % 1_000),
                    "region-\(row % 12)",
                    "state-\(row % 50)",
                    "active",
                    "network-\(row % 17)",
                    "group-\(row % 31)",
                    "2026-08-22",
                    "category-\(row % 9)",
                    "value-\(row)",
                    "flag-\(row % 2)",
                    "code-\(row % 101)",
                    "source",
                    "tail-\(row % 7)",
                ]
                buffer.append(Data(fields.joined(separator: ",").utf8))
                buffer.append(0x0A)
                if buffer.count >= 1 << 20 {
                    try writer.write(contentsOf: buffer)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty { try writer.write(contentsOf: buffer) }
            try writer.synchronize()
            try writer.close()
        } catch {
            try? writer.close()
            throw error
        }

        let attributesBefore = try FileManager.default.attributesOfItem(atPath: url.path)
        let digestBefore = try streamingFileDigest(url)
        let engine = try FileBackedPieceTable(opening: url)
        defer { engine.close() }
        let snapshot = try engine.snapshot()
        XCTAssertGreaterThanOrEqual(
            snapshot.byteCount,
            200 << 20,
            "The deterministic fixture must remain representative of a wide 250,000-row CSV"
        )
        let index = try CSVRowIndex(snapshot: snapshot)

        let indexStarted = ProcessInfo.processInfo.systemUptime
        let scan = try index.scanToEnd()
        let indexSeconds = ProcessInfo.processInfo.systemUptime - indexStarted
        XCTAssertEqual(scan.progress.totalRecordCount, Int64(rowCount + 1))
        XCTAssertLessThan(
            indexSeconds,
            maximumSeconds,
            "Indexing a deterministic 250,000-row CSV exceeded the \(maximumSeconds)s budget"
        )

        let distinctStarted = ProcessInfo.processInfo.systemUptime
        let distinct = try CSVUniqueValueProvider.collect(
            snapshot: snapshot,
            index: index,
            column: 2,
            firstRecord: 1
        )
        let distinctSeconds = ProcessInfo.processInfo.systemUptime - distinctStarted
        XCTAssertEqual(Set(distinct.values), Set(["plan-0", "plan-1", "plan-2", "plan-3"]))
        XCTAssertTrue(distinct.isCompleteDataset)
        XCTAssertEqual(distinct.scannedRecordCount, Int64(rowCount))
        XCTAssertLessThan(
            distinctSeconds,
            maximumSeconds,
            "Distinct values on 250,000 rows exceeded the \(maximumSeconds)s budget"
        )

        let filterStarted = ProcessInfo.processInfo.systemUptime
        let map = try CSVRowQueryEngine.execute(
            snapshot: snapshot,
            index: index,
            query: CSVRowQuery(firstRecord: 1, filters: [
                CSVColumnFilter(
                    column: 6,
                    containsText: "",
                    selectedValues: [exactValue]
                ),
            ])
        )
        let filterSeconds = ProcessInfo.processInfo.systemUptime - filterStarted
        XCTAssertEqual(map.rowCount, 1)
        XCTAssertEqual(try map.records(in: 0..<1), [123_457])
        map.close()
        XCTAssertLessThan(
            filterSeconds,
            maximumSeconds,
            "Exact filtering on 250,000 rows exceeded the \(maximumSeconds)s budget"
        )

        let attributesAfter = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributesBefore[.size] as? NSNumber, attributesAfter[.size] as? NSNumber)
        XCTAssertEqual(
            attributesBefore[.modificationDate] as? Date,
            attributesAfter[.modificationDate] as? Date
        )
        XCTAssertEqual(try streamingFileDigest(url), digestBefore)
        XCTAssertFalse(engine.hasUnsavedChanges)
        print(
            "LighTxt 250k CSV regression: bytes=\(snapshot.byteCount), "
                + "index=\(indexSeconds)s, distinct=\(distinctSeconds)s, "
                + "filter=\(filterSeconds)s, budget=\(maximumSeconds)s"
        )
#endif
    }

    private func streamingFileDigest(_ url: URL) throws -> UInt64 {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest: UInt64 = 14_695_981_039_346_656_037
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            for byte in chunk {
                digest ^= UInt64(byte)
                digest &*= 1_099_511_628_211
            }
        }
        return digest
    }

    func testCompletedIndexFilterUsesOneSequentialProjectionStartLookup() throws {
        let recordCount = 20_000
        var source = Data("id,kind\n".utf8)
        for row in 0..<recordCount {
            source.append(Data("\(row),\(row.isMultiple(of: 2) ? "keep" : "drop")\n".utf8))
        }
        let engine = FileBackedPieceTable(empty: .init())
        try engine.insert(source, at: 0)
        let snapshot = try engine.snapshot()
        let recorder = CSVReadCountRecorder()
        let fixture = source
        let index = try CSVRowIndex(
            byteCount: Int64(fixture.count),
            configuration: .init(
                readChunkByteCount: 4 << 10,
                initialCheckpointRecordInterval: 1_024,
                maximumCheckpointCount: 128,
                allowsAcceleratedScanner: false
            ),
            reader: { range in
                recorder.recordRead()
                return fixture.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
            }
        )
        _ = try index.scanToEnd()
        let readsBeforeQuery = recorder.readCount

        let map = try CSVRowQueryEngine.execute(
            snapshot: snapshot,
            index: index,
            query: CSVRowQuery(firstRecord: 1, filters: [
                CSVColumnFilter(
                    column: 1,
                    containsText: "",
                    selectedValues: ["keep"]
                ),
            ])
        )
        defer { map.close() }

        XCTAssertEqual(map.rowCount, Int64(recordCount / 2))
        XCTAssertLessThanOrEqual(
            recorder.readCount - readsBeforeQuery,
            1,
            "A completed-index query should refine its starting row once, not once per page"
        )
    }

    func testDenseCRLFRecordLookupReadsChunksInsteadOfOneBytePerRow() throws {
        let recordCount = 512
        let chunkByteCount = 37
        var source = Data()
        var carriageReturnOffsets: [Int] = []
        for row in 0..<recordCount {
            source.append(Data("\(row),value-\(row)".utf8))
            carriageReturnOffsets.append(source.count)
            source.append(contentsOf: [0x0D, 0x0A])
        }
        let fixture = source

        let recorder = CSVReadCountRecorder()
        let index = try CSVRowIndex(
            byteCount: Int64(source.count),
            configuration: .init(
                readChunkByteCount: chunkByteCount,
                initialCheckpointRecordInterval: 1_024,
                maximumCheckpointCount: 128,
                allowsAcceleratedScanner: false
            ),
            reader: { range in
                recorder.recordRead()
                return fixture.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
            }
        )
        _ = try index.scanToEnd()
        let readsBeforeLookup = recorder.readCount

        let locations = try index.recordLocations(startingAt: 0, limit: recordCount)
        XCTAssertEqual(locations.count, recordCount)
        XCTAssertEqual(locations.first?.record, 0)
        XCTAssertEqual(locations.last?.record, Int64(recordCount - 1))
        XCTAssertTrue(locations.allSatisfy {
            $0.completeRange.count == $0.contentRange.count + 2
        })

        let lastCarriageReturn = try XCTUnwrap(carriageReturnOffsets.last)
        let ordinaryChunkReads = lastCarriageReturn / chunkByteCount + 1
        let boundaryLookaheadReads = carriageReturnOffsets.filter {
            $0 % chunkByteCount == chunkByteCount - 1
        }.count
        XCTAssertEqual(
            recorder.readCount - readsBeforeLookup,
            ordinaryChunkReads + boundaryLookaheadReads,
            "CRLF lookahead should reuse the current chunk except at a true chunk boundary"
        )
    }

    func testExternalSortCompactsRunsBelowAConstrainedFileDescriptorLimit() throws {
        let rowCount = 6_000
        let padding = String(repeating: "x", count: 1_024)
        var source = Data("key,id\r\n".utf8)
        var expectedOrder: [(key: Int, record: Int64)] = []
        expectedOrder.reserveCapacity(rowCount)
        source.reserveCapacity(rowCount * 1_040)
        for value in stride(from: rowCount, through: 1, by: -1) {
            // Three identical keys per group deliberately straddle spill-run
            // boundaries. The source ordinal is the stable total-order
            // tiebreaker used by both in-memory and external merge passes.
            let key = (value - 1) / 3
            source.append(Data(String(format: "%06d-%@,%d\r\n", key, padding, value).utf8))
            expectedOrder.append((key: key, record: Int64(expectedOrder.count + 1)))
        }
        expectedOrder.sort {
            $0.key == $1.key ? $0.record < $1.record : $0.key < $1.key
        }

        let engine = FileBackedPieceTable(empty: .init())
        try engine.insert(source, at: 0)
        let snapshot = try engine.snapshot()
        let index = try CSVRowIndex(snapshot: snapshot)
        _ = try index.scanToEnd()

        var originalLimit = rlimit()
        XCTAssertEqual(getrlimit(RLIMIT_NOFILE, &originalLimit), 0)
        let baselineDescriptors = try openFileDescriptorCount()
        var constrainedLimit = originalLimit
        constrainedLimit.rlim_cur = min(
            originalLimit.rlim_cur,
            rlim_t(max(40, baselineDescriptors + 24))
        )
        guard constrainedLimit.rlim_cur < originalLimit.rlim_cur else {
            throw XCTSkip("The process file-descriptor soft limit is already too low to constrain safely")
        }
        XCTAssertEqual(setrlimit(RLIMIT_NOFILE, &constrainedLimit), 0)
        defer {
            var restored = originalLimit
            XCTAssertEqual(setrlimit(RLIMIT_NOFILE, &restored), 0)
        }

        let map = try CSVRowQueryEngine.execute(
            snapshot: snapshot,
            index: index,
            query: CSVRowQuery(
                firstRecord: 1,
                sortDescriptors: [CSVSortDescriptor(column: 0)]
            ),
            configuration: .init(
                pageRecordCount: 256,
                sortRunMemoryByteCount: 64 << 10,
                mergeFanIn: 4
            )
        )
        XCTAssertEqual(map.rowCount, Int64(rowCount))
        var actualOrder: [Int64] = []
        actualOrder.reserveCapacity(rowCount)
        var pageStart: Int64 = 0
        while pageStart < map.rowCount {
            let pageEnd = min(map.rowCount, pageStart + 4_096)
            actualOrder.append(contentsOf: try map.records(in: pageStart..<pageEnd))
            pageStart = pageEnd
        }
        XCTAssertEqual(actualOrder, expectedOrder.map(\.record))

        map.close()
        XCTAssertLessThanOrEqual(
            try openFileDescriptorCount(),
            baselineDescriptors,
            "All unlinked sort runs and the closed result map must release their descriptors"
        )
    }

    private func openFileDescriptorCount() throws -> Int {
        try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
    }
}

private final class CSVReadCountRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedReadCount = 0

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedReadCount
    }

    func recordRead() {
        lock.lock()
        storedReadCount += 1
        lock.unlock()
    }
}
