import Foundation

/// UI-independent MainActor owner for one document's immutable JSON index.
/// Every background result is generation-checked before publication, so a scan
/// of revision N can never replace or mutate the tree for revision N+1.
@MainActor
final class JSONStructureController {
    struct Callbacks {
        var progress: ((JSONStructureIndexProgress) -> Void)?
        var ready: ((JSONStructureIndex) -> Void)?
        var invalidated: (() -> Void)?
        var error: ((Error) -> Void)?
    }

    private(set) var index: JSONStructureIndex?
    private(set) var latestProgress: JSONStructureIndexProgress?
    private(set) var isBuilding = false
    var callbacks = Callbacks()

    private var generation: UInt64 = 0
    private var buildCancellation: CancellationToken?
    private var pageCancellations: [UUID: CancellationToken] = [:]
    private let memoryPressureSource: DispatchSourceMemoryPressure

    init() {
        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: DispatchQueue.global(qos: .utility)
        )
        memoryPressureSource = source
        source.setEventHandler { [weak self] in
            DispatchQueue.main.async { [weak self] in
                self?.purgeRebuildableResidentMemory()
            }
        }
        source.resume()
    }

    deinit {
        memoryPressureSource.cancel()
        buildCancellation?.cancel()
        for token in pageCancellations.values { token.cancel() }
        index?.close()
    }

    func rebuild(
        snapshot: DocumentSnapshot,
        configuration: JSONStructureIndexConfiguration = .default
    ) {
        cancelBuildAndAdvanceGeneration()
        let operationGeneration = generation
        let token = CancellationToken()
        buildCancellation = token
        isBuilding = true
        latestProgress = JSONStructureIndexProgress(
            processedBytes: 0,
            totalBytes: snapshot.byteCount,
            indexedContainerCount: 0,
            parsedValueCount: 0,
            diagnosticCount: 0
        )
        callbacks.progress?(latestProgress!)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<JSONStructureIndex, Error>
            do {
                result = .success(
                    try StreamingJSONStructureIndexer.build(
                        snapshot: snapshot,
                        generation: operationGeneration,
                        configuration: configuration,
                        cancellation: token,
                        progress: { update in
                            DispatchQueue.main.async { [weak self] in
                                guard let self,
                                      self.generation == operationGeneration,
                                      self.buildCancellation === token else { return }
                                self.latestProgress = update
                                self.callbacks.progress?(update)
                            }
                        }
                    )
                )
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.generation == operationGeneration,
                      self.buildCancellation === token else {
                    if case let .success(staleIndex) = result { staleIndex.close() }
                    return
                }
                self.buildCancellation = nil
                self.isBuilding = false
                switch result {
                case let .success(completed):
                    let old = self.index
                    self.index = completed
                    old?.close()
                    self.callbacks.ready?(completed)
                case .failure(is CancellationError):
                    break
                case let .failure(error):
                    self.callbacks.error?(error)
                }
            }
        }
    }

    /// Call immediately after an edit. The old snapshot remains owned until it
    /// is closed here, so concurrent readers finish safely, but stale rows are
    /// removed from the UI synchronously.
    func invalidate(forRevision revision: UInt64) {
        guard index?.sourceRevision != revision || isBuilding else { return }
        cancelBuildAndAdvanceGeneration()
        latestProgress = nil
        isBuilding = false
        let old = index
        index = nil
        old?.close()
        callbacks.invalidated?()
    }

    func cancel() {
        cancelBuildAndAdvanceGeneration()
        isBuilding = false
        latestProgress = nil
    }

    /// Releases only the completed index's mapped source/index pages. The
    /// index transparently falls back to its unlinked disk backing, so node
    /// identities, child cursors, expansion state, and selection remain valid.
    /// Repeated calls are harmless. In-flight child requests are deliberately
    /// allowed to finish: their owner uses completion to clear per-node loading
    /// state, and the disk-backed index remains safe to read during a purge.
    func purgeRebuildableResidentMemory() {
        guard let current = index else { return }
        DispatchQueue.global(qos: .utility).async {
            _ = try? current.purgeResidentMemory()
        }
    }

    /// Disk-backed JSON indexes reactivate lazily on their next child read.
    /// This explicit no-op keeps window lifecycle fan-out idempotent.
    func reactivateAfterResidentPurge() {}

    /// Cancels every operation and releases the captured source snapshot plus
    /// all unlinked index storage, even when the logical edit revision did not
    /// change. Atomic saves can rebase the source inode without a revision
    /// bump, so revision-only invalidation is not sufficient here.
    func reset() {
        cancelBuildAndAdvanceGeneration()
        isBuilding = false
        latestProgress = nil
        let old = index
        index = nil
        old?.close()
    }

    /// Child decoding is also background work: one legal JSON string can be
    /// gigabytes long even though the resulting page is small.
    @discardableResult
    func requestChildren(
        of parent: JSONStructureNode,
        cursor: JSONStructureChildrenCursor? = nil,
        limit: Int = 256,
        completion: @escaping @MainActor @Sendable (Result<JSONStructureChildrenPage, Error>) -> Void
    ) -> UUID? {
        guard let index else {
            completion(.failure(JSONStructureIndexError.closed))
            return nil
        }
        let requestID = UUID()
        let token = CancellationToken()
        let operationGeneration = generation
        pageCancellations[requestID] = token
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try index.children(
                    of: parent,
                    cursor: cursor,
                    limit: limit,
                    cancellation: token
                )
            }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.pageCancellations.removeValue(forKey: requestID) === token,
                      self.generation == operationGeneration,
                      self.index === index else { return }
                completion(result)
            }
        }
        return requestID
    }

    func cancelPageRequest(_ requestID: UUID) {
        pageCancellations.removeValue(forKey: requestID)?.cancel()
    }

    private func cancelBuildAndAdvanceGeneration() {
        generation &+= 1
        buildCancellation?.cancel()
        buildCancellation = nil
        for token in pageCancellations.values { token.cancel() }
        pageCancellations.removeAll(keepingCapacity: true)
    }
}
