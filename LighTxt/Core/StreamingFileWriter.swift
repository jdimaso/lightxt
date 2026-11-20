import Foundation
import Darwin

/// A low-overhead cancellation primitive shared by save and search operations.
public nonisolated final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

public nonisolated struct SaveProgress: Sendable, Equatable {
    public let bytesWritten: Int64
    public let totalBytes: Int64

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 1 }
        return min(1, Double(bytesWritten) / Double(totalBytes))
    }
}

nonisolated enum StreamingFileWriter {
    private static let writeBlockSize = 1 << 20
    private static let progressInterval: Int64 = 8 << 20

    /// The save panel grants the selected pathname. Foundation can allocate a
    /// private replacement directory on its volume without a parent-folder grant.
    struct StagingArea {
        let directoryURL: URL
        let fileURL: URL
    }

    static func makeStagingArea(
        appropriateFor targetURL: URL,
        targetExists: Bool,
        fileManager: FileManager = .default
    ) throws -> StagingArea {
        guard targetURL.isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme) }
        let volumeURL = targetExists ? targetURL : targetURL.deletingLastPathComponent()
        var status = stat()
        let targetDevice: dev_t?
        if stat(volumeURL.path, &status) == 0 {
            let type = status.st_mode & S_IFMT
            guard targetExists ? type == S_IFREG : type == S_IFDIR else {
                let code = targetExists ? (type == S_IFDIR ? EISDIR : EINVAL) : ENOTDIR
                throw LighTxtCoreError.io(operation: "prepare save destination", path: targetURL.path, code: code)
            }
            targetDevice = status.st_dev
        } else {
            let code = errno
            // A file-only grant can hide metadata for the parent of a new file.
            // Exclusive rename below still enforces the volume boundary at commit.
            guard !targetExists, code == EACCES || code == EPERM else {
                throw LighTxtCoreError.io(operation: "inspect save volume", path: volumeURL.path, code: code)
            }
            targetDevice = nil
        }

        func checkVolume(of directory: URL) throws {
            guard let targetDevice else { return }
            var directoryStatus = stat()
            guard stat(directory.path, &directoryStatus) == 0 else {
                throw LighTxtCoreError.io(operation: "inspect save staging volume", path: directory.path, code: errno)
            }
            guard directoryStatus.st_dev == targetDevice else {
                throw LighTxtCoreError.io(operation: "stage an atomic save on the destination volume", path: targetURL.path, code: EXDEV)
            }
        }

        let directoryURL: URL
        do {
            directoryURL = try fileManager.url(
                for: .itemReplacementDirectory,
                in: .userDomainMask,
                appropriateFor: volumeURL,
                create: true
            )
        } catch {
            let temporary = fileManager.temporaryDirectory
            try checkVolume(of: temporary)
            let fallback = temporary.appendingPathComponent("LighTxt-save-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(
                at: fallback, withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            directoryURL = fallback
        }
        do {
            try checkVolume(of: directoryURL)
        } catch {
            try? fileManager.removeItem(at: directoryURL)
            throw error
        }
        return StagingArea(directoryURL: directoryURL, fileURL: directoryURL.appendingPathComponent(UUID().uuidString))
    }

    private static func publish(
        stagedURL: URL,
        to targetURL: URL,
        targetExists: Bool
    ) throws {
        if targetExists {
            _ = try FileManager.default.replaceItemAt(
                targetURL,
                withItemAt: stagedURL,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } else {
            // A high-level move may copy across volumes. Publish only this exact
            // inode, and leave an intervening creator's destination untouched.
            if renamex_np(stagedURL.path, targetURL.path, UInt32(RENAME_EXCL)) == 0 { return }
            let code = errno
            if code == EEXIST { throw LighTxtCoreError.fileChangedExternally(path: targetURL.path) }
            throw LighTxtCoreError.io(operation: "publish atomic save", path: targetURL.path, code: code)
        }
    }

    static func write(
        snapshot: DocumentSnapshot,
        to targetURL: URL,
        expectedDestination: FileFingerprint?,
        durable: Bool,
        cancellation: CancellationToken?,
        progress: ((SaveProgress) -> Void)?,
        afterRename: (@Sendable (URL) throws -> Void)? = nil
    ) throws -> MemoryMappedFile {
        let targetPath = targetURL.path
        let directoryURL = targetURL.deletingLastPathComponent()
        guard try FileFingerprint.atPath(targetPath) == expectedDestination else {
            throw LighTxtCoreError.fileChangedExternally(path: targetPath)
        }
        var targetStatus = stat()
        let targetExists = lstat(targetPath, &targetStatus) == 0
        let stagingArea = try makeStagingArea(
            appropriateFor: targetURL,
            targetExists: targetExists
        )
        let temporaryURL = stagingArea.fileURL
        let temporaryPath = temporaryURL.path

        defer {
            try? FileManager.default.removeItem(at: stagingArea.directoryURL)
        }

        let targetMode: mode_t = targetExists
            ? mode_t(targetStatus.st_mode & 0o7777)
            : mode_t(0o666)

        var descriptor = Darwin.open(
            temporaryPath,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            targetMode
        )
        guard descriptor >= 0 else {
            throw LighTxtCoreError.io(
                operation: "create temporary save file",
                path: temporaryPath,
                code: errno
            )
        }

        var shouldRemoveTemporaryFile = true
        defer {
            if descriptor >= 0 {
                Darwin.close(descriptor)
            }
            if shouldRemoveTemporaryFile {
                unlink(temporaryPath)
            }
        }

        if targetExists, fchmod(descriptor, targetMode) != 0 {
            throw LighTxtCoreError.io(
                operation: "preserve permissions for",
                path: targetPath,
                code: errno
            )
        }

        var bytesWritten: Int64 = 0
        var nextProgress = progressInterval
        progress?(SaveProgress(bytesWritten: 0, totalBytes: snapshot.byteCount))

        try snapshot.forEachByteSlice { bytes in
            var sliceOffset = 0
            while sliceOffset < bytes.count {
                if cancellation?.isCancelled == true {
                    throw CancellationError()
                }

                let requestedCount = min(writeBlockSize, bytes.count - sliceOffset)
                let start = bytes.baseAddress!.advanced(by: sliceOffset)
                var blockOffset = 0
                while blockOffset < requestedCount {
                    let result = Darwin.write(
                        descriptor,
                        start.advanced(by: blockOffset),
                        requestedCount - blockOffset
                    )
                    if result < 0 {
                        if errno == EINTR { continue }
                        throw LighTxtCoreError.io(
                            operation: "write",
                            path: temporaryPath,
                            code: errno
                        )
                    }
                    if result == 0 {
                        throw LighTxtCoreError.io(
                            operation: "write",
                            path: temporaryPath,
                            code: EIO
                        )
                    }
                    blockOffset += result
                }

                sliceOffset += requestedCount
                bytesWritten += Int64(requestedCount)
                if bytesWritten >= nextProgress {
                    progress?(SaveProgress(
                        bytesWritten: bytesWritten,
                        totalBytes: snapshot.byteCount
                    ))
                    nextProgress = bytesWritten + progressInterval
                }
            }
        }

        if cancellation?.isCancelled == true {
            throw CancellationError()
        }
        if targetExists {
            let sourceDescriptor = Darwin.open(targetPath, O_RDONLY | O_CLOEXEC)
            if sourceDescriptor >= 0 {
                // Best effort: retain ACLs, extended attributes, flags, and the
                // rest of the destination's metadata on the replacement inode.
                _ = fcopyfile(
                    sourceDescriptor,
                    descriptor,
                    nil,
                    copyfile_flags_t(COPYFILE_METADATA)
                )
                Darwin.close(sourceDescriptor)
            }
        }
        if durable, fsync(descriptor) != 0 {
            throw LighTxtCoreError.io(
                operation: "synchronize",
                path: temporaryPath,
                code: errno
            )
        }
        let closeResult = Darwin.close(descriptor)
        descriptor = -1
        if closeResult != 0 {
            throw LighTxtCoreError.io(
                operation: "close",
                path: temporaryPath,
                code: errno
            )
        }

        // Keep a descriptor to the exact completed inode before it becomes
        // reachable through the destination pathname. Reopening `targetPath`
        // after rename has a race in which another process can substitute a
        // foreign inode and make the editor discard its own clean/undo roots.
        let committedStorage = try MemoryMappedFile(
            openingFileAt: temporaryURL,
            representedBy: targetURL
        )
        guard committedStorage.byteCount == snapshot.byteCount else {
            throw LighTxtCoreError.io(
                operation: "verify completed save",
                path: temporaryPath,
                code: EIO
            )
        }

        guard try FileFingerprint.atPath(targetPath) == expectedDestination else {
            throw LighTxtCoreError.fileChangedExternally(path: targetPath)
        }

        try publish(stagedURL: temporaryURL, to: targetURL, targetExists: targetExists)
        shouldRemoveTemporaryFile = false
        try afterRename?(targetURL)

        if durable {
            let directoryDescriptor = Darwin.open(
                directoryURL.path,
                O_RDONLY | O_CLOEXEC
            )
            if directoryDescriptor >= 0 {
                _ = fsync(directoryDescriptor)
                Darwin.close(directoryDescriptor)
            }
        }

        guard try FileFingerprint.atPath(targetPath) == committedStorage.fingerprint else {
            throw LighTxtCoreError.fileChangedExternally(path: targetPath)
        }

        progress?(SaveProgress(
            bytesWritten: snapshot.byteCount,
            totalBytes: snapshot.byteCount
        ))
        return committedStorage
    }

    /// Uses APFS copy-on-write cloning for an unchanged Duplicate/Save Copy.
    /// Returns false when the volume does not support clones so callers can
    /// transparently fall back to the streaming writer.
    static func cloneAtomically(
        from sourceURL: URL,
        to targetURL: URL,
        expectedSource: FileFingerprint,
        expectedDestination: FileFingerprint?,
        durable: Bool
    ) throws -> Bool {
        let targetPath = targetURL.path
        guard try FileFingerprint.atPath(sourceURL.path) == expectedSource else {
            throw LighTxtCoreError.fileChangedExternally(path: sourceURL.path)
        }
        guard try FileFingerprint.atPath(targetPath) == expectedDestination else {
            throw LighTxtCoreError.fileChangedExternally(path: targetPath)
        }

        let directoryURL = targetURL.deletingLastPathComponent()
        let targetExists = expectedDestination != nil
        let stagingArea = try makeStagingArea(
            appropriateFor: targetURL,
            targetExists: targetExists
        )
        let temporaryURL = stagingArea.fileURL
        let temporaryPath = temporaryURL.path
        var shouldRemove = true
        defer {
            if shouldRemove { unlink(temporaryPath) }
            try? FileManager.default.removeItem(at: stagingArea.directoryURL)
        }

        guard clonefile(sourceURL.path, temporaryPath, 0) == 0 else {
            switch errno {
            case ENOTSUP, EXDEV, EINVAL:
                return false
            default:
                throw LighTxtCoreError.io(
                    operation: "clone",
                    path: sourceURL.path,
                    code: errno
                )
            }
        }

        // `clonefile` operates on a pathname. Verify the source did not change
        // while the COW clone was being established before publishing the copy.
        guard try FileFingerprint.atPath(sourceURL.path) == expectedSource else {
            throw LighTxtCoreError.fileChangedExternally(path: sourceURL.path)
        }
        guard try FileFingerprint.atPath(targetPath) == expectedDestination else {
            throw LighTxtCoreError.fileChangedExternally(path: targetPath)
        }
        try publish(stagedURL: temporaryURL, to: targetURL, targetExists: targetExists)
        shouldRemove = false

        if durable {
            let directoryDescriptor = Darwin.open(directoryURL.path, O_RDONLY | O_CLOEXEC)
            if directoryDescriptor >= 0 {
                _ = fsync(directoryDescriptor)
                Darwin.close(directoryDescriptor)
            }
        }
        return true
    }
}
