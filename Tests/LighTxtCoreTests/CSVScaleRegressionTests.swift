import Darwin
import Foundation
import XCTest
@testable import LighTxt

final class CSVScaleRegressionTests: XCTestCase {
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
