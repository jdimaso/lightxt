import Foundation
import Darwin

public nonisolated struct BulkReplaceProgress: Sendable, Equatable {
    public let sourceBytesProcessed: Int64
    public let totalSourceBytes: Int64
    public let replacementCount: Int

    public var fractionCompleted: Double {
        guard totalSourceBytes > 0 else { return 1 }
        return min(1, Double(sourceBytesProcessed) / Double(totalSourceBytes))
    }
}

public nonisolated struct BulkReplaceResult: Sendable, Equatable {
    public let replacementCount: Int
    public let sourceByteCount: Int64
    public let resultByteCount: Int64

    public var didChange: Bool { replacementCount > 0 }
}

private nonisolated enum ReplacementTemplateToken {
    case literal(Data)
    case capture(Int)
}

private nonisolated enum BulkReplacementStrategy {
    case constant(Data)
    case template([ReplacementTemplateToken])
    case provider((SearchMatch, DocumentSnapshot) throws -> Data)
}

extension FileBackedPieceTable {
    /// Transactional, bounded-memory Replace All. The provider is invoked once
    /// per non-overlapping match in source order. Returning a large `Data` is
    /// allowed, though template/constant overloads provide the strictest memory
    /// behavior because capture bytes can stream directly to the output inode.
    @discardableResult
    public func replaceAll(
        matching pattern: SearchPattern,
        in range: Range<Int64>? = nil,
        options: SearchOptions = .init(),
        cancellation: CancellationToken? = nil,
        progress: ((BulkReplaceProgress) -> Void)? = nil,
        replacementProvider: @escaping (SearchMatch, DocumentSnapshot) throws -> Data
    ) throws -> BulkReplaceResult {
        try performBulkReplace(
            matching: pattern,
            in: range,
            options: options,
            cancellation: cancellation,
            progress: progress,
            strategy: .provider(replacementProvider)
        )
    }

    /// Replaces every match with the same literal byte sequence.
    @discardableResult
    public func replaceAll(
        matching pattern: SearchPattern,
        with replacement: Data,
        in range: Range<Int64>? = nil,
        options: SearchOptions = .init(),
        cancellation: CancellationToken? = nil,
        progress: ((BulkReplaceProgress) -> Void)? = nil
    ) throws -> BulkReplaceResult {
        try performBulkReplace(
            matching: pattern,
            in: range,
            options: options,
            cancellation: cancellation,
            progress: progress,
            strategy: .constant(replacement)
        )
    }

    /// UTF-8 replacement template supporting `$$` and `$0`...`$99` capture
    /// references. Missing/unmatched captures expand to an empty sequence.
    @discardableResult
    public func replaceAll(
        matching pattern: SearchPattern,
        withUTF8Template template: String,
        in range: Range<Int64>? = nil,
        options: SearchOptions = .init(),
        cancellation: CancellationToken? = nil,
        progress: ((BulkReplaceProgress) -> Void)? = nil
    ) throws -> BulkReplaceResult {
        try performBulkReplace(
            matching: pattern,
            in: range,
            options: options,
            cancellation: cancellation,
            progress: progress,
            strategy: .template(Self.parseReplacementTemplate(template))
        )
    }

    private func performBulkReplace(
        matching pattern: SearchPattern,
        in requestedRange: Range<Int64>?,
        options: SearchOptions,
        cancellation: CancellationToken?,
        progress: ((BulkReplaceProgress) -> Void)?,
        strategy: BulkReplacementStrategy
    ) throws -> BulkReplaceResult {
        if cancellation?.isCancelled == true { throw CancellationError() }

        let captured = try snapshot()
        let range = requestedRange ?? 0..<captured.byteCount
        try validateByteRange(range, byteCount: captured.byteCount)
        let output = try TemporaryRewriteOutput()
        var replacementCount = 0
        var sourceCursor = range.lowerBound

        func report(_ processed: Int64) {
            progress?(BulkReplaceProgress(
                sourceBytesProcessed: min(captured.byteCount, max(0, processed)),
                totalSourceBytes: captured.byteCount,
                replacementCount: replacementCount
            ))
        }

        report(0)
        try output.append(
            snapshot: captured,
            range: 0..<range.lowerBound,
            cancellation: cancellation,
            sourceProgress: report
        )

        // Replace All is defined on non-overlapping matches even if a Find All
        // caller normally requests overlap reporting.
        var nonOverlappingOptions = options
        nonOverlappingOptions.allowsOverlappingMatches = false
        let searchResult = try captured.search(
            pattern,
            in: range,
            options: nonOverlappingOptions,
            cancellation: cancellation,
            progress: { searchProgress in
                report(range.lowerBound + searchProgress.processedBytes)
            }
        ) { match in
            guard match.byteRange.lowerBound >= sourceCursor else {
                throw LighTxtCoreError.overlappingSearchMatches(
                    previousEnd: sourceCursor,
                    next: match.byteRange
                )
            }
            if cancellation?.isCancelled == true { throw CancellationError() }

            try output.append(
                snapshot: captured,
                range: sourceCursor..<match.byteRange.lowerBound,
                cancellation: cancellation,
                sourceProgress: nil
            )
            try output.appendReplacement(
                strategy,
                for: match,
                snapshot: captured,
                cancellation: cancellation
            )
            sourceCursor = match.byteRange.upperBound
            replacementCount += 1
            report(sourceCursor)
            return true
        }

        guard searchResult.stopReason != .cancelled else { throw CancellationError() }
        if cancellation?.isCancelled == true { throw CancellationError() }

        guard replacementCount > 0 else {
            report(captured.byteCount)
            return BulkReplaceResult(
                replacementCount: 0,
                sourceByteCount: captured.byteCount,
                resultByteCount: captured.byteCount
            )
        }

        try output.append(
            snapshot: captured,
            range: sourceCursor..<captured.byteCount,
            cancellation: cancellation,
            sourceProgress: report
        )
        if cancellation?.isCancelled == true { throw CancellationError() }

        let rewrittenMapping = try output.finishAndMap()
        if cancellation?.isCancelled == true { throw CancellationError() }
        try installBulkRewrite(rewrittenMapping, replacing: captured)
        report(captured.byteCount)
        return BulkReplaceResult(
            replacementCount: replacementCount,
            sourceByteCount: captured.byteCount,
            resultByteCount: rewrittenMapping.byteCount
        )
    }

    private static func parseReplacementTemplate(
        _ template: String
    ) -> [ReplacementTemplateToken] {
        let bytes = Array(template.utf8)
        var tokens: [ReplacementTemplateToken] = []
        var literal: [UInt8] = []

        func flushLiteral() {
            guard !literal.isEmpty else { return }
            tokens.append(.literal(Data(literal)))
            literal.removeAll(keepingCapacity: true)
        }

        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x24, index + 1 < bytes.count else {
                literal.append(bytes[index])
                index += 1
                continue
            }

            let next = bytes[index + 1]
            if next == 0x24 {
                literal.append(0x24)
                index += 2
                continue
            }
            guard next >= 0x30, next <= 0x39 else {
                literal.append(0x24)
                index += 1
                continue
            }

            flushLiteral()
            var capture = Int(next - 0x30)
            index += 2
            if index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
                capture = capture * 10 + Int(bytes[index] - 0x30)
                index += 1
            }
            tokens.append(.capture(capture))
        }
        flushLiteral()
        return tokens
    }
}

private nonisolated final class TemporaryRewriteOutput {
    private static let outputBufferSize = 256 << 10

    private var descriptor: Int32
    private var path: String?
    private var buffer = Data()
    private(set) var byteCount: Int64 = 0

    init() throws {
        let templateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LighTxt-rewrite-XXXXXX")
        var template = Array(templateURL.path.utf8CString)
        descriptor = mkstemp(&template)
        guard descriptor >= 0 else {
            throw LighTxtCoreError.io(
                operation: "create bulk rewrite file",
                path: templateURL.path,
                code: errno
            )
        }
        path = String(
            decoding: template.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        _ = fchmod(descriptor, 0o600)
        buffer.reserveCapacity(Self.outputBufferSize)
    }

    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
        if let path { unlink(path) }
    }

    func append(
        snapshot: DocumentSnapshot,
        range: Range<Int64>,
        cancellation: CancellationToken?,
        sourceProgress: ((Int64) -> Void)?
    ) throws {
        var consumed: Int64 = 0
        try snapshot.forEachByteSlice(in: range) { bytes in
            try append(bytes, cancellation: cancellation)
            consumed += Int64(bytes.count)
            sourceProgress?(range.lowerBound + consumed)
        }
    }

    func appendReplacement(
        _ strategy: BulkReplacementStrategy,
        for match: SearchMatch,
        snapshot: DocumentSnapshot,
        cancellation: CancellationToken?
    ) throws {
        switch strategy {
        case let .constant(data):
            try append(data, cancellation: cancellation)
        case let .provider(provider):
            try append(try provider(match, snapshot), cancellation: cancellation)
        case let .template(tokens):
            for token in tokens {
                if cancellation?.isCancelled == true { throw CancellationError() }
                switch token {
                case let .literal(data):
                    try append(data, cancellation: cancellation)
                case let .capture(index):
                    guard index < match.captureByteRanges.count,
                          let captureRange = match.captureByteRanges[index] else {
                        continue
                    }
                    try append(
                        snapshot: snapshot,
                        range: captureRange,
                        cancellation: cancellation,
                        sourceProgress: nil
                    )
                }
            }
        }
    }

    func finishAndMap() throws -> MemoryMappedFile {
        guard descriptor >= 0, let path else {
            throw LighTxtCoreError.io(
                operation: "finalize bulk rewrite file",
                path: self.path ?? "(unavailable)",
                code: EBADF
            )
        }
        try flushBuffer()
        let closeResult = Darwin.close(descriptor)
        descriptor = -1
        guard closeResult == 0 else {
            throw LighTxtCoreError.io(
                operation: "close bulk rewrite file",
                path: path,
                code: errno
            )
        }

        let mapping = try MemoryMappedFile(url: URL(fileURLWithPath: path))
        guard unlink(path) == 0 else {
            throw LighTxtCoreError.io(
                operation: "unlink bulk rewrite file",
                path: path,
                code: errno
            )
        }
        self.path = nil
        return mapping
    }

    private func append(_ data: Data, cancellation: CancellationToken?) throws {
        try data.withUnsafeBytes { bytes in
            try append(bytes, cancellation: cancellation)
        }
    }

    private func append(
        _ bytes: UnsafeRawBufferPointer,
        cancellation: CancellationToken?
    ) throws {
        guard descriptor >= 0 else {
            throw LighTxtCoreError.io(
                operation: "write bulk rewrite file",
                path: path ?? "(unavailable)",
                code: EBADF
            )
        }
        guard Int64(bytes.count) <= Int64.max - byteCount else {
            throw LighTxtCoreError.fileTooLarge(Int64.max)
        }

        var offset = 0
        while offset < bytes.count {
            if cancellation?.isCancelled == true { throw CancellationError() }
            let available = Self.outputBufferSize - buffer.count
            let copied = min(available, bytes.count - offset)
            let source = UnsafeRawBufferPointer(
                start: bytes.baseAddress!.advanced(by: offset),
                count: copied
            )
            buffer.append(contentsOf: source)
            offset += copied
            byteCount += Int64(copied)
            if buffer.count == Self.outputBufferSize {
                try flushBuffer()
            }
        }
    }

    private func flushBuffer() throws {
        guard !buffer.isEmpty else { return }
        let descriptor = self.descriptor
        let path = self.path ?? "(unavailable)"
        try buffer.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw LighTxtCoreError.io(
                        operation: "write bulk rewrite file",
                        path: path,
                        code: errno
                    )
                }
                guard result > 0 else {
                    throw LighTxtCoreError.io(
                        operation: "write bulk rewrite file",
                        path: path,
                        code: EIO
                    )
                }
                offset += result
            }
        }
        buffer.removeAll(keepingCapacity: true)
    }
}
