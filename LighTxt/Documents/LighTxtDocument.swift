import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class LighTxtDocumentController: NSDocumentController {
    private(set) static weak var active: LighTxtDocumentController?
    private var homeWindowController: LighTxtHomeWindowController?
    private var sessionRecentDocumentURLs: [URL] = []

    override init() {
        super.init()
        Self.active = self
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        Self.active = self
    }

    override var defaultType: String? { "public.plain-text" }

    override func newDocument(_ sender: Any?) {
        hideHomeWindow()
        let document = LighTxtDocument()
        addDocument(document)
        document.makeWindowControllers()
        document.showWindows()
    }

    override func makeUntitledDocument(ofType typeName: String) throws -> NSDocument {
        LighTxtDocument()
    }

    override func makeDocument(withContentsOf url: URL, ofType typeName: String) throws -> NSDocument {
        return try LighTxtDocument(contentsOf: url, ofType: typeName)
    }

    override func openDocument(
        withContentsOf url: URL,
        display displayDocument: Bool,
        completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void
    ) {
        if displayDocument, let shell = activeWindowController {
            shell.navigateToDocument(at: url) { document, error in
                if let document {
                    document.showWindows()
                    document.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
                }
                completionHandler(document, false, error)
            }
            return
        }
        performOpenDocument(
            withContentsOf: url,
            display: displayDocument,
            completionHandler: completionHandler
        )
    }

    private func performOpenDocument(
        withContentsOf url: URL,
        display displayDocument: Bool,
        completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void
    ) {
        super.openDocument(withContentsOf: url, display: displayDocument) { document, alreadyOpen, error in
            if displayDocument, let document, error == nil {
                self.hideHomeWindow()
                self.noteNewRecentDocumentURL(url)
                document.showWindows()
                document.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
            }
            completionHandler(document, alreadyOpen, error)
        }
    }

    private var activeWindowController: LighTxtWindowController? {
        if let key = NSApp.keyWindow?.windowController as? LighTxtWindowController {
            return key
        }
        if let current = currentDocument as? LighTxtDocument,
           let controller = current.windowControllers.first as? LighTxtWindowController {
            return controller
        }
        return documents.lazy.compactMap { document in
            document.windowControllers.first as? LighTxtWindowController
        }.first
    }

    var hasVisibleDocumentWindow: Bool {
        documents.contains { document in
            document.windowControllers.contains { $0.window?.isVisible == true }
        }
    }

    func showHomeWindow() {
        guard !hasVisibleDocumentWindow else {
            hideHomeWindow()
            return
        }
        let controller: LighTxtHomeWindowController
        if let homeWindowController {
            controller = homeWindowController
        } else {
            controller = LighTxtHomeWindowController()
            controller.onOpenFromDisk = { [weak self] in
                self?.openLighTxtDocument(nil)
            }
            controller.onOpenRecent = { [weak self] url in
                self?.openRecentDocument(at: url)
            }
            homeWindowController = controller
        }
        controller.updateRecentFiles(homeRecentDocumentURLs)
        controller.showWindow(nil)
    }

    func hideHomeWindow() {
        homeWindowController?.window?.orderOut(nil)
    }

    func reopenApplication() {
        if hasVisibleDocumentWindow {
            hideHomeWindow()
            documents.forEach { document in
                if document.windowControllers.isEmpty { document.makeWindowControllers() }
                document.showWindows()
            }
            documents.first?.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
        } else {
            showHomeWindow()
        }
    }

    func documentWindowDidClose() {
        // NSDocument removes the closing window/controller after the delegate
        // callback. Defer the empty-state decision to the next run-loop turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.hasVisibleDocumentWindow else { return }
            self.showHomeWindow()
        }
    }

    override func noteNewRecentDocumentURL(_ url: URL) {
        super.noteNewRecentDocumentURL(url)
        let standardized = url.standardizedFileURL
        sessionRecentDocumentURLs.removeAll { $0.standardizedFileURL == standardized }
        sessionRecentDocumentURLs.insert(standardized, at: 0)
        if sessionRecentDocumentURLs.count > 12 {
            sessionRecentDocumentURLs.removeLast(sessionRecentDocumentURLs.count - 12)
        }
        homeWindowController?.updateRecentFiles(homeRecentDocumentURLs)
    }

    override func clearRecentDocuments(_ sender: Any?) {
        super.clearRecentDocuments(sender)
        sessionRecentDocumentURLs.removeAll()
        homeWindowController?.updateRecentFiles([])
    }

    private var homeRecentDocumentURLs: [URL] {
        var seen = Set<URL>()
        return (sessionRecentDocumentURLs + recentDocumentURLs)
            .map(\.standardizedFileURL)
            .filter { seen.insert($0).inserted }
    }

    override func typeForContents(of url: URL) throws -> String {
        switch SyntaxFileTypeDetector.detect(url: url) {
        case .json: "public.json"
        case .xml: "public.xml"
        case .csv: "public.comma-separated-values-text"
        case .markdown: "net.daringfireball.markdown"
        case .yaml: "public.yaml"
        case .sql: "public.sql"
        case .parquet: "org.apache.parquet"
        case .plainText: "public.plain-text"
        }
    }

    @objc func openLighTxtDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Open a File"
        panel.message = "Choose TXT, SCRIPT, JSON, Markdown, SQL, XML, CSV, YAML, or Parquet files."
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = Self.supportedFilenameExtensions.compactMap {
            UTType(filenameExtension: $0)
        }

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard response == .OK, let self, let url = panel?.url else { return }
            self.openDocument(withContentsOf: url, display: true) { _, _, error in
                if let error, (error as? CocoaError)?.code != .userCancelled {
                    NSApp.presentError(error)
                }
            }
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    @objc func openRecentLighTxtDocument(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        openRecentDocument(at: url)
    }

    private func openRecentDocument(at url: URL) {
        openDocument(withContentsOf: url, display: true) { _, _, error in
            guard let error else { return }
            if (error as? CocoaError)?.code == .userCancelled { return }
            let cocoaCode = (error as? CocoaError)?.code
            if cocoaCode == .fileNoSuchFile || cocoaCode == .fileReadNoSuchFile {
                self.homeWindowController?.showUnavailableFile(url)
            } else if self.homeWindowController?.window?.isVisible == true {
                self.homeWindowController?.showOpenError(error)
            } else {
                NSApp.presentError(error)
            }
        }
    }

    @objc func saveCurrentLighTxtDocument(_ sender: Any?) {
        guard let document = currentDocument as? LighTxtDocument,
              !document.session.isReadOnly,
              !document.isSaving,
              !document.session.isBulkEditing else {
            NSSound.beep()
            return
        }
        guard activeEditorController?.commitPendingPresentationEdit() ?? true else { return }
        document.save(sender)
    }

    @objc func saveAsCurrentLighTxtDocument(_ sender: Any?) {
        guard let document = currentDocument as? LighTxtDocument,
              !document.session.isReadOnly,
              !document.isSaving,
              !document.session.isBulkEditing else {
            NSSound.beep()
            return
        }
        guard activeEditorController?.commitPendingPresentationEdit() ?? true else { return }
        document.saveAs(sender)
    }

    @objc func saveCopyOfCurrentLighTxtDocument(_ sender: Any?) {
        guard let document = currentDocument as? LighTxtDocument,
              !document.isSaving,
              !document.session.isBulkEditing else {
            NSSound.beep()
            return
        }
        guard activeEditorController?.commitPendingPresentationEdit() ?? true else { return }
        document.saveACopy(sender)
    }

    @objc func duplicateCurrentLighTxtDocument(_ sender: Any?) {
        guard let document = currentDocument as? LighTxtDocument,
              !document.session.isReadOnly,
              !document.isSaving,
              !document.session.isBulkEditing else {
            NSSound.beep()
            return
        }
        guard activeEditorController?.commitPendingPresentationEdit() ?? true else { return }
        document.duplicateLighTxtDocument(sender)
    }

    @objc func undoCurrentLighTxtDocument(_ sender: Any?) {
        activeEditorController?.undoDocumentEdit(sender)
    }

    @objc func redoCurrentLighTxtDocument(_ sender: Any?) {
        activeEditorController?.redoDocumentEdit(sender)
    }

    @objc func showFindForCurrentLighTxtDocument(_ sender: Any?) {
        activeEditorController?.showFindPanel(sender)
    }

    @objc func findNextInCurrentLighTxtDocument(_ sender: Any?) {
        activeEditorController?.findNext(sender)
    }

    @objc func findPreviousInCurrentLighTxtDocument(_ sender: Any?) {
        activeEditorController?.findPrevious(sender)
    }

    @objc func useSelectionForFindInCurrentLighTxtDocument(_ sender: Any?) {
        activeEditorController?.useSelectionForFind(sender)
    }

    @objc func showGoToLineForCurrentLighTxtDocument(_ sender: Any?) {
        activeEditorController?.showGoToLine(sender)
    }

    @objc func increaseFontSizeInCurrentLighTxtDocument(_ sender: Any?) {
        activeEditorController?.increaseFontSize(sender)
    }

    @objc func decreaseFontSizeInCurrentLighTxtDocument(_ sender: Any?) {
        activeEditorController?.decreaseFontSize(sender)
    }

    @objc func resetFontSizeInCurrentLighTxtDocument(_ sender: Any?) {
        activeEditorController?.resetFontSize(sender)
    }

    @objc func toggleStructureForCurrentLighTxtDocument(_ sender: Any?) {
        activeEditorController?.toggleStructure(sender)
    }

    @objc func showHelpForCurrentLighTxtDocument(_ sender: Any?) {
        if let editor = activeEditorController {
            editor.showLighTxtHelp(sender)
            return
        }
        let alert = NSAlert()
        alert.messageText = "LighTxt"
        alert.informativeText = "Open TXT, SCRIPT, JSON, Markdown, SQL, XML, CSV, YAML, or Parquet. Text stays file-backed, and Parquet opens in a read-only table."
        alert.addButton(withTitle: "Done")
        alert.runModal()
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let action = menuItem.action
        let document = currentDocument as? LighTxtDocument
        let editor = activeEditorController
        switch action {
        case #selector(openLighTxtDocument(_:)):
            return true
        case #selector(saveCurrentLighTxtDocument(_:)),
             #selector(saveAsCurrentLighTxtDocument(_:)):
            return document != nil
                && document?.session.isReadOnly == false
                && document?.isSaving == false
                && document?.session.isBulkEditing == false
        case #selector(saveCopyOfCurrentLighTxtDocument(_:)):
            return document != nil
                && document?.isSaving == false
                && document?.session.isBulkEditing == false
        case #selector(duplicateCurrentLighTxtDocument(_:)):
            return document != nil
                && document?.session.isReadOnly == false
                && document?.isSaving == false
                && document?.session.isBulkEditing == false
        case #selector(undoCurrentLighTxtDocument(_:)):
            return document?.session.canUndo == true && document?.session.isBulkEditing == false
        case #selector(redoCurrentLighTxtDocument(_:)):
            return document?.session.canRedo == true && document?.session.isBulkEditing == false
        case #selector(findNextInCurrentLighTxtDocument(_:)),
             #selector(findPreviousInCurrentLighTxtDocument(_:)):
            return editor != nil
                && document?.session.isReadOnly == false
                && document?.session.searchQuery.isEmpty == false
        case #selector(showFindForCurrentLighTxtDocument(_:)),
             #selector(useSelectionForFindInCurrentLighTxtDocument(_:)),
             #selector(showGoToLineForCurrentLighTxtDocument(_:)),
             #selector(increaseFontSizeInCurrentLighTxtDocument(_:)),
             #selector(decreaseFontSizeInCurrentLighTxtDocument(_:)),
             #selector(resetFontSizeInCurrentLighTxtDocument(_:)):
            return editor != nil && document?.session.isReadOnly == false
        case #selector(toggleStructureForCurrentLighTxtDocument(_:)):
            return editor?.canToggleStructure == true
        case #selector(showHelpForCurrentLighTxtDocument(_:)):
            return true
        default:
            return super.validateMenuItem(menuItem)
        }
    }

    private var activeEditorController: LighTxtEditorViewController? {
        if let keyEditor = NSApp.keyWindow?.contentViewController as? LighTxtEditorViewController {
            return keyEditor
        }
        guard let document = currentDocument as? LighTxtDocument else { return nil }
        return document.windowControllers.lazy.compactMap {
            $0.window?.contentViewController as? LighTxtEditorViewController
        }.first
    }

    private static let supportedFilenameExtensions = [
        "txt", "text", "log", "script", "json", "md", "markdown", "sql", "xml", "csv", "yml", "yaml", "parquet",
    ]

}

/// Owns any explicit security-scope reference for the lifetime of a document.
/// Open-panel URLs and recent-document bookmarks can lose path access as soon
/// as their originating callback returns unless the scope remains active.
private nonisolated final class DocumentSecurityScope: @unchecked Sendable {
    private let lock = NSLock()
    private var accessedURL: URL?

    func adopt(_ url: URL, accessWasStarted: Bool) {
        lock.lock()
        let previous = accessedURL
        let shouldStopPrevious: Bool
        if accessWasStarted {
            accessedURL = url
            shouldStopPrevious = previous != nil
        } else if previous?.standardizedFileURL == url.standardizedFileURL {
            shouldStopPrevious = false
        } else {
            accessedURL = nil
            shouldStopPrevious = previous != nil
        }
        lock.unlock()

        if shouldStopPrevious, let previous {
            previous.stopAccessingSecurityScopedResource()
        }
    }

    func stop() {
        lock.lock()
        let previous = accessedURL
        accessedURL = nil
        lock.unlock()
        previous?.stopAccessingSecurityScopedResource()
    }
}

@objc(LighTxtDocument)
final class LighTxtDocument: NSDocument {
    private enum SaveRoute: Equatable, Sendable {
        case inPlace
        case saveAs
        case copy
    }

    private(set) var session: LighTxtDocumentSession
    private var saveCancellation: CancellationToken?
    private(set) var isSaving = false
    private let securityScope = DocumentSecurityScope()

    override init() {
        session = LighTxtDocumentSession(memoryOnlyEmptyDocument: ())
        super.init()
        fileType = "public.plain-text"
        hasUndoManager = false
    }

    override class var autosavesInPlace: Bool { false }
    override class var preservesVersions: Bool { false }

    override func makeWindowControllers() {
        let controller = LighTxtWindowController(document: self)
        addWindowController(controller)
    }

    override func read(from url: URL, ofType typeName: String) throws {
        let accessedSecurityScope = url.startAccessingSecurityScopedResource()
        let replacement: LighTxtDocumentSession
        do {
            replacement = try MainActor.assumeIsolated {
                try LighTxtDocumentSession(opening: url)
            }
        } catch {
            if accessedSecurityScope { url.stopAccessingSecurityScopedResource() }
            throw error
        }
        MainActor.assumeIsolated {
            session.prepareForClose()
            session = replacement
            securityScope.adopt(url, accessWasStarted: accessedSecurityScope)
            fileType = typeName
        }
    }

    /// Replaces the current file while preserving the NSDocument, its window,
    /// and its single-document window shell. The caller must first complete AppKit's
    /// `canClose` review. Construction is transactional: the old engine remains
    /// alive until the new file has opened successfully.
    @MainActor
    func replaceContentsForNavigation(with url: URL, ofType typeName: String) throws {
        let target = url.standardizedFileURL
        let accessedSecurityScope = target.startAccessingSecurityScopedResource()
        let replacement: LighTxtDocumentSession
        do {
            replacement = try LighTxtDocumentSession(opening: target)
        } catch {
            if accessedSecurityScope { target.stopAccessingSecurityScopedResource() }
            throw error
        }

        let previous = session
        session = replacement
        securityScope.adopt(target, accessWasStarted: accessedSecurityScope)
        fileURL = target
        fileType = typeName
        // NSDocument uses this token to detect external edits before saving.
        // Carrying the previous file's date into a same-window replacement
        // incorrectly produces a second "changed by another application"
        // prompt even though the new source has not changed.
        fileModificationDate = try? target.resourceValues(
            forKeys: [.contentModificationDateKey]
        ).contentModificationDate
        updateChangeCount(.changeCleared)
        undoManager?.removeAllActions()
        previous.prepareForClose()
    }

    override func write(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType,
        originalContentsURL absoluteOriginalContentsURL: URL?
    ) throws {
        let engine = MainActor.assumeIsolated { session.engine }
        let route = Self.route(for: saveOperation)
        let isReadOnly = MainActor.assumeIsolated { session.isReadOnly }
        if isReadOnly, route != .copy {
            throw LighTxtSessionError.readOnlyDocument
        }
        if route == .saveAs,
           SyntaxFileTypeDetector.knownType(forPathExtension: url.pathExtension) == .parquet {
            throw LighTxtSessionError.parquetExportUnsupported
        }
        switch route {
        case .copy:
            try engine.saveCopy(to: url)
        case .saveAs:
            try engine.saveAs(url)
        case .inPlace:
            try engine.save(validatingCurrentDocumentURL: url)
        }
    }

    override func save(
        to url: URL,
        ofType typeName: String,
        for saveOperation: NSDocument.SaveOperationType,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let requestedRoute = Self.route(for: saveOperation)
        guard !session.isReadOnly || requestedRoute == .copy else {
            completionHandler(LighTxtSessionError.readOnlyDocument)
            return
        }
        if requestedRoute == .saveAs,
           SyntaxFileTypeDetector.knownType(forPathExtension: url.pathExtension) == .parquet {
            completionHandler(LighTxtSessionError.parquetExportUnsupported)
            return
        }
        guard !session.isBulkEditing else {
            session.cancelBulkOperation()
            completionHandler(LighTxtSessionError.bulkOperationInProgress)
            return
        }
        guard !isSaving else {
            completionHandler(LighTxtSessionError.saveInProgress)
            return
        }
        let engine = session.engine
        let saveRoute = requestedRoute
        if saveRoute == .inPlace {
            do {
                try engine.validateCurrentDocumentURL(url)
            } catch {
                session.callbacks.statusChanged?(error.localizedDescription, false, true)
                completionHandler(error)
                return
            }
        }
        let cancellation = CancellationToken()
        saveCancellation = cancellation
        isSaving = true
        let byteCount = engine.byteCount
        LighTxtSignpost.begin("DocumentSave", bytes: byteCount)
        NotificationCenter.default.post(
            name: .lighTxtSaveProgress,
            object: self,
            userInfo: ["progress": 0.0]
        )

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let accessedSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if accessedSecurityScope { url.stopAccessingSecurityScopedResource() }
            }

            let progress: (SaveProgress) -> Void = { update in
                guard !cancellation.isCancelled else { return }
                DispatchQueue.main.async {
                    guard let self else { return }
                    NotificationCenter.default.post(
                        name: .lighTxtSaveProgress,
                        object: self,
                        userInfo: ["progress": update.fractionCompleted]
                    )
                }
            }

            var coordinationError: NSError?
            var coordinatedResult: Result<Void, Error>?
            let coordinator = NSFileCoordinator(filePresenter: nil)
            coordinator.coordinate(
                writingItemAt: url,
                options: .forReplacing,
                error: &coordinationError
            ) { coordinatedURL in
                coordinatedResult = Result {
                    switch saveRoute {
                    case .copy:
                        try engine.saveCopy(
                            to: coordinatedURL,
                            cancellation: cancellation,
                            progress: progress
                        )
                    case .saveAs:
                        try engine.saveAs(
                            coordinatedURL,
                            cancellation: cancellation,
                            progress: progress
                        )
                    case .inPlace:
                        try engine.save(
                            validatingCurrentDocumentURL: coordinatedURL,
                            cancellation: cancellation,
                            progress: progress
                        )
                    }
                }
            }

            let result: Result<Void, Error>
            if let coordinationError {
                result = .failure(coordinationError)
            } else {
                result = coordinatedResult ?? .failure(
                    LighTxtCoreError.io(operation: "coordinate save", path: url.path, code: EIO)
                )
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    switch result {
                    case .success: completionHandler(nil)
                    case .failure(let error): completionHandler(error)
                    }
                    return
                }
                if self.saveCancellation === cancellation {
                    self.saveCancellation = nil
                    self.isSaving = false
                }
                switch result {
                case .success:
                    switch saveRoute {
                    case .saveAs:
                        let savedURL = engine.documentURL
                            ?? url.standardizedFileURL.resolvingSymlinksInPath()
                        self.fileURL = savedURL
                        self.fileType = typeName
                        let accessedSecurityScope = savedURL.startAccessingSecurityScopedResource()
                        self.securityScope.adopt(
                            savedURL,
                            accessWasStarted: accessedSecurityScope
                        )
                        self.session.adoptSavedURL(savedURL)
                        LighTxtDocumentController.active?.noteNewRecentDocumentURL(savedURL)
                    case .inPlace:
                        self.session.didSaveInPlace()
                    case .copy:
                        break
                    }
                    if saveRoute != .copy,
                       !self.session.isEdited {
                        // The engine permits editing while a large snapshot is
                        // streaming. Preserve dirty state when a newer root won.
                        self.updateChangeCount(.changeCleared)
                    }
                    LighTxtSignpost.end("DocumentSave", bytes: byteCount)
                    NotificationCenter.default.post(
                        name: .lighTxtSaveProgress,
                        object: self,
                        userInfo: [
                            "progress": 1.0,
                            "sourceRebased": saveRoute != .copy,
                        ]
                    )
                    completionHandler(nil)
                case .failure(let error):
                    LighTxtSignpost.end("DocumentSave", bytes: 0)
                    self.session.callbacks.statusChanged?(error.localizedDescription, false, true)
                    // A terminal progress event prevents a queued initial 0%
                    // update from leaving the status bar looking busy after
                    // AppKit presents the save error. The document remains
                    // dirty and can be reviewed again or saved elsewhere.
                    NotificationCenter.default.post(
                        name: .lighTxtSaveProgress,
                        object: self,
                        userInfo: [
                            "progress": 1.0,
                            "failureDescription": error.localizedDescription,
                        ]
                    )
                    completionHandler(error)
                }
            }
        }
    }

    @objc func saveACopy(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.title = "Save a Copy"
        panel.nameFieldStringValue = copyName()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let self, let url = panel.url else { return }
            self.save(to: url, ofType: self.fileType ?? "public.plain-text", for: .saveToOperation) { error in
                if let error { NSApp.presentError(error) }
            }
        }
        if let window = windowControllers.first?.window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    @objc func duplicateLighTxtDocument(_ sender: Any?) {
        do {
            let duplicateURL = try Self.makeScratchFile(
                pathExtension: fileURL?.pathExtension ?? session.syntaxFileType.preferredPathExtension
            )
            save(to: duplicateURL, ofType: fileType ?? "public.plain-text", for: .saveToOperation) { error in
                if let error {
                    try? FileManager.default.removeItem(at: duplicateURL)
                    NSApp.presentError(error)
                    return
                }
                do {
                    let duplicate = try LighTxtDocument(contentsOf: duplicateURL, ofType: self.fileType ?? "public.plain-text")
                    duplicate.session.markAsScratchBacking()
                    duplicate.fileURL = nil
                    duplicate.updateChangeCount(.changeDone)
                    LighTxtDocumentController.active?.addDocument(duplicate)
                    duplicate.makeWindowControllers()
                    duplicate.showWindows()
                } catch {
                    try? FileManager.default.removeItem(at: duplicateURL)
                    NSApp.presentError(error)
                }
            }
        } catch {
            NSApp.presentError(error)
        }
    }

    override func close() {
        saveCancellation?.cancel()
        session.prepareForClose()
        securityScope.stop()
        super.close()
    }

    private func copyName() -> String {
        let current = fileURL?.lastPathComponent ?? "Untitled.\(session.syntaxFileType.preferredPathExtension)"
        let url = URL(fileURLWithPath: current)
        return "\(url.deletingPathExtension().lastPathComponent) copy.\(url.pathExtension)"
    }

    /// Save semantics are selected solely by AppKit's operation type. In
    /// particular, URL mismatch is never interpreted as authorization to adopt
    /// a destination. Autosave-elsewhere has Save-a-Copy semantics; all other
    /// non-explicit operations fail closed through the validated in-place path.
    private static func route(for operation: NSDocument.SaveOperationType) -> SaveRoute {
        if operation == .saveAsOperation || operation == .autosaveAsOperation {
            return .saveAs
        }
        if operation == .saveToOperation || operation == .autosaveElsewhereOperation {
            return .copy
        }
        return .inPlace
    }

    private static func makeScratchFile(pathExtension: String = "txt") throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LighTxt", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory
            .appendingPathComponent("Untitled-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
        guard FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else {
            throw LighTxtCoreError.io(operation: "create", path: url.path, code: EIO)
        }
        return url
    }
}

extension Notification.Name {
    static let lighTxtSaveProgress = Notification.Name("LighTxt.saveProgress")
}
