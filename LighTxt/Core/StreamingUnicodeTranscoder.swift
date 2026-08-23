import Darwin
import Foundation

/// Configuration for a bounded Unicode transcoding pass.
public struct UnicodeTranscodingConfiguration: Sendable {
    public static let maximumReadChunkByteCount = 1 << 20

    /// Bytes read from the source at once. Values are clamped to 1...1 MiB.
    public var readChunkByteCount: Int
    /// Minimum source-byte distance between progress callbacks.
    public var progressIntervalByteCount: Int64
    /// A unique mode-0700 directory is created beneath this directory. Nil uses
    /// Foundation's process-private temporary directory.
    public var scratchDirectoryParentURL: URL?
    /// Synchronize the completed inode before it is published inside its
    /// private scratch directory.
    public var synchronizeOutput: Bool

    public init(
        readChunkByteCount: Int = 256 << 10,
        progressIntervalByteCount: Int64 = 4 << 20,
        scratchDirectoryParentURL: URL? = nil,
        synchronizeOutput: Bool = false
    ) {
        self.readChunkByteCount = min(
            Self.maximumReadChunkByteCount,
            max(1, readChunkByteCount)
        )
        self.progressIntervalByteCount = max(1, progressIntervalByteCount)
        self.scratchDirectoryParentURL = scratchDirectoryParentURL
        self.synchronizeOutput = synchronizeOutput
    }
}

public struct UnicodeTranscodingProgress: Sendable, Equatable {
    /// Includes a consumed source byte-order mark, when present.
    public let sourceBytesProcessed: Int64
    public let sourceByteCount: Int64
    /// Bytes generated for the destination, including its BOM when requested.
    public let outputBytesProduced: Int64

    public init(
        sourceBytesProcessed: Int64,
        sourceByteCount: Int64,
        outputBytesProduced: Int64
    ) {
        self.sourceBytesProcessed = max(0, sourceBytesProcessed)
        self.sourceByteCount = max(0, sourceByteCount)
        self.outputBytesProduced = max(0, outputBytesProduced)
    }

    public var fractionCompleted: Double {
        guard sourceByteCount > 0 else { return 1 }
        return min(1, Double(sourceBytesProcessed) / Double(sourceByteCount))
    }
}

public enum UnicodeTranscodingError: Error, LocalizedError, Equatable, Sendable {
    case sourceIsNotRegularFile(path: String)
    case fileTooLarge(Int64)
    case byteOrderMarkMismatch(
        expected: DocumentTextEncoding,
        found: DocumentTextEncoding
    )
    /// The offset is the start of the malformed sequence or code unit.
    case malformedInput(encoding: DocumentTextEncoding, byteOffset: Int64)
    case sourceChanged(path: String)
    case io(operation: String, path: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case let .sourceIsNotRegularFile(path):
            return "Unicode transcoding requires a regular file: \(path)"
        case let .fileTooLarge(byteCount):
            return "The source is too large to address on this system (\(byteCount) bytes)."
        case let .byteOrderMarkMismatch(expected, found):
            return "The file has a \(found.rawValue) byte-order mark, not \(expected.rawValue)."
        case let .malformedInput(encoding, byteOffset):
            return "Malformed \(encoding.rawValue) input at byte offset \(byteOffset)."
        case let .sourceChanged(path):
            return "The source changed while it was being transcoded: \(path)"
        case let .io(operation, path, code):
            return "Could not \(operation) \(path) (POSIX error \(code): \(String(cString: strerror(code))))."
        }
    }
}

/// Owns one completed transcoding result and its private scratch directory.
/// Releasing or explicitly discarding the handle removes both.
public nonisolated final class UnicodeScratchFile: @unchecked Sendable {
    public let fileURL: URL
    public let scratchDirectoryURL: URL
    public let sourceEncoding: DocumentTextEncoding
    public let outputEncoding: DocumentTextEncoding
    public let sourceByteCount: Int64
    public let outputByteCount: Int64
    public let sourceByteOrderMarkByteCount: Int
    public let outputByteOrderMarkByteCount: Int

    private let lock = NSLock()
    private var discarded = false

    fileprivate init(
        fileURL: URL,
        scratchDirectoryURL: URL,
        sourceEncoding: DocumentTextEncoding,
        outputEncoding: DocumentTextEncoding,
        sourceByteCount: Int64,
        outputByteCount: Int64,
        sourceByteOrderMarkByteCount: Int,
        outputByteOrderMarkByteCount: Int
    ) {
        self.fileURL = fileURL
        self.scratchDirectoryURL = scratchDirectoryURL
        self.sourceEncoding = sourceEncoding
        self.outputEncoding = outputEncoding
        self.sourceByteCount = sourceByteCount
        self.outputByteCount = outputByteCount
        self.sourceByteOrderMarkByteCount = sourceByteOrderMarkByteCount
        self.outputByteOrderMarkByteCount = outputByteOrderMarkByteCount
    }

    deinit {
        discard()
    }

    public func discard() {
        lock.lock()
        guard !discarded else {
            lock.unlock()
            return
        }
        discarded = true
        lock.unlock()
        try? FileManager.default.removeItem(at: scratchDirectoryURL)
    }
}

/// Strict, bounded-memory Unicode conversion for file opening and export.
public enum StreamingUnicodeTranscoder {
    private static let outputBufferByteCount = 64 << 10

    /// Strictly validates one immutable document revision as UTF-8 without
    /// copying it or materializing it in memory. Snapshot slices are already
    /// hard-capped at 1 MiB, and the decoder carries partial scalars across
    /// slice and piece boundaries.
    public static func validateUTF8(
        snapshot: DocumentSnapshot,
        cancellation: CancellationToken? = nil,
        progress: ((UnicodeTranscodingProgress) -> Void)? = nil
    ) throws {
        if cancellation?.isCancelled == true { throw CancellationError() }

        var decoder = StreamingUnicodeScalarDecoder(encoding: .utf8)
        var sourceOffset: Int64 = 0
        progress?(
            UnicodeTranscodingProgress(
                sourceBytesProcessed: 0,
                sourceByteCount: snapshot.byteCount,
                outputBytesProduced: 0
            )
        )
        try snapshot.forEachByteSlice { bytes in
            if cancellation?.isCancelled == true { throw CancellationError() }
            try decoder.consume(
                bytes,
                startingAt: sourceOffset,
                cancellation: cancellation,
                emit: { _ in }
            )
            sourceOffset += Int64(bytes.count)
            progress?(
                UnicodeTranscodingProgress(
                    sourceBytesProcessed: sourceOffset,
                    sourceByteCount: snapshot.byteCount,
                    outputBytesProduced: 0
                )
            )
        }
        try decoder.finish()
        if cancellation?.isCancelled == true { throw CancellationError() }
    }

    /// Converts one explicitly selected source encoding to the BOM-free UTF-8
    /// representation expected by LighTxt's byte-addressed core.
    public static func transcodeFileToUTF8(
        at sourceURL: URL,
        sourceEncoding: DocumentTextEncoding,
        configuration: UnicodeTranscodingConfiguration = .init(),
        cancellation: CancellationToken? = nil,
        progress: ((UnicodeTranscodingProgress) -> Void)? = nil
    ) throws -> UnicodeScratchFile {
        try transcodeFile(
            at: sourceURL,
            sourceEncoding: sourceEncoding,
            outputEncoding: .utf8,
            includeOutputByteOrderMark: false,
            configuration: configuration,
            cancellation: cancellation,
            progress: progress
        )
    }

    /// Converts a strict UTF-8 file to another supported Unicode encoding.
    /// This is suitable for a later Save As/export path without materializing a
    /// complete document in memory.
    public static func transcodeUTF8File(
        at sourceURL: URL,
        to outputEncoding: DocumentTextEncoding,
        includeByteOrderMark: Bool = true,
        configuration: UnicodeTranscodingConfiguration = .init(),
        cancellation: CancellationToken? = nil,
        progress: ((UnicodeTranscodingProgress) -> Void)? = nil
    ) throws -> UnicodeScratchFile {
        try transcodeFile(
            at: sourceURL,
            sourceEncoding: .utf8,
            outputEncoding: outputEncoding,
            includeOutputByteOrderMark: includeByteOrderMark,
            configuration: configuration,
            cancellation: cancellation,
            progress: progress
        )
    }

    /// General strict file-to-file conversion. A matching source BOM is
    /// consumed; a conflicting supported BOM fails before any scratch output is
    /// created. The final filename appears via an atomic rename only after all
    /// input has been validated and written successfully.
    public static func transcodeFile(
        at sourceURL: URL,
        sourceEncoding: DocumentTextEncoding,
        outputEncoding: DocumentTextEncoding,
        includeOutputByteOrderMark: Bool,
        configuration: UnicodeTranscodingConfiguration = .init(),
        cancellation: CancellationToken? = nil,
        progress: ((UnicodeTranscodingProgress) -> Void)? = nil
    ) throws -> UnicodeScratchFile {
        if cancellation?.isCancelled == true { throw CancellationError() }

        // Configuration is intentionally mutable for ergonomic call sites, so
        // enforce the hard bounds again at the operation boundary.
        let readChunkByteCount = min(
            UnicodeTranscodingConfiguration.maximumReadChunkByteCount,
            max(1, configuration.readChunkByteCount)
        )
        let progressIntervalByteCount = max(
            1,
            configuration.progressIntervalByteCount
        )

        let resolvedSourceURL = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        let sourcePath = resolvedSourceURL.path
        let sourceDescriptor = Darwin.open(sourcePath, O_RDONLY | O_CLOEXEC)
        guard sourceDescriptor >= 0 else {
            throw UnicodeTranscodingError.io(
                operation: "open",
                path: sourcePath,
                code: errno
            )
        }
        defer { Darwin.close(sourceDescriptor) }

        var initialStatus = stat()
        guard fstat(sourceDescriptor, &initialStatus) == 0 else {
            throw UnicodeTranscodingError.io(
                operation: "inspect",
                path: sourcePath,
                code: errno
            )
        }
        guard initialStatus.st_mode & S_IFMT == S_IFREG else {
            throw UnicodeTranscodingError.sourceIsNotRegularFile(path: sourcePath)
        }
        let sourceByteCount = Int64(initialStatus.st_size)
        guard sourceByteCount >= 0, sourceByteCount <= Int64(Int.max) else {
            throw UnicodeTranscodingError.fileTooLarge(sourceByteCount)
        }
        let sourceFingerprint = FileFingerprint(initialStatus)

        let prefix = try readPrefix(
            descriptor: sourceDescriptor,
            byteCount: min(4, Int(sourceByteCount)),
            path: sourcePath
        )
        let expectedBOM = byteOrderMark(for: sourceEncoding)
        let sourceBOMByteCount: Int
        if prefix.starts(with: expectedBOM) {
            // UTF-16 LE's BOM followed by U+0000 has the same four-byte prefix
            // as UTF-32 LE's BOM. The caller's explicit Open As choice breaks
            // that unavoidable ambiguity.
            sourceBOMByteCount = expectedBOM.count
        } else if let detectedBOM = byteOrderMark(in: prefix) {
            throw UnicodeTranscodingError.byteOrderMarkMismatch(
                expected: sourceEncoding,
                found: detectedBOM.encoding
            )
        } else {
            sourceBOMByteCount = 0
        }

        let area = try makeScratchArea(
            parentURL: configuration.scratchDirectoryParentURL,
            outputEncoding: outputEncoding
        )
        var removeScratchArea = true
        defer {
            if removeScratchArea {
                try? FileManager.default.removeItem(at: area.directoryURL)
            }
        }

        var outputDescriptor = Darwin.open(
            area.partialURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(0o600)
        )
        guard outputDescriptor >= 0 else {
            throw UnicodeTranscodingError.io(
                operation: "create scratch file",
                path: area.partialURL.path,
                code: errno
            )
        }
        defer {
            if outputDescriptor >= 0 { Darwin.close(outputDescriptor) }
        }
        guard fchmod(outputDescriptor, mode_t(0o600)) == 0 else {
            throw UnicodeTranscodingError.io(
                operation: "secure scratch file",
                path: area.partialURL.path,
                code: errno
            )
        }

        let writer = UnicodeOutputBuffer(
            descriptor: outputDescriptor,
            path: area.partialURL.path,
            encoding: outputEncoding,
            maximumBufferedByteCount: outputBufferByteCount
        )
        let outputBOM = includeOutputByteOrderMark
            ? byteOrderMark(for: outputEncoding)
            : []
        try writer.appendRawBytes(outputBOM)

        var decoder = StreamingUnicodeScalarDecoder(encoding: sourceEncoding)
        var sourceOffset = Int64(sourceBOMByteCount)
        var nextProgressOffset = progressIntervalByteCount
        progress?(
            UnicodeTranscodingProgress(
                sourceBytesProcessed: 0,
                sourceByteCount: sourceByteCount,
                outputBytesProduced: writer.outputByteCount
            )
        )
        if cancellation?.isCancelled == true { throw CancellationError() }

        while sourceOffset < sourceByteCount {
            if cancellation?.isCancelled == true { throw CancellationError() }
            let requested = min(
                readChunkByteCount,
                Int(sourceByteCount - sourceOffset)
            )
            let bytes = try readExactly(
                descriptor: sourceDescriptor,
                byteCount: requested,
                offset: sourceOffset,
                path: sourcePath
            )
            try bytes.withUnsafeBytes { rawBytes in
                try decoder.consume(
                    rawBytes,
                    startingAt: sourceOffset,
                    cancellation: cancellation
                ) { scalar in
                    try writer.append(scalar: scalar)
                }
            }
            sourceOffset += Int64(requested)

            if sourceOffset >= nextProgressOffset || sourceOffset == sourceByteCount {
                progress?(
                    UnicodeTranscodingProgress(
                        sourceBytesProcessed: sourceOffset,
                        sourceByteCount: sourceByteCount,
                        outputBytesProduced: writer.outputByteCount
                    )
                )
                nextProgressOffset = sourceOffset > Int64.max - progressIntervalByteCount
                    ? Int64.max
                    : sourceOffset + progressIntervalByteCount
            }
        }

        try decoder.finish()
        if sourceOffset != sourceByteCount {
            throw UnicodeTranscodingError.sourceChanged(path: sourcePath)
        }
        if sourceByteCount == Int64(sourceBOMByteCount) {
            progress?(
                UnicodeTranscodingProgress(
                    sourceBytesProcessed: sourceByteCount,
                    sourceByteCount: sourceByteCount,
                    outputBytesProduced: writer.outputByteCount
                )
            )
        }
        if cancellation?.isCancelled == true { throw CancellationError() }

        try writer.flush()
        if configuration.synchronizeOutput, fsync(outputDescriptor) != 0 {
            throw UnicodeTranscodingError.io(
                operation: "synchronize scratch file",
                path: area.partialURL.path,
                code: errno
            )
        }
        let closeResult = Darwin.close(outputDescriptor)
        outputDescriptor = -1
        guard closeResult == 0 else {
            throw UnicodeTranscodingError.io(
                operation: "close scratch file",
                path: area.partialURL.path,
                code: errno
            )
        }

        var finalStatus = stat()
        guard fstat(sourceDescriptor, &finalStatus) == 0 else {
            throw UnicodeTranscodingError.io(
                operation: "reinspect",
                path: sourcePath,
                code: errno
            )
        }
        guard FileFingerprint(finalStatus) == sourceFingerprint else {
            throw UnicodeTranscodingError.sourceChanged(path: sourcePath)
        }
        if cancellation?.isCancelled == true { throw CancellationError() }

        guard Darwin.rename(area.partialURL.path, area.finalURL.path) == 0 else {
            throw UnicodeTranscodingError.io(
                operation: "publish scratch file",
                path: area.finalURL.path,
                code: errno
            )
        }

        let result = UnicodeScratchFile(
            fileURL: area.finalURL,
            scratchDirectoryURL: area.directoryURL,
            sourceEncoding: sourceEncoding,
            outputEncoding: outputEncoding,
            sourceByteCount: sourceByteCount,
            outputByteCount: writer.outputByteCount,
            sourceByteOrderMarkByteCount: sourceBOMByteCount,
            outputByteOrderMarkByteCount: outputBOM.count
        )
        removeScratchArea = false
        return result
    }

    private struct ScratchArea {
        let directoryURL: URL
        let partialURL: URL
        let finalURL: URL
    }

    private static func makeScratchArea(
        parentURL: URL?,
        outputEncoding: DocumentTextEncoding
    ) throws -> ScratchArea {
        let parent = parentURL ?? FileManager.default.temporaryDirectory
        let directory = parent.appendingPathComponent(
            "LighTxt-transcode-\(UUID().uuidString)",
            isDirectory: true
        )
        guard Darwin.mkdir(directory.path, mode_t(0o700)) == 0 else {
            throw UnicodeTranscodingError.io(
                operation: "create private scratch directory",
                path: directory.path,
                code: errno
            )
        }
        guard chmod(directory.path, mode_t(0o700)) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: directory)
            throw UnicodeTranscodingError.io(
                operation: "secure scratch directory",
                path: directory.path,
                code: code
            )
        }

        let suffix: String
        switch outputEncoding {
        case .utf8: suffix = "utf8"
        case .utf16LittleEndian: suffix = "utf16le"
        case .utf16BigEndian: suffix = "utf16be"
        case .utf32LittleEndian: suffix = "utf32le"
        case .utf32BigEndian: suffix = "utf32be"
        }
        return ScratchArea(
            directoryURL: directory,
            partialURL: directory.appendingPathComponent(".content-\(UUID().uuidString).partial"),
            finalURL: directory.appendingPathComponent("content.\(suffix)")
        )
    }

    private static func readPrefix(
        descriptor: Int32,
        byteCount: Int,
        path: String
    ) throws -> [UInt8] {
        guard byteCount > 0 else { return [] }
        return [UInt8](
            try readExactly(
                descriptor: descriptor,
                byteCount: byteCount,
                offset: 0,
                path: path
            )
        )
    }

    private static func readExactly(
        descriptor: Int32,
        byteCount: Int,
        offset: Int64,
        path: String
    ) throws -> Data {
        var data = Data(count: byteCount)
        try data.withUnsafeMutableBytes { destination in
            guard let baseAddress = destination.baseAddress else { return }
            var completed = 0
            while completed < byteCount {
                let result = Darwin.pread(
                    descriptor,
                    baseAddress.advanced(by: completed),
                    byteCount - completed,
                    off_t(offset + Int64(completed))
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw UnicodeTranscodingError.io(
                        operation: "read",
                        path: path,
                        code: errno
                    )
                }
                guard result > 0 else {
                    throw UnicodeTranscodingError.sourceChanged(path: path)
                }
                completed += result
            }
        }
        return data
    }

    private struct ByteOrderMark {
        let encoding: DocumentTextEncoding
        let byteCount: Int
    }

    private static func byteOrderMark(in bytes: [UInt8]) -> ByteOrderMark? {
        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return ByteOrderMark(encoding: .utf32BigEndian, byteCount: 4)
        }
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            return ByteOrderMark(encoding: .utf32LittleEndian, byteCount: 4)
        }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return ByteOrderMark(encoding: .utf8, byteCount: 3)
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return ByteOrderMark(encoding: .utf16BigEndian, byteCount: 2)
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            return ByteOrderMark(encoding: .utf16LittleEndian, byteCount: 2)
        }
        return nil
    }

    private static func byteOrderMark(for encoding: DocumentTextEncoding) -> [UInt8] {
        switch encoding {
        case .utf8: [0xEF, 0xBB, 0xBF]
        case .utf16LittleEndian: [0xFF, 0xFE]
        case .utf16BigEndian: [0xFE, 0xFF]
        case .utf32LittleEndian: [0xFF, 0xFE, 0x00, 0x00]
        case .utf32BigEndian: [0x00, 0x00, 0xFE, 0xFF]
        }
    }
}

private final class UnicodeOutputBuffer {
    private let descriptor: Int32
    private let path: String
    private let encoding: DocumentTextEncoding
    private let maximumBufferedByteCount: Int
    private var bytes: [UInt8] = []

    private(set) var outputByteCount: Int64 = 0

    init(
        descriptor: Int32,
        path: String,
        encoding: DocumentTextEncoding,
        maximumBufferedByteCount: Int
    ) {
        self.descriptor = descriptor
        self.path = path
        self.encoding = encoding
        self.maximumBufferedByteCount = maximumBufferedByteCount
        bytes.reserveCapacity(maximumBufferedByteCount + 4)
    }

    func appendRawBytes(_ newBytes: [UInt8]) throws {
        try makeRoom(for: newBytes.count)
        bytes.append(contentsOf: newBytes)
        outputByteCount += Int64(newBytes.count)
    }

    func append(scalar: UInt32) throws {
        try makeRoom(for: 4)
        switch encoding {
        case .utf8:
            appendUTF8(scalar)
        case .utf16LittleEndian:
            appendUTF16(scalar, littleEndian: true)
        case .utf16BigEndian:
            appendUTF16(scalar, littleEndian: false)
        case .utf32LittleEndian:
            appendUInt32(scalar, littleEndian: true)
        case .utf32BigEndian:
            appendUInt32(scalar, littleEndian: false)
        }
    }

    func flush() throws {
        guard !bytes.isEmpty else { return }
        try bytes.withUnsafeBytes { rawBytes in
            guard let baseAddress = rawBytes.baseAddress else { return }
            var completed = 0
            while completed < rawBytes.count {
                let result = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: completed),
                    rawBytes.count - completed
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw UnicodeTranscodingError.io(
                        operation: "write",
                        path: path,
                        code: errno
                    )
                }
                guard result > 0 else {
                    throw UnicodeTranscodingError.io(
                        operation: "write",
                        path: path,
                        code: EIO
                    )
                }
                completed += result
            }
        }
        bytes.removeAll(keepingCapacity: true)
    }

    private func makeRoom(for additionalByteCount: Int) throws {
        if bytes.count + additionalByteCount > maximumBufferedByteCount {
            try flush()
        }
    }

    private func appendUTF8(_ scalar: UInt32) {
        if scalar <= 0x7F {
            appendByte(UInt8(scalar))
        } else if scalar <= 0x7FF {
            appendByte(0xC0 | UInt8(scalar >> 6))
            appendByte(0x80 | UInt8(scalar & 0x3F))
        } else if scalar <= 0xFFFF {
            appendByte(0xE0 | UInt8(scalar >> 12))
            appendByte(0x80 | UInt8((scalar >> 6) & 0x3F))
            appendByte(0x80 | UInt8(scalar & 0x3F))
        } else {
            appendByte(0xF0 | UInt8(scalar >> 18))
            appendByte(0x80 | UInt8((scalar >> 12) & 0x3F))
            appendByte(0x80 | UInt8((scalar >> 6) & 0x3F))
            appendByte(0x80 | UInt8(scalar & 0x3F))
        }
    }

    private func appendUTF16(_ scalar: UInt32, littleEndian: Bool) {
        if scalar <= 0xFFFF {
            appendUInt16(UInt16(scalar), littleEndian: littleEndian)
            return
        }
        let value = scalar - 0x1_0000
        let high = UInt16(0xD800 + (value >> 10))
        let low = UInt16(0xDC00 + (value & 0x3FF))
        appendUInt16(high, littleEndian: littleEndian)
        appendUInt16(low, littleEndian: littleEndian)
    }

    private func appendUInt16(_ value: UInt16, littleEndian: Bool) {
        if littleEndian {
            appendByte(UInt8(value & 0xFF))
            appendByte(UInt8(value >> 8))
        } else {
            appendByte(UInt8(value >> 8))
            appendByte(UInt8(value & 0xFF))
        }
    }

    private func appendUInt32(_ value: UInt32, littleEndian: Bool) {
        if littleEndian {
            appendByte(UInt8(value & 0xFF))
            appendByte(UInt8((value >> 8) & 0xFF))
            appendByte(UInt8((value >> 16) & 0xFF))
            appendByte(UInt8(value >> 24))
        } else {
            appendByte(UInt8(value >> 24))
            appendByte(UInt8((value >> 16) & 0xFF))
            appendByte(UInt8((value >> 8) & 0xFF))
            appendByte(UInt8(value & 0xFF))
        }
    }

    private func appendByte(_ byte: UInt8) {
        bytes.append(byte)
        outputByteCount += 1
    }
}

private struct StreamingUnicodeScalarDecoder {
    let encoding: DocumentTextEncoding

    private var pendingUTF8: [UInt8] = []
    private var expectedUTF8ByteCount = 0
    private var pendingUTF8Offset: Int64 = 0

    private var pendingCodeUnitBytes: [UInt8] = []
    private var pendingCodeUnitOffset: Int64 = 0
    private var pendingHighSurrogate: UInt16?
    private var pendingHighSurrogateOffset: Int64 = 0

    init(encoding: DocumentTextEncoding) {
        self.encoding = encoding
        pendingUTF8.reserveCapacity(4)
        pendingCodeUnitBytes.reserveCapacity(4)
    }

    mutating func consume(
        _ bytes: UnsafeRawBufferPointer,
        startingAt baseOffset: Int64,
        cancellation: CancellationToken?,
        emit: (UInt32) throws -> Void
    ) throws {
        for index in 0..<bytes.count {
            if index & 0xFFF == 0, cancellation?.isCancelled == true {
                throw CancellationError()
            }
            let offset = baseOffset + Int64(index)
            let byte = bytes[index]
            switch encoding {
            case .utf8:
                try consumeUTF8(byte, offset: offset, emit: emit)
            case .utf16LittleEndian:
                try consumeUTF16(byte, offset: offset, littleEndian: true, emit: emit)
            case .utf16BigEndian:
                try consumeUTF16(byte, offset: offset, littleEndian: false, emit: emit)
            case .utf32LittleEndian:
                try consumeUTF32(byte, offset: offset, littleEndian: true, emit: emit)
            case .utf32BigEndian:
                try consumeUTF32(byte, offset: offset, littleEndian: false, emit: emit)
            }
        }
    }

    mutating func finish() throws {
        switch encoding {
        case .utf8:
            guard pendingUTF8.isEmpty else {
                throw malformed(at: pendingUTF8Offset)
            }
        case .utf16LittleEndian, .utf16BigEndian:
            if let _ = pendingHighSurrogate {
                throw malformed(at: pendingHighSurrogateOffset)
            }
            guard pendingCodeUnitBytes.isEmpty else {
                throw malformed(at: pendingCodeUnitOffset)
            }
        case .utf32LittleEndian, .utf32BigEndian:
            guard pendingCodeUnitBytes.isEmpty else {
                throw malformed(at: pendingCodeUnitOffset)
            }
        }
    }

    private mutating func consumeUTF8(
        _ byte: UInt8,
        offset: Int64,
        emit: (UInt32) throws -> Void
    ) throws {
        if pendingUTF8.isEmpty {
            if byte <= 0x7F {
                try emit(UInt32(byte))
                return
            }
            switch byte {
            case 0xC2...0xDF: expectedUTF8ByteCount = 2
            case 0xE0...0xEF: expectedUTF8ByteCount = 3
            case 0xF0...0xF4: expectedUTF8ByteCount = 4
            default: throw malformed(at: offset)
            }
            pendingUTF8Offset = offset
            pendingUTF8.append(byte)
            return
        }

        guard byte & 0xC0 == 0x80 else {
            throw malformed(at: pendingUTF8Offset)
        }
        pendingUTF8.append(byte)
        guard pendingUTF8.count == expectedUTF8ByteCount else { return }

        let first = pendingUTF8[0]
        let second = pendingUTF8[1]
        if first == 0xE0, second < 0xA0 { throw malformed(at: pendingUTF8Offset) }
        if first == 0xED, second > 0x9F { throw malformed(at: pendingUTF8Offset) }
        if first == 0xF0, second < 0x90 { throw malformed(at: pendingUTF8Offset) }
        if first == 0xF4, second > 0x8F { throw malformed(at: pendingUTF8Offset) }

        let scalar: UInt32
        switch expectedUTF8ByteCount {
        case 2:
            scalar = (UInt32(first & 0x1F) << 6)
                | UInt32(pendingUTF8[1] & 0x3F)
        case 3:
            scalar = (UInt32(first & 0x0F) << 12)
                | (UInt32(pendingUTF8[1] & 0x3F) << 6)
                | UInt32(pendingUTF8[2] & 0x3F)
        default:
            scalar = (UInt32(first & 0x07) << 18)
                | (UInt32(pendingUTF8[1] & 0x3F) << 12)
                | (UInt32(pendingUTF8[2] & 0x3F) << 6)
                | UInt32(pendingUTF8[3] & 0x3F)
        }
        pendingUTF8.removeAll(keepingCapacity: true)
        expectedUTF8ByteCount = 0
        try emit(scalar)
    }

    private mutating func consumeUTF16(
        _ byte: UInt8,
        offset: Int64,
        littleEndian: Bool,
        emit: (UInt32) throws -> Void
    ) throws {
        if pendingCodeUnitBytes.isEmpty { pendingCodeUnitOffset = offset }
        pendingCodeUnitBytes.append(byte)
        guard pendingCodeUnitBytes.count == 2 else { return }

        let unit: UInt16
        if littleEndian {
            unit = UInt16(pendingCodeUnitBytes[0])
                | (UInt16(pendingCodeUnitBytes[1]) << 8)
        } else {
            unit = (UInt16(pendingCodeUnitBytes[0]) << 8)
                | UInt16(pendingCodeUnitBytes[1])
        }
        let unitOffset = pendingCodeUnitOffset
        pendingCodeUnitBytes.removeAll(keepingCapacity: true)

        if (0xD800...0xDBFF).contains(unit) {
            if pendingHighSurrogate != nil {
                throw malformed(at: pendingHighSurrogateOffset)
            }
            pendingHighSurrogate = unit
            pendingHighSurrogateOffset = unitOffset
            return
        }
        if (0xDC00...0xDFFF).contains(unit) {
            guard let high = pendingHighSurrogate else {
                throw malformed(at: unitOffset)
            }
            pendingHighSurrogate = nil
            let scalar = 0x1_0000
                + (UInt32(high - 0xD800) << 10)
                + UInt32(unit - 0xDC00)
            try emit(scalar)
            return
        }
        if pendingHighSurrogate != nil {
            throw malformed(at: pendingHighSurrogateOffset)
        }
        try emit(UInt32(unit))
    }

    private mutating func consumeUTF32(
        _ byte: UInt8,
        offset: Int64,
        littleEndian: Bool,
        emit: (UInt32) throws -> Void
    ) throws {
        if pendingCodeUnitBytes.isEmpty { pendingCodeUnitOffset = offset }
        pendingCodeUnitBytes.append(byte)
        guard pendingCodeUnitBytes.count == 4 else { return }

        let scalar: UInt32
        if littleEndian {
            scalar = UInt32(pendingCodeUnitBytes[0])
                | (UInt32(pendingCodeUnitBytes[1]) << 8)
                | (UInt32(pendingCodeUnitBytes[2]) << 16)
                | (UInt32(pendingCodeUnitBytes[3]) << 24)
        } else {
            scalar = (UInt32(pendingCodeUnitBytes[0]) << 24)
                | (UInt32(pendingCodeUnitBytes[1]) << 16)
                | (UInt32(pendingCodeUnitBytes[2]) << 8)
                | UInt32(pendingCodeUnitBytes[3])
        }
        let scalarOffset = pendingCodeUnitOffset
        pendingCodeUnitBytes.removeAll(keepingCapacity: true)
        guard scalar <= 0x10_FFFF,
              !(0xD800...0xDFFF).contains(scalar) else {
            throw malformed(at: scalarOffset)
        }
        try emit(scalar)
    }

    private func malformed(at offset: Int64) -> UnicodeTranscodingError {
        .malformedInput(encoding: encoding, byteOffset: offset)
    }
}
