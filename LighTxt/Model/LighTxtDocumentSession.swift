import AppKit
import Foundation

@MainActor
final class LighTxtDocumentSession: VirtualTextEditorDelegate, CSVMutationEditorDelegate {
    private struct RecoveryTransaction {
        let forward: [RecoveryPendingEdit]
        let inverse: [RecoveryPendingEdit]?
    }

    struct Callbacks {
        var documentChanged: ((Int64, Bool) -> Void)?
        var selectionChanged: ((Range<Int64>, Int64, Int) -> Void)?
        var editorViewportChanged: ((Range<Int64>, Int64) -> Void)?
        var statusChanged: ((String, Bool, Bool) -> Void)?
        var matchChanged: ((SearchMatch?) -> Void)?
        var findAllCompleted: ((SearchSummary) -> Void)?
        var searchResultsInvalidated: (() -> Void)?
        var structureChanged: (([SyntaxFoldRange], Data, Int64, SyntaxFileType) -> Void)?
        var accessStateChanged: (() -> Void)?
        var error: ((Error) -> Void)?
    }

    private(set) var engine: FileBackedPieceTable
    private(set) var syntaxFileType: SyntaxFileType
    private(set) var sampledDetection: SampledDocumentDetection?
    /// Encoding of the file selected by the user before any working-copy conversion.
    private(set) var sourceTextEncoding: DocumentTextEncoding
    /// Encoding of the bytes currently owned by `engine`.
    private(set) var textEncoding: DocumentTextEncoding
    private(set) var delimitedTextDelimiter: DelimitedTextDelimiter
    private(set) var reopenOptions: DocumentOpenOptions
    private(set) var sourceURL: URL?
    private(set) var originalSourceURL: URL?
    private(set) var isScratchDocument: Bool
    /// The bounded prefix was not valid in any supported Unicode encoding.
    /// Keep the original bytes viewable but immutable until the user makes an
    /// explicit, strictly validated Open As choice.
    private(set) var hasUnresolvedSourceEncoding: Bool
    /// Automatic detection samples only a bounded prefix. Files larger than
    /// that prefix remain immutable until a bounded background pass verifies
    /// the exact snapshot that the editor opened.
    private(set) var isSourceEncodingValidationPending: Bool
    private var scratchBackingURL: URL?
    private var transcodedScratchFile: UnicodeScratchFile?
    private var sourceEncodingValidationCancellation: CancellationToken?
    private var requiresDestinationSave = false
    private var infersUntitledSaveFormat = false
    var callbacks = Callbacks()

    private(set) var currentMatch: SearchMatch?
    private(set) var searchQuery = ""
    private(set) var searchUsesRegularExpression = false
    private(set) var searchIsCaseSensitive = false
    private(set) var searchMatchesWholeWords = false
    private(set) var isBulkEditing = false
    private(set) var isMutationSuspended = false

    private var lineIndex: SparseUTF8LineIndex
    private var lineIndexCancellation = CancellationToken()
    private var lineIndexWarmupWork: DispatchWorkItem?
    private var lineLookupCancellation: CancellationToken?
    private var lineIndexResidentStateWasPurged = false
    private var bulkCancellation: CancellationToken?
    private var estimatedBytesPerLine: Double = 80
    private var lastSelection: Range<Int64> = 0..<0
    private var recoveryCoordinator: DocumentRecoveryCoordinator?
    private var recoveredDocumentHandle: RecoveredDocument?
    private var recoveryUndoTransactions: [RecoveryTransaction] = []
    private var recoveryRedoTransactions: [RecoveryTransaction] = []
    private var recoveryPausedUntilSave = false
    private(set) var restoredRecoveryMetadata: RecoveryMetadata?
    private lazy var searchController = DocumentSearchController { [unowned self] in self.engine }

    init(
        opening url: URL,
        isScratch: Bool = false,
        openOptions: DocumentOpenOptions = DocumentOpenOptions()
    ) throws {
        let sourceEngine = try FileBackedPieceTable(opening: url)
        let sourceSnapshot = try sourceEngine.snapshot()
        let sourceSampleEnd = min(sourceSnapshot.byteCount, 64 << 10)
        let sourceSample = try sourceSnapshot.data(in: 0..<sourceSampleEnd)
        let sourceDetection = SampledDocumentDetector.detect(
            sample: sourceSample,
            fileName: url.lastPathComponent
        )
        var sourceEncodingWasUnresolved: Bool
        let selectedEncoding: DocumentTextEncoding
        switch openOptions.encoding {
        case .automatic:
            sourceEncodingWasUnresolved = sourceDetection.textEncoding.encoding == nil
            selectedEncoding = sourceDetection.textEncoding.encoding ?? .utf8
        case .explicit(let encoding):
            sourceEncodingWasUnresolved = false
            selectedEncoding = encoding
        }
        if case .automatic = openOptions.encoding,
           selectedEncoding == .utf8,
           !sourceEncodingWasUnresolved,
           sourceSnapshot.byteCount <= sourceSampleEnd {
            do {
                try StreamingUnicodeTranscoder.validateUTF8(snapshot: sourceSnapshot)
            } catch {
                sourceEncodingWasUnresolved = true
            }
        }

        let openedEngine: FileBackedPieceTable
        let scratch: UnicodeScratchFile?
        let snapshot: DocumentSnapshot
        let canUseSourceBytesDirectly: Bool
        if case .automatic = openOptions.encoding {
            canUseSourceBytesDirectly = selectedEncoding == .utf8
        } else {
            // An explicit encoding is a strict conversion request. Even
            // explicit UTF-8 validates the complete file in private scratch
            // storage instead of blessing malformed bytes.
            canUseSourceBytesDirectly = false
        }
        if canUseSourceBytesDirectly {
            openedEngine = sourceEngine
            scratch = nil
            snapshot = sourceSnapshot
        } else {
            sourceEngine.close()
            let converted = try StreamingUnicodeTranscoder.transcodeFileToUTF8(
                at: url,
                sourceEncoding: selectedEncoding
            )
            do {
                openedEngine = try FileBackedPieceTable(opening: converted.fileURL)
                snapshot = try openedEngine.snapshot()
            } catch {
                converted.discard()
                throw error
            }
            scratch = converted
        }
        let sampleEnd = min(snapshot.byteCount, 64 << 10)
        let sample = try snapshot.data(in: 0..<sampleEnd)
        let detection: SampledDocumentDetection
        if selectedEncoding != .utf8 {
            detection = SampledDocumentDetector.detect(
                sample: sample,
                fileName: url.lastPathComponent
            )
        } else if case .explicit = openOptions.encoding {
            detection = SampledDocumentDetector.detect(
                sample: sample,
                fileName: url.lastPathComponent,
                assuming: .utf8
            )
        } else {
            detection = sourceDetection
        }

        self.engine = openedEngine
        self.originalSourceURL = url
        self.sourceURL = scratch == nil ? url : nil
        self.isScratchDocument = isScratch || scratch != nil
        self.scratchBackingURL = isScratch && scratch == nil ? url : nil
        self.transcodedScratchFile = scratch
        self.requiresDestinationSave = scratch != nil
        self.hasUnresolvedSourceEncoding = false
        self.isSourceEncodingValidationPending = false
        self.sampledDetection = detection
        self.sourceTextEncoding = selectedEncoding
        self.textEncoding = .utf8
        self.reopenOptions = openOptions
        switch openOptions.format {
        case .automatic:
            let parquetByMagic = selectedEncoding == .utf8
                && SyntaxFileTypeDetector.sniff(sample) == .parquet
            // A supported filename extension is the user's strongest ordinary
            // open signal. Sampling still supplies encoding and CSV dialect,
            // while extensionless/unknown files retain content inference.
            self.syntaxFileType = detection.resolvedSyntaxFileType(
                forPathExtension: url.pathExtension,
                parquetMagicDetected: parquetByMagic
            )
        default:
            self.syntaxFileType = openOptions.format.syntaxFileType ?? .plainText
        }
        self.hasUnresolvedSourceEncoding = syntaxFileType != .parquet
            && sourceEncodingWasUnresolved
        self.isSourceEncodingValidationPending = syntaxFileType != .parquet
            && !sourceEncodingWasUnresolved
            && openOptions.encoding == .automatic
            && sourceSampleEnd < sourceSnapshot.byteCount
        if case .delimitedText(let explicitDelimiter) = openOptions.format {
            self.delimitedTextDelimiter = explicitDelimiter
        } else {
            self.delimitedTextDelimiter = detection.resolvedDelimitedTextDelimiter(
                forPathExtension: url.pathExtension
            )
        }
        self.lineIndex = try SparseUTF8LineIndex(
            byteCount: snapshot.byteCount,
            sourceRevision: snapshot.revision,
            reader: { range in try snapshot.data(in: range) }
        )
        if syntaxFileType != .parquet {
            startBackgroundLineScan(maximumWarmupChunks: 8)
        }
        if isSourceEncodingValidationPending {
            startSourceEncodingValidation(
                snapshots: [snapshot]
            )
        } else {
            configureRecoveryCoordinator(isUntitled: requiresDestinationSave)
        }
    }

    /// Untitled session that requires no scratch inode. It remains fully
    /// editable and can be persisted through an explicit Save As.
    init(memoryOnlyEmptyDocument: Void = ()) {
        let emptyEngine = FileBackedPieceTable(empty: .init())
        self.engine = emptyEngine
        self.sourceURL = nil
        self.originalSourceURL = nil
        self.isScratchDocument = true
        self.scratchBackingURL = nil
        self.transcodedScratchFile = nil
        self.hasUnresolvedSourceEncoding = false
        self.isSourceEncodingValidationPending = false
        self.syntaxFileType = .plainText
        self.sampledDetection = nil
        self.sourceTextEncoding = .utf8
        self.textEncoding = .utf8
        self.delimitedTextDelimiter = .comma
        self.reopenOptions = .defaultUntitled
        self.infersUntitledSaveFormat = true
        self.lineIndex = SparseUTF8LineIndex(emptySourceRevision: 0)
        configureRecoveryCoordinator(isUntitled: true)
    }

    init(recovering recovered: RecoveredDocument) throws {
        let engine = recovered.engine
        let snapshot = try engine.snapshot()
        let sample = try snapshot.data(in: 0..<min(snapshot.byteCount, 64 << 10))
        let metadata = recovered.entry.metadata
        let isUntitled = metadata.task?.values["untitled"] == "true"
        let recoveredType = metadata.task?.fileType.flatMap(SyntaxFileType.init(rawValue:))

        // Recovery replay can change the leading bytes. Classify the immutable
        // base separately so a journal edit cannot hide an originally unknown
        // encoding and thereby authorize an in-place save.
        let baseSnapshot: DocumentSnapshot?
        let baseSample: Data?
        if isUntitled {
            baseSnapshot = nil
            baseSample = nil
        } else {
            let baseEngine = try FileBackedPieceTable(opening: recovered.entry.baseURL)
            let pristine = try baseEngine.snapshot()
            baseSnapshot = pristine
            baseSample = try pristine.data(in: 0..<min(pristine.byteCount, 64 << 10))
            baseEngine.close()
        }

        let recoveredSyntax = recoveredType
            ?? SyntaxFileTypeDetector.detect(url: recovered.entry.baseURL, sample: sample)
        let detection = SampledDocumentDetector.detect(
            sample: sample,
            fileName: metadata.task?.displayName ?? recovered.entry.baseURL.lastPathComponent
        )
        let baseDetection = baseSample.map {
            SampledDocumentDetector.detect(
                sample: $0,
                fileName: recovered.entry.baseURL.lastPathComponent
            )
        }
        let recoveredSmallSnapshotIsInvalid = snapshot.byteCount <= Int64(sample.count)
            && (try? StreamingUnicodeTranscoder.validateUTF8(snapshot: snapshot)) == nil
        let baseSmallSnapshotIsInvalid = baseSnapshot.map { pristine in
            pristine.byteCount <= Int64(baseSample?.count ?? 0)
                && (try? StreamingUnicodeTranscoder.validateUTF8(snapshot: pristine)) == nil
        } ?? false
        let recoveredDelimiter: DelimitedTextDelimiter
        if let raw = metadata.task?.values["delimiter"],
           let byte = UInt8(raw),
           let delimiter = DelimitedTextDelimiter(rawValue: byte) {
            recoveredDelimiter = delimiter
        } else {
            recoveredDelimiter = detection.tableDialect?.delimiter ?? .comma
        }

        self.engine = engine
        self.syntaxFileType = recoveredSyntax
        self.sampledDetection = detection
        self.sourceTextEncoding = .utf8
        self.textEncoding = .utf8
        self.delimitedTextDelimiter = recoveredDelimiter
        self.reopenOptions = DocumentOpenOptions(
            format: Self.openAsFormat(
                for: recoveredSyntax,
                delimiter: recoveredDelimiter
            ),
            encoding: .explicit(.utf8)
        )
        self.sourceURL = isUntitled ? nil : recovered.entry.baseURL
        self.originalSourceURL = isUntitled ? nil : recovered.entry.baseURL
        self.isScratchDocument = isUntitled
        self.scratchBackingURL = nil
        self.transcodedScratchFile = nil
        let baseEncodingIsUnresolved = baseDetection.map {
            $0.textEncoding.encoding == nil
        } ?? false
        self.hasUnresolvedSourceEncoding = recoveredSyntax != .parquet
            && (detection.textEncoding.encoding == nil
                || baseEncodingIsUnresolved
                || recoveredSmallSnapshotIsInvalid
                || baseSmallSnapshotIsInvalid)
        let baseNeedsValidation = baseSnapshot.map {
            $0.byteCount > Int64(baseSample?.count ?? 0)
        } ?? false
        self.isSourceEncodingValidationPending = recoveredSyntax != .parquet
            && !hasUnresolvedSourceEncoding
            && (snapshot.byteCount > Int64(sample.count) || baseNeedsValidation)
        self.requiresDestinationSave = isUntitled
        self.infersUntitledSaveFormat = isUntitled
        self.lineIndex = try SparseUTF8LineIndex(
            byteCount: snapshot.byteCount,
            sourceRevision: snapshot.revision,
            reader: { range in try snapshot.data(in: range) }
        )
        self.recoveredDocumentHandle = recovered
        self.restoredRecoveryMetadata = metadata
        self.recoveryCoordinator = try? DocumentRecoveryCoordinator(resuming: recovered)
        self.recoveryCoordinator?.onFailure = { [weak self] error in
            self?.handleRecoveryFailure(error)
        }
        if syntaxFileType != .parquet {
            startBackgroundLineScan(maximumWarmupChunks: 8)
        }
        if isSourceEncodingValidationPending {
            startSourceEncodingValidation(
                snapshots: [baseSnapshot, snapshot].compactMap { $0 }
            )
        }
    }

    deinit {
        lineIndexWarmupWork?.cancel()
        lineIndexCancellation.cancel()
        sourceEncodingValidationCancellation?.cancel()
        engine.close()
        if let scratchBackingURL {
            try? FileManager.default.removeItem(at: scratchBackingURL)
        }
    }

    var editorDocumentByteCount: Int64 { engine.byteCount }
    var editorSyntaxFileType: SyntaxFileType { syntaxFileType }
    var editorCSVDelimiter: UInt8 { delimitedTextDelimiter.rawValue }
    var byteCount: Int64 { engine.byteCount }
    var isEdited: Bool { engine.hasUnsavedChanges || requiresDestinationSave || isBulkEditing }
    var canUndo: Bool { !isReadOnly && !isMutationSuspended && !isBulkEditing && engine.canUndo }
    var canRedo: Bool { !isReadOnly && !isMutationSuspended && !isBulkEditing && engine.canRedo }
    var totalLineCount: Int64? { lineIndex.totalLineCount }

    /// Drops only line-navigation checkpoints. The piece table, unsaved edit
    /// segments, undo history, selection, and recovery journal remain owned by
    /// the session, so this is safe for dirty inactive documents.
    @discardableResult
    func purgeRebuildableResidentMemory() -> Int {
        guard !lineIndexResidentStateWasPurged else { return 0 }
        lineIndexWarmupWork?.cancel()
        lineIndexWarmupWork = nil
        lineIndexCancellation.cancel()
        lineIndexCancellation = CancellationToken()
        lineLookupCancellation?.cancel()
        lineLookupCancellation = nil
        lineIndexResidentStateWasPurged = true
        return lineIndex.purgeRebuildableResidentMemory()
    }

    /// Warms one bounded chunk after an inactive document becomes key again.
    /// Exact line requests remain available even before this opportunistic
    /// warmup finishes because the sparse index rebuilds lazily.
    func reactivateAfterResidentPurge() {
        guard lineIndexResidentStateWasPurged else { return }
        lineIndexResidentStateWasPurged = false
        guard syntaxFileType != .parquet, lineIndex.progress.totalByteCount > 0 else { return }
        startBackgroundLineScan(maximumWarmupChunks: 1)
    }
    var isReadOnly: Bool {
        syntaxFileType == .parquet
            || hasUnresolvedSourceEncoding
            || isSourceEncodingValidationPending
    }
    var readOnlyError: LighTxtSessionError {
        if isSourceEncodingValidationPending { return .textEncodingValidationInProgress }
        return hasUnresolvedSourceEncoding ? .unresolvedTextEncoding : .readOnlyDocument
    }
    var readOnlyNotice: String? {
        if isSourceEncodingValidationPending {
            return "Checking the complete file’s UTF-8 encoding before enabling edits…"
        }
        guard hasUnresolvedSourceEncoding else { return nil }
        return "Encoding couldn’t be identified. Opened read-only; original bytes are unchanged. Use File > Open As… to choose an encoding."
    }
    var readOnlyNoticeIsError: Bool { hasUnresolvedSourceEncoding }
    var isSourceTextValidated: Bool {
        !hasUnresolvedSourceEncoding && !isSourceEncodingValidationPending
    }
    var needsSaveAsDestination: Bool { requiresDestinationSave }
    var preferredSavePathExtension: String {
        syntaxFileType == .csv
            ? delimitedTextDelimiter.preferredPathExtension
            : syntaxFileType.preferredPathExtension
    }

    /// Re-samples only the bounded prefix before the first Save As. This keeps
    /// typing free of background classifiers while still choosing an accurate
    /// extension for an untitled document.
    func prepareUntitledSaveSuggestion() -> String {
        guard sourceURL == nil || isScratchDocument else {
            return preferredSavePathExtension
        }
        guard infersUntitledSaveFormat else { return preferredSavePathExtension }
        do {
            let snapshot = try engine.snapshot()
            let sample = try snapshot.data(in: 0..<min(snapshot.byteCount, 64 << 10))
            let detection = SampledDocumentDetector.detect(sample: sample)
            sampledDetection = detection
            syntaxFileType = detection.syntaxFileType
            if let delimiter = detection.tableDialect?.delimiter {
                delimitedTextDelimiter = delimiter
            }
            reopenOptions.format = Self.openAsFormat(
                for: syntaxFileType,
                delimiter: delimitedTextDelimiter
            )
            callbacks.documentChanged?(engine.byteCount, isEdited)
            return preferredSavePathExtension
        } catch {
            return DocumentOpenAsFormat.defaultUntitledPathExtension
        }
    }

    func setDelimitedTextDelimiter(_ delimiter: DelimitedTextDelimiter) {
        guard delimitedTextDelimiter != delimiter else { return }
        delimitedTextDelimiter = delimiter
        if syntaxFileType == .csv {
            reopenOptions.format = .delimitedText(delimiter)
        }
    }

    func editorSnapshot() throws -> DocumentSnapshot {
        try engine.snapshot()
    }

    func editorReadBytes(in range: Range<Int64>) throws -> Data {
        try engine.snapshot().data(in: range)
    }

    func editorReplaceBytes(in range: Range<Int64>, with bytes: Data) throws {
        guard !isReadOnly else { throw readOnlyError }
        guard !isMutationSuspended else {
            throw LighTxtSessionError.documentNavigationInProgress
        }
        guard !isBulkEditing else { throw LighTxtSessionError.bulkOperationInProgress }
        let snapshot = try engine.snapshot()
        try engine.replace(byteRange: range, with: bytes)
        recordRecoveryTransaction(
            Self.makeRecoveryTransaction(
                edits: [ByteEdit(byteRange: range, replacement: bytes)],
                snapshot: snapshot
            )
        )
    }

    func editorApplyCSVRowEdits(
        _ edits: [ByteEdit],
        replacing snapshot: DocumentSnapshot,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let meaningfulEdits = edits.filter {
            !$0.byteRange.isEmpty || !$0.replacement.isEmpty
        }
        guard !meaningfulEdits.isEmpty else {
            completion(.success(()))
            return
        }
        let recoveryTransaction = Self.makeRecoveryTransaction(
            edits: meaningfulEdits,
            snapshot: snapshot
        )
        let token: CancellationToken
        do {
            token = try beginCSVMutation(status: "Updating CSV rows…")
        } catch {
            completion(.failure(error))
            return
        }
        let engine = self.engine

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<Void, Error>
            do {
                if token.isCancelled { throw CancellationError() }
                try engine.replaceAtomically(
                    edits: meaningfulEdits,
                    replacing: snapshot,
                    cancellation: { token.isCancelled }
                )
                result = .success(())
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.bulkCancellation === token else { return }
                self.bulkCancellation = nil
                self.isBulkEditing = false
                switch result {
                case .success:
                    self.recordRecoveryTransaction(recoveryTransaction)
                    self.finishSuccessfulCSVMutation(
                        status: meaningfulEdits.count == 1
                            ? "Updated 1 CSV row"
                            : "Updated \(meaningfulEdits.count.formatted()) CSV rows"
                    )
                    completion(.success(()))
                case .failure(let error as CancellationError):
                    _ = error
                    self.finishCancelledCSVMutation(status: "CSV row update cancelled")
                    completion(.failure(CancellationError()))
                case .failure(let error):
                    self.finishFailedCSVMutation(error)
                    completion(.failure(error))
                }
            }
        }
    }

    func editorApplyCSVColumnMutation(
        _ mutation: CSVColumnMutation,
        snapshot: DocumentSnapshot,
        index: CSVRowIndex,
        progress: @escaping (CSVColumnRewriteProgress) -> Void,
        completion: @escaping (Result<CSVColumnRewriteResult, Error>) -> Void
    ) {
        let token: CancellationToken
        do {
            token = try beginCSVMutation(status: "Updating CSV column…")
        } catch {
            completion(.failure(error))
            return
        }
        let engine = self.engine

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var lastProgressUpdate = CFAbsoluteTimeGetCurrent() - 1
            let reportProgress: (CSVColumnRewriteProgress) -> Void = { update in
                let now = CFAbsoluteTimeGetCurrent()
                guard now - lastProgressUpdate >= 0.10
                        || update.fractionCompleted >= 1 else { return }
                lastProgressUpdate = now
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.bulkCancellation === token,
                          !token.isCancelled else { return }
                    progress(update)
                }
            }
            let result = Result {
                try engine.applyCSVColumnMutation(
                    mutation,
                    snapshot: snapshot,
                    index: index,
                    delimiter: index.delimiter,
                    cancellation: { token.isCancelled },
                    progress: reportProgress
                )
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.bulkCancellation === token else { return }
                self.bulkCancellation = nil
                self.isBulkEditing = false
                switch result {
                case let .success(summary):
                    if summary.didChange {
                        self.pauseRecoveryUntilSave()
                        self.finishSuccessfulCSVMutation(
                            status: "Updated \(summary.changedRecordCount.formatted()) CSV rows"
                        )
                    } else {
                        self.callbacks.documentChanged?(self.engine.byteCount, self.isEdited)
                        self.callbacks.statusChanged?("No CSV values changed", false, false)
                    }
                    completion(.success(summary))
                case .failure(let error):
                    if error is CancellationError
                        || (error as? CSVRowIndex.IndexError) == .cancelled {
                        self.finishCancelledCSVMutation(status: "CSV column update cancelled")
                        completion(.failure(CancellationError()))
                    } else {
                        self.finishFailedCSVMutation(error)
                        completion(.failure(error))
                    }
                }
            }
        }
    }

    func editorCancelCSVMutation() {
        cancelBulkOperation()
    }

    /// Freezes every user mutation while AppKit reviews whether the current
    /// document may be replaced. A slow asynchronous save snapshots one root;
    /// allowing a newer edit before `canClose` completes would let AppKit
    /// approve navigation and discard that newer root.
    @discardableResult
    func beginDocumentNavigationReview() -> Bool {
        guard !isMutationSuspended, !isBulkEditing else { return false }
        isMutationSuspended = true
        return true
    }

    func endDocumentNavigationReview() {
        isMutationSuspended = false
    }

    func editorDidCommitEdit(replaced range: Range<Int64>, insertedByteCount: Int64) {
        invalidateSearchResults()
        lineLookupCancellation?.cancel()
        rebuildLineIndexAfterEdit()
        callbacks.documentChanged?(engine.byteCount, isEdited)
        callbacks.statusChanged?("Edited", false, false)
    }

    func editorLineLocation(at byteOffset: Int64) -> EditorLineLocation {
        let clamped = min(max(0, byteOffset), engine.byteCount)
        let progress = lineIndex.progress
        if lineLookupCancellation == nil,
           clamped <= progress.indexedByteCount,
           let exact = try? lineIndex.lineAndColumn(forByteOffset: clamped) {
            return EditorLineLocation(
                lineNumber: exact.line + 1,
                lineStartByteOffset: clamped - exact.column
            )
        }

        // A random jump must never wait for a scan from byte zero. Find the
        // local line start with one small backward read and estimate only the
        // line label until the sparse index catches up.
        let lookback: Int64 = 64 << 10
        let lower = max(0, clamped - lookback)
        var lineStart = lower
        if let data = try? engine.snapshot().data(in: lower..<clamped), !data.isEmpty {
            if let newline = data.lastIndex(of: 0x0A) {
                lineStart = lower + Int64(newline + 1)
            } else if let carriageReturn = data.lastIndex(of: 0x0D) {
                lineStart = lower + Int64(carriageReturn + 1)
            }
        }
        let estimate = Int64(Double(clamped) / max(1, estimatedBytesPerLine)) + 1
        return EditorLineLocation(lineNumber: max(1, estimate), lineStartByteOffset: lineStart)
    }

    func editorSelectionDidChange(byteRange: Range<Int64>, line: Int64, column: Int) {
        lastSelection = byteRange
        callbacks.selectionChanged?(byteRange, line, column)
    }

    func editorDidLoadViewport(byteRange: Range<Int64>) {
        callbacks.editorViewportChanged?(byteRange, engine.byteCount)
    }

    func editorDidExpose(byteRange: Range<Int64>) {
        // Deliberately no caching here: the viewport already owns the sole
        // decoded copy and file-backed read buffers remain bounded.
    }

    func editorDidDiscoverStructure(
        folds: [SyntaxFoldRange],
        viewportData: Data,
        viewportBaseOffset: Int64
    ) {
        callbacks.structureChanged?(folds, viewportData, viewportBaseOffset, syntaxFileType)
    }

    func editorDidFail(_ error: Error) {
        callbacks.error?(error)
    }

    func configureSearch(
        query: String,
        regularExpression: Bool,
        caseSensitive: Bool,
        wholeWords: Bool
    ) {
        let normalizedWholeWords = regularExpression ? false : wholeWords
        if query != searchQuery
            || regularExpression != searchUsesRegularExpression
            || caseSensitive != searchIsCaseSensitive
            || normalizedWholeWords != searchMatchesWholeWords {
            searchController.cancel()
            currentMatch = nil
            callbacks.matchChanged?(nil)
            callbacks.searchResultsInvalidated?()
        }
        searchQuery = query
        searchUsesRegularExpression = regularExpression
        searchIsCaseSensitive = caseSensitive
        searchMatchesWholeWords = normalizedWholeWords

        guard !query.isEmpty else {
            callbacks.statusChanged?("Ready", false, false)
            return
        }
        if regularExpression {
            do {
                _ = try NSRegularExpression(pattern: query)
                callbacks.statusChanged?("Regex ready", false, false)
            } catch {
                callbacks.statusChanged?("Invalid regular expression", false, true)
            }
        }
    }

    func findNext(backwards: Bool, from selection: Range<Int64>? = nil) {
        guard !searchQuery.isEmpty else { return }
        let selection = selection ?? lastSelection
        var origin = backwards ? selection.lowerBound : selection.upperBound
        if searchUsesRegularExpression,
           let currentMatch,
           currentMatch.byteRange.isEmpty,
           selection.lowerBound == currentMatch.byteRange.lowerBound {
            // A zero-width regex must make progress between Find Next calls.
            // The streaming regex layer repairs UTF-8 context at its bounded
            // window edge, so a one-byte coordinate advance is sufficient.
            origin = backwards
                ? max(0, origin - 1)
                : min(engine.byteCount, origin + 1)
        }
        callbacks.statusChanged?("Searching…", true, false)
        searchController.findOne(
            query: searchQuery,
            regularExpression: searchUsesRegularExpression,
            from: origin,
            backwards: backwards,
            options: currentSearchOptions
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(match):
                self.currentMatch = match
                self.callbacks.matchChanged?(match)
                if let match {
                    self.callbacks.statusChanged?(
                        "Match at byte \(match.byteRange.lowerBound.formatted())",
                        false,
                        false
                    )
                } else {
                    self.callbacks.statusChanged?("No matches", false, false)
                }
            case let .failure(error):
                self.currentMatch = nil
                self.callbacks.matchChanged?(nil)
                self.callbacks.statusChanged?(error.localizedDescription, false, true)
            }
        }
    }

    func findAll() {
        guard !searchQuery.isEmpty else { return }
        callbacks.statusChanged?("Searching entire file…", true, false)
        searchController.findAll(
            query: searchQuery,
            regularExpression: searchUsesRegularExpression,
            options: currentSearchOptions,
            progress: { [weak self] update in
                self?.callbacks.statusChanged?(
                    "Searching \(Int(update.fractionCompleted * 100))%  ·  \(update.matchesFound.formatted()) \(update.matchesFound == 1 ? "match" : "matches")",
                    true,
                    false
                )
            },
            completion: { [weak self] result in
                guard let self else { return }
                switch result {
                case let .success(summary):
                    self.callbacks.findAllCompleted?(summary)
                    let suffix = summary.retainedLimitReached ? " (first results retained)" : ""
                    self.callbacks.statusChanged?(
                        "\(summary.totalMatches.formatted()) \(summary.totalMatches == 1 ? "match" : "matches") in \(summary.elapsed.formatted(.number.precision(.fractionLength(2)))) s\(suffix)",
                        false,
                        false
                    )
                case .failure(let error as CancellationError):
                    _ = error
                    self.callbacks.statusChanged?("Search cancelled", false, false)
                case .failure(let error):
                    self.callbacks.statusChanged?(error.localizedDescription, false, true)
                }
            }
        )
    }

    func replaceCurrent(with template: String) throws -> SearchMatch? {
        guard !isReadOnly else { throw readOnlyError }
        guard !isMutationSuspended else {
            throw LighTxtSessionError.documentNavigationInProgress
        }
        guard !isBulkEditing else {
            throw LighTxtSessionError.bulkOperationInProgress
        }
        guard let match = currentMatch else { return nil }
        searchController.cancel()
        callbacks.searchResultsInvalidated?()
        let snapshot = try engine.snapshot()
        let replacement: Data
        if searchUsesRegularExpression {
            replacement = try match.expandingUTF8ReplacementTemplate(template, in: snapshot)
        } else {
            replacement = Data(template.utf8)
        }
        try engine.replace(byteRange: match.byteRange, with: replacement)
        recordRecoveryTransaction(
            Self.makeRecoveryTransaction(
                edits: [ByteEdit(byteRange: match.byteRange, replacement: replacement)],
                snapshot: snapshot
            )
        )
        let replacementRange = match.byteRange.lowerBound..<(match.byteRange.lowerBound + Int64(replacement.count))
        currentMatch = SearchMatch(byteRange: replacementRange)
        rebuildLineIndexAfterEdit()
        callbacks.documentChanged?(engine.byteCount, isEdited)
        callbacks.matchChanged?(currentMatch)
        return currentMatch
    }

    func replaceAll(
        with replacement: String,
        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        guard !isReadOnly else {
            completion(.failure(readOnlyError))
            return
        }
        guard !isMutationSuspended else {
            completion(.failure(LighTxtSessionError.documentNavigationInProgress))
            return
        }
        guard !isBulkEditing else {
            completion(.failure(LighTxtSessionError.bulkOperationInProgress))
            return
        }
        guard !searchQuery.isEmpty else {
            completion(.failure(LighTxtCoreError.emptySearchPattern))
            return
        }
        searchController.cancel()
        currentMatch = nil
        callbacks.matchChanged?(nil)
        callbacks.searchResultsInvalidated?()
        bulkCancellation?.cancel()
        let token = CancellationToken()
        bulkCancellation = token
        isBulkEditing = true
        let engine = self.engine
        let pattern: SearchPattern = searchUsesRegularExpression
            ? .regularExpression(searchQuery)
            : .literal(searchQuery)
        let regex = searchUsesRegularExpression
        let searchOptions = currentSearchOptions
        callbacks.statusChanged?("Replacing…", true, false)
        callbacks.documentChanged?(engine.byteCount, true)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<BulkReplaceResult, Error>
            var lastProgressUpdate = CFAbsoluteTimeGetCurrent() - 1
            let reportProgress: (BulkReplaceProgress) -> Void = { update in
                let now = CFAbsoluteTimeGetCurrent()
                guard now - lastProgressUpdate >= 0.10 || update.fractionCompleted >= 1 else { return }
                lastProgressUpdate = now
                DispatchQueue.main.async { [weak self] in
                    guard self?.bulkCancellation === token else { return }
                    self?.callbacks.statusChanged?(
                        "Replacing \(Int(update.fractionCompleted * 100))%  ·  \(update.replacementCount.formatted())",
                        true,
                        false
                    )
                }
            }
            do {
                let replacementResult: BulkReplaceResult
                if regex {
                    replacementResult = try engine.replaceAll(
                        matching: pattern,
                        withUTF8Template: replacement,
                        options: searchOptions,
                        cancellation: token,
                        progress: reportProgress
                    )
                } else {
                    replacementResult = try engine.replaceAll(
                        matching: pattern,
                        with: Data(replacement.utf8),
                        options: searchOptions,
                        cancellation: token,
                        progress: reportProgress
                    )
                }
                result = .success(replacementResult)
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.bulkCancellation === token else { return }
                self.bulkCancellation = nil
                self.isBulkEditing = false
                switch result {
                case let .success(summary):
                    if summary.replacementCount > 0 {
                        self.pauseRecoveryUntilSave()
                    }
                    self.currentMatch = nil
                    self.rebuildLineIndexAfterEdit()
                    self.callbacks.documentChanged?(self.engine.byteCount, self.isEdited)
                    self.callbacks.matchChanged?(nil)
                    self.callbacks.statusChanged?(
                        "Replaced \(summary.replacementCount.formatted()) \(summary.replacementCount == 1 ? "match" : "matches")",
                        false,
                        false
                    )
                    completion(.success(summary.replacementCount))
                case .failure(let error as CancellationError):
                    _ = error
                    self.callbacks.documentChanged?(self.engine.byteCount, self.isEdited)
                    self.callbacks.statusChanged?("Replace All cancelled", false, false)
                    completion(.failure(CancellationError()))
                case .failure(let error):
                    self.callbacks.documentChanged?(self.engine.byteCount, self.isEdited)
                    self.callbacks.statusChanged?(error.localizedDescription, false, true)
                    completion(.failure(error))
                }
            }
        }
    }

    func cancelBulkOperation() {
        bulkCancellation?.cancel()
    }

    private var currentSearchOptions: SearchOptions {
        SearchOptions(
            caseSensitive: searchIsCaseSensitive,
            matchesWholeWords: searchMatchesWholeWords
        )
    }

    @discardableResult
    func undo() -> Bool {
        guard !isReadOnly, !isMutationSuspended, !isBulkEditing else { return false }
        guard engine.undo() else { return false }
        if let transaction = recoveryUndoTransactions.popLast() {
            if let inverse = transaction.inverse, !recoveryPausedUntilSave {
                recoveryCoordinator?.record(inverse)
                recoveryRedoTransactions.append(transaction)
            } else {
                pauseRecoveryUntilSave()
            }
        } else if !recoveryPausedUntilSave {
            pauseRecoveryUntilSave()
        }
        invalidateSearchResults()
        lineLookupCancellation?.cancel()
        rebuildLineIndexAfterEdit()
        callbacks.documentChanged?(engine.byteCount, isEdited)
        callbacks.statusChanged?("Undid edit", false, false)
        return true
    }

    @discardableResult
    func redo() -> Bool {
        guard !isReadOnly, !isMutationSuspended, !isBulkEditing else { return false }
        guard engine.redo() else { return false }
        if let transaction = recoveryRedoTransactions.popLast(), !recoveryPausedUntilSave {
            recoveryCoordinator?.record(transaction.forward)
            recoveryUndoTransactions.append(transaction)
        } else if !recoveryPausedUntilSave {
            pauseRecoveryUntilSave()
        }
        invalidateSearchResults()
        lineLookupCancellation?.cancel()
        rebuildLineIndexAfterEdit()
        callbacks.documentChanged?(engine.byteCount, isEdited)
        callbacks.statusChanged?("Redid edit", false, false)
        return true
    }

    func byteOffset(forOneBasedLine line: Int64, completion: @escaping (Result<Int64?, Error>) -> Void) {
        let requested = max(0, line - 1)
        let index = lineIndex
        lineLookupCancellation?.cancel()
        let token = CancellationToken()
        lineLookupCancellation = token
        callbacks.statusChanged?("Locating line \(line.formatted())…", true, false)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try index.byteOffset(forLine: requested, cancellation: { token.isCancelled })
            }
            DispatchQueue.main.async {
                guard let self, self.lineLookupCancellation === token else { return }
                self.lineLookupCancellation = nil
                self.callbacks.statusChanged?("Ready", false, false)
                guard !token.isCancelled else { return }
                completion(result)
            }
        }
    }

    func adoptSavedURL(_ url: URL) {
        // A successful Save As can rebase the engine onto a replacement inode.
        // Refresh the reader closure immediately so the sparse index does not
        // keep the old mapping (and its potentially enormous unlinked inode)
        // alive until the next edit.
        rebuildLineIndexAfterEdit()
        if let scratchBackingURL {
            try? FileManager.default.removeItem(at: scratchBackingURL)
            self.scratchBackingURL = nil
        }
        sourceURL = url
        originalSourceURL = url
        isScratchDocument = false
        requiresDestinationSave = false
        infersUntitledSaveFormat = false
        transcodedScratchFile = nil
        sourceTextEncoding = .utf8
        textEncoding = .utf8
        let detectedType = SyntaxFileTypeDetector.knownType(
            forPathExtension: url.pathExtension
        )
        // Save As writes the current byte stream; it never encodes a Parquet
        // container. A text document named with a .parquet suffix must not
        // become a binary, read-only table after the save completes.
        if let detectedType, detectedType != .parquet {
            syntaxFileType = detectedType
        }
        switch url.pathExtension.lowercased() {
        case "tsv": delimitedTextDelimiter = .tab
        case "psv": delimitedTextDelimiter = .pipe
        default: break
        }
        reopenOptions = DocumentOpenOptions(
            format: Self.openAsFormat(
                for: syntaxFileType,
                delimiter: delimitedTextDelimiter
            ),
            encoding: .explicit(.utf8)
        )
        callbacks.documentChanged?(engine.byteCount, isEdited)
        resetRecoveryAfterSave(baseURL: url)
    }

    /// Refreshes snapshot-backed readers after an ordinary save without
    /// adopting any URL supplied by the caller.
    func didSaveInPlace() {
        rebuildLineIndexAfterEdit()
        callbacks.documentChanged?(engine.byteCount, isEdited)
        resetRecoveryAfterSave(baseURL: engine.documentURL)
    }

    func markAsScratchBacking() {
        isScratchDocument = true
        scratchBackingURL = sourceURL
        requiresDestinationSave = true
        infersUntitledSaveFormat = false
        sourceTextEncoding = .utf8
        textEncoding = .utf8
        reopenOptions = DocumentOpenOptions(
            format: Self.openAsFormat(
                for: syntaxFileType,
                delimiter: delimitedTextDelimiter
            ),
            encoding: .explicit(.utf8)
        )
        recoveryCoordinator?.discardAfterSuccessfulSave()
        recoveryCoordinator = nil
        recoveryPausedUntilSave = false
        configureRecoveryCoordinator(isUntitled: true)
    }

    func prepareForClose() {
        // A normal NSDocument close follows Save/Discard review. Recovery is
        // only for abnormal termination, so an explicit close removes it.
        recoveryCoordinator?.discardAfterSuccessfulSave()
        searchController.cancel()
        bulkCancellation?.cancel()
        bulkCancellation = nil
        isBulkEditing = false
        lineIndexWarmupWork?.cancel()
        lineIndexCancellation.cancel()
        lineLookupCancellation?.cancel()
        sourceEncodingValidationCancellation?.cancel()
        sourceEncodingValidationCancellation = nil
        engine.close()
    }

    func updateRecoveryMetadata(_ metadata: RecoveryMetadata) {
        recoveryCoordinator?.updateMetadata(metadata)
    }

    /// Recovery UI state is a one-shot input for the first window created for
    /// the recovered session. Consuming it prevents a later replacement
    /// window from unexpectedly jumping back to the crash-time state.
    func takeRestoredRecoveryMetadata() -> RecoveryMetadata? {
        defer { restoredRecoveryMetadata = nil }
        return restoredRecoveryMetadata
    }

    private static func makeRecoveryTransaction(
        edits: [ByteEdit],
        snapshot: DocumentSnapshot
    ) -> RecoveryTransaction {
        let ordered = edits.enumerated().sorted { lhs, rhs in
            if lhs.element.byteRange.lowerBound != rhs.element.byteRange.lowerBound {
                return lhs.element.byteRange.lowerBound > rhs.element.byteRange.lowerBound
            }
            if lhs.element.byteRange.upperBound != rhs.element.byteRange.upperBound {
                return lhs.element.byteRange.upperBound > rhs.element.byteRange.upperBound
            }
            return lhs.offset > rhs.offset
        }.map(\.element)
        let forward = ordered.map {
            RecoveryPendingEdit(byteRange: $0.byteRange, replacement: $0.replacement)
        }

        let maximumInversePayload = 1 << 20
        var inverseInForwardOrder: [RecoveryPendingEdit] = []
        inverseInForwardOrder.reserveCapacity(ordered.count)
        for edit in ordered {
            guard edit.byteRange.count <= maximumInversePayload,
                  let previous = try? snapshot.data(in: edit.byteRange) else {
                return RecoveryTransaction(forward: forward, inverse: nil)
            }
            let insertedUpper = edit.byteRange.lowerBound + Int64(edit.replacement.count)
            inverseInForwardOrder.append(RecoveryPendingEdit(
                byteRange: edit.byteRange.lowerBound..<insertedUpper,
                replacement: previous
            ))
        }
        return RecoveryTransaction(
            forward: forward,
            inverse: Array(inverseInForwardOrder.reversed())
        )
    }

    private func recordRecoveryTransaction(_ transaction: RecoveryTransaction) {
        guard !recoveryPausedUntilSave else { return }
        guard transaction.forward.allSatisfy({ $0.replacement.count <= 16 << 20 }) else {
            pauseRecoveryUntilSave()
            return
        }
        recoveryCoordinator?.record(transaction.forward)
        recoveryUndoTransactions.append(transaction)
        if recoveryUndoTransactions.count > 512 {
            recoveryUndoTransactions.removeFirst(recoveryUndoTransactions.count - 512)
        }
        recoveryRedoTransactions.removeAll(keepingCapacity: true)
    }

    private func pauseRecoveryUntilSave() {
        guard !recoveryPausedUntilSave else { return }
        recoveryPausedUntilSave = true
        recoveryCoordinator?.discardAfterSuccessfulSave()
        recoveryCoordinator = nil
        recoveryUndoTransactions.removeAll(keepingCapacity: false)
        recoveryRedoTransactions.removeAll(keepingCapacity: false)
    }

    private func configureRecoveryCoordinator(isUntitled: Bool) {
        guard !isReadOnly, recoveryCoordinator == nil else { return }
        let coordinator = try? DocumentRecoveryCoordinator(
            baseURL: engine.documentURL,
            displayName: originalSourceURL?.lastPathComponent,
            fileType: syntaxFileType.rawValue,
            isUntitled: isUntitled,
            expectedBaseFingerprint: engine.recoveryBaseFingerprint
        )
        coordinator?.onFailure = { [weak self] error in
            self?.handleRecoveryFailure(error)
        }
        recoveryCoordinator = coordinator
    }

    private func startSourceEncodingValidation(
        snapshots: [DocumentSnapshot]
    ) {
        sourceEncodingValidationCancellation?.cancel()
        let token = CancellationToken()
        sourceEncodingValidationCancellation = token

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result: Result<Void, Error> = Result {
                for snapshot in snapshots {
                    try StreamingUnicodeTranscoder.validateUTF8(
                        snapshot: snapshot,
                        cancellation: token
                    )
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.sourceEncodingValidationCancellation === token else { return }
                self.sourceEncodingValidationCancellation = nil
                guard !token.isCancelled else { return }
                self.isSourceEncodingValidationPending = false

                switch result {
                case .success:
                    self.configureRecoveryCoordinator(
                        isUntitled: self.requiresDestinationSave
                    )
                    self.callbacks.accessStateChanged?()
                    self.callbacks.statusChanged?("UTF-8 encoding verified", false, false)
                case .failure(let error):
                    self.hasUnresolvedSourceEncoding = true
                    self.callbacks.accessStateChanged?()
                    self.callbacks.statusChanged?(
                        self.readOnlyNotice ?? error.localizedDescription,
                        false,
                        true
                    )
                }
            }
        }
    }

    private func handleRecoveryFailure(_ error: Error) {
        recoveryPausedUntilSave = true
        recoveryUndoTransactions.removeAll(keepingCapacity: false)
        recoveryRedoTransactions.removeAll(keepingCapacity: false)
        callbacks.statusChanged?(
            "Crash recovery paused: \(error.localizedDescription)",
            false,
            true
        )
    }

    private func resetRecoveryAfterSave(baseURL: URL?) {
        recoveryCoordinator?.discardAfterSuccessfulSave()
        recoveryCoordinator = nil
        recoveryUndoTransactions.removeAll(keepingCapacity: false)
        recoveryRedoTransactions.removeAll(keepingCapacity: false)
        if engine.hasUnsavedChanges {
            recoveryPausedUntilSave = true
            return
        }
        recoveryPausedUntilSave = false
        configureRecoveryCoordinator(isUntitled: baseURL == nil)
    }

    private static func openAsFormat(
        for syntaxFileType: SyntaxFileType,
        delimiter: DelimitedTextDelimiter
    ) -> DocumentOpenAsFormat {
        switch syntaxFileType {
        case .plainText: .plainText
        case .json: .json
        case .markdown: .markdown
        case .sql: .sql
        case .xml: .xml
        case .csv: .delimitedText(delimiter)
        case .yaml: .yaml
        // Parquet is selected through its extension/magic bytes, not the text
        // Open As model. Automatic preserves that binary detection on reload.
        case .parquet: .automatic
        }
    }

    private func beginCSVMutation(status: String) throws -> CancellationToken {
        guard !isReadOnly else { throw readOnlyError }
        guard syntaxFileType == .csv else {
            throw LighTxtSessionError.csvMutationUnavailable
        }
        guard !isMutationSuspended else {
            throw LighTxtSessionError.documentNavigationInProgress
        }
        guard !isBulkEditing else {
            throw LighTxtSessionError.bulkOperationInProgress
        }
        invalidateSearchResults()
        let token = CancellationToken()
        bulkCancellation = token
        isBulkEditing = true
        callbacks.statusChanged?(status, true, false)
        // The in-flight flag participates in `isEdited`, ensuring Close/Quit
        // invokes AppKit's save review while the old root is still visible.
        callbacks.documentChanged?(engine.byteCount, true)
        return token
    }

    private func finishSuccessfulCSVMutation(status: String) {
        lineLookupCancellation?.cancel()
        rebuildLineIndexAfterEdit()
        callbacks.documentChanged?(engine.byteCount, isEdited)
        callbacks.statusChanged?(status, false, false)
    }

    private func finishCancelledCSVMutation(status: String) {
        callbacks.documentChanged?(engine.byteCount, isEdited)
        callbacks.statusChanged?(status, false, false)
    }

    private func finishFailedCSVMutation(_ error: Error) {
        callbacks.documentChanged?(engine.byteCount, isEdited)
        callbacks.statusChanged?(error.localizedDescription, false, true)
    }

    private func invalidateSearchResults() {
        searchController.cancel()
        currentMatch = nil
        callbacks.matchChanged?(nil)
        callbacks.searchResultsInvalidated?()
    }

    private func rebuildLineIndexAfterEdit() {
        // Every root change invalidates an in-flight exact Go to Line scan.
        // Cancel it before taking the index's invalidation lock so a main-
        // thread edit never waits behind a multi-gigabyte lookup.
        lineLookupCancellation?.cancel()
        lineLookupCancellation = nil
        let prior = lineIndex.progress
        if prior.indexedByteCount > 0 {
            estimatedBytesPerLine = max(
                1,
                Double(prior.indexedByteCount) / Double(max(1, prior.knownLineCount))
            )
        }
        lineIndexCancellation.cancel()
        lineIndexCancellation = CancellationToken()
        lineIndexResidentStateWasPurged = false
        do {
            let snapshot = try engine.snapshot()
            _ = try lineIndex.invalidate(
                byteCount: snapshot.byteCount,
                sourceRevision: snapshot.revision,
                reader: { range in try snapshot.data(in: range) }
            )
            // Re-index a small prefix only after typing settles. Go to Line
            // extends the sparse index on demand; beginning a 1 MiB scan in
            // every key-event path would turn an otherwise logarithmic edit
            // into avoidable file I/O.
            lineIndexWarmupWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.startBackgroundLineScan(maximumWarmupChunks: 1)
            }
            lineIndexWarmupWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        } catch {
            callbacks.error?(error)
        }
    }

    private func startBackgroundLineScan(maximumWarmupChunks: Int) {
        lineIndexWarmupWork = nil
        let index = lineIndex
        let token = lineIndexCancellation
        let generation = index.generation
        DispatchQueue.global(qos: .utility).async { [weak self] in
            do {
                // Warm only a small prefix. Eagerly walking a 24 GiB document
                // merely to learn its total line count would turn opening into
                // an unsolicited full-disk scan. Exact Go to Line queries extend
                // this same sparse index on demand, still in bounded chunks.
                var lastResult: SparseUTF8LineIndex.ScanResult?
                for _ in 0..<maximumWarmupChunks {
                    let result = try index.scanNextChunk(
                        generation: generation,
                        cancellation: { token.isCancelled }
                    )
                    lastResult = result
                    let progress = result.progress
                    if progress.indexedByteCount > 0 {
                        let average = Double(progress.indexedByteCount) / Double(max(1, progress.knownLineCount))
                        DispatchQueue.main.async { [weak self] in
                            self?.estimatedBytesPerLine = max(1, average)
                        }
                    }
                    guard result.stopReason == .advanced else { break }
                }
                guard let result = lastResult, result.stopReason == .completed else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.lineIndex.generation == generation else { return }
                    let lines = result.progress.totalLineCount ?? result.progress.knownLineCount
                    self.callbacks.statusChanged?("Indexed \(lines.formatted()) lines", false, false)
                }
            } catch {
                guard !token.isCancelled else { return }
                DispatchQueue.main.async { [weak self] in self?.callbacks.error?(error) }
            }
        }
    }

}

enum LighTxtSessionError: Error, LocalizedError {
    case bulkOperationInProgress
    case saveInProgress
    case documentNavigationInProgress
    case csvMutationUnavailable
    case readOnlyDocument
    case textEncodingValidationInProgress
    case unresolvedTextEncoding
    case parquetExportUnsupported

    var errorDescription: String? {
        switch self {
        case .bulkOperationInProgress:
            "Finish or cancel the current document operation before editing."
        case .saveInProgress:
            "A save is already in progress."
        case .documentNavigationInProgress:
            "Finish switching documents before editing."
        case .csvMutationUnavailable:
            "CSV row and column operations are available only for CSV documents."
        case .readOnlyDocument:
            "Parquet documents are read-only."
        case .textEncodingValidationInProgress:
            "LighTxt is checking the complete file’s UTF-8 encoding before enabling changes."
        case .unresolvedTextEncoding:
            "This file’s text encoding couldn’t be identified. It is read-only so the original bytes cannot be damaged. Reopen it with File > Open As… and choose an encoding."
        case .parquetExportUnsupported:
            "LighTxt can view Parquet files, but it does not export text as Parquet."
        }
    }
}

extension SyntaxFileType {
    var displayName: String {
        switch self {
        case .plainText: "Plain Text"
        case .json: "JSON"
        case .markdown: "Markdown"
        case .sql: "SQL"
        case .xml: "XML"
        case .csv: "CSV"
        case .yaml: "YAML"
        case .parquet: "Parquet"
        }
    }

    var displayAbbreviation: String {
        switch self {
        case .plainText: "TXT"
        case .markdown: "MD"
        case .parquet: "PARQUET"
        default: rawValue.uppercased()
        }
    }
}
