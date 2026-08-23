import Foundation
import XCTest
@testable import LighTxt

nonisolated final class SparseUTF8LineIndexTests: XCTestCase {
    func testEmptyDocumentIsImmediatelyComplete() throws {
        let reader = RecordingDataReader(Data())
        let index = try SparseUTF8LineIndex(
            byteCount: 0,
            reader: { try reader.read($0) }
        )

        XCTAssertTrue(index.progress.isComplete)
        XCTAssertEqual(index.progress.fractionCompleted, 1)
        XCTAssertEqual(index.totalLineCount, 1)
        XCTAssertEqual(try index.byteOffset(forLine: 0), 0)
        XCTAssertNil(try index.byteOffset(forLine: 1))
        XCTAssertEqual(
            try index.lineAndColumn(forByteOffset: 0),
            .init(line: 0, column: 0)
        )
        XCTAssertTrue(reader.requestedRanges.isEmpty)
    }

    func testMixedNewlinesAndCRLFAcrossChunkBoundaries() throws {
        let data = Data("a\r\nbb\rc\n\r\nd".utf8)
        let reader = RecordingDataReader(data)
        let index = try SparseUTF8LineIndex(
            byteCount: Int64(data.count),
            configuration: .init(
                checkpointLineInterval: 2,
                readChunkByteCount: 2
            ),
            reader: { try reader.read($0) }
        )

        let first = try index.scanNextChunk()
        XCTAssertEqual(first.stopReason, .advanced)
        XCTAssertEqual(first.progress.indexedByteCount, 2)
        XCTAssertEqual(first.progress.knownLineCount, 1)
        XCTAssertNil(first.progress.totalLineCount)

        let finished = try index.scanToEnd()
        XCTAssertEqual(finished.stopReason, .completed)
        XCTAssertEqual(finished.progress.totalLineCount, 5)
        XCTAssertEqual(finished.progress.checkpointCount, 3)

        let expectedStarts: [Int64] = [0, 3, 6, 8, 10]
        for (line, expectedOffset) in expectedStarts.enumerated() {
            XCTAssertEqual(
                try index.byteOffset(forLine: Int64(line)),
                expectedOffset
            )
        }
        XCTAssertNil(try index.byteOffset(forLine: 5))

        XCTAssertEqual(
            try index.lineAndColumn(forByteOffset: 2),
            .init(line: 0, column: 2),
            "An insertion point inside CRLF remains on the preceding line"
        )
        XCTAssertEqual(
            try index.lineAndColumn(forByteOffset: 3),
            .init(line: 1, column: 0)
        )
        XCTAssertEqual(
            try index.lineAndColumn(forByteOffset: 6),
            .init(line: 2, column: 0),
            "A lone CR starts a line immediately after CR"
        )
        XCTAssertEqual(
            try index.lineAndColumn(forByteOffset: 9),
            .init(line: 3, column: 1)
        )
        XCTAssertEqual(
            try index.lineAndColumn(forByteOffset: 11),
            .init(line: 4, column: 1)
        )
        XCTAssertLessThanOrEqual(reader.largestRequest, 2)
    }

    func testColumnsAreUTF8ByteColumns() throws {
        let data = Data("é🙂\nβ".utf8)
        let reader = RecordingDataReader(data)
        let index = try SparseUTF8LineIndex(
            byteCount: Int64(data.count),
            configuration: .init(readChunkByteCount: 3),
            reader: { try reader.read($0) }
        )

        XCTAssertEqual(
            try index.lineAndColumn(forByteOffset: 2),
            .init(line: 0, column: 2)
        )
        XCTAssertEqual(
            try index.lineAndColumn(forByteOffset: 6),
            .init(line: 0, column: 6)
        )
        XCTAssertEqual(try index.byteOffset(forLine: 1), 7)
        XCTAssertEqual(
            try index.lineAndColumn(forByteOffset: 9),
            .init(line: 1, column: 2)
        )
    }

    func testSparseCheckpointMemoryAndBoundedIncrementalReads() throws {
        let breakCount = 10_000
        let data = Data(String(repeating: "x\n", count: breakCount).utf8)
        let reader = RecordingDataReader(data)
        let index = try SparseUTF8LineIndex(
            byteCount: Int64(data.count),
            configuration: .init(
                checkpointLineInterval: 128,
                readChunkByteCount: 17
            ),
            reader: { try reader.read($0) }
        )

        var indexedByteCounts: [Int64] = []
        let result = try index.scanToEnd(
            cancellation: { false },
            progressHandler: { progress in
                indexedByteCounts.append(progress.indexedByteCount)
            }
        )

        XCTAssertEqual(result.stopReason, .completed)
        XCTAssertEqual(result.progress.totalLineCount, Int64(breakCount + 1))
        XCTAssertEqual(result.progress.checkpointCount, 79)
        XCTAssertEqual(result.progress.checkpointPayloadByteCount, 79 * 8)
        XCTAssertLessThanOrEqual(reader.largestRequest, 17)
        XCTAssertEqual(indexedByteCounts, indexedByteCounts.sorted())
        XCTAssertEqual(indexedByteCounts.last, Int64(data.count))
    }

    func testResidentPurgeRetainsSourceAndRebuildsCheckpointsLazily() throws {
        let lineCount = 512
        let data = Data(String(repeating: "value\n", count: lineCount).utf8)
        let reader = RecordingDataReader(data)
        let index = try SparseUTF8LineIndex(
            byteCount: Int64(data.count),
            sourceRevision: 41,
            configuration: .init(
                checkpointLineInterval: 1,
                readChunkByteCount: 37
            ),
            reader: { try reader.read($0) }
        )

        _ = try index.scanToEnd()
        let oldGeneration = index.generation
        let oldPayload = index.progress.checkpointPayloadByteCount
        XCTAssertGreaterThan(oldPayload, MemoryLayout<Int64>.stride)

        XCTAssertEqual(
            index.purgeRebuildableResidentMemory(),
            oldPayload - MemoryLayout<Int64>.stride
        )
        let purged = index.progress
        XCTAssertEqual(purged.generation.sourceRevision, 41)
        XCTAssertNotEqual(purged.generation, oldGeneration)
        XCTAssertEqual(purged.indexedByteCount, 0)
        XCTAssertEqual(purged.checkpointCount, 1)
        XCTAssertEqual(purged.checkpointPayloadByteCount, MemoryLayout<Int64>.stride)
        XCTAssertFalse(purged.isComplete)
        XCTAssertNil(purged.totalLineCount)

        XCTAssertThrowsError(
            try index.byteOffset(forLine: 1, generation: oldGeneration)
        ) { error in
            guard let indexError = error as? SparseUTF8LineIndex.IndexError,
                  case .generationInvalidated = indexError else {
                return XCTFail("Expected a generation invalidation, got \(error)")
            }
        }

        XCTAssertEqual(try index.byteOffset(forLine: 123), Int64(123 * 6))
        XCTAssertGreaterThan(index.progress.indexedByteCount, 0)
        XCTAssertEqual(try index.scanToEnd().progress.totalLineCount, Int64(lineCount + 1))
    }

    func testAllNewlineFormsAndTrailingEmptyLine() throws {
        let cases: [(text: String, starts: [Int64])] = [
            ("a", [0]),
            ("a\n", [0, 2]),
            ("a\r", [0, 2]),
            ("a\r\n", [0, 3]),
            ("\r\n", [0, 2]),
            ("\n\r", [0, 1, 2]),
        ]

        for testCase in cases {
            let data = Data(testCase.text.utf8)
            let reader = RecordingDataReader(data)
            let index = try SparseUTF8LineIndex(
                byteCount: Int64(data.count),
                configuration: .init(
                    checkpointLineInterval: 1,
                    readChunkByteCount: 1
                ),
                reader: { try reader.read($0) }
            )
            _ = try index.scanToEnd()

            XCTAssertEqual(
                index.totalLineCount,
                Int64(testCase.starts.count),
                "Unexpected count for \(testCase.text.debugDescription)"
            )
            for (line, start) in testCase.starts.enumerated() {
                XCTAssertEqual(
                    try index.byteOffset(forLine: Int64(line)),
                    start,
                    "Unexpected line start for \(testCase.text.debugDescription)"
                )
            }
        }
    }

    func testLookupScansOnlyAsFarAsNeeded() throws {
        let data = Data("zero\none\ntwo\nthree\nfour".utf8)
        let reader = RecordingDataReader(data)
        let index = try SparseUTF8LineIndex(
            byteCount: Int64(data.count),
            configuration: .init(
                checkpointLineInterval: 2,
                readChunkByteCount: 4
            ),
            reader: { try reader.read($0) }
        )

        XCTAssertEqual(try index.byteOffset(forLine: 2), 9)
        XCTAssertFalse(index.progress.isComplete)
        XCTAssertGreaterThanOrEqual(index.progress.knownLineCount, 3)
        XCTAssertLessThan(index.progress.indexedByteCount, Int64(data.count))

        XCTAssertEqual(
            try index.lineAndColumn(forByteOffset: 12),
            .init(line: 2, column: 3)
        )
        XCTAssertLessThanOrEqual(reader.largestRequest, 4)
    }

    func testCancellationStopsWithoutCommittingAChunk() throws {
        let data = Data(String(repeating: "line\n", count: 100).utf8)
        let reader = RecordingDataReader(data)
        let index = try SparseUTF8LineIndex(
            byteCount: Int64(data.count),
            configuration: .init(readChunkByteCount: 32),
            reader: { try reader.read($0) }
        )

        let result = try index.scanNextChunk(cancellation: { true })
        XCTAssertEqual(result.stopReason, .cancelled)
        XCTAssertEqual(result.progress.indexedByteCount, 0)
        XCTAssertTrue(reader.requestedRanges.isEmpty)

        XCTAssertThrowsError(
            try index.byteOffset(forLine: 4, cancellation: { true })
        ) { error in
            XCTAssertEqual(error as? SparseUTF8LineIndex.IndexError, .cancelled)
        }
    }

    func testEditInvalidatesAnInFlightGeneration() throws {
        let oldData = Data("old\nsource\nwith\nlines".utf8)
        let newData = Data("new\ntext".utf8)
        let holder = IndexHolder()
        let newReader = RecordingDataReader(newData)
        let oldReader = InvalidatingReader(data: oldData) {
            guard let index = holder.index else { return }
            _ = try index.invalidate(
                byteCount: Int64(newData.count),
                sourceRevision: 2,
                reader: { try newReader.read($0) }
            )
        }
        let index = try SparseUTF8LineIndex(
            byteCount: Int64(oldData.count),
            sourceRevision: 1,
            configuration: .init(
                checkpointLineInterval: 1,
                readChunkByteCount: 8
            ),
            reader: { try oldReader.read($0) }
        )
        holder.index = index
        let oldGeneration = index.generation

        let staleResult = try index.scanNextChunk(generation: oldGeneration)
        XCTAssertEqual(staleResult.stopReason, .invalidated)
        XCTAssertEqual(staleResult.progress.generation.sourceRevision, 2)
        XCTAssertEqual(staleResult.progress.indexedByteCount, 0)
        XCTAssertEqual(staleResult.progress.checkpointCount, 1)

        XCTAssertThrowsError(
            try index.byteOffset(forLine: 0, generation: oldGeneration)
        ) { error in
            guard let indexError = error as? SparseUTF8LineIndex.IndexError,
                  case let .generationInvalidated(expected, actual) = indexError else {
                return XCTFail("Expected a generation invalidation, got \(error)")
            }
            XCTAssertEqual(expected, oldGeneration)
            XCTAssertEqual(actual.sourceRevision, 2)
        }

        XCTAssertEqual(try index.scanToEnd().progress.totalLineCount, 2)
        XCTAssertEqual(try index.byteOffset(forLine: 1), 4)
    }

    func testInt64LogicalSourceAndBoundedVirtualReader() throws {
        let logicalByteCount = Int64(UInt32.max) + 4_096
        let reader = RepeatingByteReader(byte: 0x61)
        let index = try SparseUTF8LineIndex(
            byteCount: logicalByteCount,
            configuration: .init(readChunkByteCount: 4_096),
            reader: { try reader.read($0) }
        )

        let first = try index.scanNextChunk()
        XCTAssertEqual(first.progress.indexedByteCount, 4_096)
        XCTAssertEqual(first.progress.totalByteCount, logicalByteCount)
        XCTAssertFalse(first.progress.isComplete)

        XCTAssertEqual(
            try index.lineAndColumn(forByteOffset: 8_192),
            .init(line: 0, column: 8_192)
        )
        XCTAssertLessThanOrEqual(reader.largestRequest, 4_096)
        XCTAssertEqual(index.progress.knownLineCount, 1)
    }

    func testRejectsShortReaderResultsAndInvalidCoordinates() throws {
        let index = try SparseUTF8LineIndex(byteCount: 4) { _ in Data([0x61]) }

        XCTAssertThrowsError(try index.scanNextChunk()) { error in
            guard let indexError = error as? SparseUTF8LineIndex.IndexError,
                  case let .invalidReaderResult(range, actual) = indexError else {
                return XCTFail("Expected an invalid reader result, got \(error)")
            }
            XCTAssertEqual(range, 0..<4)
            XCTAssertEqual(actual, 1)
        }
        XCTAssertThrowsError(try index.byteOffset(forLine: -1))
        XCTAssertThrowsError(try index.lineAndColumn(forByteOffset: 5))
    }

    func testRandomizedNewlineBoundariesMatchReferenceIndex() throws {
        var random = DeterministicRandom(state: 0x4c69_6768_5478_7421)
        var bytes: [UInt8] = []
        for _ in 0..<513 {
            switch random.next() % 17 {
            case 0, 1:
                bytes.append(0x0d)
            case 2, 3:
                bytes.append(0x0a)
            case 4:
                bytes.append(0x80) // Invalid UTF-8 is still byte-addressable.
            default:
                bytes.append(UInt8(ascii: "a") + UInt8(random.next() % 26))
            }
        }
        let data = Data(bytes)
        let expectedStarts = referenceLineStarts(in: bytes)

        for chunkSize in [1, 2, 3, 7, 31] {
            for interval: Int64 in [1, 5, 19] {
                let reader = RecordingDataReader(data)
                let index = try SparseUTF8LineIndex(
                    byteCount: Int64(data.count),
                    configuration: .init(
                        checkpointLineInterval: interval,
                        readChunkByteCount: chunkSize
                    ),
                    reader: { try reader.read($0) }
                )
                _ = try index.scanToEnd()

                XCTAssertEqual(index.totalLineCount, Int64(expectedStarts.count))
                for (line, start) in expectedStarts.enumerated() {
                    XCTAssertEqual(
                        try index.byteOffset(forLine: Int64(line)),
                        start,
                        "chunk=\(chunkSize), interval=\(interval), line=\(line)"
                    )
                }

                for offset in 0...bytes.count {
                    let byteOffset = Int64(offset)
                    let line = expectedStarts.lastIndex(where: { $0 <= byteOffset }) ?? 0
                    XCTAssertEqual(
                        try index.lineAndColumn(forByteOffset: byteOffset),
                        .init(
                            line: Int64(line),
                            column: byteOffset - expectedStarts[line]
                        ),
                        "chunk=\(chunkSize), interval=\(interval), offset=\(offset)"
                    )
                }
                XCTAssertLessThanOrEqual(reader.largestRequest, Int64(chunkSize))
            }
        }
    }
}

private nonisolated func referenceLineStarts(in bytes: [UInt8]) -> [Int64] {
    var starts: [Int64] = [0]
    var index = 0
    while index < bytes.count {
        if bytes[index] == 0x0d {
            if index + 1 < bytes.count, bytes[index + 1] == 0x0a {
                index += 2
            } else {
                index += 1
            }
            starts.append(Int64(index))
        } else if bytes[index] == 0x0a {
            index += 1
            starts.append(Int64(index))
        } else {
            index += 1
        }
    }
    return starts
}

private nonisolated struct DeterministicRandom {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
        value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
        return value ^ (value >> 31)
    }
}

private nonisolated final class RecordingDataReader: @unchecked Sendable {
    private let data: Data
    private let lock = NSLock()
    private var ranges: [Range<Int64>] = []

    init(_ data: Data) {
        self.data = data
    }

    func read(_ range: Range<Int64>) throws -> Data {
        lock.lock()
        ranges.append(range)
        lock.unlock()
        return data.subdata(
            in: Int(range.lowerBound)..<Int(range.upperBound)
        )
    }

    var requestedRanges: [Range<Int64>] {
        lock.lock()
        defer { lock.unlock() }
        return ranges
    }

    var largestRequest: Int64 {
        requestedRanges.map { $0.upperBound - $0.lowerBound }.max() ?? 0
    }
}

private nonisolated final class RepeatingByteReader: @unchecked Sendable {
    private let byte: UInt8
    private let lock = NSLock()
    private var maximum = 0

    init(byte: UInt8) {
        self.byte = byte
    }

    func read(_ range: Range<Int64>) throws -> Data {
        let count = Int(range.upperBound - range.lowerBound)
        lock.lock()
        maximum = max(maximum, count)
        lock.unlock()
        return Data(repeating: byte, count: count)
    }

    var largestRequest: Int {
        lock.lock()
        defer { lock.unlock() }
        return maximum
    }
}

private nonisolated final class InvalidatingReader: @unchecked Sendable {
    private let data: Data
    private let invalidate: @Sendable () throws -> Void
    private let lock = NSLock()
    private var hasInvalidated = false

    init(data: Data, invalidate: @escaping @Sendable () throws -> Void) {
        self.data = data
        self.invalidate = invalidate
    }

    func read(_ range: Range<Int64>) throws -> Data {
        let shouldInvalidate: Bool
        lock.lock()
        shouldInvalidate = !hasInvalidated
        hasInvalidated = true
        lock.unlock()
        if shouldInvalidate { try invalidate() }
        return data.subdata(
            in: Int(range.lowerBound)..<Int(range.upperBound)
        )
    }
}

private nonisolated final class IndexHolder: @unchecked Sendable {
    var index: SparseUTF8LineIndex?
}
