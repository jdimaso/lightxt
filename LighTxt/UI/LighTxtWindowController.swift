import AppKit
import QuartzCore

private nonisolated struct JSONSidebarPreviewBatch: Sendable {
    let page: JSONStructureChildrenPage
    let previews: [JSONStructureNodePreview?]
}

private nonisolated enum JSONSidebarPathComponent: Sendable {
    case member(JSONStructureNode)
    case index(Int64)
    case unavailable
}

private nonisolated enum JSONSidebarCopyRequest: Sendable, Equatable {
    case value
    case object
    case path

    var subject: String {
        switch self {
        case .value: return "value"
        case .object: return "object"
        case .path: return "JSON path"
        }
    }
}

private nonisolated struct JSONSidebarPasteboardPayload: Sendable {
    let text: String
    let wasTruncated: Bool
}

@MainActor
final class LighTxtWindowController: NSWindowController, NSWindowDelegate {
    private var editorViewController: LighTxtEditorViewController
    private let preferredInitialContentSize: NSSize
    private var needsInitialExpandedFrame: Bool
    private var pendingNavigation: (
        url: URL,
        completion: ((LighTxtDocument?, Error?) -> Void)?
    )?

    init(document: LighTxtDocument) {
        let initialSize = Self.initialContentSize()
        editorViewController = LighTxtEditorViewController(document: document)
        preferredInitialContentSize = initialSize
        needsInitialExpandedFrame = true
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: initialSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = document.displayName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = LighTxtTheme.windowBackground
        window.sharingType = .readOnly
        window.minSize = NSSize(width: 1_000, height: 560)
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        // Each document owns an independently virtualized viewport. Automatic
        // tabbing can leave a launch-time requested file hidden behind a
        // restored untitled tab, so keep document windows explicit.
        window.tabbingMode = .disallowed
        window.contentViewController = editorViewController
        // Do not attach AppKit frame autosave here. Older releases persisted a
        // 700 × 460 fitting frame and AppKit reapplied it every time the
        // document was shown, overriding the intended expanded workspace.

        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true
    }

    private static func initialContentSize() -> NSSize {
        guard let visible = NSScreen.main?.visibleFrame ?? NSScreen.screens.first?.visibleFrame else {
            return NSSize(width: 1_400, height: 900)
        }
        // Nearly fill a laptop display without pinning edges or obscuring the
        // Dock/menu bar; larger displays cap at a calm 1400 × 900 workspace.
        return NSSize(
            width: min(1_400, floor(visible.width * 0.90)),
            height: min(900, floor(visible.height * 0.90))
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if needsInitialExpandedFrame, let window {
            // NSDocument performs one final fitting-size pass when it first
            // shows a controller. Apply the expanded default after that pass,
            // exactly once, so subsequent deliberate resizing is preserved.
            window.setContentSize(preferredInitialContentSize)
            window.center()
            needsInitialExpandedFrame = false
        }
        window?.makeKeyAndOrderFront(sender)
        editorViewController.focusCurrentPresentation()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        editorViewController.refreshChrome()
    }

    func windowWillClose(_ notification: Notification) {
        LighTxtDocumentController.active?.documentWindowDidClose()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard pendingNavigation == nil else {
            NSSound.beep()
            return false
        }
        return editorViewController.commitPendingPresentationEdit()
    }

    /// Reuses this NSDocument and NSWindow for an external Open request. The
    /// AppKit review is asynchronous so a large save completes before the old
    /// session is released, and Cancel leaves every bit of current UI intact.
    func navigateToDocument(
        at url: URL,
        completion: ((LighTxtDocument?, Error?) -> Void)? = nil
    ) {
        guard pendingNavigation == nil,
              let document = document as? LighTxtDocument,
              !document.isSaving,
              !document.session.isBulkEditing else {
            NSSound.beep()
            completion?(nil, LighTxtSessionError.saveInProgress)
            return
        }
        let target = url.standardizedFileURL
        if document.fileURL?.standardizedFileURL == target {
            window?.makeKeyAndOrderFront(nil)
            completion?(document, nil)
            return
        }
        guard editorViewController.commitPendingPresentationEdit() else {
            completion?(nil, CocoaError(.validationMissingMandatoryProperty))
            return
        }
        // The engine is the source of truth. Reconcile a mutation whose UI
        // callback may still be queued (for example, a bounded large paste)
        // before asking NSDocument whether a save review is required.
        if document.session.isEdited, !document.isDocumentEdited {
            document.updateChangeCount(.changeDone)
        }
        guard document.session.beginDocumentNavigationReview() else {
            NSSound.beep()
            completion?(nil, LighTxtSessionError.documentNavigationInProgress)
            return
        }

        pendingNavigation = (target, completion)
        document.canClose(
            withDelegate: self,
            shouldClose: #selector(navigationReviewDidFinish(_:shouldClose:contextInfo:)),
            contextInfo: nil
        )
    }

    @objc private func navigationReviewDidFinish(
        _ reviewedDocument: NSDocument,
        shouldClose: Bool,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        guard let pending = pendingNavigation,
              let currentDocument = document as? LighTxtDocument,
              reviewedDocument === currentDocument else { return }
        pendingNavigation = nil

        guard shouldClose, let document = reviewedDocument as? LighTxtDocument else {
            (reviewedDocument as? LighTxtDocument)?.session.endDocumentNavigationReview()
            pending.completion?(nil, CocoaError(.userCancelled))
            return
        }

        do {
            let type = try LighTxtDocumentController.active?.typeForContents(of: pending.url)
                ?? "public.plain-text"
            try document.replaceContentsForNavigation(with: pending.url, ofType: type)
            installFreshEditor(for: document)
            LighTxtDocumentController.active?.noteNewRecentDocumentURL(pending.url)
            pending.completion?(document, nil)
        } catch {
            document.session.endDocumentNavigationReview()
            pending.completion?(nil, error)
        }
    }

    private func installFreshEditor(for document: LighTxtDocument) {
        let replacement = LighTxtEditorViewController(document: document)
        editorViewController = replacement
        let preservedFrame = window?.frame
        window?.contentViewController = replacement
        if let preservedFrame {
            window?.setFrame(preservedFrame, display: true)
        }
        window?.title = document.displayName
        window?.representedURL = document.fileURL
        window?.isDocumentEdited = false
        replacement.focusCurrentPresentation()
    }
}

@MainActor
final class LighTxtEditorViewController: NSViewController, FindBarViewDelegate, StructureSidebarDelegate, NSSplitViewDelegate, NSMenuItemValidation {
    let editorView = VirtualTextEditorView()

    private weak var document: LighTxtDocument?
    private let session: LighTxtDocumentSession
    private let header = DocumentHeaderView()
    private let findBar = FindBarView()
    private let statusBar = DocumentStatusBar()
    private let structureSidebar = StructureSidebarView()
    private let workspaceSplitView = LighTxtWorkspaceSplitView()
    private let primaryContentHost = NSView()
    private lazy var markdownPreviewView: MarkdownPreviewView = {
        let preview = MarkdownPreviewView()
        preview.onStatusChange = { [weak self] text, busy in
            self?.statusBar.setState(text, busy: busy)
        }
        return preview
    }()
    private lazy var csvTableView: CSVTableView = {
        let table = CSVTableView()
        table.onStatusChange = { [weak self] text, busy in
            self?.statusBar.setState(text, busy: busy)
        }
        table.onEditingRegistrationChange = { [weak self, weak table] isEditing in
            guard let self, let table, let document = self.document else { return }
            if isEditing {
                document.objectDidBeginEditing(table)
            } else {
                document.objectDidEndEditing(table)
            }
            self.refreshChrome()
        }
        return table
    }()
    private weak var installedPrimaryContentView: NSView?
    private var findHeightConstraint: NSLayoutConstraint!
    private var structureIsVisible = false
    private var editModeStructureWasVisible = false
    private var presentationMode: DocumentPresentationMode = .edit
    private var preferredStructureWidth: CGFloat = 340
    private var sidebarShowsSearchResults = false
    private var lastStructurePayload: (folds: [SyntaxFoldRange], data: Data, base: Int64, type: SyntaxFileType)?
    private var saveObserver: NSObjectProtocol?
    private let jsonStructureController = JSONStructureController()
    private let jsonPageSize = 256
    private var jsonKnownRevision: UInt64?
    private var jsonRebuildWork: DispatchWorkItem?
    private var jsonNodeBySidebarIdentifier: [String: JSONStructureNode] = [:]
    private var jsonParentIdentifierBySidebarIdentifier: [String: String] = [:]
    private var jsonPathComponentBySidebarIdentifier: [String: JSONSidebarPathComponent] = [:]
    private var jsonRootSidebarIdentifier: String?
    private var jsonCursorByParentIdentifier: [String: JSONStructureChildrenCursor] = [:]
    private var jsonLoadingParents: Set<String> = []
    private var jsonLoadMoreParentByIdentifier: [String: String] = [:]
    private var jsonPresentedGeneration: UInt64?
    private var pendingEditRevealRange: Range<Int64>?
    private var lastEditorViewport: Range<Int64> = 0..<0
    private var observedSyntaxFileType: SyntaxFileType
    private var syntaxChangedDuringSave = false

    /// Optional rendered-content integrations can replace the primary pane
    /// after this callback. The chrome and split view do not depend on a JSON,
    /// Markdown, or CSV parser.
    var presentationModeDidChange: ((DocumentPresentationMode) -> Void)?

    init(document: LighTxtDocument) {
        self.document = document
        self.session = document.session
        self.observedSyntaxFileType = document.session.syntaxFileType
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let saveObserver { NotificationCenter.default.removeObserver(saveObserver) }
        jsonRebuildWork?.cancel()
    }

    override func loadView() {
        let root = NSView()
        view = root
        configureLayout()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        findBar.findDelegate = self
        structureSidebar.delegate = self
        editorView.editorDelegate = session
        header.onFind = { [weak self] in self?.showFindPanel(nil) }
        header.onStructure = { [weak self] in self?.toggleStructure(nil) }
        header.onOpenFolder = { [weak self] url in
            let workspace = NSWorkspace.shared
            guard !workspace.open(url) else { return }

            // A sandboxed document grant may not authorize opening ancestor
            // folders directly. Revealing the next breadcrumb item still opens
            // the clicked folder itself, without retaining a folder grant.
            let folderComponents = url.standardizedFileURL.pathComponents
            let documentComponents = self?.document?.fileURL?.standardizedFileURL.pathComponents ?? []
            if documentComponents.starts(with: folderComponents),
               documentComponents.count > folderComponents.count {
                workspace.activateFileViewerSelecting([
                    url.appendingPathComponent(documentComponents[folderComponents.count])
                ])
            } else {
                workspace.activateFileViewerSelecting([url])
            }
        }
        header.onPresentationModeChanged = { [weak self] mode in
            self?.setPresentationMode(mode, notifyIntegration: true)
        }
        installSessionCallbacks()
        installJSONStructureCallbacks()
        observeSaveProgress()
        refreshChrome()
        if Self.prefersViewMode(for: session.syntaxFileType) {
            setPresentationMode(.view, notifyIntegration: false)
        } else {
            header.presentationMode = .edit
            statusBar.updateByteWindow(0..<min(Int64(VirtualTextEditorView.maximumViewportBytes), session.byteCount), totalByteCount: session.byteCount)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusCurrentPresentation()
    }

    func refreshChrome() {
        guard let document else { return }
        let title = document.fileURL?.lastPathComponent ?? "Untitled"
        let isEdited = session.isEdited || document.isDocumentEdited
        header.update(
            fileURL: document.fileURL,
            title: title,
            typeName: session.syntaxFileType.displayName,
            typeAbbreviation: session.syntaxFileType.displayAbbreviation,
            byteCount: session.byteCount,
            edited: isEdited,
            structureAvailable: canToggleStructure
        )
        view.window?.title = title
        view.window?.representedURL = document.fileURL
        view.window?.isDocumentEdited = isEdited
    }

    private func configureLayout() {
        [header, findBar, workspaceSplitView, statusBar].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        findHeightConstraint = findBar.heightAnchor.constraint(equalToConstant: 0)

        editorView.translatesAutoresizingMaskIntoConstraints = false
        primaryContentHost.addSubview(editorView)
        installedPrimaryContentView = editorView
        NSLayoutConstraint.activate([
            editorView.leadingAnchor.constraint(equalTo: primaryContentHost.leadingAnchor),
            editorView.trailingAnchor.constraint(equalTo: primaryContentHost.trailingAnchor),
            editorView.topAnchor.constraint(equalTo: primaryContentHost.topAnchor),
            editorView.bottomAnchor.constraint(equalTo: primaryContentHost.bottomAnchor)
        ])

        workspaceSplitView.isVertical = true
        workspaceSplitView.dividerStyle = .thin
        workspaceSplitView.delegate = self
        workspaceSplitView.addArrangedSubview(primaryContentHost)
        workspaceSplitView.addArrangedSubview(structureSidebar)
        structureSidebar.isHidden = true

        let storedWidth = UserDefaults.standard.double(forKey: "LighTxt.StructureSidebarWidth")
        if storedWidth >= 260, storedWidth <= 560 {
            preferredStructureWidth = CGFloat(storedWidth)
        }

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.heightAnchor.constraint(equalToConstant: 60),

            findBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            findBar.topAnchor.constraint(equalTo: header.bottomAnchor),
            findHeightConstraint,

            statusBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 27),

            workspaceSplitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            workspaceSplitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            workspaceSplitView.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            workspaceSplitView.bottomAnchor.constraint(equalTo: statusBar.topAnchor)
        ])
        findBar.isHidden = true
    }

    private func installSessionCallbacks() {
        session.callbacks.documentChanged = { [weak self] byteCount, edited in
            guard let self, let document = self.document else { return }
            if edited, !document.isDocumentEdited {
                document.updateChangeCount(.changeDone)
            } else if !edited, document.isDocumentEdited {
                document.updateChangeCount(.changeCleared)
            }
            let currentType = self.session.syntaxFileType
            let typeChanged = currentType != self.observedSyntaxFileType
            if typeChanged {
                self.handleSyntaxFileTypeChange(to: currentType)
            }
            self.refreshChrome()
            guard !typeChanged else { return }
            self.handleJSONDocumentChange()
            // A transactional rewrite publishes a temporary dirty state so
            // Close/Quit remains prompt-safe. Do not rebuild an unchanged CSV
            // table (or other rendered view) at that start notification; the
            // final notification installs exactly one fresh generation.
            guard !self.session.isBulkEditing else { return }
            if self.presentationMode == .view {
                (self.installedPrimaryContentView as? MarkdownPreviewView)?.reloadDocument()
                if let table = self.installedPrimaryContentView as? CSVTableView,
                   !table.consumeDocumentReloadSuppression() {
                    table.reloadDocument()
                }
            }
        }
        session.callbacks.editorViewportChanged = { [weak self] range, total in
            guard let self else { return }
            self.lastEditorViewport = range
            if self.presentationMode == .edit {
                self.statusBar.updateByteWindow(range, totalByteCount: total)
            }
        }
        session.callbacks.selectionChanged = { [weak self] range, line, column in
            self?.statusBar.updatePosition(
                line: line,
                column: column,
                selectionByteCount: Int64(range.count)
            )
        }
        session.callbacks.statusChanged = { [weak self] text, busy, isError in
            self?.statusBar.setState(text, busy: busy, isError: isError)
            if self?.findBar.isHidden == false {
                self?.findBar.setStatus(text, isError: isError)
            }
        }
        session.callbacks.matchChanged = { [weak self] match in
            guard let self, let match else { return }
            guard self.presentationMode == .edit else {
                // Search completion is asynchronous. In View mode the find
                // field may already contain more input by the time a match is
                // published, so changing modes here would steal first
                // responder from that field and send the remaining keystrokes
                // into the bounded editor. Remember the match for an explicit
                // switch to Edit, but never let search choose the document's
                // presentation mode.
                self.pendingEditRevealRange = match.byteRange
                return
            }
            self.editorView.scrollTo(byteRange: match.byteRange)
        }
        session.callbacks.findAllCompleted = { [weak self] summary in
            guard let self else { return }
            self.sidebarShowsSearchResults = true
            self.jsonPresentedGeneration = nil
            self.structureSidebar.updateSearchResults(
                summary.retainedMatches,
                total: summary.totalMatches,
                truncated: summary.retainedLimitReached
            )
            self.setStructureVisible(true)
            let noun = summary.totalMatches == 1 ? "match" : "matches"
            self.findBar.setStatus("\(summary.totalMatches.formatted()) \(noun)")
        }
        session.callbacks.searchResultsInvalidated = { [weak self] in
            guard let self, self.sidebarShowsSearchResults else { return }
            self.sidebarShowsSearchResults = false
            if self.presentationMode == .view, self.session.syntaxFileType == .json {
                self.restoreJSONStructureAfterSearch()
                return
            }
            if let payload = self.lastStructurePayload {
                self.structureSidebar.update(
                    folds: payload.folds,
                    viewportData: payload.data,
                    viewportBaseOffset: payload.base,
                    fileType: payload.type
                )
            } else {
                self.structureSidebar.updateSearchResults([], total: 0, truncated: false)
            }
        }
        session.callbacks.structureChanged = { [weak self] folds, data, base, type in
            guard let self else { return }
            self.lastStructurePayload = (folds, data, base, type)
            guard !self.sidebarShowsSearchResults else { return }
            guard !(self.presentationMode == .view && type == .json) else { return }
            if type == .json { self.jsonPresentedGeneration = nil }
            self.structureSidebar.update(
                folds: folds,
                viewportData: data,
                viewportBaseOffset: base,
                fileType: type
            )
        }
        session.callbacks.error = { [weak self] error in
            self?.statusBar.setState(error.localizedDescription, busy: false, isError: true)
            if let window = self?.view.window {
                window.presentError(error)
            } else {
                NSApp.presentError(error)
            }
        }
    }

    private func installJSONStructureCallbacks() {
        jsonStructureController.callbacks.progress = { [weak self] progress in
            self?.showJSONProgress(progress)
        }
        jsonStructureController.callbacks.ready = { [weak self] index in
            guard let self else { return }
            self.jsonKnownRevision = index.sourceRevision
            guard self.presentationMode == .view,
                  self.session.syntaxFileType == .json,
                  !self.sidebarShowsSearchResults else { return }
            self.presentJSONIndex(index)
        }
        jsonStructureController.callbacks.invalidated = { [weak self] in
            guard let self else { return }
            self.resetJSONSidebarState()
            guard self.presentationMode == .view,
                  self.session.syntaxFileType == .json,
                  !self.sidebarShowsSearchResults else { return }
            self.structureSidebar.showLoading(
                StructureSidebarLoadingState(
                    title: "Refreshing JSON",
                    detail: "The document changed. Rebuilding its file-backed outline…",
                    totalByteCount: self.session.byteCount
                )
            )
        }
        jsonStructureController.callbacks.error = { [weak self] error in
            guard let self,
                  self.presentationMode == .view,
                  self.session.syntaxFileType == .json,
                  !self.sidebarShowsSearchResults else { return }
            self.structureSidebar.showMessage(
                title: "JSON outline unavailable",
                detail: error.localizedDescription,
                scope: "The editor remains available"
            )
            self.statusBar.setState(error.localizedDescription, busy: false, isError: true)
        }
    }

    private static func prefersViewMode(for fileType: SyntaxFileType) -> Bool {
        fileType == .json || fileType == .markdown || fileType == .csv
    }

    private static func supportsStructure(for fileType: SyntaxFileType) -> Bool {
        fileType == .json || fileType == .xml || fileType == .yaml
    }

    var canToggleStructure: Bool {
        Self.supportsStructure(for: session.syntaxFileType)
    }

    /// Save As may change the detected format without replacing this window
    /// controller. Release the old renderer's captured snapshots/indexes and
    /// reinstall the presentation for the new format immediately.
    private func handleSyntaxFileTypeChange(to newType: SyntaxFileType) {
        observedSyntaxFileType = newType
        syntaxChangedDuringSave = true
        jsonRebuildWork?.cancel()
        jsonRebuildWork = nil
        jsonStructureController.reset()
        jsonKnownRevision = nil
        resetJSONSidebarState()
        lastStructurePayload = nil
        sidebarShowsSearchResults = false
        if !Self.supportsStructure(for: newType) {
            editModeStructureWasVisible = false
            setStructureVisible(false)
        }
        // JSON View hides the primary pane instead of installing a replacement
        // view. Normalize through the editor first so an old CSV/Markdown
        // renderer cannot keep scanning or retain its source invisibly.
        restoreEditorAsPrimaryContent()

        if presentationMode == .view, Self.prefersViewMode(for: newType) {
            // Force the existing logical mode back through its installation
            // path so JSON, Markdown, and CSV cannot leave stale UI behind.
            presentationMode = .edit
            setPresentationMode(.view, notifyIntegration: true)
        } else if presentationMode == .view {
            setPresentationMode(.edit, notifyIntegration: true)
        } else {
            restoreEditorAsPrimaryContent()
            editorView.reloadPreservingSelection()
            header.presentationMode = .edit
        }
    }

    func focusCurrentPresentation() {
        guard let window = view.window else { return }
        switch presentationMode {
        case .edit:
            window.makeFirstResponder(editorView)
        case .view:
            if session.syntaxFileType == .markdown {
                window.makeFirstResponder(markdownPreviewView)
            } else if session.syntaxFileType == .csv {
                window.makeFirstResponder(csvTableView)
            } else {
                window.makeFirstResponder(structureSidebar)
            }
        }
    }

    private func handleJSONDocumentChange() {
        guard session.syntaxFileType == .json else { return }
        let snapshot: DocumentSnapshot
        do {
            snapshot = try session.editorSnapshot()
        } catch {
            if presentationMode == .view {
                structureSidebar.showMessage(
                    title: "JSON outline unavailable",
                    detail: error.localizedDescription,
                    scope: "The editor remains available"
                )
            }
            return
        }

        if session.isBulkEditing {
            jsonKnownRevision = nil
            jsonRebuildWork?.cancel()
            // The replacement has not published its final revision yet, but
            // the visible outline must stop claiming it is current now.
            jsonStructureController.invalidate(forRevision: snapshot.revision &+ 1)
            return
        }

        guard jsonKnownRevision != snapshot.revision else { return }
        jsonKnownRevision = snapshot.revision
        jsonStructureController.invalidate(forRevision: snapshot.revision)
        scheduleJSONRebuildIfViewing()
    }

    private func scheduleJSONRebuildIfViewing() {
        jsonRebuildWork?.cancel()
        guard presentationMode == .view,
              session.syntaxFileType == .json,
              !session.isBulkEditing else { return }
        let work = DispatchWorkItem { [weak self] in self?.startJSONStructureIfNeeded() }
        jsonRebuildWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.30, execute: work)
    }

    private func startJSONStructureIfNeeded() {
        guard presentationMode == .view,
              session.syntaxFileType == .json,
              !sidebarShowsSearchResults,
              !session.isBulkEditing else { return }
        do {
            let snapshot = try session.editorSnapshot()
            if let knownRevision = jsonKnownRevision, knownRevision != snapshot.revision {
                jsonStructureController.invalidate(forRevision: snapshot.revision)
            }
            jsonKnownRevision = snapshot.revision
            if let index = jsonStructureController.index,
               index.sourceRevision == snapshot.revision,
               index.isOpen {
                if jsonPresentedGeneration != index.generation {
                    presentJSONIndex(index)
                } else {
                    updateJSONReadyStatus(index)
                }
                return
            }
            if jsonStructureController.isBuilding {
                if let progress = jsonStructureController.latestProgress {
                    showJSONProgress(progress)
                }
                return
            }
            resetJSONSidebarState()
            jsonStructureController.rebuild(snapshot: snapshot)
        } catch {
            structureSidebar.showMessage(
                title: "JSON outline unavailable",
                detail: error.localizedDescription,
                scope: "The editor remains available"
            )
            statusBar.setState(error.localizedDescription, busy: false, isError: true)
        }
    }

    private func showJSONProgress(_ progress: JSONStructureIndexProgress) {
        guard presentationMode == .view,
              session.syntaxFileType == .json,
              !sidebarShowsSearchResults else { return }
        structureSidebar.showLoading(
            StructureSidebarLoadingState(
                title: "Mapping JSON",
                detail: "Mapping the entire document into a searchable outline. You can return to Edit at any time.",
                fractionCompleted: progress.fractionCompleted,
                processedByteCount: progress.processedBytes,
                totalByteCount: progress.totalBytes
            )
        )
        let percent = Int(progress.fractionCompleted * 100)
        statusBar.setState(
            "Mapping JSON \(percent)%  ·  \(progress.parsedValueCount.formatted()) values  ·  \(progress.indexedContainerCount.formatted()) groups",
            busy: true
        )
        statusBar.showFileBackedView(totalByteCount: progress.totalBytes)
    }

    private func presentJSONIndex(_ index: JSONStructureIndex) {
        guard jsonStructureController.index === index, index.isOpen else { return }
        let isFirstVisiblePresentation = jsonPresentedGeneration != index.generation
        resetJSONSidebarState()
        jsonPresentedGeneration = index.generation
        let root = index.documentRoot
        let identifier = jsonSidebarIdentifier(for: root, index: index)
        jsonNodeBySidebarIdentifier[identifier] = root
        jsonRootSidebarIdentifier = identifier
        let issueText = index.diagnosticCount > 0
            ? "  ·  \(index.diagnosticCount.formatted()) syntax issue\(index.diagnosticCount == 1 ? "" : "s")"
            : ""
        let rootNode = StructureSidebarNode(
            identifier: identifier,
            title: "JSON document",
            subtitle: "\(index.parsedValueCount.formatted()) values  ·  \(index.indexedContainerCount.formatted()) groups\(issueText)",
            range: root.byteRange,
            kind: .object,
            childState: (root.childCount ?? 0) > 0 ? .unloaded : .leaf
        )
        structureSidebar.applyTreeSnapshot(
            [rootNode],
            title: "JSON Explorer",
            scope: jsonIndexScope(index),
            documentByteCount: index.sourceByteCount,
            preservingExpansion: false
        )
        updateJSONReadyStatus(index)
        if isFirstVisiblePresentation {
            LighTxtSignpost.event("JSONVisibleReady", bytes: index.sourceByteCount)
        }
    }

    private func updateJSONReadyStatus(_ index: JSONStructureIndex) {
        let readyText: String
        if index.diagnosticCount > 0 {
            readyText = "JSON mapped with \(index.diagnosticCount.formatted()) syntax issue\(index.diagnosticCount == 1 ? "" : "s")"
        } else {
            readyText = "JSON mapped  ·  \(index.parsedValueCount.formatted()) values"
        }
        statusBar.setState(readyText, busy: false, isError: index.diagnosticCount > 0)
        statusBar.showFileBackedView(totalByteCount: index.sourceByteCount)
    }

    private func restoreJSONStructureAfterSearch() {
        guard presentationMode == .view, session.syntaxFileType == .json else { return }
        if let index = jsonStructureController.index, index.isOpen {
            presentJSONIndex(index)
        } else if let progress = jsonStructureController.latestProgress,
                  jsonStructureController.isBuilding {
            showJSONProgress(progress)
        } else {
            startJSONStructureIfNeeded()
        }
    }

    private func resetJSONSidebarState() {
        jsonNodeBySidebarIdentifier.removeAll(keepingCapacity: true)
        jsonParentIdentifierBySidebarIdentifier.removeAll(keepingCapacity: true)
        jsonPathComponentBySidebarIdentifier.removeAll(keepingCapacity: true)
        jsonRootSidebarIdentifier = nil
        jsonCursorByParentIdentifier.removeAll(keepingCapacity: true)
        jsonLoadingParents.removeAll(keepingCapacity: true)
        jsonLoadMoreParentByIdentifier.removeAll(keepingCapacity: true)
        jsonPresentedGeneration = nil
    }

    private func jsonIndexScope(_ index: JSONStructureIndex) -> String {
        var components = [
            ByteCountFormatter.lighTxt.string(fromByteCount: index.sourceByteCount),
            "\(index.parsedValueCount.formatted()) values",
        ]
        if index.diagnosticCount > 0 {
            components.append("\(index.diagnosticCount.formatted()) issues")
        }
        return components.joined(separator: "  ·  ")
    }

    private func observeSaveProgress() {
        saveObserver = NotificationCenter.default.addObserver(
            forName: .lighTxtSaveProgress,
            object: document,
            queue: .main
        ) { [weak self] notification in
            let fraction = notification.userInfo?["progress"] as? Double ?? 0
            let sourceRebased = notification.userInfo?["sourceRebased"] as? Bool ?? false
            let failureDescription = notification.userInfo?["failureDescription"] as? String
            Task { @MainActor [weak self] in
                if let failureDescription {
                    self?.statusBar.setState(failureDescription, busy: false, isError: true)
                } else if fraction < 1 {
                    self?.statusBar.setState("Saving \(Int(fraction * 100))%", busy: true)
                } else {
                    guard let self else { return }
                    self.statusBar.setState("Saved", busy: false)
                    self.refreshChrome()
                    if self.syntaxChangedDuringSave {
                        // The type-transition path already installed a fresh
                        // renderer/index against the post-save source.
                        self.syntaxChangedDuringSave = false
                    } else if sourceRebased, self.session.syntaxFileType == .json {
                        // Atomic save rebases the source inode without always
                        // changing the edit revision. Drop the old snapshot so
                        // the replaced source and disk index are reclaimed.
                        self.jsonRebuildWork?.cancel()
                        self.jsonRebuildWork = nil
                        self.jsonStructureController.reset()
                        self.jsonKnownRevision = nil
                        self.resetJSONSidebarState()
                        if self.presentationMode == .view {
                            self.startJSONStructureIfNeeded()
                        }
                    }
                }
            }
        }
    }

    @objc func showFindPanel(_ sender: Any?) {
        findBar.isHidden = false
        findHeightConstraint.constant = 104
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.layoutSubtreeIfNeeded()
        }
        findBar.focus(selectAll: false)
    }

    @objc func findNext(_ sender: Any?) {
        session.findNext(backwards: false, from: editorView.selectedGlobalByteRange)
    }

    @objc func findPrevious(_ sender: Any?) {
        session.findNext(backwards: true, from: editorView.selectedGlobalByteRange)
    }

    @objc func useSelectionForFind(_ sender: Any?) {
        guard let selected = editorView.useSelectionForFind(), !selected.isEmpty else { return }
        showFindPanel(sender)
        findBar.query = selected
    }

    @objc func showGoToLine(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.informativeText = session.totalLineCount.map { "Enter a line from 1 to \($0.formatted())." }
            ?? "Enter a line number. LighTxt will locate it without loading the file."
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: "")
        field.placeholderString = "Line number"
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        guard alert.runModal() == .alertFirstButtonReturn,
              let line = Int64(field.stringValue), line > 0 else { return }
        session.byteOffset(forOneBasedLine: line) { [weak self] result in
            switch result {
            case .success(let offset?): self?.editorView.scrollTo(byteRange: offset..<offset, select: false)
            case .success(nil): NSSound.beep()
            case .failure(let error): self?.session.callbacks.error?(error)
            }
        }
    }

    @objc func toggleStructure(_ sender: Any?) {
        guard canToggleStructure else { return }
        if presentationMode == .view {
            setPresentationMode(.edit, notifyIntegration: true)
            return
        }
        sidebarShowsSearchResults = false
        if let payload = lastStructurePayload {
            structureSidebar.update(
                folds: payload.folds,
                viewportData: payload.data,
                viewportBaseOffset: payload.base,
                fileType: payload.type
            )
        }
        setStructureVisible(!structureIsVisible)
    }

    @objc func increaseFontSize(_ sender: Any?) { editorView.changeFontSize(by: 1) }
    @objc func decreaseFontSize(_ sender: Any?) { editorView.changeFontSize(by: -1) }
    @objc func resetFontSize(_ sender: Any?) { editorView.resetFontSize() }

    @objc func undoDocumentEdit(_ sender: Any?) {
        guard commitPendingPresentationEdit() else { return }
        if session.undo() { editorView.reloadPreservingSelection() }
    }

    @objc func undo(_ sender: Any?) { undoDocumentEdit(sender) }

    @objc func redoDocumentEdit(_ sender: Any?) {
        guard commitPendingPresentationEdit() else { return }
        if session.redo() { editorView.reloadPreservingSelection() }
    }

    @objc func redo(_ sender: Any?) { redoDocumentEdit(sender) }

    @objc func saveACopy(_ sender: Any?) {
        guard commitPendingPresentationEdit() else { return }
        document?.saveACopy(sender)
    }
    @objc func duplicateLighTxtDocument(_ sender: Any?) {
        guard commitPendingPresentationEdit() else { return }
        document?.duplicateLighTxtDocument(sender)
    }

    @objc func showLighTxtHelp(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "LighTxt"
        alert.informativeText = "Open TXT, JSON, Markdown, SQL, XML, CSV, or YAML. Only a bounded editing viewport is decoded; the source remains file-backed. Use ⌘F for literal or regex find/replace, ⌘L to jump to a line, and the Structure panel for expandable JSON/XML/YAML groups."
        alert.addButton(withTitle: "Done")
        alert.runModal()
    }

    func findBar(
        _ findBar: FindBarView,
        queryDidChange query: String,
        regularExpression: Bool,
        caseSensitive: Bool,
        wholeWords: Bool
    ) {
        session.configureSearch(
            query: query,
            regularExpression: regularExpression,
            caseSensitive: caseSensitive,
            wholeWords: wholeWords
        )
        guard !query.isEmpty else {
            findBar.setStatus("Search this document")
            return
        }
        session.findNext(backwards: false, from: editorView.selectedGlobalByteRange)
    }

    func findBarFindNext(_ findBar: FindBarView, backwards: Bool) {
        session.findNext(backwards: backwards, from: editorView.selectedGlobalByteRange)
    }

    func findBarFindAll(_ findBar: FindBarView) {
        session.findAll()
    }

    func findBarReplaceCurrent(_ findBar: FindBarView, replacement: String) {
        do {
            if let range = try session.replaceCurrent(with: replacement)?.byteRange {
                editorView.reloadPreservingSelection()
                editorView.scrollTo(byteRange: range)
                session.findNext(backwards: false, from: range)
            } else {
                session.findNext(backwards: false, from: editorView.selectedGlobalByteRange)
            }
        } catch {
            findBar.setStatus(error.localizedDescription, isError: true)
        }
    }

    func findBarReplaceAll(_ findBar: FindBarView, replacement: String) {
        session.replaceAll(with: replacement) { [weak self] result in
            switch result {
            case .success(let count):
                let noun = count == 1 ? "match" : "matches"
                self?.findBar.setStatus("Replaced \(count.formatted()) \(noun)")
                self?.editorView.reloadPreservingSelection()
            case .failure(let error):
                self?.findBar.setStatus(error.localizedDescription, isError: true)
            }
        }
    }

    func findBarDidRequestClose(_ findBar: FindBarView) {
        findHeightConstraint.constant = 0
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            view.layoutSubtreeIfNeeded()
        }, completionHandler: { [weak self] in
            self?.findBar.isHidden = true
            self?.view.window?.makeFirstResponder(self?.editorView)
        })
    }

    func structureSidebar(_ sidebar: StructureSidebarView, revealByteRange range: Range<Int64>) {
        if sidebarShowsSearchResults {
            pendingEditRevealRange = range
            setPresentationMode(.edit, notifyIntegration: true)
        } else if presentationMode == .view {
            pendingEditRevealRange = range
            statusBar.setState(
                "Selected JSON value at byte \(range.lowerBound.formatted())  ·  choose Edit to modify",
                busy: false
            )
        } else {
            revealPendingRangeInEditor(range)
        }
    }

    func structureSidebar(
        _ sidebar: StructureSidebarView,
        didRequestChildrenFor node: StructureSidebarNode
    ) {
        guard !sidebarShowsSearchResults else { return }
        requestJSONChildren(forParentIdentifier: node.identifier)
    }

    func structureSidebar(
        _ sidebar: StructureSidebarView,
        didActivate node: StructureSidebarNode
    ) -> Bool {
        guard node.role == .loadMore,
              let parentIdentifier = jsonLoadMoreParentByIdentifier[node.identifier] else {
            return false
        }
        requestJSONChildren(forParentIdentifier: parentIdentifier)
        return true
    }

    func structureSidebar(
        _ sidebar: StructureSidebarView,
        contextMenuFor node: StructureSidebarNode
    ) -> NSMenu? {
        guard presentationMode == .view,
              session.syntaxFileType == .json,
              !sidebarShowsSearchResults,
              node.role == .content,
              let index = jsonStructureController.index,
              index.isOpen,
              jsonPresentedGeneration == index.generation,
              let jsonNode = jsonNodeBySidebarIdentifier[node.identifier],
              jsonNode.kind != .document,
              jsonNode.kind != .invalid else { return nil }

        let menu = NSMenu(title: "JSON")
        menu.autoenablesItems = false
        switch jsonNode.kind {
        case .string, .number, .boolean, .null:
            menu.addItem(jsonCopyMenuItem(
                title: "Copy Value",
                action: #selector(copyJSONValueFromMenu(_:)),
                identifier: node.identifier
            ))
        case .object, .array:
            menu.addItem(jsonCopyMenuItem(
                title: "Copy Object",
                action: #selector(copyJSONObjectFromMenu(_:)),
                identifier: node.identifier
            ))
        case .document, .invalid:
            return nil
        }
        menu.addItem(.separator())
        menu.addItem(jsonCopyMenuItem(
            title: "Copy Path",
            action: #selector(copyJSONPathFromMenu(_:)),
            identifier: node.identifier
        ))
        return menu
    }

    func structureSidebarDidRequestClose(_ sidebar: StructureSidebarView) {
        if presentationMode == .view {
            setPresentationMode(.edit, notifyIntegration: true)
        } else {
            setStructureVisible(false)
        }
    }

    private func requestJSONChildren(forParentIdentifier parentIdentifier: String) {
        guard presentationMode == .view,
              session.syntaxFileType == .json,
              let index = jsonStructureController.index,
              let parent = jsonNodeBySidebarIdentifier[parentIdentifier],
              !jsonLoadingParents.contains(parentIdentifier) else { return }
        let cursor = jsonCursorByParentIdentifier[parentIdentifier]
        jsonLoadingParents.insert(parentIdentifier)
        structureSidebar.setChildState(.loading, for: parentIdentifier)
        let request = jsonStructureController.requestChildren(
            of: parent,
            cursor: cursor,
            limit: jsonPageSize
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.jsonLoadingParents.remove(parentIdentifier)
                self.structureSidebar.setChildState(.unloaded, for: parentIdentifier)
                self.statusBar.setState(error.localizedDescription, busy: false, isError: true)
            case .success(let page):
                // Child labels perform bounded source reads. Decode the whole
                // page away from MainActor, then publish one UI batch.
                DispatchQueue.global(qos: .userInitiated).async {
                    let previews = page.nodes.map { try? index.preview(for: $0) }
                    let batch = JSONSidebarPreviewBatch(page: page, previews: previews)
                    DispatchQueue.main.async { [weak self] in
                        self?.publishJSONPage(
                            batch,
                            parent: parent,
                            parentIdentifier: parentIdentifier,
                            index: index
                        )
                    }
                }
            }
        }
        if request == nil {
            jsonLoadingParents.remove(parentIdentifier)
        }
    }

    private func publishJSONPage(
        _ batch: JSONSidebarPreviewBatch,
        parent: JSONStructureNode,
        parentIdentifier: String,
        index: JSONStructureIndex
    ) {
        guard jsonStructureController.index === index,
              index.isOpen,
              jsonLoadingParents.remove(parentIdentifier) != nil else { return }

        // Valid JSON has one document child. Promote that real object/array to
        // the visible root so users land directly on top-level keys instead of
        // drilling through “JSON document → Root value”. Malformed multi-root
        // input keeps the synthetic document node as an honest fallback.
        if parent.kind == .document,
           batch.page.nodes.count == 1,
           batch.page.nextCursor == nil,
           let node = batch.page.nodes.first {
            let preview = batch.previews.first ?? nil
            resetJSONSidebarState()
            jsonPresentedGeneration = index.generation
            let identifier = jsonSidebarIdentifier(for: node, index: index)
            jsonNodeBySidebarIdentifier[identifier] = node
            jsonRootSidebarIdentifier = identifier
            let title: String
            switch node.kind {
            case .object: title = "Root object"
            case .array: title = "Root array"
            default: title = "Root value"
            }
            var subtitle = jsonSubtitle(for: node, preview: preview)
            if node.containsErrors { subtitle += "  ·  contains syntax issues" }
            if !node.isComplete { subtitle += "  ·  incomplete" }
            let rootNode = StructureSidebarNode(
                identifier: identifier,
                title: title,
                subtitle: subtitle,
                range: node.byteRange,
                kind: syntaxFoldKind(for: node.kind),
                childState: node.kind.isContainer && (node.childCount ?? 0) > 0 ? .unloaded : .leaf
            )
            structureSidebar.applyTreeSnapshot(
                [rootNode],
                title: "JSON Explorer",
                scope: jsonIndexScope(index),
                documentByteCount: index.sourceByteCount,
                preservingExpansion: false
            )
            updateJSONReadyStatus(index)
            return
        }

        let pageNodes = batch.page.nodes.enumerated().map { offset, node in
            let preview = offset < batch.previews.count ? batch.previews[offset] : nil
            let ordinal = batch.page.firstChildOrdinal + Int64(offset)
            let sidebarNode = makeJSONSidebarNode(
                node,
                preview: preview,
                ordinal: ordinal,
                parent: parent,
                index: index
            )
            jsonNodeBySidebarIdentifier[sidebarNode.identifier] = node
            jsonParentIdentifierBySidebarIdentifier[sidebarNode.identifier] = parentIdentifier
            switch parent.kind {
            case .object:
                jsonPathComponentBySidebarIdentifier[sidebarNode.identifier] = .member(node)
            case .array:
                jsonPathComponentBySidebarIdentifier[sidebarNode.identifier] = .index(ordinal)
            case .document, .string, .number, .boolean, .null, .invalid:
                jsonPathComponentBySidebarIdentifier[sidebarNode.identifier] = .unavailable
            }
            return sidebarNode
        }

        let continuation: StructureSidebarNode?
        if let nextCursor = batch.page.nextCursor {
            jsonCursorByParentIdentifier[parentIdentifier] = nextCursor
            let loadedCount = batch.page.firstChildOrdinal + Int64(batch.page.nodes.count)
            let totalCount = max(loadedCount, parent.childCount ?? loadedCount)
            let continuationIdentifier = "\(parentIdentifier):load-more"
            jsonLoadMoreParentByIdentifier[continuationIdentifier] = parentIdentifier
            continuation = StructureSidebarNode(
                identifier: continuationIdentifier,
                title: "Load more…",
                subtitle: "\(loadedCount.formatted()) of \(totalCount.formatted()) children loaded",
                range: parent.byteRange.lowerBound..<parent.byteRange.lowerBound,
                kind: nil,
                role: .loadMore,
                childState: .leaf
            )
        } else {
            jsonCursorByParentIdentifier.removeValue(forKey: parentIdentifier)
            continuation = nil
        }

        structureSidebar.appendChildren(
            of: parentIdentifier,
            page: pageNodes,
            continuation: continuation,
            final: batch.page.nextCursor == nil
        )
        let loaded = batch.page.firstChildOrdinal + Int64(batch.page.nodes.count)
        let total = parent.childCount ?? loaded
        statusBar.setState(
            batch.page.nextCursor == nil
                ? "Loaded all \(total.formatted()) children"
                : "Loaded \(loaded.formatted()) of \(total.formatted()) children",
            busy: false
        )
    }

    private func jsonSidebarIdentifier(
        for node: JSONStructureNode,
        index: JSONStructureIndex
    ) -> String {
        "json:\(index.generation):\(node.kind.rawValue):\(node.byteRange.lowerBound)"
    }

    private func jsonCopyMenuItem(
        title: String,
        action: Selector,
        identifier: String
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = identifier
        item.isEnabled = true
        return item
    }

    @objc private func copyJSONValueFromMenu(_ sender: NSMenuItem) {
        beginJSONCopy(.value, from: sender)
    }

    @objc private func copyJSONObjectFromMenu(_ sender: NSMenuItem) {
        beginJSONCopy(.object, from: sender)
    }

    @objc private func copyJSONPathFromMenu(_ sender: NSMenuItem) {
        beginJSONCopy(.path, from: sender)
    }

    private func beginJSONCopy(_ request: JSONSidebarCopyRequest, from sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else {
            statusBar.setState("Could not copy JSON: the selected row is no longer available.", busy: false, isError: true)
            return
        }
        beginJSONCopy(request, identifier: identifier)
    }

    private func beginJSONCopy(_ request: JSONSidebarCopyRequest, identifier: String) {
        guard presentationMode == .view,
              session.syntaxFileType == .json,
              !sidebarShowsSearchResults,
              let index = jsonStructureController.index,
              index.isOpen,
              jsonPresentedGeneration == index.generation,
              let node = jsonNodeBySidebarIdentifier[identifier] else {
            statusBar.setState("Could not copy JSON: the selected row is no longer available.", busy: false, isError: true)
            return
        }

        let pathSegments: [JSONStructurePathSegment]?
        if request == .path {
            guard let resolved = jsonPathSegments(for: identifier) else {
                statusBar.setState("Could not copy JSON path: this row has no exact path.", busy: false, isError: true)
                return
            }
            pathSegments = resolved
        } else {
            pathSegments = nil
        }

        statusBar.setState("Preparing \(request.subject)…", busy: true)
        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<JSONSidebarPasteboardPayload, Error>
            do {
                let payload: JSONSidebarPasteboardPayload
                switch request {
                case .value:
                    let copy = try index.copyText(for: node, kind: .scalarValue)
                    payload = JSONSidebarPasteboardPayload(
                        text: copy.text,
                        wasTruncated: copy.wasTruncated
                    )
                case .object:
                    let copy = try index.copyText(for: node, kind: .containerJSON)
                    payload = JSONSidebarPasteboardPayload(
                        text: copy.text,
                        wasTruncated: copy.wasTruncated
                    )
                case .path:
                    payload = JSONSidebarPasteboardPayload(
                        text: try index.jsonPath(for: pathSegments ?? []),
                        wasTruncated: false
                    )
                }
                result = .success(payload)
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { [weak self] in
                self?.finishJSONCopy(
                    result,
                    request: request,
                    identifier: identifier,
                    node: node,
                    index: index
                )
            }
        }
    }

    private func finishJSONCopy(
        _ result: Result<JSONSidebarPasteboardPayload, Error>,
        request: JSONSidebarCopyRequest,
        identifier: String,
        node: JSONStructureNode,
        index: JSONStructureIndex
    ) {
        guard presentationMode == .view,
              session.syntaxFileType == .json,
              !sidebarShowsSearchResults,
              jsonStructureController.index === index,
              index.isOpen,
              jsonPresentedGeneration == index.generation,
              jsonNodeBySidebarIdentifier[identifier] == node else {
            statusBar.setState("JSON changed before the copy completed.", busy: false, isError: true)
            return
        }

        switch result {
        case let .failure(error):
            statusBar.setState(
                "Could not copy \(request.subject): \(error.localizedDescription)",
                busy: false,
                isError: true
            )
        case let .success(payload):
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(payload.text, forType: .string) else {
                statusBar.setState("Could not write \(request.subject) to the clipboard.", busy: false, isError: true)
                return
            }
            if payload.wasTruncated {
                statusBar.setState(
                    "Copied \(request.subject) preview  ·  \(payload.text.count.formatted()) characters  ·  truncated",
                    busy: false
                )
            } else {
                statusBar.setState("Copied \(request.subject)", busy: false)
            }
        }
    }

    private func jsonPathSegments(for identifier: String) -> [JSONStructurePathSegment]? {
        guard let rootIdentifier = jsonRootSidebarIdentifier,
              jsonNodeBySidebarIdentifier[identifier] != nil else { return nil }
        var currentIdentifier = identifier
        var reversed: [JSONStructurePathSegment] = []
        var visited: Set<String> = []
        while currentIdentifier != rootIdentifier {
            guard visited.insert(currentIdentifier).inserted,
                  visited.count <= 4_096,
                  let parentIdentifier = jsonParentIdentifierBySidebarIdentifier[currentIdentifier],
                  jsonNodeBySidebarIdentifier[parentIdentifier] != nil,
                  let component = jsonPathComponentBySidebarIdentifier[currentIdentifier] else {
                return nil
            }
            switch component {
            case let .member(node): reversed.append(.member(node))
            case let .index(ordinal): reversed.append(.index(ordinal))
            case .unavailable: return nil
            }
            currentIdentifier = parentIdentifier
        }
        return Array(reversed.reversed())
    }

    private func makeJSONSidebarNode(
        _ node: JSONStructureNode,
        preview: JSONStructureNodePreview?,
        ordinal: Int64,
        parent: JSONStructureNode,
        index: JSONStructureIndex
    ) -> StructureSidebarNode {
        let title: String
        if let key = preview?.key {
            let cleanKey = sanitizedJSONText(key, maximumCharacters: 120)
            title = cleanKey.isEmpty ? "“”" : cleanKey + ((preview?.keyWasTruncated ?? false) ? "…" : "")
        } else if parent.kind == .array {
            title = "[\(ordinal.formatted())]"
        } else if parent.kind == .document {
            title = (parent.childCount ?? 0) == 1 ? "Root value" : "Root value \((ordinal + 1).formatted())"
        } else {
            title = "Member \((ordinal + 1).formatted())"
        }

        var subtitle = jsonSubtitle(for: node, preview: preview)
        if node.containsErrors { subtitle += "  ·  contains syntax issues" }
        if !node.isComplete { subtitle += "  ·  incomplete" }
        return StructureSidebarNode(
            identifier: jsonSidebarIdentifier(for: node, index: index),
            title: title,
            subtitle: subtitle,
            range: node.byteRange,
            kind: syntaxFoldKind(for: node.kind),
            childState: node.kind.isContainer && (node.childCount ?? 0) > 0 ? .unloaded : .leaf
        )
    }

    private func jsonSubtitle(
        for node: JSONStructureNode,
        preview: JSONStructureNodePreview?
    ) -> String {
        let value = sanitizedJSONText(preview?.value ?? "", maximumCharacters: 180)
        let suffix = (preview?.valueWasTruncated ?? false) ? "…" : ""
        switch node.kind {
        case .document: return value.isEmpty ? "JSON document" : value
        case .object: return value.isEmpty ? "Object" : value
        case .array: return value.isEmpty ? "Array" : value
        case .string: return "String  ·  “\(value)\(suffix)”"
        case .number: return "Number  ·  \(value)\(suffix)"
        case .boolean: return "Boolean  ·  \(value)\(suffix)"
        case .null: return "Null"
        case .invalid: return "Invalid JSON  ·  \(value)\(suffix)"
        }
    }

    private func sanitizedJSONText(_ text: String, maximumCharacters: Int) -> String {
        let flattened = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        return String(flattened.prefix(maximumCharacters))
    }

    private func syntaxFoldKind(for kind: JSONStructureNodeKind) -> SyntaxFoldKind {
        switch kind {
        case .document, .object: return .object
        case .array: return .array
        case .string, .number, .boolean, .null, .invalid: return .scalar
        }
    }

    private func revealPendingRangeInEditor(_ range: Range<Int64>) {
        // Huge containers cannot be selected wholesale inside a bounded byte
        // window. Their exact start remains the edit target; bounded values are
        // selected in full.
        let maximumSelection = Int64(VirtualTextEditorView.maximumViewportBytes / 2)
        let target = range.count <= maximumSelection
            ? range
            : range.lowerBound..<range.lowerBound
        editorView.scrollTo(byteRange: target)
    }

    /// Installs a format-specific renderer in the primary split pane. Passing
    /// the editor restores the default byte-window editing surface.
    func installPrimaryContentView(_ contentView: NSView) {
        guard installedPrimaryContentView !== contentView else { return }
        (installedPrimaryContentView as? MarkdownPreviewView)?.deactivate()
        (installedPrimaryContentView as? CSVTableView)?.deactivate()
        primaryContentHost.subviews.forEach { $0.removeFromSuperview() }
        contentView.translatesAutoresizingMaskIntoConstraints = false
        primaryContentHost.addSubview(contentView)
        installedPrimaryContentView = contentView
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: primaryContentHost.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: primaryContentHost.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: primaryContentHost.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: primaryContentHost.bottomAnchor)
        ])
    }

    func restoreEditorAsPrimaryContent() {
        guard editorView.superview !== primaryContentHost else { return }
        installPrimaryContentView(editorView)
    }

    var isStructureSidebarVisible: Bool { structureIsVisible }

    var currentStructureSidebarWidth: CGFloat {
        structureIsVisible && !primaryContentHost.isHidden
            ? structureSidebar.frame.width
            : preferredStructureWidth
    }

    func setStructureSidebarWidth(_ width: CGFloat) {
        preferredStructureWidth = min(560, max(260, width))
        guard structureIsVisible, !primaryContentHost.isHidden else { return }
        positionStructureDivider()
    }

    func showStructureLoading(_ state: StructureSidebarLoadingState) {
        structureSidebar.showLoading(state)
        if presentationMode == .view {
            showStructureFullWorkspace()
        } else {
            setStructureVisible(true)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(undoDocumentEdit(_:)): session.canUndo
        case #selector(redoDocumentEdit(_:)): session.canRedo
        case #selector(findNext(_:)), #selector(findPrevious(_:)): !session.searchQuery.isEmpty
        case #selector(toggleStructure(_:)): canToggleStructure
        default: true
        }
    }

    private func setPresentationMode(
        _ mode: DocumentPresentationMode,
        notifyIntegration: Bool
    ) {
        guard mode != presentationMode else {
            header.presentationMode = mode
            if notifyIntegration { presentationModeDidChange?(mode) }
            return
        }

        if presentationMode == .view,
           mode != .view,
           (installedPrimaryContentView as? CSVTableView)?.commitPendingEdit() == false {
            header.presentationMode = presentationMode
            return
        }

        let previousMode = presentationMode
        if mode == .view { editModeStructureWasVisible = structureIsVisible }
        presentationMode = mode
        header.presentationMode = mode

        switch mode {
        case .edit:
            if previousMode == .view, session.syntaxFileType == .json {
                jsonRebuildWork?.cancel()
                jsonRebuildWork = nil
                if jsonStructureController.isBuilding {
                    // A whole-file scan must never keep consuming CPU, I/O,
                    // and temporary disk after the user returns to Edit. A
                    // completed unchanged index remains reusable; any edit
                    // invalidates it through the normal revision callback.
                    jsonStructureController.reset()
                    jsonKnownRevision = nil
                    resetJSONSidebarState()
                }
            }
            restoreEditorAsPrimaryContent()
            // The editor is deliberately inactive while a rendered/table
            // View is installed. Refresh its bounded snapshot and byte map so
            // a CSV cell edit or structure-driven change cannot leave stale
            // local-to-global coordinates when Edit becomes active again.
            editorView.reloadPreservingSelection()
            primaryContentHost.isHidden = false
            structureSidebar.presentation = .sidebar
            setStructureVisible(editModeStructureWasVisible)
            let viewport = lastEditorViewport.isEmpty
                ? 0..<min(Int64(VirtualTextEditorView.maximumViewportBytes), session.byteCount)
                : lastEditorViewport
            statusBar.updateByteWindow(viewport, totalByteCount: session.byteCount)
            statusBar.setState("Editing a bounded byte window", busy: false)
            view.window?.makeFirstResponder(editorView)
            if let target = pendingEditRevealRange {
                pendingEditRevealRange = nil
                revealPendingRangeInEditor(target)
            }
        case .view:
            if session.syntaxFileType == .json ||
                session.syntaxFileType == .xml ||
                session.syntaxFileType == .yaml {
                showStructureFullWorkspace()
                statusBar.showFileBackedView(totalByteCount: session.byteCount)
                if session.syntaxFileType == .json {
                    startJSONStructureIfNeeded()
                }
            } else if session.syntaxFileType == .markdown {
                prepareMarkdownPreview()
                primaryContentHost.isHidden = false
                structureSidebar.presentation = .sidebar
                setStructureVisible(false)
                statusBar.showFileBackedView(totalByteCount: session.byteCount)
                view.window?.makeFirstResponder(markdownPreviewView)
            } else if session.syntaxFileType == .csv {
                prepareCSVTable()
                primaryContentHost.isHidden = false
                structureSidebar.presentation = .sidebar
                setStructureVisible(false)
                statusBar.showFileBackedView(totalByteCount: session.byteCount)
                view.window?.makeFirstResponder(csvTableView)
            } else {
                restoreEditorAsPrimaryContent()
                primaryContentHost.isHidden = false
                structureSidebar.presentation = .sidebar
                setStructureVisible(false)
                statusBar.showFileBackedView(totalByteCount: session.byteCount)
            }
        }
        if notifyIntegration { presentationModeDidChange?(mode) }
    }

    @discardableResult
    func commitPendingPresentationEdit() -> Bool {
        (installedPrimaryContentView as? CSVTableView)?.commitPendingEdit() ?? true
    }

    private func prepareMarkdownPreview() {
        installPrimaryContentView(markdownPreviewView)
        if markdownPreviewView.editorDelegate !== session {
            markdownPreviewView.editorDelegate = session
        } else {
            markdownPreviewView.reloadDocument()
        }
    }

    private func prepareCSVTable() {
        installPrimaryContentView(csvTableView)
        if csvTableView.editorDelegate !== session {
            csvTableView.editorDelegate = session
        } else {
            csvTableView.reloadDocument()
        }
    }

    private func showStructureFullWorkspace() {
        structureSidebar.presentation = .fullWorkspace
        primaryContentHost.isHidden = true
        structureSidebar.isHidden = false
        structureIsVisible = true
        header.setStructureVisible(true)
        workspaceSplitView.adjustSubviews()
    }

    private func setStructureVisible(_ visible: Bool) {
        guard !primaryContentHost.isHidden else {
            structureIsVisible = true
            structureSidebar.isHidden = false
            header.setStructureVisible(true)
            return
        }
        structureIsVisible = visible
        header.setStructureVisible(visible)
        structureSidebar.presentation = .sidebar

        if visible {
            structureSidebar.isHidden = false
            workspaceSplitView.adjustSubviews()
            positionStructureDivider()
        } else {
            if structureSidebar.frame.width >= 220 {
                preferredStructureWidth = min(560, max(260, structureSidebar.frame.width))
            }
            structureSidebar.isHidden = true
            workspaceSplitView.adjustSubviews()
        }
    }

    private func positionStructureDivider() {
        // Capture the requested width before laying out. AppKit may deliver a
        // resize notification during `layoutSubtreeIfNeeded`; that notification
        // reflects the old divider position and must not overwrite this request.
        let requestedWidth = preferredStructureWidth
        view.layoutSubtreeIfNeeded()
        let available = workspaceSplitView.bounds.width
        guard available > 0, workspaceSplitView.subviews.count > 1 else { return }
        let maximum = max(260, min(560, available - 420))
        let width = min(maximum, max(260, requestedWidth))
        workspaceSplitView.setPosition(
            max(0, available - width - workspaceSplitView.dividerThickness),
            ofDividerAt: 0
        )
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainSplitPosition proposedPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard dividerIndex == 0, !primaryContentHost.isHidden, !structureSidebar.isHidden else {
            return proposedPosition
        }
        let available = splitView.bounds.width
        let minimumSidebar: CGFloat = 260
        let maximumSidebar = max(minimumSidebar, min(560, available - 420))
        let proposedSidebar = available - proposedPosition - splitView.dividerThickness
        let constrained = min(maximumSidebar, max(minimumSidebar, proposedSidebar))
        return available - constrained - splitView.dividerThickness
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
        subview === structureSidebar
    }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        // Window resizing should give/take space from the primary content while
        // preserving the user's chosen outline width. Direct divider dragging
        // remains unconstrained between the minimum and maximum bounds above.
        view === primaryContentHost
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard structureIsVisible,
              !primaryContentHost.isHidden,
              !structureSidebar.isHidden,
              structureSidebar.frame.width >= 220 else { return }
        preferredStructureWidth = min(560, max(260, structureSidebar.frame.width))
        UserDefaults.standard.set(
            Double(preferredStructureWidth),
            forKey: "LighTxt.StructureSidebarWidth"
        )
    }
}

private final class LighTxtWorkspaceSplitView: NSSplitView {
    override var dividerColor: NSColor {
        LighTxtTheme.resolved(LighTxtTheme.separator, for: effectiveAppearance)
    }
}
