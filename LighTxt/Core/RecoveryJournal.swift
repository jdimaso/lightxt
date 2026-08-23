import Darwin
import Foundation

/// A stable, codable copy of the file identity used by the byte-backed engine.
/// Recovery is permitted only while every field still matches the selected base
/// file, so the journal never replays offsets against foreign bytes.
public nonisolated struct RecoveryBaseFingerprint: Codable, Equatable, Sendable {
    public let device: UInt64
    public let inode: UInt64
    public let byteCount: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64

    init(_ fingerprint: FileFingerprint) {
        device = fingerprint.device
        inode = fingerprint.inode
        byteCount = fingerprint.byteCount
        modifiedSeconds = fingerprint.modifiedSeconds
        modifiedNanoseconds = fingerprint.modifiedNanoseconds
    }

    fileprivate func matches(_ fingerprint: FileFingerprint) -> Bool {
        device == fingerprint.device
            && inode == fingerprint.inode
            && byteCount == fingerprint.byteCount
            && modifiedSeconds == fingerprint.modifiedSeconds
            && modifiedNanoseconds == fingerprint.modifiedNanoseconds
    }
}

/// AppKit-independent window state that can be restored after the document bytes
/// have been recovered. Coordinates are deliberately plain doubles so the core
/// package does not acquire an AppKit dependency.
public nonisolated struct RecoveryWindowMetadata: Codable, Equatable, Sendable {
    public nonisolated struct Frame: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public var frame: Frame?
    public var selectionLowerByteOffset: Int64?
    public var selectionUpperByteOffset: Int64?
    public var viewportByteOffset: Int64?
    public var presentationMode: String?
    public var structureSidebarVisible: Bool?
    public var structureSidebarWidth: Double?

    public init(
        frame: Frame? = nil,
        selectionLowerByteOffset: Int64? = nil,
        selectionUpperByteOffset: Int64? = nil,
        viewportByteOffset: Int64? = nil,
        presentationMode: String? = nil,
        structureSidebarVisible: Bool? = nil,
        structureSidebarWidth: Double? = nil
    ) {
        self.frame = frame
        self.selectionLowerByteOffset = selectionLowerByteOffset
        self.selectionUpperByteOffset = selectionUpperByteOffset
        self.viewportByteOffset = viewportByteOffset
        self.presentationMode = presentationMode
        self.structureSidebarVisible = structureSidebarVisible
        self.structureSidebarWidth = structureSidebarWidth
    }
}

/// Small task/document descriptors useful to a recovery chooser. Arbitrary
/// values are string-only and strictly size-bounded before publication.
public nonisolated struct RecoveryTaskMetadata: Codable, Equatable, Sendable {
    public var taskIdentifier: String?
    public var displayName: String?
    public var fileType: String?
    public var values: [String: String]

    public init(
        taskIdentifier: String? = nil,
        displayName: String? = nil,
        fileType: String? = nil,
        values: [String: String] = [:]
    ) {
        self.taskIdentifier = taskIdentifier
        self.displayName = displayName
        self.fileType = fileType
        self.values = values
    }
}

public nonisolated struct RecoveryMetadata: Codable, Equatable, Sendable {
    public var window: RecoveryWindowMetadata?
    public var task: RecoveryTaskMetadata?

    public init(
        window: RecoveryWindowMetadata? = nil,
        task: RecoveryTaskMetadata? = nil
    ) {
        self.window = window
        self.task = task
    }
}

/// One edit in the coordinate space produced by all preceding edits. Only the
/// inserted bytes are journaled; deleted/replaced bytes remain in the immutable
/// base file and therefore do not scale recovery storage with document size.
public nonisolated struct RecoveryPendingEdit: Equatable, Sendable {
    public let byteRange: Range<Int64>
    public let replacement: Data

    public init(byteRange: Range<Int64>, replacement: Data) {
        self.byteRange = byteRange
        self.replacement = replacement
    }
}

public nonisolated struct RecoveryJournalConfiguration: Equatable, Sendable {
    public var maximumOperationCount: Int
    public var maximumInsertedBytesPerOperation: Int
    public var maximumTotalInsertedBytes: Int64
    public var maximumManifestBytes: Int
    public var maximumBookmarkBytes: Int
    public var maximumMetadataUTF8Bytes: Int
    public var maximumMetadataValueCount: Int

    public init(
        maximumOperationCount: Int = 16_384,
        maximumInsertedBytesPerOperation: Int = 16 << 20,
        maximumTotalInsertedBytes: Int64 = 512 << 20,
        maximumManifestBytes: Int = 8 << 20,
        maximumBookmarkBytes: Int = 1 << 20,
        maximumMetadataUTF8Bytes: Int = 64 << 10,
        maximumMetadataValueCount: Int = 64
    ) {
        self.maximumOperationCount = max(1, maximumOperationCount)
        self.maximumInsertedBytesPerOperation = max(0, maximumInsertedBytesPerOperation)
        self.maximumTotalInsertedBytes = max(0, maximumTotalInsertedBytes)
        self.maximumManifestBytes = max(4 << 10, maximumManifestBytes)
        self.maximumBookmarkBytes = max(0, maximumBookmarkBytes)
        self.maximumMetadataUTF8Bytes = max(0, maximumMetadataUTF8Bytes)
        self.maximumMetadataValueCount = max(0, maximumMetadataValueCount)
    }

    public static let `default` = RecoveryJournalConfiguration()
}

public nonisolated enum RecoveryJournalError: Error, LocalizedError, Equatable {
    case entryNotFound
    case entryClosed
    case invalidBaseFile
    case baseFileMissing
    case baseFileChanged
    case baseFileInaccessible
    case invalidEditRange(requested: Range<Int64>, byteCount: Int64)
    case operationLimitExceeded(limit: Int)
    case insertedOperationTooLarge(requested: Int, limit: Int)
    case insertedPayloadLimitExceeded(requested: Int64, limit: Int64)
    case metadataLimitExceeded
    case bookmarkTooLarge(requested: Int, limit: Int)
    case unsupportedManifestVersion(Int)
    case damagedManifest
    case damagedBlob
    case io(operation: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .entryNotFound:
            return "The recovery entry no longer exists."
        case .entryClosed:
            return "The recovery journal is closed."
        case .invalidBaseFile:
            return "Recovery requires a regular local base file."
        case .baseFileMissing:
            return "The recovery base file is no longer available."
        case .baseFileChanged:
            return "The recovery base file changed, so its saved byte offsets cannot be replayed safely."
        case .baseFileInaccessible:
            return "LighTxt no longer has permission to inspect the recovery base file."
        case let .invalidEditRange(range, byteCount):
            return "Recovery edit range \(range) is outside the current \(byteCount)-byte document."
        case let .operationLimitExceeded(limit):
            return "The recovery journal reached its \(limit.formatted())-operation limit. Save or start a new recovery checkpoint."
        case let .insertedOperationTooLarge(requested, limit):
            return "A \(requested)-byte edit exceeds the recovery journal's \(limit)-byte per-operation limit."
        case let .insertedPayloadLimitExceeded(requested, limit):
            return "Recovery edit payloads require \(requested) bytes, exceeding the \(limit)-byte journal limit."
        case .metadataLimitExceeded:
            return "Recovery window or task metadata exceeds its bounded storage limit."
        case let .bookmarkTooLarge(requested, limit):
            return "The \(requested)-byte security bookmark exceeds the \(limit)-byte recovery limit."
        case let .unsupportedManifestVersion(version):
            return "Recovery manifest version \(version) is not supported."
        case .damagedManifest:
            return "The recovery manifest is incomplete or damaged."
        case .damagedBlob:
            return "The recovery edit payload is incomplete or damaged."
        case let .io(operation, code):
            return "Could not \(operation) recovery data (POSIX error \(code): \(String(cString: strerror(code))))."
        }
    }
}

public nonisolated struct RecoveryEntry: Equatable, Sendable {
    public let identifier: UUID
    public let baseURL: URL
    public let baseFingerprint: RecoveryBaseFingerprint
    public let createdAt: Date
    public let updatedAt: Date
    public let operationCount: Int
    public let insertedByteCount: Int64
    public let resultingByteCount: Int64
    public let metadata: RecoveryMetadata
}

public nonisolated enum RecoveryEntryAvailability: Equatable, Sendable {
    case recoverable
    case baseMissing
    case baseChanged
    case baseInaccessible
    case damaged
}

public nonisolated struct RecoveryEntryInspection: Equatable, Sendable {
    public let identifier: UUID
    public let entry: RecoveryEntry?
    public let availability: RecoveryEntryAvailability
}

public nonisolated struct RecoveryPrunePolicy: Equatable, Sendable {
    public var maximumAge: TimeInterval
    public var maximumEntryCount: Int
    public var maximumStoredBytes: Int64
    public var damagedEntryGracePeriod: TimeInterval
    public var removeEntriesWhoseBaseChanged: Bool

    public init(
        maximumAge: TimeInterval = 14 * 24 * 60 * 60,
        maximumEntryCount: Int = 32,
        maximumStoredBytes: Int64 = 1 << 30,
        damagedEntryGracePeriod: TimeInterval = 24 * 60 * 60,
        removeEntriesWhoseBaseChanged: Bool = false
    ) {
        self.maximumAge = max(0, maximumAge)
        self.maximumEntryCount = max(0, maximumEntryCount)
        self.maximumStoredBytes = max(0, maximumStoredBytes)
        self.damagedEntryGracePeriod = max(0, damagedEntryGracePeriod)
        self.removeEntriesWhoseBaseChanged = removeEntriesWhoseBaseChanged
    }

    public static let `default` = RecoveryPrunePolicy()
}

public nonisolated enum RecoveryPruneReason: Equatable, Sendable {
    case expired
    case entryLimit
    case storageLimit
    case damaged
    case baseChanged
}

public nonisolated struct RecoveryPrunedEntry: Equatable, Sendable {
    public let identifier: UUID
    public let reason: RecoveryPruneReason
    public let reclaimedBytes: Int64
}

public nonisolated struct RecoveryPruneReport: Equatable, Sendable {
    public let removed: [RecoveryPrunedEntry]

    public var reclaimedBytes: Int64 {
        removed.reduce(0) { partial, entry in
            let (sum, overflow) = partial.addingReportingOverflow(entry.reclaimedBytes)
            return overflow ? Int64.max : sum
        }
    }
}

private nonisolated struct RecoveryBlobReference: Codable, Equatable, Sendable {
    let offset: Int64
    let length: Int64
    let checksum: UInt64
}

private nonisolated struct RecoveryStoredEdit: Codable, Equatable, Sendable {
    let sequence: UInt64
    let lowerBound: Int64
    let upperBound: Int64
    let replacement: RecoveryBlobReference?
}

private nonisolated struct RecoveryManifest: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int
    var identifier: UUID
    var baseURL: URL
    var securityScopedBookmark: Data?
    var baseFingerprint: RecoveryBaseFingerprint
    var createdAt: Date
    var updatedAt: Date
    var resultingByteCount: Int64
    var committedBlobByteCount: Int64
    var edits: [RecoveryStoredEdit]
    var metadata: RecoveryMetadata

    var entry: RecoveryEntry {
        RecoveryEntry(
            identifier: identifier,
            baseURL: baseURL,
            baseFingerprint: baseFingerprint,
            createdAt: createdAt,
            updatedAt: updatedAt,
            operationCount: edits.count,
            insertedByteCount: committedBlobByteCount,
            resultingByteCount: resultingByteCount,
            metadata: metadata
        )
    }
}

private nonisolated enum RecoveryFileLayout {
    static let manifestName = "manifest.json"
    static let blobName = "edits.blob"
    static let untitledBaseName = "untitled-base.txt"

    static func manifest(in directory: URL) -> URL {
        directory.appendingPathComponent(manifestName, isDirectory: false)
    }

    static func blob(in directory: URL) -> URL {
        directory.appendingPathComponent(blobName, isDirectory: false)
    }
}

/// Owns a live journal. Calls are synchronous because returning success means
/// both the blob and the atomically replaced manifest have reached `fsync`.
/// Integrators should coalesce typing into short batches before calling
/// `record(_:)` to avoid one durability barrier per key event.
public nonisolated final class RecoveryJournal: @unchecked Sendable {
    public let identifier: UUID

    private let lock = NSLock()
    private let rootURL: URL
    private let directoryURL: URL
    private let configuration: RecoveryJournalConfiguration
    private var manifest: RecoveryManifest
    private var closed = false

    fileprivate init(
        rootURL: URL,
        directoryURL: URL,
        configuration: RecoveryJournalConfiguration,
        manifest: RecoveryManifest
    ) {
        identifier = manifest.identifier
        self.rootURL = rootURL
        self.directoryURL = directoryURL
        self.configuration = configuration
        self.manifest = manifest
    }

    public var entry: RecoveryEntry {
        lock.lock()
        defer { lock.unlock() }
        return manifest.entry
    }

    /// Records a group of sequential current-document-coordinate edits and
    /// publishes one manifest. If any write fails, the old manifest remains the
    /// recovery boundary and an unreferenced blob tail is ignored/truncated by
    /// the next call.
    @discardableResult
    public func record(
        _ edits: [RecoveryPendingEdit],
        metadata: RecoveryMetadata? = nil,
        now: Date = Date()
    ) throws -> RecoveryEntry {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw RecoveryJournalError.entryClosed }

        let meaningful = edits.filter { !$0.byteRange.isEmpty || !$0.replacement.isEmpty }
        guard !meaningful.isEmpty else { return manifest.entry }
        let requestedOperationCount = manifest.edits.count + meaningful.count
        guard requestedOperationCount <= configuration.maximumOperationCount else {
            throw RecoveryJournalError.operationLimitExceeded(
                limit: configuration.maximumOperationCount
            )
        }

        var resultingByteCount = manifest.resultingByteCount
        var addedByteCount: Int64 = 0
        for edit in meaningful {
            guard edit.byteRange.lowerBound >= 0,
                  edit.byteRange.upperBound >= edit.byteRange.lowerBound,
                  edit.byteRange.upperBound <= resultingByteCount else {
                throw RecoveryJournalError.invalidEditRange(
                    requested: edit.byteRange,
                    byteCount: resultingByteCount
                )
            }
            guard edit.replacement.count <= configuration.maximumInsertedBytesPerOperation else {
                throw RecoveryJournalError.insertedOperationTooLarge(
                    requested: edit.replacement.count,
                    limit: configuration.maximumInsertedBytesPerOperation
                )
            }
            let inserted = Int64(edit.replacement.count)
            let added = addedByteCount.addingReportingOverflow(inserted)
            guard !added.overflow else {
                throw RecoveryJournalError.insertedPayloadLimitExceeded(
                    requested: Int64.max,
                    limit: configuration.maximumTotalInsertedBytes
                )
            }
            addedByteCount = added.partialValue
            let retained = resultingByteCount - Int64(edit.byteRange.count)
            let next = retained.addingReportingOverflow(inserted)
            guard !next.overflow, next.partialValue >= 0 else {
                throw RecoveryJournalError.invalidEditRange(
                    requested: edit.byteRange,
                    byteCount: resultingByteCount
                )
            }
            resultingByteCount = next.partialValue
        }

        let totalInserted = manifest.committedBlobByteCount.addingReportingOverflow(addedByteCount)
        guard !totalInserted.overflow,
              totalInserted.partialValue <= configuration.maximumTotalInsertedBytes else {
            throw RecoveryJournalError.insertedPayloadLimitExceeded(
                requested: totalInserted.overflow ? Int64.max : totalInserted.partialValue,
                limit: configuration.maximumTotalInsertedBytes
            )
        }
        let publishedMetadata = metadata ?? manifest.metadata
        try RecoveryValidation.validate(
            metadata: publishedMetadata,
            resultingByteCount: resultingByteCount,
            configuration: configuration
        )

        let blobURL = RecoveryFileLayout.blob(in: directoryURL)
        let descriptor = Darwin.open(blobURL.path, O_RDWR | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw RecoveryJournalError.io(operation: "open", code: errno)
        }
        defer { Darwin.close(descriptor) }

        guard ftruncate(descriptor, off_t(manifest.committedBlobByteCount)) == 0 else {
            throw RecoveryJournalError.io(operation: "truncate an uncommitted blob tail", code: errno)
        }

        var nextManifest = manifest
        var blobOffset = manifest.committedBlobByteCount
        for edit in meaningful {
            let reference: RecoveryBlobReference?
            if edit.replacement.isEmpty {
                reference = nil
            } else {
                try RecoveryFileIO.write(
                    edit.replacement,
                    to: descriptor,
                    at: blobOffset,
                    operation: "append edit bytes"
                )
                reference = RecoveryBlobReference(
                    offset: blobOffset,
                    length: Int64(edit.replacement.count),
                    checksum: RecoveryChecksum.fnv1a64(edit.replacement)
                )
                blobOffset += Int64(edit.replacement.count)
            }
            nextManifest.edits.append(RecoveryStoredEdit(
                sequence: UInt64(nextManifest.edits.count),
                lowerBound: edit.byteRange.lowerBound,
                upperBound: edit.byteRange.upperBound,
                replacement: reference
            ))
        }

        guard fsync(descriptor) == 0 else {
            throw RecoveryJournalError.io(operation: "synchronize edit bytes", code: errno)
        }
        nextManifest.resultingByteCount = resultingByteCount
        nextManifest.committedBlobByteCount = blobOffset
        nextManifest.metadata = publishedMetadata
        nextManifest.updatedAt = max(
            RecoveryTimestamp.manifestPrecision(now),
            nextManifest.createdAt
        )
        try RecoveryManifestIO.publish(
            nextManifest,
            in: directoryURL,
            configuration: configuration
        )
        manifest = nextManifest
        return nextManifest.entry
    }

    @discardableResult
    public func record(
        _ edit: RecoveryPendingEdit,
        metadata: RecoveryMetadata? = nil,
        now: Date = Date()
    ) throws -> RecoveryEntry {
        try record([edit], metadata: metadata, now: now)
    }

    @discardableResult
    public func updateMetadata(
        _ metadata: RecoveryMetadata,
        now: Date = Date()
    ) throws -> RecoveryEntry {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw RecoveryJournalError.entryClosed }
        try RecoveryValidation.validate(
            metadata: metadata,
            resultingByteCount: manifest.resultingByteCount,
            configuration: configuration
        )
        var next = manifest
        next.metadata = metadata
        next.updatedAt = max(RecoveryTimestamp.manifestPrecision(now), next.createdAt)
        try RecoveryManifestIO.publish(next, in: directoryURL, configuration: configuration)
        manifest = next
        return next.entry
    }

    /// Stops further writes but retains the entry for a future recovery chooser.
    public func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }

    /// Removes the recovery entry after a normal save or an explicit user choice.
    public func discard() throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { throw RecoveryJournalError.entryClosed }
        try RecoveryFileIO.removeEntry(directoryURL, syncing: rootURL)
        closed = true
    }
}

/// A recovered document owns both the byte-backed engine and any temporary
/// security-scope lease used to reopen the base. Keep this object alive for the
/// lifetime of the recovered engine.
public nonisolated final class RecoveredDocument: @unchecked Sendable {
    public let entry: RecoveryEntry
    public let engine: FileBackedPieceTable
    /// The resumed single-writer journal. Record subsequent accepted engine
    /// edits here; its first write also discards any uncommitted crash tail.
    public let journal: RecoveryJournal

    private let lock = NSLock()
    private var scope: RecoverySecurityScope?
    private var closed = false

    fileprivate init(
        entry: RecoveryEntry,
        engine: FileBackedPieceTable,
        journal: RecoveryJournal,
        scope: RecoverySecurityScope?
    ) {
        self.entry = entry
        self.engine = engine
        self.journal = journal
        self.scope = scope
    }

    deinit { close() }

    public func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        let heldScope = scope
        scope = nil
        lock.unlock()
        engine.close()
        journal.close()
        heldScope?.stop()
    }
}

/// Directory-level recovery API. It never copies a base document: discovery
/// compares metadata, and replay opens the existing file through the same
/// descriptor-backed piece table used by the editor.
public nonisolated struct RecoveryStore: Sendable {
    public let rootURL: URL
    public let configuration: RecoveryJournalConfiguration

    public init(
        rootURL: URL,
        configuration: RecoveryJournalConfiguration = .default
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.configuration = configuration
    }

    public static func defaultRootURL(fileManager: FileManager = .default) throws -> URL {
#if LIGHTXT_RUNTIME_QA
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "--workflow-runtime-qa-recovery-root"),
           arguments.indices.contains(flag + 1) {
            let isolatedURL = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
                .standardizedFileURL
            try fileManager.createDirectory(
                at: isolatedURL,
                withIntermediateDirectories: true
            )
            return isolatedURL
        }
        if let isolatedPath = ProcessInfo.processInfo.environment["LIGHTXT_RUNTIME_QA_RECOVERY_ROOT"],
           !isolatedPath.isEmpty {
            let isolatedURL = URL(fileURLWithPath: isolatedPath, isDirectory: true)
                .standardizedFileURL
            try fileManager.createDirectory(
                at: isolatedURL,
                withIntermediateDirectories: true
            )
            return isolatedURL
        }
#endif
        return try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        .appendingPathComponent("LighTxt", isDirectory: true)
        .appendingPathComponent("Recovery", isDirectory: true)
    }

    public func createJournal(
        for baseURL: URL,
        securityScopedBookmark: Data? = nil,
        metadata: RecoveryMetadata = RecoveryMetadata(),
        now: Date = Date()
    ) throws -> RecoveryJournal {
        try createJournal(
            for: baseURL,
            securityScopedBookmark: securityScopedBookmark,
            metadata: metadata,
            now: now,
            expectedBaseFingerprint: nil
        )
    }

    public func createJournal(
        for baseURL: URL,
        securityScopedBookmark: Data? = nil,
        metadata: RecoveryMetadata = RecoveryMetadata(),
        now: Date = Date(),
        expectedBaseFingerprint: RecoveryBaseFingerprint?
    ) throws -> RecoveryJournal {
        if let securityScopedBookmark,
           securityScopedBookmark.count > configuration.maximumBookmarkBytes {
            throw RecoveryJournalError.bookmarkTooLarge(
                requested: securityScopedBookmark.count,
                limit: configuration.maximumBookmarkBytes
            )
        }
        let standardized = baseURL.standardizedFileURL
        guard standardized.isFileURL else { throw RecoveryJournalError.invalidBaseFile }
        let physical = standardized.resolvingSymlinksInPath()
        let fingerprint: FileFingerprint
        do {
            guard let captured = try FileFingerprint.atPath(physical.path) else {
                throw RecoveryJournalError.baseFileMissing
            }
            fingerprint = captured
        } catch let error as RecoveryJournalError {
            throw error
        } catch {
            throw RecoveryJournalError.baseFileInaccessible
        }
        if let expectedBaseFingerprint,
           !expectedBaseFingerprint.matches(fingerprint) {
            throw RecoveryJournalError.baseFileChanged
        }
        try RecoveryFileIO.requireRegularFile(at: physical)
        try RecoveryValidation.validate(
            metadata: metadata,
            resultingByteCount: fingerprint.byteCount,
            configuration: configuration
        )

        try RecoveryFileIO.preparePrivateDirectory(rootURL, intermediate: true)
        let identifier = UUID()
        let directory = rootURL.appendingPathComponent(identifier.uuidString, isDirectory: true)
        try RecoveryFileIO.preparePrivateDirectory(directory, intermediate: false)
        var keepDirectory = false
        defer {
            if !keepDirectory { try? FileManager.default.removeItem(at: directory) }
        }

        let blobURL = RecoveryFileLayout.blob(in: directory)
        let descriptor = Darwin.open(
            blobURL.path,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw RecoveryJournalError.io(operation: "create an edit blob", code: errno)
        }
        guard Darwin.close(descriptor) == 0 else {
            throw RecoveryJournalError.io(operation: "close an edit blob", code: errno)
        }

        let timestamp = RecoveryTimestamp.manifestPrecision(now)
        let manifest = RecoveryManifest(
            version: RecoveryManifest.currentVersion,
            identifier: identifier,
            baseURL: standardized,
            securityScopedBookmark: securityScopedBookmark,
            baseFingerprint: RecoveryBaseFingerprint(fingerprint),
            createdAt: timestamp,
            updatedAt: timestamp,
            resultingByteCount: fingerprint.byteCount,
            committedBlobByteCount: 0,
            edits: [],
            metadata: metadata
        )
        try RecoveryManifestIO.publish(manifest, in: directory, configuration: configuration)
        try RecoveryFileIO.syncDirectory(rootURL)
        keepDirectory = true
        return RecoveryJournal(
            rootURL: rootURL,
            directoryURL: directory,
            configuration: configuration,
            manifest: manifest
        )
    }

    /// Creates an empty base inside the recovery entry itself. Untitled
    /// documents can therefore use the same offset journal without copying a
    /// user file, and pruning/discarding the entry removes its base atomically
    /// with the rest of the recovery data.
    public func createUntitledJournal(
        metadata: RecoveryMetadata = RecoveryMetadata(),
        now: Date = Date()
    ) throws -> RecoveryJournal {
        try RecoveryValidation.validate(
            metadata: metadata,
            resultingByteCount: 0,
            configuration: configuration
        )
        try RecoveryFileIO.preparePrivateDirectory(rootURL, intermediate: true)
        let identifier = UUID()
        let directory = rootURL.appendingPathComponent(identifier.uuidString, isDirectory: true)
        try RecoveryFileIO.preparePrivateDirectory(directory, intermediate: false)
        var keepDirectory = false
        defer {
            if !keepDirectory { try? FileManager.default.removeItem(at: directory) }
        }

        func createPrivateFile(_ url: URL) throws {
            let descriptor = Darwin.open(
                url.path,
                O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC,
                mode_t(0o600)
            )
            guard descriptor >= 0 else {
                throw RecoveryJournalError.io(operation: "create an untitled recovery file", code: errno)
            }
            guard fsync(descriptor) == 0 else {
                let code = errno
                Darwin.close(descriptor)
                throw RecoveryJournalError.io(operation: "synchronize an untitled recovery file", code: code)
            }
            guard Darwin.close(descriptor) == 0 else {
                throw RecoveryJournalError.io(operation: "close an untitled recovery file", code: errno)
            }
        }

        let baseURL = directory.appendingPathComponent(RecoveryFileLayout.untitledBaseName)
        try createPrivateFile(baseURL)
        let blobURL = RecoveryFileLayout.blob(in: directory)
        try createPrivateFile(blobURL)
        guard let fingerprint = try FileFingerprint.atPath(baseURL.path) else {
            throw RecoveryJournalError.baseFileMissing
        }

        let timestamp = RecoveryTimestamp.manifestPrecision(now)
        let manifest = RecoveryManifest(
            version: RecoveryManifest.currentVersion,
            identifier: identifier,
            baseURL: baseURL,
            securityScopedBookmark: nil,
            baseFingerprint: RecoveryBaseFingerprint(fingerprint),
            createdAt: timestamp,
            updatedAt: timestamp,
            resultingByteCount: 0,
            committedBlobByteCount: 0,
            edits: [],
            metadata: metadata
        )
        try RecoveryManifestIO.publish(manifest, in: directory, configuration: configuration)
        try RecoveryFileIO.syncDirectory(rootURL)
        keepDirectory = true
        return RecoveryJournal(
            rootURL: rootURL,
            directoryURL: directory,
            configuration: configuration,
            manifest: manifest
        )
    }

    /// Returns every parseable entry and a non-destructive availability result.
    /// Damaged entries are represented without attempting to read arbitrary
    /// unbounded data from them.
    public func inspectEntries() throws -> [RecoveryEntryInspection] {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return [] }
        let directories = try RecoveryFileIO.entryDirectories(in: rootURL)
        return directories.compactMap { directory in
            guard let identifier = UUID(uuidString: directory.lastPathComponent) else { return nil }
            do {
                let manifest = try RecoveryManifestIO.load(
                    from: directory,
                    expectedIdentifier: identifier,
                    configuration: configuration
                )
                let availability = RecoveryBaseResolver.availability(of: manifest)
                return RecoveryEntryInspection(
                    identifier: identifier,
                    entry: manifest.entry,
                    availability: availability
                )
            } catch {
                return RecoveryEntryInspection(
                    identifier: identifier,
                    entry: nil,
                    availability: .damaged
                )
            }
        }
        .sorted { lhs, rhs in
            let lhsDate = lhs.entry?.updatedAt ?? .distantPast
            let rhsDate = rhs.entry?.updatedAt ?? .distantPast
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return lhs.identifier.uuidString < rhs.identifier.uuidString
        }
    }

    public func recoveryCandidates() throws -> [RecoveryEntry] {
        try inspectEntries().compactMap { inspection in
            inspection.availability == .recoverable ? inspection.entry : nil
        }
    }

    public func recover(identifier: UUID) throws -> RecoveredDocument {
        let directory = rootURL.appendingPathComponent(identifier.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw RecoveryJournalError.entryNotFound
        }
        let manifest = try RecoveryManifestIO.load(
            from: directory,
            expectedIdentifier: identifier,
            configuration: configuration
        )
        let resolution = try RecoveryBaseResolver.resolveAndValidate(manifest)
        var keepScope = false
        defer {
            if !keepScope { resolution.scope?.stop() }
        }

        let engine = try FileBackedPieceTable(opening: resolution.url)
        do {
            try RecoveryReplay.apply(
                manifest: manifest,
                blobURL: RecoveryFileLayout.blob(in: directory),
                to: engine,
                configuration: configuration
            )
            guard let finalFingerprint = try FileFingerprint.atPath(
                resolution.url.standardizedFileURL.resolvingSymlinksInPath().path
            ), manifest.baseFingerprint.matches(finalFingerprint) else {
                throw RecoveryJournalError.baseFileChanged
            }
        } catch {
            engine.close()
            throw error
        }
        keepScope = true
        let journal = RecoveryJournal(
            rootURL: rootURL,
            directoryURL: directory,
            configuration: configuration,
            manifest: manifest
        )
        return RecoveredDocument(
            entry: manifest.entry,
            engine: engine,
            journal: journal,
            scope: resolution.scope
        )
    }

    public func discard(identifier: UUID) throws {
        let directory = rootURL.appendingPathComponent(identifier.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try RecoveryFileIO.removeEntry(directory, syncing: rootURL)
    }

    /// Removes expired/damaged entries and then enforces count and disk budgets,
    /// oldest first. A base mismatch is retained by default so temporary
    /// permission failures or a moved volume cannot silently destroy recovery.
    @discardableResult
    public func prune(
        policy: RecoveryPrunePolicy = .default,
        now: Date = Date()
    ) throws -> RecoveryPruneReport {
        guard FileManager.default.fileExists(atPath: rootURL.path) else {
            return RecoveryPruneReport(removed: [])
        }
        var removed: [RecoveryPrunedEntry] = []
        var retained: [(directory: URL, manifest: RecoveryManifest, bytes: Int64)] = []

        for directory in try RecoveryFileIO.entryDirectories(in: rootURL) {
            guard let identifier = UUID(uuidString: directory.lastPathComponent) else { continue }
            let bytes = RecoveryFileIO.directoryByteCount(directory)
            do {
                let manifest = try RecoveryManifestIO.load(
                    from: directory,
                    expectedIdentifier: identifier,
                    configuration: configuration
                )
                let age = max(0, now.timeIntervalSince(manifest.updatedAt))
                if age > policy.maximumAge {
                    try RecoveryFileIO.removeEntry(directory, syncing: rootURL)
                    removed.append(RecoveryPrunedEntry(
                        identifier: identifier,
                        reason: .expired,
                        reclaimedBytes: bytes
                    ))
                    continue
                }
                if policy.removeEntriesWhoseBaseChanged,
                   RecoveryBaseResolver.availability(of: manifest) == .baseChanged {
                    try RecoveryFileIO.removeEntry(directory, syncing: rootURL)
                    removed.append(RecoveryPrunedEntry(
                        identifier: identifier,
                        reason: .baseChanged,
                        reclaimedBytes: bytes
                    ))
                    continue
                }
                RecoveryFileIO.removeOldManifestTemps(
                    in: directory,
                    olderThan: now.addingTimeInterval(-policy.damagedEntryGracePeriod)
                )
                retained.append((directory, manifest, bytes))
            } catch {
                let modified = RecoveryFileIO.modificationDate(directory) ?? .distantPast
                let age = max(0, now.timeIntervalSince(modified))
                if age > policy.damagedEntryGracePeriod {
                    try RecoveryFileIO.removeEntry(directory, syncing: rootURL)
                    removed.append(RecoveryPrunedEntry(
                        identifier: identifier,
                        reason: .damaged,
                        reclaimedBytes: bytes
                    ))
                }
            }
        }

        retained.sort {
            if $0.manifest.updatedAt != $1.manifest.updatedAt {
                return $0.manifest.updatedAt > $1.manifest.updatedAt
            }
            return $0.manifest.identifier.uuidString < $1.manifest.identifier.uuidString
        }
        if retained.count > policy.maximumEntryCount {
            let overflow = retained[policy.maximumEntryCount...]
            for item in overflow {
                try RecoveryFileIO.removeEntry(item.directory, syncing: rootURL)
                removed.append(RecoveryPrunedEntry(
                    identifier: item.manifest.identifier,
                    reason: .entryLimit,
                    reclaimedBytes: item.bytes
                ))
            }
            retained.removeLast(retained.count - policy.maximumEntryCount)
        }

        var retainedBytes: Int64 = 0
        var storageOverflow: [(directory: URL, manifest: RecoveryManifest, bytes: Int64)] = []
        for item in retained {
            let sum = retainedBytes.addingReportingOverflow(item.bytes)
            if sum.overflow || sum.partialValue > policy.maximumStoredBytes {
                storageOverflow.append(item)
            } else {
                retainedBytes = sum.partialValue
            }
        }
        for item in storageOverflow {
            try RecoveryFileIO.removeEntry(item.directory, syncing: rootURL)
            removed.append(RecoveryPrunedEntry(
                identifier: item.manifest.identifier,
                reason: .storageLimit,
                reclaimedBytes: item.bytes
            ))
        }
        return RecoveryPruneReport(removed: removed)
    }
}

private nonisolated enum RecoveryValidation {
    static func validate(
        manifest: RecoveryManifest,
        expectedIdentifier: UUID,
        configuration: RecoveryJournalConfiguration
    ) throws {
        guard manifest.version == RecoveryManifest.currentVersion else {
            throw RecoveryJournalError.unsupportedManifestVersion(manifest.version)
        }
        guard manifest.identifier == expectedIdentifier,
              manifest.baseURL.isFileURL,
              manifest.baseFingerprint.byteCount >= 0,
              manifest.createdAt <= manifest.updatedAt,
              manifest.edits.count <= configuration.maximumOperationCount,
              manifest.committedBlobByteCount >= 0,
              manifest.committedBlobByteCount <= configuration.maximumTotalInsertedBytes else {
            throw RecoveryJournalError.damagedManifest
        }
        if let bookmark = manifest.securityScopedBookmark,
           bookmark.count > configuration.maximumBookmarkBytes {
            throw RecoveryJournalError.damagedManifest
        }

        var currentByteCount = manifest.baseFingerprint.byteCount
        var expectedBlobOffset: Int64 = 0
        for (index, edit) in manifest.edits.enumerated() {
            guard edit.sequence == UInt64(index),
                  edit.lowerBound >= 0,
                  edit.upperBound >= edit.lowerBound,
                  edit.upperBound <= currentByteCount else {
                throw RecoveryJournalError.damagedManifest
            }
            let inserted: Int64
            if let replacement = edit.replacement {
                guard replacement.offset == expectedBlobOffset,
                      replacement.length > 0,
                      replacement.length <= Int64(configuration.maximumInsertedBytesPerOperation),
                      replacement.length <= Int64(Int.max) else {
                    throw RecoveryJournalError.damagedManifest
                }
                let nextOffset = expectedBlobOffset.addingReportingOverflow(replacement.length)
                guard !nextOffset.overflow else { throw RecoveryJournalError.damagedManifest }
                expectedBlobOffset = nextOffset.partialValue
                inserted = replacement.length
            } else {
                inserted = 0
            }
            let retained = currentByteCount - (edit.upperBound - edit.lowerBound)
            let nextByteCount = retained.addingReportingOverflow(inserted)
            guard !nextByteCount.overflow, nextByteCount.partialValue >= 0 else {
                throw RecoveryJournalError.damagedManifest
            }
            currentByteCount = nextByteCount.partialValue
        }
        guard expectedBlobOffset == manifest.committedBlobByteCount,
              currentByteCount == manifest.resultingByteCount else {
            throw RecoveryJournalError.damagedManifest
        }
        try validate(
            metadata: manifest.metadata,
            resultingByteCount: manifest.resultingByteCount,
            configuration: configuration
        )
    }

    static func validate(
        metadata: RecoveryMetadata,
        resultingByteCount: Int64,
        configuration: RecoveryJournalConfiguration
    ) throws {
        if let window = metadata.window {
            if let frame = window.frame,
               !(frame.x.isFinite && frame.y.isFinite && frame.width.isFinite
                   && frame.height.isFinite && frame.width >= 0 && frame.height >= 0) {
                throw RecoveryJournalError.metadataLimitExceeded
            }
            if let lower = window.selectionLowerByteOffset,
               let upper = window.selectionUpperByteOffset,
               !(lower >= 0 && upper >= lower && upper <= resultingByteCount) {
                throw RecoveryJournalError.metadataLimitExceeded
            }
            if (window.selectionLowerByteOffset == nil) != (window.selectionUpperByteOffset == nil) {
                throw RecoveryJournalError.metadataLimitExceeded
            }
            if let viewport = window.viewportByteOffset,
               !(viewport >= 0 && viewport <= resultingByteCount) {
                throw RecoveryJournalError.metadataLimitExceeded
            }
            if let width = window.structureSidebarWidth,
               !(width.isFinite && width >= 0) {
                throw RecoveryJournalError.metadataLimitExceeded
            }
        }

        let taskValues = metadata.task?.values ?? [:]
        guard taskValues.count <= configuration.maximumMetadataValueCount else {
            throw RecoveryJournalError.metadataLimitExceeded
        }
        var strings: [String] = []
        if let mode = metadata.window?.presentationMode { strings.append(mode) }
        if let task = metadata.task {
            if let identifier = task.taskIdentifier { strings.append(identifier) }
            if let displayName = task.displayName { strings.append(displayName) }
            if let fileType = task.fileType { strings.append(fileType) }
            for (key, value) in task.values {
                strings.append(key)
                strings.append(value)
            }
        }
        var byteCount = 0
        for string in strings {
            let next = byteCount.addingReportingOverflow(string.utf8.count)
            guard !next.overflow,
                  next.partialValue <= configuration.maximumMetadataUTF8Bytes else {
                throw RecoveryJournalError.metadataLimitExceeded
            }
            byteCount = next.partialValue
        }
    }
}

private nonisolated enum RecoveryManifestIO {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    static func publish(
        _ manifest: RecoveryManifest,
        in directory: URL,
        configuration: RecoveryJournalConfiguration
    ) throws {
        try RecoveryValidation.validate(
            manifest: manifest,
            expectedIdentifier: manifest.identifier,
            configuration: configuration
        )
        let data: Data
        do {
            data = try encoder().encode(manifest)
        } catch {
            throw RecoveryJournalError.damagedManifest
        }
        guard data.count <= configuration.maximumManifestBytes else {
            throw RecoveryJournalError.operationLimitExceeded(
                limit: configuration.maximumOperationCount
            )
        }

        let temporary = directory.appendingPathComponent(
            "\(RecoveryFileLayout.manifestName).tmp.\(UUID().uuidString)",
            isDirectory: false
        )
        let destination = RecoveryFileLayout.manifest(in: directory)
        let descriptor = Darwin.open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw RecoveryJournalError.io(operation: "create a manifest", code: errno)
        }
        var descriptorIsOpen = true
        defer {
            if descriptorIsOpen { Darwin.close(descriptor) }
            unlink(temporary.path)
        }
        try RecoveryFileIO.write(data, to: descriptor, at: 0, operation: "write a manifest")
        guard fsync(descriptor) == 0 else {
            throw RecoveryJournalError.io(operation: "synchronize a manifest", code: errno)
        }
        guard Darwin.close(descriptor) == 0 else {
            descriptorIsOpen = false
            throw RecoveryJournalError.io(operation: "close a manifest", code: errno)
        }
        descriptorIsOpen = false
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            throw RecoveryJournalError.io(operation: "publish a manifest", code: errno)
        }
        try RecoveryFileIO.syncDirectory(directory)
    }

    static func load(
        from directory: URL,
        expectedIdentifier: UUID,
        configuration: RecoveryJournalConfiguration
    ) throws -> RecoveryManifest {
        let manifestURL = RecoveryFileLayout.manifest(in: directory)
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: manifestURL.path)
        } catch {
            throw RecoveryJournalError.damagedManifest
        }
        guard let number = attributes[.size] as? NSNumber,
              number.int64Value >= 0,
              number.int64Value <= Int64(configuration.maximumManifestBytes) else {
            throw RecoveryJournalError.damagedManifest
        }
        let data: Data
        do {
            data = try Data(contentsOf: manifestURL, options: [])
        } catch {
            throw RecoveryJournalError.damagedManifest
        }
        let manifest: RecoveryManifest
        do {
            manifest = try decoder().decode(RecoveryManifest.self, from: data)
        } catch {
            throw RecoveryJournalError.damagedManifest
        }
        try RecoveryValidation.validate(
            manifest: manifest,
            expectedIdentifier: expectedIdentifier,
            configuration: configuration
        )
        try RecoveryFileIO.validateBlobLength(
            RecoveryFileLayout.blob(in: directory),
            minimumByteCount: manifest.committedBlobByteCount
        )
        return manifest
    }
}

private nonisolated enum RecoveryReplay {
    static func apply(
        manifest: RecoveryManifest,
        blobURL: URL,
        to engine: FileBackedPieceTable,
        configuration: RecoveryJournalConfiguration
    ) throws {
        let descriptor = Darwin.open(blobURL.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw RecoveryJournalError.damagedBlob }
        defer { Darwin.close(descriptor) }

        for edit in manifest.edits {
            let replacement: Data
            if let reference = edit.replacement {
                guard reference.length <= Int64(configuration.maximumInsertedBytesPerOperation) else {
                    throw RecoveryJournalError.damagedManifest
                }
                replacement = try RecoveryFileIO.read(
                    from: descriptor,
                    range: reference.offset..<(reference.offset + reference.length)
                )
                guard RecoveryChecksum.fnv1a64(replacement) == reference.checksum else {
                    throw RecoveryJournalError.damagedBlob
                }
            } else {
                replacement = Data()
            }
            do {
                try engine.replace(
                    byteRange: edit.lowerBound..<edit.upperBound,
                    with: replacement
                )
            } catch {
                throw RecoveryJournalError.damagedManifest
            }
        }
        guard engine.byteCount == manifest.resultingByteCount else {
            throw RecoveryJournalError.damagedManifest
        }
    }
}

private nonisolated final class RecoverySecurityScope: @unchecked Sendable {
    private let lock = NSLock()
    private var url: URL?

    init(url: URL, started: Bool) {
        self.url = started ? url : nil
    }

    deinit { stop() }

    func stop() {
        lock.lock()
        let stopping = url
        url = nil
        lock.unlock()
        stopping?.stopAccessingSecurityScopedResource()
    }
}

private nonisolated enum RecoveryBaseResolver {
    struct Resolution {
        let url: URL
        let scope: RecoverySecurityScope?
    }

    static func availability(of manifest: RecoveryManifest) -> RecoveryEntryAvailability {
        do {
            let resolution = try resolve(manifest)
            defer { resolution.scope?.stop() }
            let physical = resolution.url.standardizedFileURL.resolvingSymlinksInPath()
            guard let current = try FileFingerprint.atPath(physical.path) else {
                return .baseMissing
            }
            return manifest.baseFingerprint.matches(current) ? .recoverable : .baseChanged
        } catch let error as RecoveryJournalError {
            switch error {
            case .baseFileMissing: return .baseMissing
            case .baseFileChanged: return .baseChanged
            default: return .baseInaccessible
            }
        } catch {
            return .baseInaccessible
        }
    }

    static func resolveAndValidate(_ manifest: RecoveryManifest) throws -> Resolution {
        let resolution = try resolve(manifest)
        do {
            let physical = resolution.url.standardizedFileURL.resolvingSymlinksInPath()
            guard let current = try FileFingerprint.atPath(physical.path) else {
                throw RecoveryJournalError.baseFileMissing
            }
            guard manifest.baseFingerprint.matches(current) else {
                throw RecoveryJournalError.baseFileChanged
            }
            try RecoveryFileIO.requireRegularFile(at: physical)
            return Resolution(url: physical, scope: resolution.scope)
        } catch {
            resolution.scope?.stop()
            if let recoveryError = error as? RecoveryJournalError { throw recoveryError }
            throw RecoveryJournalError.baseFileInaccessible
        }
    }

    private static func resolve(_ manifest: RecoveryManifest) throws -> Resolution {
        guard let bookmark = manifest.securityScopedBookmark else {
            return Resolution(url: manifest.baseURL, scope: nil)
        }
        var stale = false
        let resolved: URL
        do {
            resolved = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
        } catch {
            // The persisted URL can still be valid when a non-sandbox test or a
            // stale bookmark cannot be resolved. Fingerprint validation remains
            // the authority and prevents replay against another file.
            return Resolution(url: manifest.baseURL, scope: nil)
        }
        let started = resolved.startAccessingSecurityScopedResource()
        return Resolution(
            url: resolved,
            scope: started ? RecoverySecurityScope(url: resolved, started: true) : nil
        )
    }
}

private nonisolated enum RecoveryChecksum {
    static func fnv1a64(_ data: Data) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in data {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return hash
    }
}

private nonisolated enum RecoveryTimestamp {
    /// Mirrors JSONEncoder's milliseconds-since-1970 representation so entries
    /// returned before and after a process restart compare identically.
    static func manifestPrecision(_ date: Date) -> Date {
        let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded(.towardZero)
        return Date(timeIntervalSince1970: milliseconds / 1_000)
    }
}

private nonisolated enum RecoveryFileIO {
    static let readChunkByteCount = 1 << 20

    static func preparePrivateDirectory(_ url: URL, intermediate: Bool) throws {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue,
                  (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                throw RecoveryJournalError.io(operation: "validate a private directory", code: ENOTDIR)
            }
        } else {
            do {
                try FileManager.default.createDirectory(
                    at: url,
                    withIntermediateDirectories: intermediate,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                throw RecoveryJournalError.io(operation: "create a private directory", code: errno)
            }
        }
        guard chmod(url.path, mode_t(0o700)) == 0 else {
            throw RecoveryJournalError.io(operation: "secure a private directory", code: errno)
        }
    }

    static func requireRegularFile(at url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0 else {
            if errno == ENOENT { throw RecoveryJournalError.baseFileMissing }
            throw RecoveryJournalError.baseFileInaccessible
        }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw RecoveryJournalError.invalidBaseFile
        }
    }

    static func write(
        _ data: Data,
        to descriptor: Int32,
        at offset: Int64,
        operation: String
    ) throws {
        let isEmpty = data.isEmpty
        try data.withUnsafeBytes { bytes in
            guard isEmpty || bytes.baseAddress != nil else {
                throw RecoveryJournalError.io(operation: operation, code: EIO)
            }
            var completed = 0
            while completed < bytes.count {
                let result = Darwin.pwrite(
                    descriptor,
                    bytes.baseAddress!.advanced(by: completed),
                    bytes.count - completed,
                    off_t(offset + Int64(completed))
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw RecoveryJournalError.io(operation: operation, code: errno)
                }
                guard result > 0 else {
                    throw RecoveryJournalError.io(operation: operation, code: EIO)
                }
                completed += result
            }
        }
    }

    static func read(from descriptor: Int32, range: Range<Int64>) throws -> Data {
        let length = range.upperBound - range.lowerBound
        guard range.lowerBound >= 0,
              range.upperBound >= range.lowerBound,
              length <= Int64(Int.max) else {
            throw RecoveryJournalError.damagedBlob
        }
        var data = Data(count: Int(length))
        let isEmpty = data.isEmpty
        try data.withUnsafeMutableBytes { destination in
            guard isEmpty || destination.baseAddress != nil else {
                throw RecoveryJournalError.damagedBlob
            }
            var completed = 0
            while completed < destination.count {
                let requested = min(readChunkByteCount, destination.count - completed)
                let result = Darwin.pread(
                    descriptor,
                    destination.baseAddress!.advanced(by: completed),
                    requested,
                    off_t(range.lowerBound + Int64(completed))
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw RecoveryJournalError.damagedBlob
                }
                guard result > 0 else { throw RecoveryJournalError.damagedBlob }
                completed += result
            }
        }
        return data
    }

    static func validateBlobLength(_ url: URL, minimumByteCount: Int64) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              Int64(status.st_size) >= minimumByteCount else {
            throw RecoveryJournalError.damagedBlob
        }
    }

    static func syncDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw RecoveryJournalError.io(operation: "open a recovery directory", code: errno)
        }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw RecoveryJournalError.io(operation: "synchronize a recovery directory", code: errno)
        }
    }

    static func entryDirectories(in root: URL) throws -> [URL] {
        let children: [URL]
        do {
            children = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw RecoveryJournalError.io(operation: "enumerate recovery entries", code: errno)
        }
        return children.filter { child in
            guard UUID(uuidString: child.lastPathComponent) != nil,
                  let values = try? child.resourceValues(
                      forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                  ) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true
        }
    }

    static func removeEntry(_ directory: URL, syncing root: URL) throws {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            throw RecoveryJournalError.io(operation: "remove a recovery entry", code: errno)
        }
        try syncDirectory(root)
    }

    static func directoryByteCount(_ directory: URL) -> Int64 {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for child in children {
            guard let values = try? child.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]
            ), values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            let sum = total.addingReportingOverflow(size)
            total = sum.overflow ? Int64.max : sum.partialValue
        }
        return total
    }

    static func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    static func removeOldManifestTemps(in directory: URL, olderThan cutoff: Date) {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        for child in children where child.lastPathComponent.hasPrefix(
            "\(RecoveryFileLayout.manifestName).tmp."
        ) {
            guard let values = try? child.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey]
            ), values.isRegularFile == true,
               (values.contentModificationDate ?? .distantPast) < cutoff else { continue }
            try? FileManager.default.removeItem(at: child)
        }
    }
}
