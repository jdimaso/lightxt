import Foundation
import Darwin

/// Owns a read-only descriptor for one file revision.
///
/// Reads use bounded positional I/O rather than a permanent mapping. Besides
/// keeping resident memory independent of file size, this is essential for
/// safety: dereferencing an mmap after another process truncates the same inode
/// raises SIGBUS and cannot be recovered as a Swift error. `pread` instead
/// reports a short read/error, and the fingerprint checks below turn any
/// in-place mutation into a normal, user-visible external-change error.
nonisolated final class MemoryMappedFile: @unchecked Sendable {
    static let maximumReadByteCount = 1 << 20

    let url: URL
    let byteCount: Int64
    let fingerprint: FileFingerprint

    private let descriptor: Int32

    convenience init(url: URL) throws {
        let physicalURL = url.standardizedFileURL.resolvingSymlinksInPath()
        try self.init(openingFileAt: physicalURL, representedBy: physicalURL)
    }

    /// Opens `physicalURL` while exposing `logicalURL` as the storage's stable
    /// document URL. Atomic save uses this to open the completed temporary inode
    /// *before* rename, so a later pathname race can never make the editor adopt
    /// a foreign inode.
    init(openingFileAt physicalURL: URL, representedBy logicalURL: URL) throws {
        let physicalPath = physicalURL.standardizedFileURL.path
        let representedURL = logicalURL.standardizedFileURL.resolvingSymlinksInPath()
        let descriptor = Darwin.open(physicalPath, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw LighTxtCoreError.io(
                operation: "open",
                path: physicalPath,
                code: errno
            )
        }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw LighTxtCoreError.io(
                operation: "inspect",
                path: physicalPath,
                code: code
            )
        }

        let length = Int64(status.st_size)
        guard length >= 0, length <= Int64(Int.max) else {
            Darwin.close(descriptor)
            throw LighTxtCoreError.fileTooLarge(length)
        }

        self.url = representedURL
        self.byteCount = length
        self.fingerprint = FileFingerprint(status)
        self.descriptor = descriptor
    }

    deinit {
        Darwin.close(descriptor)
    }

    func withUnsafeBytes<R>(
        in range: Range<Int64>,
        _ body: (UnsafeRawBufferPointer) throws -> R
    ) throws -> R {
        try validateByteRange(range, byteCount: byteCount)
        let count = try checkedInt(range.upperBound - range.lowerBound)
        guard count > 0 else {
            return try body(UnsafeRawBufferPointer(start: nil, count: 0))
        }
        guard count <= Self.maximumReadByteCount else {
            throw LighTxtCoreError.requestedMaterializationTooLarge(
                requested: Int64(count),
                limit: Int64(Self.maximumReadByteCount)
            )
        }

        try validateDescriptorFingerprint()
        var bytes = Data(count: count)
        try bytes.withUnsafeMutableBytes { destination in
            guard let baseAddress = destination.baseAddress else {
                throw LighTxtCoreError.io(
                    operation: "read",
                    path: url.path,
                    code: EIO
                )
            }
            var completed = 0
            while completed < count {
                let result = Darwin.pread(
                    descriptor,
                    baseAddress.advanced(by: completed),
                    count - completed,
                    off_t(range.lowerBound + Int64(completed))
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw LighTxtCoreError.io(
                        operation: "read",
                        path: url.path,
                        code: errno
                    )
                }
                guard result > 0 else {
                    // A zero-length result before the captured EOF is the safe
                    // pread equivalent of the mmap/SIGBUS truncate case.
                    try validateDescriptorFingerprint()
                    throw LighTxtCoreError.fileChangedExternally(path: url.path)
                }
                completed += result
            }
        }
        try validateDescriptorFingerprint()
        return try bytes.withUnsafeBytes(body)
    }

    private func validateDescriptorFingerprint() throws {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw LighTxtCoreError.io(
                operation: "inspect open file",
                path: url.path,
                code: errno
            )
        }
        guard FileFingerprint(status) == fingerprint else {
            throw LighTxtCoreError.fileChangedExternally(path: url.path)
        }
    }
}

nonisolated struct FileFingerprint: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let byteCount: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64

    init(_ status: stat) {
        device = UInt64(status.st_dev)
        inode = UInt64(status.st_ino)
        byteCount = Int64(status.st_size)
        modifiedSeconds = Int64(status.st_mtimespec.tv_sec)
        modifiedNanoseconds = Int64(status.st_mtimespec.tv_nsec)
    }

    static func atPath(_ path: String) throws -> FileFingerprint? {
        var status = stat()
        if lstat(path, &status) == 0 { return FileFingerprint(status) }
        if errno == ENOENT { return nil }
        throw LighTxtCoreError.io(operation: "inspect", path: path, code: errno)
    }
}

/// One append-only, unlinked spill inode shared by all over-budget additions in
/// a document. A per-segment file descriptor would turn sustained editing into
/// an eventual EMFILE failure once the resident budget had been crossed.
nonisolated final class TemporaryAdditionStore: @unchecked Sendable {
    private let descriptor: Int32
    private let diagnosticPath: String
    private let lock = NSLock()
    private var storedByteCount: Int64 = 0

    init() throws {
        let templateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LighTxt-edits-XXXXXX")
        var template = Array(templateURL.path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else {
            throw LighTxtCoreError.io(
                operation: "create edit backing store",
                path: templateURL.path,
                code: errno
            )
        }
        let path = String(
            decoding: template.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        guard fchmod(descriptor, 0o600) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            unlink(path)
            throw LighTxtCoreError.io(
                operation: "secure edit backing store",
                path: path,
                code: code
            )
        }
        guard unlink(path) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw LighTxtCoreError.io(
                operation: "unlink edit backing store",
                path: path,
                code: code
            )
        }
        self.descriptor = descriptor
        self.diagnosticPath = path
    }

    deinit {
        Darwin.close(descriptor)
    }

    func append(_ data: Data) throws -> Range<Int64> {
        lock.lock()
        defer { lock.unlock() }

        let length = Int64(data.count)
        guard length <= Int64.max - storedByteCount else {
            throw LighTxtCoreError.fileTooLarge(Int64.max)
        }
        let start = storedByteCount
        try data.withUnsafeBytes { bytes in
            guard data.isEmpty || bytes.baseAddress != nil else {
                throw LighTxtCoreError.io(
                    operation: "write edit backing store",
                    path: diagnosticPath,
                    code: EIO
                )
            }
            var completed = 0
            while completed < bytes.count {
                let result = Darwin.pwrite(
                    descriptor,
                    bytes.baseAddress!.advanced(by: completed),
                    bytes.count - completed,
                    off_t(start + Int64(completed))
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw LighTxtCoreError.io(
                        operation: "write edit backing store",
                        path: diagnosticPath,
                        code: errno
                    )
                }
                guard result > 0 else {
                    throw LighTxtCoreError.io(
                        operation: "write edit backing store",
                        path: diagnosticPath,
                        code: EIO
                    )
                }
                completed += result
            }
        }
        storedByteCount += length
        return start..<storedByteCount
    }

    func withUnsafeBytes<R>(
        in range: Range<Int64>,
        _ body: (UnsafeRawBufferPointer) throws -> R
    ) throws -> R {
        lock.lock()
        let available = storedByteCount
        lock.unlock()
        try validateByteRange(range, byteCount: available)
        let count = try checkedInt(range.upperBound - range.lowerBound)
        guard count > 0 else {
            return try body(UnsafeRawBufferPointer(start: nil, count: 0))
        }
        guard count <= MemoryMappedFile.maximumReadByteCount else {
            throw LighTxtCoreError.requestedMaterializationTooLarge(
                requested: Int64(count),
                limit: Int64(MemoryMappedFile.maximumReadByteCount)
            )
        }

        var data = Data(count: count)
        try data.withUnsafeMutableBytes { destination in
            guard let baseAddress = destination.baseAddress else {
                throw LighTxtCoreError.io(
                    operation: "read edit backing store",
                    path: diagnosticPath,
                    code: EIO
                )
            }
            var completed = 0
            while completed < count {
                let result = Darwin.pread(
                    descriptor,
                    baseAddress.advanced(by: completed),
                    count - completed,
                    off_t(range.lowerBound + Int64(completed))
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw LighTxtCoreError.io(
                        operation: "read edit backing store",
                        path: diagnosticPath,
                        code: errno
                    )
                }
                guard result > 0 else {
                    throw LighTxtCoreError.io(
                        operation: "read edit backing store",
                        path: diagnosticPath,
                        code: EIO
                    )
                }
                completed += result
            }
        }
        return try data.withUnsafeBytes(body)
    }
}

/// Immutable edit bytes. Pieces retain only the edit payloads reachable from
/// the current root or an undo snapshot, so abandoned redo branches are freed.
nonisolated final class AdditionSegment: @unchecked Sendable {
    private enum Storage {
        case memory(Data)
        case temporary(store: TemporaryAdditionStore, offset: Int64)
    }

    private let storage: Storage
    let byteCount: Int64

    init(data: Data, temporaryStore: TemporaryAdditionStore?) throws {
        byteCount = Int64(data.count)
        if let temporaryStore, !data.isEmpty {
            let range = try temporaryStore.append(data)
            storage = .temporary(store: temporaryStore, offset: range.lowerBound)
        } else {
            storage = .memory(data)
        }
    }

    func withUnsafeBytes<R>(
        in range: Range<Int64>,
        _ body: (UnsafeRawBufferPointer) throws -> R
    ) throws -> R {
        try validateByteRange(range, byteCount: byteCount)
        switch storage {
        case let .memory(data):
            let lower = try checkedInt(range.lowerBound)
            let upper = try checkedInt(range.upperBound)
            return try data.withUnsafeBytes { bytes in
                try body(UnsafeRawBufferPointer(rebasing: bytes[lower..<upper]))
            }
        case let .temporary(store, offset):
            return try store.withUnsafeBytes(
                in: (offset + range.lowerBound)..<(offset + range.upperBound),
                body
            )
        }
    }
}
