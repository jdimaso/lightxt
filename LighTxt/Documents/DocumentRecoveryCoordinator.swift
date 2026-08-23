import Foundation

/// Debounces accepted byte edits before handing them to the durable core
/// journal. Typing therefore pays no synchronous fsync cost; a close/quit
/// performs one final bounded flush.
@MainActor
final class DocumentRecoveryCoordinator {
    private enum Base: Sendable {
        case file(
            URL,
            bookmark: Data?,
            expectedFingerprint: RecoveryBaseFingerprint?
        )
        case untitled
    }

    /// Mutable journal state is owned exclusively by `queue`. Keeping the
    /// stop flag and metadata snapshots out of this object avoids unchecked
    /// reads from the main actor while a durable write is in flight.
    private nonisolated final class Storage: @unchecked Sendable {
        let store: RecoveryStore
        let base: Base
        var journal: RecoveryJournal?
        var isStopped = false

        init(
            store: RecoveryStore,
            base: Base,
            journal: RecoveryJournal?
        ) {
            self.store = store
            self.base = base
            self.journal = journal
        }

        func ensureJournal(metadata: RecoveryMetadata) throws -> RecoveryJournal {
            if let journal { return journal }
            let created: RecoveryJournal
            switch base {
            case let .file(url, bookmark, expectedFingerprint):
                created = try store.createJournal(
                    for: url,
                    securityScopedBookmark: bookmark,
                    metadata: metadata,
                    expectedBaseFingerprint: expectedFingerprint
                )
            case .untitled:
                created = try store.createUntitledJournal(metadata: metadata)
            }
            journal = created
            return created
        }

        /// A failed append can leave a valid, earlier checkpoint. Close it and
        /// reject all queued follow-on edits whose coordinates may depend on
        /// the failed edit.
        func stopPreservingJournal() {
            isStopped = true
            journal?.close()
        }

        /// Normal save/close must not leave a chooser entry behind. A journal
        /// may already be closed after an earlier failure, so fall back to the
        /// store-level removal API in that case.
        func discardJournal() {
            isStopped = true
            guard let journal else { return }
            do {
                try journal.discard()
            } catch RecoveryJournalError.entryClosed {
                try? store.discard(identifier: journal.identifier)
            } catch {
                // The document save/close has already succeeded. A stale,
                // fingerprint-validated entry is safer than surfacing a second
                // failure or blocking the user indefinitely.
            }
            self.journal = nil
        }
    }

    private let queue = DispatchQueue(
        label: "app.lightxt.document-recovery",
        qos: .utility,
        autoreleaseFrequency: .workItem
    )
    private let storage: Storage
    private var pendingEdits: [RecoveryPendingEdit] = []
    private var pendingInsertedBytes = 0
    private var flushWorkItem: DispatchWorkItem?
    private var metadataWorkItem: DispatchWorkItem?
    private var generation: UInt64 = 0
    private var latestMetadata: RecoveryMetadata
    private var isStopped = false
    private var didDiscard = false
    var onFailure: ((Error) -> Void)?

    init(
        baseURL: URL?,
        displayName: String?,
        fileType: String?,
        isUntitled: Bool,
        expectedBaseFingerprint: RecoveryBaseFingerprint?
    ) throws {
        let root = try RecoveryStore.defaultRootURL()
        let store = RecoveryStore(rootURL: root)
        let base: Base
        if let baseURL {
            let bookmark = try? baseURL.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            base = .file(
                baseURL.standardizedFileURL,
                bookmark: bookmark,
                expectedFingerprint: expectedBaseFingerprint
            )
        } else {
            base = .untitled
        }
        let metadata = RecoveryMetadata(task: RecoveryTaskMetadata(
            displayName: displayName,
            fileType: fileType,
            values: ["untitled": isUntitled ? "true" : "false"]
        ))
        latestMetadata = metadata
        storage = Storage(store: store, base: base, journal: nil)
    }

    init(resuming recovered: RecoveredDocument) throws {
        let store = RecoveryStore(rootURL: try RecoveryStore.defaultRootURL())
        latestMetadata = recovered.entry.metadata
        storage = Storage(
            store: store,
            base: .file(
                recovered.entry.baseURL,
                bookmark: nil,
                expectedFingerprint: recovered.entry.baseFingerprint
            ),
            journal: recovered.journal
        )
    }

    func record(_ edit: RecoveryPendingEdit) {
        record([edit])
    }

    func record(_ edits: [RecoveryPendingEdit]) {
        let meaningful = edits.filter { !$0.byteRange.isEmpty || !$0.replacement.isEmpty }
        guard !meaningful.isEmpty, !isStopped else { return }
        pendingEdits.append(contentsOf: meaningful)
        pendingInsertedBytes += meaningful.reduce(0) { $0 + $1.replacement.count }
        if pendingEdits.count >= 64 || pendingInsertedBytes >= 256 << 10 {
            flushPendingEdits(publishing: latestMetadata)
        } else {
            scheduleEditFlush()
        }
    }

    func updateMetadata(_ metadata: RecoveryMetadata) {
        guard !isStopped else { return }
        latestMetadata = metadata
        metadataWorkItem?.cancel()
        let generation = self.generation
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation else { return }
            if !self.flushPendingEdits(publishing: metadata) {
                self.publishMetadata(metadata, generation: generation)
            }
        }
        metadataWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: item)
    }

    /// Waits only at an explicit close/quit boundary. Ordinary typing and
    /// metadata updates never block the main actor on disk synchronization.
    func flushSynchronously() {
        guard !isStopped else { return }
        flushWorkItem?.cancel()
        metadataWorkItem?.cancel()
        let metadata = latestMetadata
        let generation = self.generation
        if !flushPendingEdits(publishing: metadata) {
            publishMetadata(metadata, generation: generation)
        }
        queue.sync {}
    }

    func discardAfterSuccessfulSave() {
        guard !didDiscard else { return }
        didDiscard = true
        isStopped = true
        generation &+= 1
        flushWorkItem?.cancel()
        metadataWorkItem?.cancel()
        pendingEdits.removeAll(keepingCapacity: false)
        pendingInsertedBytes = 0
        // Saving and an explicit close are rare synchronization boundaries.
        // Waiting here prevents a successfully closed document from being
        // offered as a stale crash-recovery candidate on the next launch.
        queue.sync { [storage] in storage.discardJournal() }
    }

    func stopRetainingRecovery() {
        flushSynchronously()
        guard !isStopped else { return }
        isStopped = true
        generation &+= 1
        queue.sync { [storage] in storage.stopPreservingJournal() }
    }

    private func scheduleEditFlush() {
        flushWorkItem?.cancel()
        let generation = self.generation
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.generation == generation else { return }
            self.flushPendingEdits(publishing: self.latestMetadata)
        }
        flushWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: item)
    }

    @discardableResult
    private func flushPendingEdits(publishing metadata: RecoveryMetadata) -> Bool {
        guard !pendingEdits.isEmpty, !isStopped else { return false }
        let batch = Self.coalescingAdjacentInsertions(in: pendingEdits)
        pendingEdits.removeAll(keepingCapacity: true)
        pendingInsertedBytes = 0
        let generation = self.generation
        queue.async { [weak self, storage] in
            guard !storage.isStopped else { return }
            do {
                try storage.ensureJournal(metadata: metadata).record(
                    batch,
                    metadata: metadata
                )
            } catch {
                storage.stopPreservingJournal()
                DispatchQueue.main.async {
                    self?.handleFailure(error, generation: generation)
                }
            }
        }
        return true
    }

    private func publishMetadata(_ metadata: RecoveryMetadata, generation: UInt64) {
        queue.async { [weak self, storage] in
            guard !storage.isStopped else { return }
            do {
                if let journal = storage.journal {
                    try journal.updateMetadata(metadata)
                }
            } catch {
                storage.stopPreservingJournal()
                DispatchQueue.main.async {
                    self?.handleFailure(error, generation: generation)
                }
            }
        }
    }

    private func handleFailure(_ error: Error, generation: UInt64) {
        guard self.generation == generation, !isStopped else { return }
        isStopped = true
        self.generation &+= 1
        flushWorkItem?.cancel()
        metadataWorkItem?.cancel()
        pendingEdits.removeAll(keepingCapacity: false)
        pendingInsertedBytes = 0
        onFailure?(error)
    }

    /// A normal run of typed UTF-8 characters becomes one journal operation
    /// instead of consuming the fixed manifest operation budget key by key.
    /// Other edits retain their original order and coordinate semantics.
    private static func coalescingAdjacentInsertions(
        in edits: [RecoveryPendingEdit]
    ) -> [RecoveryPendingEdit] {
        guard edits.count > 1 else { return edits }
        var result: [RecoveryPendingEdit] = []
        result.reserveCapacity(edits.count)
        for edit in edits {
            if let previous = result.last,
               previous.byteRange.isEmpty,
               edit.byteRange.isEmpty,
               let expectedOffset = Int64(exactly: previous.replacement.count)
                    .flatMap({ previous.byteRange.lowerBound.addingReportingOverflow($0) })
                    .flatMap({ $0.overflow ? nil : $0.partialValue }),
               edit.byteRange.lowerBound == expectedOffset {
                var combined = previous.replacement
                combined.append(edit.replacement)
                result[result.count - 1] = RecoveryPendingEdit(
                    byteRange: previous.byteRange,
                    replacement: combined
                )
            } else {
                result.append(edit)
            }
        }
        return result
    }
}
