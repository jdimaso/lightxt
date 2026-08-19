import Foundation

private nonisolated enum PieceBacking {
    case mapped(MemoryMappedFile)
    case addition(AdditionSegment)

    func withUnsafeBytes<R>(
        in range: Range<Int64>,
        _ body: (UnsafeRawBufferPointer) throws -> R
    ) throws -> R {
        switch self {
        case let .mapped(file):
            return try file.withUnsafeBytes(in: range, body)
        case let .addition(segment):
            return try segment.withUnsafeBytes(in: range, body)
        }
    }
}

private nonisolated struct Piece {
    let backing: PieceBacking
    let offset: Int64
    let length: Int64

    func prefix(_ byteCount: Int64) -> Piece {
        Piece(backing: backing, offset: offset, length: byteCount)
    }

    func droppingFirst(_ byteCount: Int64) -> Piece {
        Piece(
            backing: backing,
            offset: offset + byteCount,
            length: length - byteCount
        )
    }
}

/// An immutable implicit treap node. Path-copying makes an undo state cost
/// O(log piece-count), rather than a copy of the document or its piece list.
nonisolated final class PieceNode: @unchecked Sendable {
    fileprivate let piece: Piece
    fileprivate let priority: UInt64
    fileprivate let left: PieceNode?
    fileprivate let right: PieceNode?
    let subtreeByteCount: Int64
    let subtreePieceCount: Int

    fileprivate init(
        piece: Piece,
        priority: UInt64,
        left: PieceNode? = nil,
        right: PieceNode? = nil
    ) {
        self.piece = piece
        self.priority = priority
        self.left = left
        self.right = right
        self.subtreeByteCount = (left?.subtreeByteCount ?? 0)
            + piece.length
            + (right?.subtreeByteCount ?? 0)
        self.subtreePieceCount = (left?.subtreePieceCount ?? 0)
            + 1
            + (right?.subtreePieceCount ?? 0)
    }
}

@inline(__always)
nonisolated private func treeByteCount(_ node: PieceNode?) -> Int64 {
    node?.subtreeByteCount ?? 0
}

nonisolated private func mergeTrees(_ left: PieceNode?, _ right: PieceNode?) -> PieceNode? {
    guard let left else { return right }
    guard let right else { return left }

    if left.priority >= right.priority {
        return PieceNode(
            piece: left.piece,
            priority: left.priority,
            left: left.left,
            right: mergeTrees(left.right, right)
        )
    }
    return PieceNode(
        piece: right.piece,
        priority: right.priority,
        left: mergeTrees(left, right.left),
        right: right.right
    )
}

/// Splits immediately before `byteOffset`. Both results retain structural
/// sharing with `node`; splitting inside a piece creates only two piece nodes.
nonisolated private func splitTree(
    _ node: PieceNode?,
    at byteOffset: Int64,
    random: inout SplitMix64
) -> (PieceNode?, PieceNode?) {
    guard let node else { return (nil, nil) }
    if byteOffset <= 0 { return (nil, node) }
    if byteOffset >= node.subtreeByteCount { return (node, nil) }

    let leftBytes = treeByteCount(node.left)
    let pieceEnd = leftBytes + node.piece.length

    if byteOffset < leftBytes {
        let (before, after) = splitTree(node.left, at: byteOffset, random: &random)
        return (
            before,
            PieceNode(
                piece: node.piece,
                priority: node.priority,
                left: after,
                right: node.right
            )
        )
    }

    if byteOffset > pieceEnd {
        let (before, after) = splitTree(
            node.right,
            at: byteOffset - pieceEnd,
            random: &random
        )
        return (
            PieceNode(
                piece: node.piece,
                priority: node.priority,
                left: node.left,
                right: before
            ),
            after
        )
    }

    if byteOffset == leftBytes {
        return (
            node.left,
            PieceNode(
                piece: node.piece,
                priority: node.priority,
                left: nil,
                right: node.right
            )
        )
    }

    if byteOffset == pieceEnd {
        return (
            PieceNode(
                piece: node.piece,
                priority: node.priority,
                left: node.left,
                right: nil
            ),
            node.right
        )
    }

    let offsetInsidePiece = byteOffset - leftBytes
    let beforePiece = PieceNode(
        piece: node.piece.prefix(offsetInsidePiece),
        priority: random.next()
    )
    let afterPiece = PieceNode(
        piece: node.piece.droppingFirst(offsetInsidePiece),
        priority: random.next()
    )
    return (
        mergeTrees(node.left, beforePiece),
        mergeTrees(afterPiece, node.right)
    )
}

nonisolated private func rootsAreIdentical(_ lhs: PieceNode?, _ rhs: PieceNode?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): return true
    case let (lhs?, rhs?): return lhs === rhs
    default: return false
    }
}

/// One source-coordinate edit in an atomic byte-edit batch.
///
/// Every range in a batch addresses the same immutable document revision.
/// `FileBackedPieceTable` validates and applies those ranges from the end of
/// the document toward the beginning, so an earlier replacement never shifts
/// a later edit's source coordinates.
public nonisolated struct ByteEdit: Sendable, Equatable {
    public let byteRange: Range<Int64>
    public let replacement: Data

    public init(byteRange: Range<Int64>, replacement: Data) {
        self.byteRange = byteRange
        self.replacement = replacement
    }
}

private nonisolated struct SplitMix64 {
    private var state: UInt64 = 0x4c69_6768_5478_7421

    mutating func next() -> UInt64 {
        state &+= 0x9e37_79b9_7f4a_7c15
        var value = state
        value = (value ^ (value >> 30)) &* 0xbf58_476d_1ce4_e5b9
        value = (value ^ (value >> 27)) &* 0x94d0_49bb_1331_11eb
        return value ^ (value >> 31)
    }
}

/// A stable, immutable view of one document revision.
///
/// Snapshots are cheap and safe to consume on a background queue while edits
/// continue. Each callback receives either immutable edit memory or a bounded
/// positional-read buffer and is valid only for the callback's duration.
public nonisolated final class DocumentSnapshot: @unchecked Sendable {
    fileprivate let root: PieceNode?
    private let mappingKeeper: MemoryMappedFile?

    public let revision: UInt64
    public let byteCount: Int64
    public let pieceCount: Int

    fileprivate init(root: PieceNode?, mapping: MemoryMappedFile?, revision: UInt64) {
        self.root = root
        self.mappingKeeper = mapping
        self.revision = revision
        self.byteCount = treeByteCount(root)
        self.pieceCount = root?.subtreePieceCount ?? 0
    }

    /// Enumerates the requested range in backing-store slices without first
    /// materializing it as a contiguous buffer.
    public func forEachByteSlice(
        in requestedRange: Range<Int64>? = nil,
        _ body: (UnsafeRawBufferPointer) throws -> Void
    ) throws {
        let range = requestedRange ?? 0..<byteCount
        try validateByteRange(range, byteCount: byteCount)
        guard !range.isEmpty else { return }

        func visit(_ node: PieceNode?, documentOffset: Int64) throws {
            guard let node else { return }
            let leftBytes = treeByteCount(node.left)
            let pieceStart = documentOffset + leftBytes
            let pieceEnd = pieceStart + node.piece.length

            if range.lowerBound < pieceStart {
                try visit(node.left, documentOffset: documentOffset)
            }

            let intersectionStart = max(range.lowerBound, pieceStart)
            let intersectionEnd = min(range.upperBound, pieceEnd)
            if intersectionStart < intersectionEnd {
                var backingStart = node.piece.offset + (intersectionStart - pieceStart)
                let backingEnd = backingStart + (intersectionEnd - intersectionStart)
                // Bounded callbacks give long-running consumers regular
                // cancellation points and hard-bound positional-read buffers.
                let maximumSliceBytes = Int64(MemoryMappedFile.maximumReadByteCount)
                while backingStart < backingEnd {
                    let sliceEnd = min(backingEnd, backingStart + maximumSliceBytes)
                    try node.piece.backing.withUnsafeBytes(
                        in: backingStart..<sliceEnd,
                        body
                    )
                    backingStart = sliceEnd
                }
            }

            if range.upperBound > pieceEnd {
                try visit(node.right, documentOffset: pieceEnd)
            }
        }

        try visit(root, documentOffset: 0)
    }

    /// Copies a bounded range for UI presentation or parsing. Large-document
    /// paths should prefer `forEachByteSlice`.
    public func data(in range: Range<Int64>) throws -> Data {
        try validateByteRange(range, byteCount: byteCount)
        let resultSize = try checkedInt(range.upperBound - range.lowerBound)
        var result = Data()
        result.reserveCapacity(resultSize)
        try forEachByteSlice(in: range) { bytes in
            result.append(contentsOf: bytes)
        }
        return result
    }

    public func utf8String(in range: Range<Int64>) throws -> String {
        let bytes = try data(in: range)
        guard let string = String(data: bytes, encoding: .utf8) else {
            throw LighTxtCoreError.invalidUTF8(range: range)
        }
        return string
    }

    /// Explicit whole-document materialization for parsers that truly require
    /// it. The default cap prevents an accidental multi-gigabyte allocation.
    public func materializedData(maximumByteCount: Int64 = 64 << 20) throws -> Data {
        guard byteCount <= maximumByteCount else {
            throw LighTxtCoreError.requestedMaterializationTooLarge(
                requested: byteCount,
                limit: maximumByteCount
            )
        }
        return try data(in: 0..<byteCount)
    }

    public func byte(at offset: Int64) throws -> UInt8 {
        guard offset >= 0, offset < byteCount else {
            throw LighTxtCoreError.invalidByteRange(
                requested: offset..<offset,
                byteCount: byteCount
            )
        }
        var value: UInt8 = 0
        try forEachByteSlice(in: offset..<(offset + 1)) { bytes in
            value = bytes[0]
        }
        return value
    }
}

/// A thread-safe, byte-addressed, file-backed piece table.
///
/// The original file is never copied wholesale into `Data`: an open descriptor
/// serves bounded positional reads, while edits are represented by immutable
/// added-byte segments plus a persistent balanced tree. UI code should translate
/// character selections to UTF-8 byte ranges before applying edits.
public nonisolated final class FileBackedPieceTable: @unchecked Sendable {
    public struct Configuration: Sendable {
        public var maximumUndoLevels: Int
        public var rebaseAfterSave: Bool
        public var durableSaves: Bool
        /// Total edit payload admitted to heap memory between rebases. Once the
        /// budget is exhausted, subsequent additions use one unlinked temporary
        /// pread store. This is deliberately monotonic, making it a hard bound.
        public var maximumResidentEditBytes: Int64
        public var individualEditSpillThresholdBytes: Int64
        /// Internal deterministic fault injection used to prove that a pathname
        /// substitution after rename cannot be adopted as the clean document.
        var _afterSaveRenameForTesting: (@Sendable (URL) throws -> Void)?

        public init(
            maximumUndoLevels: Int = 512,
            rebaseAfterSave: Bool = true,
            durableSaves: Bool = false,
            maximumResidentEditBytes: Int64 = 16 << 20,
            individualEditSpillThresholdBytes: Int64 = 4 << 20
        ) {
            self.maximumUndoLevels = max(0, maximumUndoLevels)
            self.rebaseAfterSave = rebaseAfterSave
            self.durableSaves = durableSaves
            self.maximumResidentEditBytes = max(0, maximumResidentEditBytes)
            self.individualEditSpillThresholdBytes = max(
                0,
                individualEditSpillThresholdBytes
            )
            self._afterSaveRenameForTesting = nil
        }
    }

    private struct State {
        var documentURL: URL?
        var mapping: MemoryMappedFile?
        var diskFingerprint: FileFingerprint?
        var root: PieceNode?
        var savedRoot: PieceNode?
        var undoRoots: [PieceNode?] = []
        var redoRoots: [PieceNode?] = []
        var revision: UInt64 = 0
        var random = SplitMix64()
        var residentEditBytes: Int64 = 0
        var temporaryAdditionStore: TemporaryAdditionStore?
    }

    private let lock = NSLock()
    private let configuration: Configuration
    private var state: State?

    public init(opening url: URL, configuration: Configuration = .init()) throws {
        self.configuration = configuration
        let mapping = try MemoryMappedFile(url: url)
        let initialRoot: PieceNode?
        var random = SplitMix64()
        if mapping.byteCount == 0 {
            initialRoot = nil
        } else {
            initialRoot = PieceNode(
                piece: Piece(
                    backing: .mapped(mapping),
                    offset: 0,
                    length: mapping.byteCount
                ),
                priority: random.next()
            )
        }
        self.state = State(
            documentURL: mapping.url,
            mapping: mapping,
            diskFingerprint: mapping.fingerprint,
            root: initialRoot,
            savedRoot: initialRoot,
            random: random
        )
    }

    /// Creates an empty, fully editable document without touching the file
    /// system. This is the final fallback for an untitled document when macOS
    /// cannot create its normal private scratch file. The first persistent save
    /// must use `saveAs`; ordinary `save` deliberately fails until then.
    public init(empty configuration: Configuration = .init()) {
        self.configuration = configuration
        self.state = State(
            documentURL: nil,
            mapping: nil,
            diskFingerprint: nil,
            root: nil,
            savedRoot: nil
        )
    }

    public var isOpen: Bool {
        withLock { state != nil }
    }

    public var documentURL: URL? {
        withLock { state?.documentURL }
    }

    public var byteCount: Int64 {
        withLock { treeByteCount(state?.root) }
    }

    public var pieceCount: Int {
        withLock { state?.root?.subtreePieceCount ?? 0 }
    }

    public var canUndo: Bool {
        withLock { !(state?.undoRoots.isEmpty ?? true) }
    }

    public var canRedo: Bool {
        withLock { !(state?.redoRoots.isEmpty ?? true) }
    }

    public var hasUnsavedChanges: Bool {
        withLock {
            guard let state else { return false }
            return !rootsAreIdentical(state.root, state.savedRoot)
        }
    }

    /// Releases this document's root and open storage. Existing snapshots remain
    /// readable until their consumers release them.
    public func close() {
        withLock { state = nil }
    }

    public func snapshot() throws -> DocumentSnapshot {
        try withLock {
            guard let state else { throw LighTxtCoreError.documentClosed }
            return DocumentSnapshot(
                root: state.root,
                mapping: state.mapping,
                revision: state.revision
            )
        }
    }

    public func insert(_ bytes: Data, at byteOffset: Int64) throws {
        try replace(byteRange: byteOffset..<byteOffset, with: bytes)
    }

    public func insert(utf8 string: String, at byteOffset: Int64) throws {
        try insert(Data(string.utf8), at: byteOffset)
    }

    public func delete(byteRange: Range<Int64>) throws {
        try replace(byteRange: byteRange, with: Data())
    }

    public func replace(byteRange: Range<Int64>, withUTF8 string: String) throws {
        try replace(byteRange: byteRange, with: Data(string.utf8))
    }

    public func replace(byteRange: Range<Int64>, with bytes: Data) throws {
        try replaceAtomically(edits: [
            ByteEdit(byteRange: byteRange, replacement: bytes),
        ])
    }

    /// Applies non-overlapping source-coordinate edits as one transaction.
    ///
    /// Validation, replacement storage, and the new persistent tree are all
    /// prepared before the live state is published. A failure therefore leaves
    /// the document bytes, revision, dirty state, and undo/redo stacks exactly
    /// as they were. The batch consumes one undo level and one revision.
    public func replaceAtomically(
        edits: [ByteEdit],
        cancellation: (@Sendable () -> Bool)? = nil
    ) throws {
        try replaceAtomically(
            edits: edits,
            requiring: nil,
            cancellation: cancellation
        )
    }

    /// Applies an atomic batch only if `captured` is still the current root.
    /// This is the safe commit boundary for edits whose ranges were calculated
    /// asynchronously from an immutable snapshot.
    public func replaceAtomically(
        edits: [ByteEdit],
        replacing captured: DocumentSnapshot,
        cancellation: (@Sendable () -> Bool)? = nil
    ) throws {
        try replaceAtomically(
            edits: edits,
            requiring: captured,
            cancellation: cancellation
        )
    }

    private func replaceAtomically(
        edits: [ByteEdit],
        requiring captured: DocumentSnapshot?,
        cancellation: (@Sendable () -> Bool)?
    ) throws {
        if cancellation?() == true { throw CancellationError() }
        try withLock {
            guard var current = state else { throw LighTxtCoreError.documentClosed }
            if cancellation?() == true { throw CancellationError() }
            if let captured,
               !rootsAreIdentical(current.root, captured.root) {
                throw LighTxtCoreError.documentChangedDuringBulkOperation
            }

            let oldByteCount = treeByteCount(current.root)
            var ordered = edits.filter { !$0.byteRange.isEmpty || !$0.replacement.isEmpty }
            for edit in ordered {
                if cancellation?() == true { throw CancellationError() }
                try validateByteRange(edit.byteRange, byteCount: oldByteCount)
            }
            guard !ordered.isEmpty else { return }

            // A deterministic tie-break makes zero-length insertions at the
            // same source offset well-defined without relying on sort
            // stability. Later entries at that offset are applied first, so
            // their final byte order matches the caller's array order.
            ordered = ordered.enumerated().sorted { lhs, rhs in
                if lhs.element.byteRange.lowerBound != rhs.element.byteRange.lowerBound {
                    return lhs.element.byteRange.lowerBound > rhs.element.byteRange.lowerBound
                }
                if lhs.element.byteRange.upperBound != rhs.element.byteRange.upperBound {
                    return lhs.element.byteRange.upperBound > rhs.element.byteRange.upperBound
                }
                return lhs.offset > rhs.offset
            }.map(\.element)
            if cancellation?() == true { throw CancellationError() }

            for pair in zip(ordered, ordered.dropFirst()) {
                if cancellation?() == true { throw CancellationError() }
                let higher = pair.0.byteRange
                let lower = pair.1.byteRange
                guard lower.upperBound <= higher.lowerBound else {
                    throw LighTxtCoreError.overlappingByteEdits(
                        first: higher,
                        second: lower
                    )
                }
            }

            var totalRemoved: Int64 = 0
            var totalInserted: Int64 = 0
            for edit in ordered {
                if cancellation?() == true { throw CancellationError() }
                let removed = edit.byteRange.upperBound - edit.byteRange.lowerBound
                let inserted = Int64(edit.replacement.count)
                let removedTotal = totalRemoved.addingReportingOverflow(removed)
                let insertedTotal = totalInserted.addingReportingOverflow(inserted)
                guard !removedTotal.overflow, !insertedTotal.overflow else {
                    throw LighTxtCoreError.fileTooLarge(Int64.max)
                }
                totalRemoved = removedTotal.partialValue
                totalInserted = insertedTotal.partialValue
            }
            let retainedByteCount = oldByteCount - totalRemoved
            guard !retainedByteCount.addingReportingOverflow(totalInserted).overflow else {
                throw LighTxtCoreError.fileTooLarge(Int64.max)
            }

            let originalRoot = current.root
            var nextRoot = originalRoot
            for edit in ordered {
                if cancellation?() == true { throw CancellationError() }
                let (before, tail) = splitTree(
                    nextRoot,
                    at: edit.byteRange.lowerBound,
                    random: &current.random
                )
                let (_, after) = splitTree(
                    tail,
                    at: edit.byteRange.upperBound - edit.byteRange.lowerBound,
                    random: &current.random
                )

                var insertedRoot: PieceNode?
                if !edit.replacement.isEmpty {
                    let byteLength = Int64(edit.replacement.count)
                    let residentBudgetRemaining = configuration.maximumResidentEditBytes
                        - current.residentEditBytes
                    let storeOnDisk = byteLength
                        > configuration.individualEditSpillThresholdBytes
                        || byteLength > residentBudgetRemaining
                    let segment: AdditionSegment
                    if storeOnDisk {
                        let store: TemporaryAdditionStore
                        if let existing = current.temporaryAdditionStore {
                            store = existing
                        } else {
                            store = try TemporaryAdditionStore()
                            current.temporaryAdditionStore = store
                        }
                        segment = try AdditionSegment(
                            data: edit.replacement,
                            temporaryStore: store
                        )
                    } else {
                        segment = try AdditionSegment(
                            data: edit.replacement,
                            temporaryStore: nil
                        )
                        current.residentEditBytes += byteLength
                    }
                    insertedRoot = PieceNode(
                        piece: Piece(
                            backing: .addition(segment),
                            offset: 0,
                            length: byteLength
                        ),
                        priority: current.random.next()
                    )
                }
                if cancellation?() == true { throw CancellationError() }
                nextRoot = mergeTrees(mergeTrees(before, insertedRoot), after)
            }

            // This is the linearization point. Cancellation before it leaves
            // the live root, revision, undo/redo stacks, and dirty state intact.
            if cancellation?() == true { throw CancellationError() }
            if configuration.maximumUndoLevels > 0 {
                current.undoRoots.append(originalRoot)
                if current.undoRoots.count > configuration.maximumUndoLevels {
                    current.undoRoots.removeFirst(
                        current.undoRoots.count - configuration.maximumUndoLevels
                    )
                }
            }
            current.redoRoots.removeAll(keepingCapacity: true)
            current.root = nextRoot
            current.revision &+= 1
            state = current
        }
    }

    /// Commits a fully streamed rewrite as one undoable edit, but only if the
    /// captured root is still current. The rewritten storage is retained by the
    /// new root (and later by redo) without becoming the on-disk save baseline.
    func installBulkRewrite(
        _ rewrittenMapping: MemoryMappedFile,
        replacing captured: DocumentSnapshot,
        cancellation: (@Sendable () -> Bool)? = nil
    ) throws {
        if cancellation?() == true { throw CancellationError() }
        try withLock {
            guard var current = state else { throw LighTxtCoreError.documentClosed }
            if cancellation?() == true { throw CancellationError() }
            guard rootsAreIdentical(current.root, captured.root) else {
                throw LighTxtCoreError.documentChangedDuringBulkOperation
            }
            if cancellation?() == true { throw CancellationError() }

            let rewrittenRoot: PieceNode?
            if rewrittenMapping.byteCount == 0 {
                rewrittenRoot = nil
            } else {
                rewrittenRoot = PieceNode(
                    piece: Piece(
                        backing: .mapped(rewrittenMapping),
                        offset: 0,
                        length: rewrittenMapping.byteCount
                    ),
                    priority: current.random.next()
                )
            }

            // Cancellation and root publication linearize under the same
            // document lock. Once this check passes, the rewrite wins the race;
            // cancellation observed before it publishes no document state.
            if cancellation?() == true { throw CancellationError() }

            if configuration.maximumUndoLevels > 0 {
                current.undoRoots.append(current.root)
                if current.undoRoots.count > configuration.maximumUndoLevels {
                    current.undoRoots.removeFirst(
                        current.undoRoots.count - configuration.maximumUndoLevels
                    )
                }
            }
            current.redoRoots.removeAll(keepingCapacity: true)
            current.root = rewrittenRoot
            current.revision &+= 1
            state = current
        }
    }

    @discardableResult
    public func undo() -> Bool {
        withLock {
            guard var current = state, let previous = current.undoRoots.popLast() else {
                return false
            }
            current.redoRoots.append(current.root)
            current.root = previous
            current.revision &+= 1
            state = current
            return true
        }
    }

    @discardableResult
    public func redo() -> Bool {
        withLock {
            guard var current = state, let next = current.redoRoots.popLast() else {
                return false
            }
            current.undoRoots.append(current.root)
            current.root = next
            current.revision &+= 1
            state = current
            return true
        }
    }

    /// Atomically saves to the current document URL.
    public func save(
        cancellation: CancellationToken? = nil,
        progress: ((SaveProgress) -> Void)? = nil
    ) throws {
        let destination = try withLock { () throws -> (URL, FileFingerprint) in
            guard let state else { throw LighTxtCoreError.documentClosed }
            guard let documentURL = state.documentURL,
                  let diskFingerprint = state.diskFingerprint else {
                throw LighTxtCoreError.documentHasNoSaveDestination
            }
            return (documentURL, diskFingerprint)
        }
        try performSave(
            to: destination.0,
            expectedDestination: destination.1,
            cancellation: cancellation,
            progress: progress
        )
    }

    /// Performs an ordinary in-place save only after proving that the URL
    /// supplied by NSDocument still resolves to this engine's existing URL.
    /// A changed symlink therefore fails closed and can never be inferred as a
    /// Save As operation.
    public func save(
        validatingCurrentDocumentURL requestedURL: URL,
        cancellation: CancellationToken? = nil,
        progress: ((SaveProgress) -> Void)? = nil
    ) throws {
        let resolvedRequest = requestedURL.standardizedFileURL.resolvingSymlinksInPath()
        let destination = try withLock { () throws -> (URL, FileFingerprint) in
            guard let state else { throw LighTxtCoreError.documentClosed }
            guard let documentURL = state.documentURL,
                  let diskFingerprint = state.diskFingerprint else {
                throw LighTxtCoreError.documentHasNoSaveDestination
            }
            guard resolvedRequest == documentURL else {
                throw LighTxtCoreError.fileChangedExternally(path: requestedURL.path)
            }
            return (documentURL, diskFingerprint)
        }
        try performSave(
            to: destination.0,
            expectedDestination: destination.1,
            cancellation: cancellation,
            progress: progress
        )
    }

    /// Validates an ordinary-save URL without writing. AppKit uses this before
    /// entering file coordination, then `save(validatingCurrentDocumentURL:)`
    /// repeats the check at the actual write boundary.
    public func validateCurrentDocumentURL(_ requestedURL: URL) throws {
        let resolvedRequest = requestedURL.standardizedFileURL.resolvingSymlinksInPath()
        try withLock {
            guard let state else { throw LighTxtCoreError.documentClosed }
            guard let documentURL = state.documentURL,
                  state.diskFingerprint != nil else {
                throw LighTxtCoreError.documentHasNoSaveDestination
            }
            guard resolvedRequest == documentURL else {
                throw LighTxtCoreError.fileChangedExternally(path: requestedURL.path)
            }
        }
    }

    /// Atomically saves and adopts `url` as the document's current URL.
    public func saveAs(
        _ url: URL,
        cancellation: CancellationToken? = nil,
        progress: ((SaveProgress) -> Void)? = nil
    ) throws {
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        let expectedDestination = try withLock { () throws -> FileFingerprint? in
            guard let current = state else { throw LighTxtCoreError.documentClosed }
            if current.documentURL == target {
                return current.diskFingerprint
            }
            return try FileFingerprint.atPath(target.path)
        }
        try performSave(
            to: target,
            expectedDestination: expectedDestination,
            cancellation: cancellation,
            progress: progress
        )
    }

    private func performSave(
        to target: URL,
        expectedDestination: FileFingerprint?,
        cancellation: CancellationToken?,
        progress: ((SaveProgress) -> Void)?
    ) throws {
        let captured = try snapshot()
        let savedMapping = try StreamingFileWriter.write(
            snapshot: captured,
            to: target,
            expectedDestination: expectedDestination,
            durable: configuration.durableSaves,
            cancellation: cancellation,
            progress: progress,
            afterRename: configuration._afterSaveRenameForTesting
        )

        try withLock {
            guard var current = state else { throw LighTxtCoreError.documentClosed }
            // The writer owns the exact inode that was renamed. Validate that
            // the pathname still names it while the document state is locked;
            // never clear dirty/undo state onto bytes reopened through a raced
            // pathname.
            guard try FileFingerprint.atPath(target.path) == savedMapping.fingerprint else {
                throw LighTxtCoreError.fileChangedExternally(path: target.path)
            }
            current.documentURL = target
            current.diskFingerprint = savedMapping.fingerprint

            if rootsAreIdentical(current.root, captured.root) {
                if configuration.rebaseAfterSave {
                    let newRoot: PieceNode?
                    if savedMapping.byteCount == 0 {
                        newRoot = nil
                    } else {
                        newRoot = PieceNode(
                            piece: Piece(
                                backing: .mapped(savedMapping),
                                offset: 0,
                                length: savedMapping.byteCount
                            ),
                            priority: current.random.next()
                        )
                    }
                    current.mapping = savedMapping
                    current.root = newRoot
                    current.savedRoot = newRoot
                    current.undoRoots.removeAll(keepingCapacity: false)
                    current.redoRoots.removeAll(keepingCapacity: false)
                    current.residentEditBytes = 0
                    current.temporaryAdditionStore = nil
                } else {
                    current.savedRoot = captured.root
                }
            } else {
                // Edits arrived while streaming the snapshot. They remain dirty,
                // while undo can still return to the exact saved root.
                current.savedRoot = captured.root
            }
            state = current
        }
    }

    /// Writes an atomic copy without changing the document URL or dirty state.
    public func saveCopy(
        to url: URL,
        cancellation: CancellationToken? = nil,
        progress: ((SaveProgress) -> Void)? = nil
    ) throws {
        if cancellation?.isCancelled == true {
            throw CancellationError()
        }
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        let copyState = try withLock { () throws -> (
            snapshot: DocumentSnapshot,
            sourceURL: URL?,
            sourceFingerprint: FileFingerprint?,
            clean: Bool
        ) in
            guard let current = state else { throw LighTxtCoreError.documentClosed }
            return (
                DocumentSnapshot(
                    root: current.root,
                    mapping: current.mapping,
                    revision: current.revision
                ),
                current.documentURL,
                current.diskFingerprint,
                rootsAreIdentical(current.root, current.savedRoot)
            )
        }
        guard copyState.sourceURL.map({ target != $0 }) ?? true else {
            throw LighTxtCoreError.copyDestinationMatchesDocument
        }
        let expectedDestination: FileFingerprint?
        expectedDestination = try FileFingerprint.atPath(target.path)

        if copyState.clean,
           let sourceURL = copyState.sourceURL,
           let sourceFingerprint = copyState.sourceFingerprint,
           try FileFingerprint.atPath(sourceURL.path) == sourceFingerprint,
           try StreamingFileWriter.cloneAtomically(
                from: sourceURL,
                to: target,
                expectedSource: sourceFingerprint,
                expectedDestination: expectedDestination,
                durable: configuration.durableSaves
           ) {
            progress?(SaveProgress(
                bytesWritten: copyState.snapshot.byteCount,
                totalBytes: copyState.snapshot.byteCount
            ))
            return
        }

        _ = try StreamingFileWriter.write(
            snapshot: copyState.snapshot,
            to: target,
            expectedDestination: expectedDestination,
            durable: configuration.durableSaves,
            cancellation: cancellation,
            progress: progress
        )
    }

    @inline(__always)
    private func withLock<R>(_ body: () throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
