import Foundation
#if SWIFT_PACKAGE
import LighTxtJSONAccelerator
#endif

/// A bounded-memory, RFC-4180-aware record index for arbitrarily large CSV
/// documents. The index retains one byte offset per checkpoint interval, not
/// one offset per row. If an unusually dense file reaches the checkpoint
/// budget, existing checkpoints are thinned and the interval doubles. Memory
/// therefore remains capped even for files containing billions of tiny rows.
public nonisolated final class CSVRowIndex: @unchecked Sendable {
    public typealias ChunkReader = @Sendable (Range<Int64>) throws -> Data
    public typealias CancellationCheck = @Sendable () -> Bool

    public struct Configuration: Sendable, Equatable {
        public let delimiter: UInt8
        public let readChunkByteCount: Int
        public let initialCheckpointRecordInterval: Int64
        public let maximumCheckpointCount: Int
        public let allowsAcceleratedScanner: Bool

        public init(
            delimiter: UInt8 = 0x2C,
            readChunkByteCount: Int = 1 << 20,
            initialCheckpointRecordInterval: Int64 = 1_024,
            maximumCheckpointCount: Int = 65_536,
            allowsAcceleratedScanner: Bool = true
        ) {
            self.delimiter = delimiter
            self.readChunkByteCount = max(1, readChunkByteCount)
            self.initialCheckpointRecordInterval = max(1, initialCheckpointRecordInterval)
            self.maximumCheckpointCount = max(2, maximumCheckpointCount)
            self.allowsAcceleratedScanner = allowsAcceleratedScanner
        }
    }

    public struct Progress: Sendable, Equatable {
        public let indexedByteCount: Int64
        public let totalByteCount: Int64
        /// Records whose terminating newline (or EOF) has been observed.
        public let knownRecordCount: Int64
        public let totalRecordCount: Int64?
        public let checkpointCount: Int
        public let checkpointRecordInterval: Int64
        public let isComplete: Bool

        public var fractionCompleted: Double {
            guard totalByteCount > 0 else { return 1 }
            return min(1, Double(indexedByteCount) / Double(totalByteCount))
        }

        public var checkpointPayloadByteCount: Int {
            checkpointCount * MemoryLayout<Int64>.stride
        }
    }

    public struct RecordLocation: Sendable, Equatable {
        public let record: Int64
        /// The CSV record excluding CR/LF terminator bytes.
        public let contentRange: Range<Int64>
        /// The complete record including its CR, LF, or CRLF terminator.
        public let completeRange: Range<Int64>
    }

    public enum StopReason: Sendable, Equatable {
        case advanced
        case completed
        case cancelled
    }

    public struct ScanResult: Sendable, Equatable {
        public let progress: Progress
        public let stopReason: StopReason
    }

    public enum IndexError: Error, LocalizedError, Equatable {
        case invalidByteCount(Int64)
        case invalidRecord(Int64)
        case invalidReaderResult(requested: Range<Int64>, actualByteCount: Int)
        case cancelled
        case inconsistentCheckpointData

        public var errorDescription: String? {
            switch self {
            case let .invalidByteCount(count):
                return "A CSV index cannot address a negative byte count (\(count))."
            case let .invalidRecord(record):
                return "CSV row numbers must be zero or greater (received \(record))."
            case let .invalidReaderResult(range, actual):
                return "The CSV reader returned \(actual) bytes for the exact range \(range)."
            case .cancelled:
                return "CSV indexing was cancelled."
            case .inconsistentCheckpointData:
                return "The CSV checkpoints are inconsistent with their byte source."
            }
        }
    }

    private struct State {
        var checkpoints: [Int64] = [0]
        var checkpointInterval: Int64
        var scanOffset: Int64 = 0
        var recordStart: Int64 = 0
        var completedRecords: Int64 = 0
        var inQuotedField = false
        var pendingQuote = false
        var atFieldStart = true
        var pendingCarriageReturn = false
        var checkpointPending = false
        var isComplete: Bool
    }

    private let byteCount: Int64
    private let reader: ChunkReader
    private let configuration: Configuration
    private let stateLock = NSLock()
    private let scanLock = NSLock()
    private var state: State
    /// Reused fixed-capacity bridge output. It is protected by `scanLock` and
    /// remains tiny regardless of document size.
    private var acceleratedCheckpointScratch: [Int64]

    public init(
        byteCount: Int64,
        configuration: Configuration = .init(),
        reader: @escaping ChunkReader
    ) throws {
        guard byteCount >= 0 else { throw IndexError.invalidByteCount(byteCount) }
        self.byteCount = byteCount
        self.reader = reader
        self.configuration = configuration
        self.state = State(
            checkpointInterval: configuration.initialCheckpointRecordInterval,
            isComplete: byteCount == 0
        )
        self.acceleratedCheckpointScratch = Array(
            repeating: 0,
            count: min(4_096, configuration.maximumCheckpointCount)
        )
    }

    public convenience init(
        snapshot: DocumentSnapshot,
        configuration: Configuration = .init()
    ) throws {
        try self.init(
            byteCount: snapshot.byteCount,
            configuration: configuration,
            reader: { range in try snapshot.data(in: range) }
        )
    }

    public var progress: Progress {
        withStateLock { makeProgress($0) }
    }

    @discardableResult
    public func scanNextChunk(
        cancellation: CancellationCheck? = nil
    ) throws -> ScanResult {
        scanLock.lock()
        defer { scanLock.unlock() }

        if cancellation?() == true {
            return ScanResult(progress: progress, stopReason: .cancelled)
        }

        let capture = withStateLock { $0 }
        if capture.isComplete {
            return ScanResult(progress: makeProgress(capture), stopReason: .completed)
        }

        let upper = min(byteCount, capture.scanOffset + Int64(configuration.readChunkByteCount))
        let requested = capture.scanOffset..<upper
        let data = try reader(requested)
        guard data.count == Int(requested.count) else {
            throw IndexError.invalidReaderResult(requested: requested, actualByteCount: data.count)
        }

        var next = capture
        if !processChunk(
            data,
            baseOffset: requested.lowerBound,
            state: &next,
            cancellation: cancellation
        ) {
            return ScanResult(progress: makeProgress(capture), stopReason: .cancelled)
        }
        next.scanOffset = upper

        if upper == byteCount {
            // A trailing CR/LF already completed its row. Otherwise EOF closes
            // the final (possibly quoted) record without materializing it.
            if next.recordStart < byteCount,
               !(next.pendingCarriageReturn && next.recordStart == byteCount) {
                next.completedRecords += 1
            }
            next.pendingCarriageReturn = false
            next.checkpointPending = false
            next.isComplete = true
        }

        withStateLock { $0 = next }
        let resultProgress = makeProgress(next)
        return ScanResult(
            progress: resultProgress,
            stopReason: next.isComplete ? .completed : .advanced
        )
    }

    @discardableResult
    public func scanToEnd(
        cancellation: CancellationCheck? = nil,
        progressHandler: ((Progress) -> Void)? = nil
    ) throws -> ScanResult {
        progressHandler?(progress)
        while true {
            let result = try scanNextChunk(cancellation: cancellation)
            progressHandler?(result.progress)
            if result.stopReason != .advanced { return result }
        }
    }

    /// Resolves one record by rescanning no more than one current checkpoint
    /// interval from the nearest retained byte offset. Reads stay chunk-bounded.
    public func recordLocation(
        forRecord requestedRecord: Int64,
        cancellation: CancellationCheck? = nil
    ) throws -> RecordLocation? {
        try recordLocations(
            startingAt: requestedRecord,
            limit: 1,
            cancellation: cancellation
        ).first
    }

    /// Returns a page of adjacent record ranges with one checkpoint refinement
    /// scan. Table views should use this instead of resolving every visible row
    /// independently. The page cap keeps returned metadata strictly bounded.
    public func recordLocations(
        startingAt requestedRecord: Int64,
        limit requestedLimit: Int,
        cancellation: CancellationCheck? = nil
    ) throws -> [RecordLocation] {
        guard requestedRecord >= 0 else { throw IndexError.invalidRecord(requestedRecord) }
        let limit = min(4_096, max(0, requestedLimit))
        guard limit > 0 else { return [] }
        let desiredUpper: Int64
        if Int64(limit) > Int64.max - requestedRecord {
            desiredUpper = Int64.max
        } else {
            desiredUpper = requestedRecord + Int64(limit)
        }

        while true {
            let current = progress
            if desiredUpper <= current.knownRecordCount || current.isComplete { break }
            let result = try scanNextChunk(cancellation: cancellation)
            if result.stopReason == .cancelled { throw IndexError.cancelled }
        }

        let available = progress.knownRecordCount
        guard requestedRecord < available else { return [] }
        let actualUpper = min(desiredUpper, available)

        let capture: (checkpoints: [Int64], interval: Int64) = withStateLock {
            ($0.checkpoints, $0.checkpointInterval)
        }
        let checkpointIndex64 = requestedRecord / capture.interval
        guard checkpointIndex64 <= Int64(Int.max),
              Int(checkpointIndex64) < capture.checkpoints.count else {
            throw IndexError.inconsistentCheckpointData
        }
        let checkpointIndex = Int(checkpointIndex64)
        let checkpointRecord = Int64(checkpointIndex) * capture.interval
        let startOffset = capture.checkpoints[checkpointIndex]
        return try locateRecords(
            requestedRecord..<actualUpper,
            checkpointRecord: checkpointRecord,
            startOffset: startOffset,
            cancellation: cancellation
        )
    }

    /// Reuses all sparse indexing work after a row-preserving field edit.
    /// CSV table edits replace one encoded field and therefore cannot add or
    /// remove logical record boundaries. Checkpoints at or after the old edit
    /// end shift by the byte delta while record ordinals and parser state stay
    /// valid. The returned index reads only from the new immutable snapshot.
    public func rebased(
        onto snapshot: DocumentSnapshot,
        replacing oldRange: Range<Int64>,
        insertedByteCount: Int64
    ) throws -> CSVRowIndex {
        guard oldRange.lowerBound >= 0,
              oldRange.lowerBound <= oldRange.upperBound,
              oldRange.upperBound <= byteCount,
              insertedByteCount >= 0 else {
            throw IndexError.inconsistentCheckpointData
        }
        let removed = oldRange.upperBound - oldRange.lowerBound
        let (delta, overflow) = insertedByteCount.subtractingReportingOverflow(removed)
        guard !overflow,
              byteCount.addingReportingOverflow(delta).overflow == false,
              snapshot.byteCount == byteCount + delta else {
            throw IndexError.inconsistentCheckpointData
        }

        // Serialize with the current chunk scanner so the captured state and
        // checkpoints describe one coherent prefix. Further work on the old
        // index cannot affect the independent rebased instance.
        scanLock.lock()
        let captured = withStateLock { $0 }
        scanLock.unlock()

        let rebased = try CSVRowIndex(snapshot: snapshot, configuration: configuration)
        var adjusted = captured
        let pivot = oldRange.upperBound
        adjusted.checkpoints = adjusted.checkpoints.map { offset in
            offset >= pivot ? offset + delta : offset
        }
        if adjusted.scanOffset >= pivot { adjusted.scanOffset += delta }
        if adjusted.recordStart >= pivot { adjusted.recordStart += delta }
        guard adjusted.checkpoints.allSatisfy({ $0 >= 0 && $0 <= snapshot.byteCount }),
              adjusted.scanOffset >= 0,
              adjusted.scanOffset <= snapshot.byteCount,
              adjusted.recordStart >= 0,
              adjusted.recordStart <= snapshot.byteCount else {
            throw IndexError.inconsistentCheckpointData
        }
        rebased.withStateLock { $0 = adjusted }
        return rebased
    }

    private func process(_ byte: UInt8, at offset: Int64, state: inout State) {
        if state.pendingCarriageReturn {
            state.pendingCarriageReturn = false
            if byte == 0x0A {
                state.recordStart = offset + 1
                return
            }
        }

        if state.checkpointPending {
            appendCheckpointIfNeeded(at: state.recordStart, state: &state)
            state.checkpointPending = false
        }

        if state.inQuotedField {
            if state.pendingQuote {
                if byte == 0x22 {
                    state.pendingQuote = false // Escaped quote.
                    return
                }
                state.inQuotedField = false
                state.pendingQuote = false
                // The current byte belongs to the unquoted delimiter context.
            } else if byte == 0x22 {
                state.pendingQuote = true
                return
            } else {
                return
            }
        }

        if state.atFieldStart, byte == 0x22 {
            state.inQuotedField = true
            state.pendingQuote = false
            state.atFieldStart = false
        } else if byte == configuration.delimiter {
            state.atFieldStart = true
        } else if byte == 0x0A {
            completeRecord(nextStart: offset + 1, afterCarriageReturn: false, state: &state)
        } else if byte == 0x0D {
            completeRecord(nextStart: offset + 1, afterCarriageReturn: true, state: &state)
        } else {
            state.atFieldStart = false
        }
    }

    /// Skips ordinary field contents eight bytes at a time. CSV indexing only
    /// needs quotes, delimiters, and record terminators; decoding every other
    /// byte through the full RFC-4180 state machine was the dominant cost on
    /// multi-gigabyte exports.
    private func processChunk(
        _ data: Data,
        baseOffset: Int64,
        state: inout State,
        cancellation: CancellationCheck?
    ) -> Bool {
        if configuration.allowsAcceleratedScanner {
            return processChunkAccelerated(
                data,
                baseOffset: baseOffset,
                state: &state,
                cancellation: cancellation
            )
        }
        return processChunkSwift(
            data,
            baseOffset: baseOffset,
            state: &state,
            cancellation: cancellation
        )
    }

    /// Native, allocation-free quote/newline scanning over 64 KiB cancellation
    /// slices. The source chunk is never retained and sparse checkpoint output
    /// is capped by the same adaptive Swift index budget.
    private func processChunkAccelerated(
        _ data: Data,
        baseOffset: Int64,
        state: inout State,
        cancellation: CancellationCheck?
    ) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return true }
            var consumed = 0
            var mustResumeFullOutput = false
            repeat {
                if cancellation?() == true { return false }
                if mustResumeFullOutput {
                    thinCheckpointsToMakeRoom(state: &state)
                }
                let remainingCheckpointCapacity = configuration.maximumCheckpointCount
                    - state.checkpoints.count
                let outputCapacity = min(
                    acceleratedCheckpointScratch.count,
                    remainingCheckpointCapacity
                )

                let segmentByteCount = min(64 << 10, bytes.count - consumed)
                var bridgeState = LighTxtCSVScannerState()
                bridgeState.completedRecords = UInt64(state.completedRecords)
                bridgeState.recordStart = state.recordStart
                bridgeState.checkpointInterval = UInt64(state.checkpointInterval)
                bridgeState.inQuotedField = state.inQuotedField ? 1 : 0
                bridgeState.pendingQuote = state.pendingQuote ? 1 : 0
                bridgeState.atFieldStart = state.atFieldStart ? 1 : 0
                bridgeState.pendingCarriageReturn = state.pendingCarriageReturn ? 1 : 0
                bridgeState.checkpointPending = state.checkpointPending ? 1 : 0

                let result = acceleratedCheckpointScratch.withUnsafeMutableBufferPointer { output in
                    LighTxtScanCSVChunk(
                        base.assumingMemoryBound(to: UInt8.self).advanced(by: consumed),
                        UInt64(segmentByteCount),
                        baseOffset + Int64(consumed),
                        configuration.delimiter,
                        bridgeState,
                        output.baseAddress,
                        UInt64(outputCapacity)
                    )
                }
                guard result.status == UInt32(LighTxtCSVScannerSuccess)
                        || result.status == UInt32(LighTxtCSVScannerCheckpointBufferFull),
                      result.processedByteCount <= UInt64(segmentByteCount),
                      result.emittedCheckpointCount <= UInt64(outputCapacity),
                      result.state.completedRecords <= UInt64(Int64.max) else {
                    return false
                }

                state.completedRecords = Int64(result.state.completedRecords)
                state.recordStart = result.state.recordStart
                state.checkpointInterval = Int64(result.state.checkpointInterval)
                state.inQuotedField = result.state.inQuotedField != 0
                state.pendingQuote = result.state.pendingQuote != 0
                state.atFieldStart = result.state.atFieldStart != 0
                state.pendingCarriageReturn = result.state.pendingCarriageReturn != 0
                state.checkpointPending = result.state.checkpointPending != 0
                for index in 0..<Int(result.emittedCheckpointCount) {
                    state.checkpoints.append(acceleratedCheckpointScratch[index])
                }
                consumed += Int(result.processedByteCount)
                mustResumeFullOutput = result.status
                    == UInt32(LighTxtCSVScannerCheckpointBufferFull)
                if mustResumeFullOutput,
                   result.processedByteCount == 0,
                   result.emittedCheckpointCount == 0,
                   state.checkpoints.count < configuration.maximumCheckpointCount {
                    return false
                }
            } while consumed < bytes.count || mustResumeFullOutput
            return true
        }
    }

    private func processChunkSwift(
        _ data: Data,
        baseOffset: Int64,
        state: inout State,
        cancellation: CancellationCheck?
    ) -> Bool {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return true }
            var cursor = 0
            var nextCancellationCheck = 0
            while cursor < bytes.count {
                if cursor >= nextCancellationCheck {
                    if cancellation?() == true { return false }
                    nextCancellationCheck = cursor + (64 << 10)
                }
                let scanLimit = min(bytes.count, nextCancellationCheck)

                if state.inQuotedField, !state.pendingQuote {
                    let end = csvScanUntilQuote(base, from: cursor, to: scanLimit)
                    if end > cursor {
                        cursor = end
                        if cursor == bytes.count { continue }
                        if cursor == scanLimit { continue }
                    }
                } else if !state.inQuotedField,
                          !state.pendingCarriageReturn,
                          !state.checkpointPending,
                          !state.atFieldStart {
                    let end = csvScanUntilUnquotedSpecial(
                        base,
                        from: cursor,
                        to: scanLimit,
                        delimiter: configuration.delimiter
                    )
                    if end > cursor {
                        cursor = end
                        if cursor == bytes.count { continue }
                        if cursor == scanLimit { continue }
                    }
                }

                let byte = base.load(fromByteOffset: cursor, as: UInt8.self)
                process(byte, at: baseOffset + Int64(cursor), state: &state)
                cursor += 1
            }
            return true
        }
    }

    private func completeRecord(
        nextStart: Int64,
        afterCarriageReturn: Bool,
        state: inout State
    ) {
        state.completedRecords += 1
        state.recordStart = nextStart
        state.inQuotedField = false
        state.pendingQuote = false
        state.atFieldStart = true
        state.pendingCarriageReturn = afterCarriageReturn
        state.checkpointPending = state.completedRecords.isMultiple(of: state.checkpointInterval)
        if !afterCarriageReturn, state.checkpointPending {
            appendCheckpointIfNeeded(at: nextStart, state: &state)
            state.checkpointPending = false
        }
    }

    private func appendCheckpointIfNeeded(at offset: Int64, state: inout State) {
        thinCheckpointsToMakeRoom(state: &state)
        guard state.completedRecords.isMultiple(of: state.checkpointInterval) else { return }
        let expectedIndex = state.completedRecords / state.checkpointInterval
        if expectedIndex == Int64(state.checkpoints.count) {
            state.checkpoints.append(offset)
        }
    }

    private func thinCheckpointsToMakeRoom(state: inout State) {
        while state.checkpoints.count >= configuration.maximumCheckpointCount {
            var thinned: [Int64] = []
            thinned.reserveCapacity((state.checkpoints.count + 1) / 2)
            for index in stride(from: 0, to: state.checkpoints.count, by: 2) {
                thinned.append(state.checkpoints[index])
            }
            state.checkpoints = thinned
            if state.checkpointInterval > Int64.max / 2 {
                state.checkpointInterval = Int64.max
                break
            }
            state.checkpointInterval *= 2
        }
    }

    private func locateRecords(
        _ requestedRecords: Range<Int64>,
        checkpointRecord: Int64,
        startOffset: Int64,
        cancellation: CancellationCheck?
    ) throws -> [RecordLocation] {
        var currentRecord = checkpointRecord
        var recordStart = startOffset
        var offset = startOffset
        var inQuotedField = false
        var pendingQuote = false
        var atFieldStart = true
        var skippedLineFeedOffset: Int64?
        var found: [RecordLocation] = []
        found.reserveCapacity(Int(requestedRecords.count))

        while offset < byteCount {
            if cancellation?() == true { throw IndexError.cancelled }
            let upper = min(byteCount, offset + Int64(configuration.readChunkByteCount))
            let requested = offset..<upper
            let data = try reader(requested)
            guard data.count == Int(requested.count) else {
                throw IndexError.invalidReaderResult(requested: requested, actualByteCount: data.count)
            }

            for (localOffset, byte) in data.enumerated() {
                let position = offset + Int64(localOffset)
                if localOffset.isMultiple(of: 16_384), cancellation?() == true {
                    throw IndexError.cancelled
                }
                if skippedLineFeedOffset == position {
                    skippedLineFeedOffset = nil
                    continue
                }

                if inQuotedField {
                    if pendingQuote {
                        if byte == 0x22 {
                            pendingQuote = false
                            continue
                        }
                        inQuotedField = false
                        pendingQuote = false
                    } else if byte == 0x22 {
                        pendingQuote = true
                        continue
                    } else {
                        continue
                    }
                }

                if atFieldStart, byte == 0x22 {
                    inQuotedField = true
                    pendingQuote = false
                    atFieldStart = false
                } else if byte == configuration.delimiter {
                    atFieldStart = true
                } else if byte == 0x0A || byte == 0x0D {
                    var completeEnd = position + 1
                    if byte == 0x0D, position + 1 < byteCount {
                        let nextByte: UInt8
                        if localOffset + 1 < data.count {
                            // Dense RFC-4180 files normally use CRLF. The LF is
                            // already present in this chunk almost every time;
                            // issuing a separate one-byte snapshot read per row
                            // turns a linear refinement scan into millions of
                            // tiny reads on large exports.
                            nextByte = data[localOffset + 1]
                        } else {
                            // Only a CR at the exact chunk boundary needs a
                            // bounded look-ahead into the next chunk.
                            let requestedNext = (position + 1)..<(position + 2)
                            let next = try reader(requestedNext)
                            guard next.count == 1 else {
                                throw IndexError.invalidReaderResult(
                                    requested: requestedNext,
                                    actualByteCount: next.count
                                )
                            }
                            nextByte = next[0]
                        }
                        if nextByte == 0x0A { completeEnd += 1 }
                    }
                    if requestedRecords.contains(currentRecord) {
                        found.append(RecordLocation(
                            record: currentRecord,
                            contentRange: recordStart..<position,
                            completeRange: recordStart..<completeEnd
                        ))
                        if currentRecord + 1 >= requestedRecords.upperBound { return found }
                    }
                    currentRecord += 1
                    recordStart = completeEnd
                    atFieldStart = true
                    inQuotedField = false
                    pendingQuote = false
                    if byte == 0x0D, completeEnd == position + 2 {
                        // Skip the LF already included in this CRLF terminator,
                        // including when the pair straddles reader chunks.
                        skippedLineFeedOffset = position + 1
                    }
                } else {
                    atFieldStart = false
                }
            }
            offset = upper
        }

        if requestedRecords.contains(currentRecord), recordStart < byteCount {
            found.append(RecordLocation(
                record: currentRecord,
                contentRange: recordStart..<byteCount,
                completeRange: recordStart..<byteCount
            ))
        }
        return found
    }

    private func makeProgress(_ state: State) -> Progress {
        Progress(
            indexedByteCount: state.scanOffset,
            totalByteCount: byteCount,
            knownRecordCount: state.completedRecords,
            totalRecordCount: state.isComplete ? state.completedRecords : nil,
            checkpointCount: state.checkpoints.count,
            checkpointRecordInterval: state.checkpointInterval,
            isComplete: state.isComplete
        )
    }

    @inline(__always)
    private func withStateLock<T>(_ body: (inout State) throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body(&state)
    }
}

@inline(__always)
private nonisolated func csvWordContainsByte(_ word: UInt64, _ byte: UInt8) -> Bool {
    let ones: UInt64 = 0x0101_0101_0101_0101
    let highs: UInt64 = 0x8080_8080_8080_8080
    let repeated = UInt64(byte) &* ones
    let value = word ^ repeated
    return ((value &- ones) & ~value & highs) != 0
}

@inline(__always)
private nonisolated func csvScanUntilQuote(
    _ base: UnsafeRawPointer,
    from start: Int,
    to end: Int
) -> Int {
    var cursor = start
    while cursor + MemoryLayout<UInt64>.size <= end {
        let word = base.loadUnaligned(fromByteOffset: cursor, as: UInt64.self)
        if csvWordContainsByte(word, 0x22) { break }
        cursor += MemoryLayout<UInt64>.size
    }
    while cursor < end,
          base.load(fromByteOffset: cursor, as: UInt8.self) != 0x22 {
        cursor += 1
    }
    return cursor
}

@inline(__always)
private nonisolated func csvScanUntilUnquotedSpecial(
    _ base: UnsafeRawPointer,
    from start: Int,
    to end: Int,
    delimiter: UInt8
) -> Int {
    var cursor = start
    while cursor + MemoryLayout<UInt64>.size <= end {
        let word = base.loadUnaligned(fromByteOffset: cursor, as: UInt64.self)
        if csvWordContainsByte(word, delimiter)
            || csvWordContainsByte(word, 0x0a)
            || csvWordContainsByte(word, 0x0d) { break }
        cursor += MemoryLayout<UInt64>.size
    }
    while cursor < end {
        let byte = base.load(fromByteOffset: cursor, as: UInt8.self)
        if byte == delimiter || byte == 0x0a || byte == 0x0d { break }
        cursor += 1
    }
    return cursor
}

public nonisolated struct CSVFieldValue: Sendable, Equatable {
    /// Exact raw field bytes, including enclosing quotes when present.
    public let byteRange: Range<Int64>
    /// A decoded logical value. Doubled CSV quotes are unescaped.
    public let value: String
    public let wasTruncated: Bool
}

public nonisolated struct CSVParsedRecord: Sendable, Equatable {
    public let fields: [CSVFieldValue]
    public let hadMoreFields: Bool
}

/// A bounded projection of one record. `fieldCount` always describes the
/// complete RFC-4180 record, while `fields` contains only the requested
/// columns. This lets query and transformation code inspect a column near the
/// end of a very wide row without retaining every preceding value.
public nonisolated struct CSVSelectedFields: Sendable, Equatable {
    public let fieldCount: Int
    public let fields: [Int: CSVFieldValue]
}

public nonisolated enum CSVRecordParser {
    public struct Limits: Sendable, Equatable {
        public let maximumFields: Int
        public let maximumPreviewBytesPerField: Int
        public let maximumPreviewBytesPerRecord: Int

        public init(
            maximumFields: Int = 2_048,
            maximumPreviewBytesPerField: Int = 1 << 20,
            maximumPreviewBytesPerRecord: Int = 8 << 20
        ) {
            self.maximumFields = max(1, maximumFields)
            self.maximumPreviewBytesPerField = max(0, maximumPreviewBytesPerField)
            self.maximumPreviewBytesPerRecord = max(0, maximumPreviewBytesPerRecord)
        }
    }

    public static func parse(
        snapshot: DocumentSnapshot,
        location: CSVRowIndex.RecordLocation,
        delimiter: UInt8 = 0x2C,
        limits: Limits = .init(),
        cancellation: CSVRowIndex.CancellationCheck? = nil
    ) throws -> CSVParsedRecord {
        let contentRange = try logicalContentRange(
            snapshot: snapshot,
            location: location
        )
        var fields: [CSVFieldValue] = []
        fields.reserveCapacity(min(32, limits.maximumFields))
        var fieldStart = contentRange.lowerBound
        var current = Data()
        current.reserveCapacity(min(256, limits.maximumPreviewBytesPerField))
        var truncated = false
        var atFieldStart = true
        var inQuotedField = false
        var pendingQuote = false
        var absoluteOffset = contentRange.lowerBound
        var hadMoreFields = false
        var retainedPreviewBytes = 0

        func appendValueByte(_ byte: UInt8) {
            if current.count < limits.maximumPreviewBytesPerField,
               retainedPreviewBytes < limits.maximumPreviewBytesPerRecord {
                current.append(byte)
                retainedPreviewBytes += 1
            } else {
                truncated = true
            }
        }

        func finishField(at end: Int64) {
            if fields.count < limits.maximumFields {
                fields.append(CSVFieldValue(
                    byteRange: fieldStart..<end,
                    value: String(decoding: current, as: UTF8.self),
                    wasTruncated: truncated
                ))
            } else {
                hadMoreFields = true
            }
            current.removeAll(keepingCapacity: true)
            truncated = false
            fieldStart = end + 1
            atFieldStart = true
            inQuotedField = false
            pendingQuote = false
        }

        try snapshot.forEachByteSlice(in: contentRange) { bytes in
            if cancellation?() == true { throw CancellationError() }
            for (localOffset, byte) in bytes.enumerated() {
                if localOffset.isMultiple(of: 16_384), cancellation?() == true {
                    throw CancellationError()
                }
                if inQuotedField {
                    if pendingQuote {
                        if byte == 0x22 {
                            appendValueByte(0x22)
                            pendingQuote = false
                            absoluteOffset += 1
                            continue
                        }
                        inQuotedField = false
                        pendingQuote = false
                    } else if byte == 0x22 {
                        pendingQuote = true
                        absoluteOffset += 1
                        continue
                    } else {
                        appendValueByte(byte)
                        absoluteOffset += 1
                        continue
                    }
                }

                if atFieldStart, byte == 0x22 {
                    inQuotedField = true
                    atFieldStart = false
                } else if byte == delimiter {
                    finishField(at: absoluteOffset)
                } else {
                    appendValueByte(byte)
                    atFieldStart = false
                }
                absoluteOffset += 1
            }
        }
        finishField(at: contentRange.upperBound)
        return CSVParsedRecord(fields: fields, hadMoreFields: hadMoreFields)
    }

    /// Parses only selected logical fields while still scanning the complete
    /// record for exact field coordinates and RFC-4180 quoting. Retained value
    /// bytes are independently capped per field and in aggregate. Callers that
    /// require exact comparisons must reject `wasTruncated` rather than treating
    /// a preview as a complete value.
    public static func selectedFields(
        snapshot: DocumentSnapshot,
        location: CSVRowIndex.RecordLocation,
        columns requestedColumns: Set<Int>,
        delimiter: UInt8 = 0x2C,
        maximumValueBytesPerField: Int = 1 << 20,
        maximumRetainedValueBytes: Int = 4 << 20,
        cancellation: CSVRowIndex.CancellationCheck? = nil
    ) throws -> CSVSelectedFields {
        let contentRange = try logicalContentRange(
            snapshot: snapshot,
            location: location
        )
        let columns = Set(requestedColumns.filter { $0 >= 0 })
        let perFieldLimit = max(0, maximumValueBytesPerField)
        let aggregateLimit = max(0, maximumRetainedValueBytes)
        var selected: [Int: CSVFieldValue] = [:]
        selected.reserveCapacity(columns.count)
        var fieldIndex = 0
        var fieldStart = contentRange.lowerBound
        var current = Data()
        current.reserveCapacity(min(256, perFieldLimit))
        var truncated = false
        var retainedBytes = 0
        var retainsCurrentField = columns.contains(0)
        var atFieldStart = true
        var inQuotedField = false
        var pendingQuote = false
        var absoluteOffset = contentRange.lowerBound

        func appendValueByte(_ byte: UInt8) {
            guard retainsCurrentField else { return }
            if current.count < perFieldLimit, retainedBytes < aggregateLimit {
                current.append(byte)
                retainedBytes += 1
            } else {
                truncated = true
            }
        }

        func finishField(at end: Int64) {
            if retainsCurrentField {
                selected[fieldIndex] = CSVFieldValue(
                    byteRange: fieldStart..<end,
                    value: String(decoding: current, as: UTF8.self),
                    wasTruncated: truncated
                )
            }
            fieldIndex += 1
            retainsCurrentField = columns.contains(fieldIndex)
            current.removeAll(keepingCapacity: true)
            truncated = false
            fieldStart = end + 1
            atFieldStart = true
            inQuotedField = false
            pendingQuote = false
        }

        try snapshot.forEachByteSlice(in: contentRange) { bytes in
            if cancellation?() == true { throw CancellationError() }
            for (localOffset, byte) in bytes.enumerated() {
                if localOffset.isMultiple(of: 16_384), cancellation?() == true {
                    throw CancellationError()
                }
                if inQuotedField {
                    if pendingQuote {
                        if byte == 0x22 {
                            appendValueByte(0x22)
                            pendingQuote = false
                            absoluteOffset += 1
                            continue
                        }
                        inQuotedField = false
                        pendingQuote = false
                    } else if byte == 0x22 {
                        pendingQuote = true
                        absoluteOffset += 1
                        continue
                    } else {
                        appendValueByte(byte)
                        absoluteOffset += 1
                        continue
                    }
                }

                if atFieldStart, byte == 0x22 {
                    inQuotedField = true
                    atFieldStart = false
                } else if byte == delimiter {
                    finishField(at: absoluteOffset)
                } else {
                    appendValueByte(byte)
                    atFieldStart = false
                }
                absoluteOffset += 1
            }
        }
        finishField(at: contentRange.upperBound)
        return CSVSelectedFields(fieldCount: fieldIndex, fields: selected)
    }

    /// UTF-8 BOM bytes describe the file encoding and are not part of the
    /// first logical CSV value. Keep their raw bytes outside the editable
    /// field range so header detection and cell replacement both preserve the
    /// marker used by Excel-style exports.
    private static func logicalContentRange(
        snapshot: DocumentSnapshot,
        location: CSVRowIndex.RecordLocation
    ) throws -> Range<Int64> {
        guard location.record == 0,
              location.contentRange.lowerBound == 0,
              location.contentRange.upperBound >= 3,
              try snapshot.data(in: 0..<3) == Data([0xEF, 0xBB, 0xBF]) else {
            return location.contentRange
        }
        return 3..<location.contentRange.upperBound
    }

    /// Encodes one logical value as a standards-compliant CSV field. Replacing
    /// `CSVFieldValue.byteRange` with this result preserves every untouched byte
    /// in the piece table and never requires a whole-document rewrite.
    public static func encodedField(_ value: String, delimiter: UInt8 = 0x2C) -> Data {
        let bytes = Data(value.utf8)
        let needsQuotes = bytes.contains(delimiter)
            || bytes.contains(0x22)
            || bytes.contains(0x0A)
            || bytes.contains(0x0D)
        guard needsQuotes else { return bytes }

        var encoded = Data()
        encoded.reserveCapacity(bytes.count + 2)
        encoded.append(0x22)
        for byte in bytes {
            if byte == 0x22 { encoded.append(0x22) }
            encoded.append(byte)
        }
        encoded.append(0x22)
        return encoded
    }

    public static func encodedRecord(
        _ values: [String],
        delimiter: UInt8 = 0x2C
    ) -> Data {
        var encoded = Data()
        for (index, value) in values.enumerated() {
            if index > 0 { encoded.append(delimiter) }
            encoded.append(encodedField(value, delimiter: delimiter))
        }
        return encoded
    }
}

public nonisolated enum CSVHeaderDetector {
    public static func isLikelyHeader(
        first: CSVParsedRecord,
        second: CSVParsedRecord?
    ) -> Bool {
        let labels = first.fields.map { $0.value.trimmingCharacters(in: .whitespaces) }
        guard labels.count >= 2,
              labels.allSatisfy({ !$0.isEmpty }),
              Set(labels.map { $0.lowercased() }).count == labels.count else { return false }

        let identifierLike = labels.filter { label in
            label.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_ -./")).contains($0)
            }
        }.count
        guard identifierLike * 4 >= labels.count * 3 else { return false }
        let textualLabels = labels.filter { scalarKind($0) == .text }.count
        guard textualLabels * 4 >= labels.count * 3 else { return false }
        guard let second else { return true }

        let values = second.fields.map(\.value)
        let comparisonCount = min(labels.count, values.count)
        guard comparisonCount > 0 else { return true }
        for index in 0..<comparisonCount where scalarKind(labels[index]) != scalarKind(values[index]) {
            if scalarKind(labels[index]) == .text, scalarKind(values[index]) != .text { return true }
        }
        return labels.contains { $0.contains("_") || $0.contains(" ") }
    }

    private enum ScalarKind { case empty, number, boolean, text }

    private static func scalarKind(_ value: String) -> ScalarKind {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if Double(trimmed) != nil { return .number }
        if ["true", "false", "yes", "no"].contains(trimmed.lowercased()) { return .boolean }
        return .text
    }
}
