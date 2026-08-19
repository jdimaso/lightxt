import Foundation

/// A sparse, byte-addressed line index for UTF-8 documents.
///
/// The index stores one `Int64` offset every `checkpointLineInterval` lines,
/// rather than one object per line. It never materializes the document and asks
/// its reader for at most `readChunkByteCount` bytes at a time. The reader can
/// therefore be backed directly by a `DocumentSnapshot`:
///
///     SparseUTF8LineIndex(byteCount: snapshot.byteCount) { range in
///         try snapshot.data(in: range)
///     }
///
/// All public methods are thread-safe. `scanToEnd` is synchronous by design so
/// callers can run it on their own background queue without the index imposing
/// a task or queue policy.
public nonisolated final class SparseUTF8LineIndex: @unchecked Sendable {
    public typealias ChunkReader = @Sendable (Range<Int64>) throws -> Data
    public typealias CancellationCheck = @Sendable () -> Bool

    public struct Configuration: Sendable, Equatable {
        /// One eight-byte offset is retained for this many logical lines.
        public let checkpointLineInterval: Int64
        /// The largest range ever passed to `ChunkReader`.
        public let readChunkByteCount: Int

        public init(
            checkpointLineInterval: Int64 = 1_024,
            readChunkByteCount: Int = 1 << 20
        ) {
            self.checkpointLineInterval = max(1, checkpointLineInterval)
            self.readChunkByteCount = max(1, readChunkByteCount)
        }
    }

    /// Identifies one immutable byte source. A generation becomes stale as soon
    /// as `invalidate` installs the snapshot produced by an edit.
    public struct Generation: Sendable, Hashable {
        public let rawValue: UInt64
        public let sourceRevision: UInt64?

        fileprivate init(rawValue: UInt64, sourceRevision: UInt64?) {
            self.rawValue = rawValue
            self.sourceRevision = sourceRevision
        }
    }

    /// A zero-based line and zero-based UTF-8 code-unit (byte) column.
    public struct LineAndColumn: Sendable, Equatable {
        public let line: Int64
        public let column: Int64

        public init(line: Int64, column: Int64) {
            self.line = line
            self.column = column
        }
    }

    public struct Progress: Sendable, Equatable {
        public let generation: Generation
        public let indexedByteCount: Int64
        public let totalByteCount: Int64
        /// Lines discovered so far, including the current (possibly partial)
        /// line. The value is exact once `isComplete` is true.
        public let knownLineCount: Int64
        public let totalLineCount: Int64?
        public let checkpointCount: Int
        public let isComplete: Bool

        public var fractionCompleted: Double {
            guard totalByteCount > 0 else { return 1 }
            return min(1, Double(indexedByteCount) / Double(totalByteCount))
        }

        /// Payload bytes retained by the sparse offset array. Array bookkeeping
        /// and the fixed-size scanner state are intentionally excluded.
        public var checkpointPayloadByteCount: Int {
            checkpointCount * MemoryLayout<Int64>.stride
        }
    }

    public enum ScanStopReason: Sendable, Equatable {
        /// One bounded chunk was committed; more input remains.
        case advanced
        case completed
        case cancelled
        /// The reader's generation was replaced while this scan was running.
        case invalidated
    }

    public struct ScanResult: Sendable, Equatable {
        public let progress: Progress
        public let stopReason: ScanStopReason
    }

    public enum IndexError: Swift.Error, LocalizedError, Equatable {
        case invalidByteCount(Int64)
        case invalidLine(Int64)
        case invalidByteOffset(requested: Int64, byteCount: Int64)
        case invalidReaderResult(requested: Range<Int64>, actualByteCount: Int)
        case generationInvalidated(expected: Generation, actual: Generation)
        case cancelled
        case inconsistentCheckpointData

        public var errorDescription: String? {
            switch self {
            case let .invalidByteCount(count):
                return "A line index cannot address a negative byte count (\(count))."
            case let .invalidLine(line):
                return "Line numbers must be zero or greater (received \(line))."
            case let .invalidByteOffset(offset, count):
                return "Byte offset \(offset) is outside the document's 0...\(count) bounds."
            case let .invalidReaderResult(range, actual):
                return "The line-index reader returned \(actual) bytes for the exact range \(range)."
            case let .generationInvalidated(expected, actual):
                return "Line-index generation \(expected.rawValue) was replaced by generation \(actual.rawValue)."
            case .cancelled:
                return "Line indexing was cancelled."
            case .inconsistentCheckpointData:
                return "The sparse line checkpoints are inconsistent with their byte source."
            }
        }
    }

    private struct State {
        var generation: Generation
        var byteCount: Int64
        var reader: ChunkReader
        var checkpoints: [Int64]
        var scannedByteOffset: Int64
        var completedLineBreakCount: Int64
        var hasPendingCarriageReturn: Bool
        var isComplete: Bool
    }

    private struct ScanCapture {
        let generation: Generation
        let byteCount: Int64
        let reader: ChunkReader
        let scannedByteOffset: Int64
        let completedLineBreakCount: Int64
        let hasPendingCarriageReturn: Bool
        let progress: Progress
    }

    private enum ScanCaptureResult {
        case capture(ScanCapture)
        case invalidated(Progress)
    }

    private struct QueryCapture {
        let generation: Generation
        let byteCount: Int64
        let reader: ChunkReader
        let checkpoints: [Int64]
    }

    private let configuration: Configuration
    private let stateLock = NSLock()
    /// Serializes scanners and lookup refinement while still allowing an edit
    /// to invalidate a blocked reader through `stateLock`.
    private let scanLock = NSLock()
    private var state: State

    public init(
        byteCount: Int64,
        sourceRevision: UInt64? = nil,
        configuration: Configuration = .init(),
        reader: @escaping ChunkReader
    ) throws {
        guard byteCount >= 0 else { throw IndexError.invalidByteCount(byteCount) }
        self.configuration = configuration
        self.state = State(
            generation: Generation(rawValue: 0, sourceRevision: sourceRevision),
            byteCount: byteCount,
            reader: reader,
            checkpoints: [0],
            scannedByteOffset: 0,
            completedLineBreakCount: 0,
            hasPendingCarriageReturn: false,
            isComplete: byteCount == 0
        )
    }

    /// Nonthrowing zero-byte source used by the memory-only untitled-document
    /// fallback. No read is ever needed until the first edit invalidates this
    /// generation with the document engine's real snapshot reader.
    public init(
        emptySourceRevision sourceRevision: UInt64? = nil,
        configuration: Configuration = .init()
    ) {
        self.configuration = configuration
        self.state = State(
            generation: Generation(rawValue: 0, sourceRevision: sourceRevision),
            byteCount: 0,
            reader: { _ in Data() },
            checkpoints: [0],
            scannedByteOffset: 0,
            completedLineBreakCount: 0,
            hasPendingCarriageReturn: false,
            isComplete: true
        )
    }

    public var generation: Generation {
        withStateLock { $0.generation }
    }

    public var progress: Progress {
        withStateLock { Self.makeProgress(from: $0) }
    }

    /// The exact line count after a complete scan, otherwise `nil`.
    /// Empty input contains one empty line; a trailing line break creates a
    /// final empty line.
    public var totalLineCount: Int64? {
        progress.totalLineCount
    }

    /// Installs a new immutable source after an edit and invalidates all work
    /// captured from the previous generation. In-flight scans may finish their
    /// current bounded read, but can never commit stale checkpoints afterward.
    @discardableResult
    public func invalidate(
        byteCount: Int64,
        sourceRevision: UInt64? = nil,
        reader: @escaping ChunkReader
    ) throws -> Generation {
        guard byteCount >= 0 else { throw IndexError.invalidByteCount(byteCount) }
        return withStateLock { state in
            let next = Generation(
                rawValue: state.generation.rawValue &+ 1,
                sourceRevision: sourceRevision
            )
            state = State(
                generation: next,
                byteCount: byteCount,
                reader: reader,
                checkpoints: [0],
                scannedByteOffset: 0,
                completedLineBreakCount: 0,
                hasPendingCarriageReturn: false,
                isComplete: byteCount == 0
            )
            return next
        }
    }

    /// Scans and commits at most one configured chunk.
    @discardableResult
    public func scanNextChunk(
        cancellation: CancellationCheck? = nil
    ) throws -> ScanResult {
        scanLock.lock()
        defer { scanLock.unlock() }
        let currentGeneration = withStateLock { $0.generation }
        return try scanNextChunkLocked(
            generation: currentGeneration,
            cancellation: cancellation
        )
    }

    /// Scans one chunk only if `generation` is still current. This overload is
    /// useful to background jobs that captured a generation before dispatch.
    @discardableResult
    public func scanNextChunk(
        generation: Generation,
        cancellation: CancellationCheck? = nil
    ) throws -> ScanResult {
        scanLock.lock()
        defer { scanLock.unlock() }
        return try scanNextChunkLocked(
            generation: generation,
            cancellation: cancellation
        )
    }

    /// Repeatedly scans bounded chunks until completion, cancellation, or edit
    /// invalidation. Invoke this method on a background queue for eager indexing.
    @discardableResult
    public func scanToEnd(
        cancellation: CancellationCheck? = nil,
        progressHandler: ((Progress) -> Void)? = nil
    ) throws -> ScanResult {
        let currentGeneration = generation
        return try scanToEnd(
            generation: currentGeneration,
            cancellation: cancellation,
            progressHandler: progressHandler
        )
    }

    /// Generation-pinned variant for a previously dispatched background job.
    @discardableResult
    public func scanToEnd(
        generation: Generation,
        cancellation: CancellationCheck? = nil,
        progressHandler: ((Progress) -> Void)? = nil
    ) throws -> ScanResult {
        progressHandler?(progress)
        while true {
            let result = try scanNextChunk(
                generation: generation,
                cancellation: cancellation
            )
            progressHandler?(result.progress)
            if result.stopReason != .advanced { return result }
        }
    }

    /// Returns the byte offset of a zero-based line, or `nil` when a completed
    /// scan proves the line does not exist. At most one checkpoint interval is
    /// rescanned for the final lookup.
    public func byteOffset(
        forLine line: Int64,
        cancellation: CancellationCheck? = nil
    ) throws -> Int64? {
        try byteOffset(
            forLine: line,
            generation: generation,
            cancellation: cancellation
        )
    }

    public func byteOffset(
        forLine line: Int64,
        generation: Generation,
        cancellation: CancellationCheck? = nil
    ) throws -> Int64? {
        guard line >= 0 else { throw IndexError.invalidLine(line) }
        scanLock.lock()
        defer { scanLock.unlock() }

        guard try ensureLineIsKnownLocked(
            line,
            generation: generation,
            cancellation: cancellation
        ) else {
            return nil
        }

        let capture = try queryCapture(expected: generation)
        let checkpointNumber = line / configuration.checkpointLineInterval
        guard checkpointNumber <= Int64(Int.max),
              Int(checkpointNumber) < capture.checkpoints.count else {
            throw IndexError.inconsistentCheckpointData
        }
        let checkpointIndex = Int(checkpointNumber)
        let checkpointLine = checkpointNumber * configuration.checkpointLineInterval
        let checkpointOffset = capture.checkpoints[checkpointIndex]
        if checkpointLine == line {
            try requireCurrent(generation)
            return checkpointOffset
        }

        return try locateLineStart(
            targetLine: line,
            checkpointLine: checkpointLine,
            checkpointOffset: checkpointOffset,
            capture: capture,
            cancellation: cancellation
        )
    }

    /// Resolves a byte insertion point to a zero-based line and UTF-8 byte
    /// column. The end-of-document offset is valid. A position inside a CRLF
    /// pair remains on the preceding line; the next line starts after LF.
    public func lineAndColumn(
        forByteOffset byteOffset: Int64,
        cancellation: CancellationCheck? = nil
    ) throws -> LineAndColumn {
        try lineAndColumn(
            forByteOffset: byteOffset,
            generation: generation,
            cancellation: cancellation
        )
    }

    public func lineAndColumn(
        forByteOffset byteOffset: Int64,
        generation: Generation,
        cancellation: CancellationCheck? = nil
    ) throws -> LineAndColumn {
        scanLock.lock()
        defer { scanLock.unlock() }

        let initialByteCount = try withStateLock { state in
            guard state.generation == generation else {
                throw IndexError.generationInvalidated(
                    expected: generation,
                    actual: state.generation
                )
            }
            return state.byteCount
        }
        guard byteOffset >= 0, byteOffset <= initialByteCount else {
            throw IndexError.invalidByteOffset(
                requested: byteOffset,
                byteCount: initialByteCount
            )
        }
        try ensureByteIsKnownLocked(
            byteOffset,
            generation: generation,
            cancellation: cancellation
        )

        let capture = try queryCapture(expected: generation)
        let checkpointIndex = Self.lastCheckpointIndex(
            atOrBefore: byteOffset,
            checkpoints: capture.checkpoints
        )
        let checkpointLine = Int64(checkpointIndex)
            * configuration.checkpointLineInterval
        return try locatePosition(
            byteOffset: byteOffset,
            checkpointLine: checkpointLine,
            checkpointOffset: capture.checkpoints[checkpointIndex],
            capture: capture,
            cancellation: cancellation
        )
    }

    private func scanNextChunkLocked(
        generation expectedGeneration: Generation,
        cancellation: CancellationCheck?
    ) throws -> ScanResult {
        let captureOrProgress: ScanCaptureResult = withStateLock { state in
            guard state.generation == expectedGeneration else {
                return .invalidated(Self.makeProgress(from: state))
            }
            return .capture(ScanCapture(
                generation: state.generation,
                byteCount: state.byteCount,
                reader: state.reader,
                scannedByteOffset: state.scannedByteOffset,
                completedLineBreakCount: state.completedLineBreakCount,
                hasPendingCarriageReturn: state.hasPendingCarriageReturn,
                progress: Self.makeProgress(from: state)
            ))
        }

        let capture: ScanCapture
        switch captureOrProgress {
        case let .capture(value):
            capture = value
        case let .invalidated(currentProgress):
            return ScanResult(progress: currentProgress, stopReason: .invalidated)
        }

        if let invalidated = invalidatedProgress(expected: expectedGeneration) {
            return ScanResult(progress: invalidated, stopReason: .invalidated)
        }
        let currentProgress = capture.progress
        if currentProgress.isComplete {
            return ScanResult(progress: currentProgress, stopReason: .completed)
        }
        if cancellation?() == true {
            return ScanResult(progress: currentProgress, stopReason: .cancelled)
        }

        let remaining = capture.byteCount - capture.scannedByteOffset
        let requestedCount = min(Int64(configuration.readChunkByteCount), remaining)
        let upperBound = capture.scannedByteOffset + requestedCount
        let range = capture.scannedByteOffset..<upperBound
        let data: Data
        do {
            data = try capture.reader(range)
        } catch {
            if let invalidated = invalidatedProgress(expected: expectedGeneration) {
                return ScanResult(progress: invalidated, stopReason: .invalidated)
            }
            throw error
        }

        if let invalidated = invalidatedProgress(expected: expectedGeneration) {
            return ScanResult(progress: invalidated, stopReason: .invalidated)
        }
        guard data.count == Int(requestedCount) else {
            throw IndexError.invalidReaderResult(
                requested: range,
                actualByteCount: data.count
            )
        }
        if cancellation?() == true {
            return ScanResult(progress: progress, stopReason: .cancelled)
        }

        var completedBreaks = capture.completedLineBreakCount
        var pendingCR = capture.hasPendingCarriageReturn
        var newCheckpoints: [Int64] = []
        var interruptedByCancellation = false
        var interruptedByInvalidation = false

        @inline(__always)
        func recordLineStart(at byteOffset: Int64) {
            completedBreaks += 1
            if completedBreaks % configuration.checkpointLineInterval == 0 {
                newCheckpoints.append(byteOffset)
            }
        }

        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            for index in bytes.indices {
                if index & 0xffff == 0 {
                    if cancellation?() == true {
                        interruptedByCancellation = true
                        break
                    }
                    if !isCurrent(expectedGeneration) {
                        interruptedByInvalidation = true
                        break
                    }
                }

                let byte = bytes[index]
                let absoluteOffset = range.lowerBound + Int64(index)
                if pendingCR {
                    if byte == 0x0a {
                        pendingCR = false
                        recordLineStart(at: absoluteOffset + 1)
                        continue
                    }
                    pendingCR = false
                    recordLineStart(at: absoluteOffset)
                }

                if byte == 0x0d {
                    pendingCR = true
                } else if byte == 0x0a {
                    recordLineStart(at: absoluteOffset + 1)
                }
            }
        }

        if interruptedByInvalidation,
           let invalidated = invalidatedProgress(expected: expectedGeneration) {
            return ScanResult(progress: invalidated, stopReason: .invalidated)
        }
        if interruptedByCancellation || cancellation?() == true {
            if let invalidated = invalidatedProgress(expected: expectedGeneration) {
                return ScanResult(progress: invalidated, stopReason: .invalidated)
            }
            return ScanResult(progress: progress, stopReason: .cancelled)
        }

        var completed = upperBound == capture.byteCount
        if completed, pendingCR {
            pendingCR = false
            recordLineStart(at: capture.byteCount)
        }

        let commit: (Progress, Bool) = withStateLock { state in
            guard state.generation == expectedGeneration,
                  state.scannedByteOffset == capture.scannedByteOffset else {
                return (Self.makeProgress(from: state), false)
            }
            state.checkpoints.append(contentsOf: newCheckpoints)
            state.scannedByteOffset = upperBound
            state.completedLineBreakCount = completedBreaks
            state.hasPendingCarriageReturn = pendingCR
            state.isComplete = completed
            return (Self.makeProgress(from: state), true)
        }
        guard commit.1 else {
            return ScanResult(progress: commit.0, stopReason: .invalidated)
        }
        completed = commit.0.isComplete
        return ScanResult(
            progress: commit.0,
            stopReason: completed ? .completed : .advanced
        )
    }

    private func ensureLineIsKnownLocked(
        _ line: Int64,
        generation: Generation,
        cancellation: CancellationCheck?
    ) throws -> Bool {
        while true {
            let status: (breaks: Int64, complete: Bool, actual: Generation) =
                withStateLock { state in
                    (
                        state.completedLineBreakCount,
                        state.isComplete,
                        state.generation
                    )
                }
            guard status.actual == generation else {
                throw IndexError.generationInvalidated(
                    expected: generation,
                    actual: status.actual
                )
            }
            if status.breaks >= line { return true }
            if status.complete { return false }

            let result = try scanNextChunkLocked(
                generation: generation,
                cancellation: cancellation
            )
            try requireUsable(result, expected: generation)
        }
    }

    private func ensureByteIsKnownLocked(
        _ byteOffset: Int64,
        generation: Generation,
        cancellation: CancellationCheck?
    ) throws {
        while true {
            let status: (
                scanned: Int64,
                pendingCR: Bool,
                complete: Bool,
                actual: Generation
            ) = withStateLock { state in
                (
                    state.scannedByteOffset,
                    state.hasPendingCarriageReturn,
                    state.isComplete,
                    state.generation
                )
            }
            guard status.actual == generation else {
                throw IndexError.generationInvalidated(
                    expected: generation,
                    actual: status.actual
                )
            }

            // A CR immediately before this insertion point needs one-byte
            // lookahead to distinguish CRLF from a lone CR.
            let unresolvedAtTarget = status.scanned == byteOffset
                && status.pendingCR
                && !status.complete
            if status.scanned >= byteOffset, !unresolvedAtTarget { return }

            let result = try scanNextChunkLocked(
                generation: generation,
                cancellation: cancellation
            )
            try requireUsable(result, expected: generation)
        }
    }

    private func requireUsable(
        _ result: ScanResult,
        expected: Generation
    ) throws {
        switch result.stopReason {
        case .advanced, .completed:
            return
        case .cancelled:
            throw IndexError.cancelled
        case .invalidated:
            throw IndexError.generationInvalidated(
                expected: expected,
                actual: result.progress.generation
            )
        }
    }

    private func locateLineStart(
        targetLine: Int64,
        checkpointLine: Int64,
        checkpointOffset: Int64,
        capture: QueryCapture,
        cancellation: CancellationCheck?
    ) throws -> Int64 {
        var line = checkpointLine
        var cursor = checkpointOffset
        var pendingCR = false
        var foundOffset: Int64?

        while cursor < capture.byteCount, foundOffset == nil {
            try checkInterruption(
                expected: capture.generation,
                cancellation: cancellation
            )
            let requestedCount = min(
                Int64(configuration.readChunkByteCount),
                capture.byteCount - cursor
            )
            let upperBound = cursor + requestedCount
            let range = cursor..<upperBound
            let data = try readExact(range, using: capture.reader)
            try requireCurrent(capture.generation)

            data.withUnsafeBytes { rawBuffer in
                let bytes = rawBuffer.bindMemory(to: UInt8.self)
                for index in bytes.indices {
                    let byte = bytes[index]
                    let absoluteOffset = range.lowerBound + Int64(index)
                    if pendingCR {
                        if byte == 0x0a {
                            pendingCR = false
                            line += 1
                            if line == targetLine {
                                foundOffset = absoluteOffset + 1
                                break
                            }
                            continue
                        }
                        pendingCR = false
                        line += 1
                        if line == targetLine {
                            foundOffset = absoluteOffset
                            break
                        }
                    }

                    if byte == 0x0d {
                        pendingCR = true
                    } else if byte == 0x0a {
                        line += 1
                        if line == targetLine {
                            foundOffset = absoluteOffset + 1
                            break
                        }
                    }
                }
            }
            cursor = upperBound
        }

        if foundOffset == nil, pendingCR, cursor == capture.byteCount {
            line += 1
            if line == targetLine { foundOffset = capture.byteCount }
        }
        try checkInterruption(
            expected: capture.generation,
            cancellation: cancellation
        )
        guard let foundOffset else {
            throw IndexError.inconsistentCheckpointData
        }
        return foundOffset
    }

    private func locatePosition(
        byteOffset: Int64,
        checkpointLine: Int64,
        checkpointOffset: Int64,
        capture: QueryCapture,
        cancellation: CancellationCheck?
    ) throws -> LineAndColumn {
        var line = checkpointLine
        var lineStart = checkpointOffset
        var cursor = checkpointOffset
        var pendingCR = false

        @inline(__always)
        func recordLineStart(at offset: Int64) {
            line += 1
            lineStart = offset
        }

        while cursor < byteOffset {
            try checkInterruption(
                expected: capture.generation,
                cancellation: cancellation
            )
            let requestedCount = min(
                Int64(configuration.readChunkByteCount),
                byteOffset - cursor
            )
            let upperBound = cursor + requestedCount
            let range = cursor..<upperBound
            let data = try readExact(range, using: capture.reader)
            try requireCurrent(capture.generation)

            data.withUnsafeBytes { rawBuffer in
                let bytes = rawBuffer.bindMemory(to: UInt8.self)
                for index in bytes.indices {
                    let byte = bytes[index]
                    let absoluteOffset = range.lowerBound + Int64(index)
                    if pendingCR {
                        if byte == 0x0a {
                            pendingCR = false
                            recordLineStart(at: absoluteOffset + 1)
                            continue
                        }
                        pendingCR = false
                        recordLineStart(at: absoluteOffset)
                    }

                    if byte == 0x0d {
                        pendingCR = true
                    } else if byte == 0x0a {
                        recordLineStart(at: absoluteOffset + 1)
                    }
                }
            }
            cursor = upperBound
        }

        if pendingCR {
            if byteOffset == capture.byteCount {
                recordLineStart(at: byteOffset)
            } else {
                let lookaheadRange = byteOffset..<(byteOffset + 1)
                let lookahead = try readExact(
                    lookaheadRange,
                    using: capture.reader
                )
                try requireCurrent(capture.generation)
                if lookahead[lookahead.startIndex] != 0x0a {
                    recordLineStart(at: byteOffset)
                }
            }
        }

        try checkInterruption(
            expected: capture.generation,
            cancellation: cancellation
        )
        return LineAndColumn(line: line, column: byteOffset - lineStart)
    }

    private func readExact(
        _ range: Range<Int64>,
        using reader: ChunkReader
    ) throws -> Data {
        let data = try reader(range)
        let expected = Int(range.upperBound - range.lowerBound)
        guard data.count == expected else {
            throw IndexError.invalidReaderResult(
                requested: range,
                actualByteCount: data.count
            )
        }
        return data
    }

    private func queryCapture(expected: Generation) throws -> QueryCapture {
        try withStateLock { state in
            guard state.generation == expected else {
                throw IndexError.generationInvalidated(
                    expected: expected,
                    actual: state.generation
                )
            }
            return QueryCapture(
                generation: state.generation,
                byteCount: state.byteCount,
                reader: state.reader,
                checkpoints: state.checkpoints
            )
        }
    }

    private func checkInterruption(
        expected: Generation,
        cancellation: CancellationCheck?
    ) throws {
        if cancellation?() == true { throw IndexError.cancelled }
        try requireCurrent(expected)
    }

    private func requireCurrent(_ expected: Generation) throws {
        let actual = withStateLock { $0.generation }
        guard actual == expected else {
            throw IndexError.generationInvalidated(
                expected: expected,
                actual: actual
            )
        }
    }

    private func isCurrent(_ expected: Generation) -> Bool {
        withStateLock { $0.generation == expected }
    }

    private func invalidatedProgress(expected: Generation) -> Progress? {
        withStateLock { state in
            state.generation == expected ? nil : Self.makeProgress(from: state)
        }
    }

    private static func lastCheckpointIndex(
        atOrBefore byteOffset: Int64,
        checkpoints: [Int64]
    ) -> Int {
        var lowerBound = 0
        var upperBound = checkpoints.count
        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if checkpoints[middle] <= byteOffset {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return max(0, lowerBound - 1)
    }

    private static func makeProgress(from state: State) -> Progress {
        Progress(
            generation: state.generation,
            indexedByteCount: state.scannedByteOffset,
            totalByteCount: state.byteCount,
            knownLineCount: state.completedLineBreakCount + 1,
            totalLineCount: state.isComplete
                ? state.completedLineBreakCount + 1
                : nil,
            checkpointCount: state.checkpoints.count,
            isComplete: state.isComplete
        )
    }

    @inline(__always)
    private func withStateLock<Result>(
        _ body: (inout State) throws -> Result
    ) rethrows -> Result {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body(&state)
    }
}
