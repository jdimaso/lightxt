import AppKit
import Foundation
import UniformTypeIdentifiers

@MainActor
final class LighTxtDocumentController: NSDocumentController, NSMenuDelegate {
    private static let lastTaskDefaultsKey = "LighTxt.LastDocumentTask.v1"
    private(set) static weak var active: LighTxtDocumentController?
    private var homeWindowController: LighTxtHomeWindowController?
    private var sessionRecentDocumentURLs: [URL] = []
    private struct PendingOpen {
        let options: DocumentOpenOptions
        var waiters: [(LighTxtDocument?, Error?) -> Void] = []
    }
    private var pendingOpenRequests: [URL: PendingOpen] = [:]
    private var documentHistory = DocumentVisitHistory<ObjectIdentifier>()
    private var isActivatingDocumentHistory = false
    private var isReplayingPersistedTask = false

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
        noteDocumentActivated(document)
    }

    override func makeUntitledDocument(ofType typeName: String) throws -> NSDocument {
        LighTxtDocument()
    }

    override func makeDocument(withContentsOf url: URL, ofType typeName: String) throws -> NSDocument {
        try LighTxtDocument(
            opening: url,
            ofType: typeName,
            openOptions: DocumentOpenOptions()
        )
    }

    override func openDocument(
        withContentsOf url: URL,
        display displayDocument: Bool,
        completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void
    ) {
        openDocument(
            withContentsOf: url,
            openOptions: DocumentOpenOptions(),
            display: displayDocument,
            completionHandler: completionHandler
        )
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

    private static func documentIdentityURL(for url: URL) -> URL {
        DocumentURLIdentity.canonicalURL(for: url)
    }

    private func existingDocument(matching url: URL) -> NSDocument? {
        if let direct = document(for: url) { return direct }
        let identity = Self.documentIdentityURL(for: url)
        return documents.first { document in
            // Converted working copies have no save destination, but the
            // source the user opened still identifies the existing window.
            let openURL = document.fileURL ?? (document as? LighTxtDocument)?.session.originalSourceURL
            return openURL.map { Self.documentIdentityURL(for: $0) == identity } ?? false
        }
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
        if !documents.isEmpty {
            hideHomeWindow()
            documents.forEach { document in
                if document.windowControllers.isEmpty { document.makeWindowControllers() }
                document.showWindows()
            }
            if let document = documents.first as? LighTxtDocument {
                document.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
                noteDocumentActivated(document)
            }
        } else if reopenPersistedTask() {
            hideHomeWindow()
        } else {
            showHomeWindow()
        }
    }

    private enum RecoveryChoice: Int {
        case recover, keep, discard
    }

    func offerCrashRecovery(from store: RecoveryStore? = nil, completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let store = try store ?? RecoveryStore(rootURL: RecoveryStore.defaultRootURL())
                _ = try? store.prune()
                let candidates = try store.recoveryCandidates()
                DispatchQueue.main.async {
                    guard let self, !candidates.isEmpty else { completion(false); return }
                    let choices = self.chooseRecoveryActions(for: candidates)
                    self.applyRecoveryChoices(choices[...], from: store, openedAny: false, completion: completion)
                }
            } catch {
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    private func chooseRecoveryActions(for entries: [RecoveryEntry]) -> [(RecoveryEntry, RecoveryChoice)] {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Recover unsaved work?"
        alert.informativeText = "Choose what to do with each document from the interrupted session."
        let apply = alert.addButton(withTitle: "Apply Choices")
        alert.addButton(withTitle: "Not Now").keyEquivalent = "\u{1b}"
        apply.keyEquivalent = "\r"

        let width: CGFloat = 470
        let rowHeight: CGFloat = 52
        let height = rowHeight * CGFloat(entries.count)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: min(height, 5 * rowHeight)))
        scroll.hasVerticalScroller = height > scroll.frame.height
        scroll.autohidesScrollers = true
        let list = NSView(frame: NSRect(x: 0, y: 0, width: scroll.contentSize.width, height: height))
        scroll.documentView = list
        var menus: [NSPopUpButton] = []
        for (index, entry) in entries.enumerated() {
            let y = height - CGFloat(index + 1) * rowHeight
            let untitled = entry.metadata.task?.values["untitled"] == "true"
            let name = entry.metadata.task?.displayName ?? (untitled ? "Untitled" : entry.baseURL.lastPathComponent)
            let labelWidth = list.frame.width - 150
            let title = NSTextField(labelWithString: name)
            title.font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            title.frame = NSRect(x: 0, y: y + 25, width: labelWidth, height: 18)
            title.lineBreakMode = .byTruncatingMiddle
            list.addSubview(title)

            let date = entry.updatedAt.formatted(date: .abbreviated, time: .shortened)
            let details = untitled ? date : date + "  ·  " + entry.baseURL.deletingLastPathComponent().path
            let subtitle = NSTextField(labelWithString: details)
            subtitle.frame = NSRect(x: 0, y: y + 6, width: labelWidth, height: 17)
            subtitle.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
            subtitle.textColor = .secondaryLabelColor
            subtitle.lineBreakMode = .byTruncatingMiddle
            subtitle.toolTip = details
            list.addSubview(subtitle)

            let menu = NSPopUpButton(frame: NSRect(x: labelWidth + 8, y: y + 13, width: 136, height: 26))
            menu.addItems(withTitles: ["Recover", "Keep for Later", "Discard"])
            menu.setAccessibilityLabel("Recovery action for " + name)
            list.addSubview(menu)
            menus.append(menu)
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, height - scroll.contentSize.height)))
        scroll.reflectScrolledClipView(scroll.contentView)
        alert.accessoryView = scroll
        guard alert.runModal() == .alertFirstButtonReturn else { return [] }
        return zip(entries, menus).map { entry, menu in
            (entry, RecoveryChoice(rawValue: menu.indexOfSelectedItem) ?? .keep)
        }
    }

    private func applyRecoveryChoices(
        _ choices: ArraySlice<(RecoveryEntry, RecoveryChoice)>,
        from store: RecoveryStore,
        openedAny: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        guard let (entry, choice) = choices.first else { completion(openedAny); return }
        let next: (Bool) -> Void = { opened in
            self.applyRecoveryChoices(choices.dropFirst(), from: store, openedAny: openedAny || opened, completion: completion)
        }
        switch choice {
        case .recover:
            recover(entry, from: store, completion: next)
        case .discard:
            DispatchQueue.global(qos: .utility).async {
                let result = Result { try store.discard(identifier: entry.identifier) }
                DispatchQueue.main.async {
                    if case .failure(let error) = result { NSApp.presentError(error) }
                    next(false)
                }
            }
        case .keep:
            next(false)
        }
    }

    private func recover(
        _ entry: RecoveryEntry,
        from store: RecoveryStore,
        completion: @escaping (Bool) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try store.recover(identifier: entry.identifier) }
            DispatchQueue.main.async {
                guard let self else {
                    completion(false)
                    return
                }
                do {
                    let recovered = try result.get()
                    let base = Self.documentIdentityURL(for: entry.baseURL)
                    let existing = self.documents.compactMap { $0 as? LighTxtDocument }.filter { document in
                        guard entry.metadata.task?.values["untitled"] != "true", let url = document.fileURL else { return false }
                        return Self.documentIdentityURL(for: url) == base
                    }
                    let conflictingEdits = existing.contains { $0.session.isEdited || $0.isDocumentEdited }
                    let document = try LighTxtDocument(recovering: recovered, asCopy: conflictingEdits)
                    for clean in existing where !clean.session.isEdited && !clean.isDocumentEdited { clean.close() }
                    self.addDocument(document)
                    self.hideHomeWindow()
                    document.makeWindowControllers()
                    document.showWindows()
                    self.noteDocumentActivated(document)
                    self.captureCurrentTask()
                    completion(true)
                } catch {
                    NSApp.presentError(error)
                    completion(false)
                }
            }
        }
    }

    func documentWindowDidClose() {
        // NSDocument removes the closing window/controller after the delegate
        // callback. Defer the empty-state decision to the next run-loop turn.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pruneDocumentHistory()
            self.captureCurrentTask()
            if !self.hasVisibleDocumentWindow {
                self.showHomeWindow()
            }
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
        case .jsonLines: "app.lightext.json-lines"
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
        presentOpenPanel(openAs: false, forceSeparateWindow: false)
    }

    @objc func openLighTxtDocumentInNewWindow(_ sender: Any?) {
        presentOpenPanel(openAs: false, forceSeparateWindow: true)
    }

    @objc func openAsLighTxtDocument(_ sender: Any?) {
        presentOpenPanel(openAs: true, forceSeparateWindow: false)
    }

    private func presentOpenPanel(openAs: Bool, forceSeparateWindow: Bool) {
        let configured = makeOpenPanel(
            openAs: openAs,
            forceSeparateWindow: forceSeparateWindow
        )
        let panel = configured.panel
        let accessory = configured.accessory

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard response == .OK, let self, let panel else { return }
            let options = accessory?.options
            self.openDocumentsInNewWindows(
                at: panel.urls,
                openOptions: options,
                forceSeparateWindow: forceSeparateWindow
            )
        }
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func makeOpenPanel(
        openAs: Bool,
        forceSeparateWindow: Bool
    ) -> (panel: NSOpenPanel, accessory: DocumentOpenAsAccessoryView?) {
        let panel = NSOpenPanel()
        if openAs {
            panel.title = "Open Any File As"
        } else if forceSeparateWindow {
            panel.title = "Open in New Window"
        } else {
            panel.title = "Open Files"
        }
        panel.message = openAs
            ? "Choose any local file, then select how LighTxt should interpret its sampled content."
            : "Choose one or more text, JSON, JSON Lines, Markdown, SQL, XML, CSV/TSV/PSV, YAML, or Parquet files."
        panel.prompt = "Open"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        // Open As applies one explicit interpretation to one file. Normal Open
        // accepts a Finder-style selection and creates a document for each URL.
        panel.allowsMultipleSelection = !openAs
        panel.resolvesAliases = true
        panel.treatsFilePackagesAsDirectories = false
        let accessory: DocumentOpenAsAccessoryView?
        if openAs {
            let options = DocumentOpenAsAccessoryView()
            panel.accessoryView = options
            panel.allowedContentTypes = []
            accessory = options
        } else {
            panel.allowedContentTypes = Self.supportedFilenameExtensions.compactMap {
                UTType(filenameExtension: $0)
            }
            accessory = nil
        }

        return (panel, accessory)
    }

    /// Opens every requested URL as an independent NSDocument. Operations are
    /// serialized to keep Finder/open-panel ordering deterministic and to
    /// present one coherent error after the rest of the selection has opened.
    func openDocumentsInNewWindows(at urls: [URL]) {
        openDocumentsInNewWindows(
            at: urls,
            openOptions: nil,
            forceSeparateWindow: false
        )
    }

    private func openDocumentsInNewWindows(
        at urls: [URL],
        openOptions: DocumentOpenOptions?,
        forceSeparateWindow: Bool,
        captureTaskOnCompletion: Bool = true,
        completion: ((Bool) -> Void)? = nil
    ) {
        let orderedURLs = DocumentURLIdentity.uniqueURLsPreservingOrder(urls)
        guard !orderedURLs.isEmpty else { return }

        var failures: [(URL, Error)] = []
        func open(at index: Int) {
            guard orderedURLs.indices.contains(index) else {
                if captureTaskOnCompletion { self.captureCurrentTask() }
                self.presentOpenFailures(failures)
                if !self.hasVisibleDocumentWindow { self.showHomeWindow() }
                completion?(failures.isEmpty)
                return
            }
            let url = orderedURLs[index]
            let completion: (NSDocument?, Bool, Error?) -> Void = { document, _, error in
                if let error, (error as? CocoaError)?.code != .userCancelled {
                    failures.append((url, error))
                }
                DispatchQueue.main.async {
                    if forceSeparateWindow,
                       let window = document?.windowControllers.first?.window,
                       (window.tabbedWindows?.count ?? 0) > 1 {
                        window.moveTabToNewWindow(nil)
                    }
                    open(at: index + 1)
                }
            }
            if let openOptions {
                self.openDocument(
                    withContentsOf: url,
                    openOptions: openOptions,
                    display: true,
                    completionHandler: completion
                )
            } else {
                self.openDocument(
                    withContentsOf: url,
                    display: true,
                    completionHandler: completion
                )
            }
        }
        open(at: 0)
    }

#if LIGHTXT_RUNTIME_QA
    func qaConfiguredOpenPanel(
        openAs: Bool,
        forceSeparateWindow: Bool
    ) -> NSOpenPanel {
        makeOpenPanel(
            openAs: openAs,
            forceSeparateWindow: forceSeparateWindow
        ).panel
    }

    func qaOpenDocumentsInNewWindows(
        at urls: [URL],
        forceSeparateWindow: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        openDocumentsInNewWindows(
            at: urls,
            openOptions: nil,
            forceSeparateWindow: forceSeparateWindow,
            captureTaskOnCompletion: false,
            completion: completion
        )
    }

    var qaCurrentHistoryURL: URL? {
        pruneDocumentHistory()
        guard let identifier = documentHistory.current else { return nil }
        return documents.compactMap { $0 as? LighTxtDocument }.first {
            ObjectIdentifier($0) == identifier
        }?.fileURL?.standardizedFileURL
    }
#endif

    private func openDocument(
        withContentsOf url: URL,
        openOptions: DocumentOpenOptions,
        display: Bool,
        completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void
    ) {
        if let existing = existingDocument(matching: url) {
            // Open As is intentionally allowed to reinterpret an already-open
            // source (most importantly, a read-only file whose encoding could
            // not be identified). Reuse that document's save-review flow so
            // two editable NSDocuments never point at the same disk file.
            if openOptions != DocumentOpenOptions() {
                if existing.windowControllers.isEmpty { existing.makeWindowControllers() }
            }
            if openOptions != DocumentOpenOptions(),
               let controller = existing.windowControllers.first as? LighTxtWindowController {
                controller.navigateToDocument(at: url, openOptions: openOptions) { document, error in
                    if display, let document, error == nil {
                        self.presentOpenedDocument(document, from: url)
                    }
                    completionHandler(document, true, error)
                }
                return
            }
            if display { presentOpenedDocument(existing, from: url) }
            completionHandler(existing, true, nil)
            return
        }

        let identity = Self.documentIdentityURL(for: url)
        if let pendingOptions = pendingOpenRequests[identity]?.options {
            pendingOpenRequests[identity]?.waiters.append { document, error in
                if let error {
                    completionHandler(nil, false, error)
                } else if pendingOptions == openOptions, let document {
                    if display { self.presentOpenedDocument(document, from: url) }
                    completionHandler(document, true, nil)
                } else {
                    self.openDocument(withContentsOf: url, openOptions: openOptions, display: display,
                                      completionHandler: completionHandler)
                }
            }
            return
        }
        pendingOpenRequests[identity] = PendingOpen(options: openOptions)
        let operation = DocumentOpeningOperation(url: url, options: openOptions, showsProgress: display)
        operation.start { result, scope in
            let waiting = self.pendingOpenRequests.removeValue(forKey: identity)?.waiters ?? []
            switch result {
            case .success(let session):
                let document = LighTxtDocument(openedSession: session, url: url, scope: scope)
                self.addDocument(document)
                if display { self.presentOpenedDocument(document, from: url) }
                completionHandler(document, false, nil)
                waiting.forEach { $0(document, nil) }
            case .failure(let error):
                completionHandler(nil, false, error)
                waiting.forEach { $0(nil, error) }
            }
        }
    }

    private func presentOpenedDocument(_ document: NSDocument, from url: URL) {
        hideHomeWindow()
        noteNewRecentDocumentURL(url)
        if document.windowControllers.isEmpty { document.makeWindowControllers() }
        document.showWindows()
        document.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
        if let document = document as? LighTxtDocument { noteDocumentActivated(document) }
        captureCurrentTask()
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

    @objc func reopenLastTask(_ sender: Any?) {
        guard reopenPersistedTask() else {
            NSSound.beep()
            return
        }
        hideHomeWindow()
    }

    /// Called by document windows whenever they become key. The history is
    /// intentionally visit-based rather than static window order, so Back/Next
    /// behaves predictably after the user clicks among several documents.
    func noteDocumentActivated(_ document: LighTxtDocument) {
        guard documents.contains(where: { $0 === document }) else { return }
        pruneDocumentHistory()
        if isActivatingDocumentHistory {
            isActivatingDocumentHistory = false
            return
        }
        documentHistory.recordActivation(ObjectIdentifier(document))
    }

    @objc func activatePreviousLighTxtDocument(_ sender: Any?) {
        activateDocumentHistory(step: -1)
    }

    @objc func activateNextLighTxtDocument(_ sender: Any?) {
        activateDocumentHistory(step: 1)
    }

    private func activateDocumentHistory(step: Int) {
        guard let target = documentHistoryTarget(step: step) else {
            NSSound.beep()
            return
        }
        _ = documentHistory.navigate(step: step)
        isActivatingDocumentHistory = true
        if target.windowControllers.isEmpty {
            target.makeWindowControllers()
        }
        target.showWindows()
        target.windowControllers.first?.window?.makeKeyAndOrderFront(nil)
        // A window that was already key does not emit another activation.
        // Clear the guard on the following turn without altering the cursor.
        DispatchQueue.main.async { [weak self] in
            self?.isActivatingDocumentHistory = false
        }
    }

    private func documentHistoryTarget(
        step: Int
    ) -> LighTxtDocument? {
        pruneDocumentHistory()
        guard let identifier = documentHistory.target(step: step) else { return nil }
        return documents.compactMap { $0 as? LighTxtDocument }.first {
            ObjectIdentifier($0) == identifier
        }
    }

    private func pruneDocumentHistory() {
        let validIdentifiers = Set(documents.compactMap { document -> ObjectIdentifier? in
            guard let document = document as? LighTxtDocument else { return nil }
            return ObjectIdentifier(document)
        })
        documentHistory.retainOnly(validIdentifiers)
    }

    func captureCurrentTask() {
        guard !isReplayingPersistedTask else { return }
        let urls = DocumentURLIdentity.uniqueURLsPreservingOrder(
            documents.compactMap(\.fileURL)
        )
        // Closing the final window should leave a useful Reopen Last Task
        // target rather than replacing it with an empty snapshot.
        guard !urls.isEmpty else { return }
        do {
            let task = try DocumentTaskManifest(urls: urls) { url in
                try url.bookmarkData(
                        options: [.withSecurityScope],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )
            }
            let encoded = try JSONEncoder().encode(task)
            UserDefaults.standard.set(encoded, forKey: Self.lastTaskDefaultsKey)
        } catch {
            // Keep the previous manifest intact. Replacing it with raw paths
            // would appear successful but lose sandbox access after relaunch.
            NSLog("LighTxt could not update Reopen Last Task: %@", error.localizedDescription)
            return
        }
    }

    private var persistedTaskURLs: [URL] {
        guard let data = UserDefaults.standard.data(forKey: Self.lastTaskDefaultsKey),
              let task = try? JSONDecoder().decode(DocumentTaskManifest.self, from: data) else {
            return []
        }
        return task.resolvedURLs { bookmark in
            var bookmarkIsStale = false
            return try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &bookmarkIsStale
            )
        }
    }

    @discardableResult
    private func reopenPersistedTask() -> Bool {
        guard !isReplayingPersistedTask else { return false }
        let urls = persistedTaskURLs
        guard !urls.isEmpty else { return false }
        isReplayingPersistedTask = true
        openDocumentsInNewWindows(
            at: urls,
            openOptions: nil,
            forceSeparateWindow: false,
            captureTaskOnCompletion: false
        ) { [weak self] allOpened in
            guard let self else { return }
            self.isReplayingPersistedTask = false
            // A partial replay must not overwrite the durable manifest with
            // only the files that happened to be reachable this time.
            if allOpened { self.captureCurrentTask() }
        }
        return true
    }

    private func presentOpenFailures(_ failures: [(URL, Error)]) {
        guard !failures.isEmpty else { return }
        if failures.count == 1, let failure = failures.first {
            if homeWindowController?.window?.isVisible == true {
                homeWindowController?.showOpenError(failure.1)
            } else {
                NSApp.presentError(failure.1)
            }
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Some files couldn’t be opened"
        let details = failures.prefix(6).map { url, error in
            "• \(url.lastPathComponent): \(error.localizedDescription)"
        }
        let remainder = failures.count - details.count
        alert.informativeText = details.joined(separator: "\n")
            + (remainder > 0 ? "\n• and \(remainder) more" : "")
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.title == "Open Recent" else { return }
        populateRecentDocumentsMenu(menu)
    }

    func populateRecentDocumentsMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        for url in homeRecentDocumentURLs.prefix(12) {
            let recent = NSMenuItem(
                title: url.lastPathComponent,
                action: #selector(openRecentLighTxtDocument(_:)),
                keyEquivalent: ""
            )
            recent.target = self
            recent.representedObject = url
            recent.toolTip = url.path
            menu.addItem(recent)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let clear = NSMenuItem(
            title: "Clear Menu",
            action: #selector(NSDocumentController.clearRecentDocuments(_:)),
            keyEquivalent: ""
        )
        clear.target = self
        clear.isEnabled = !homeRecentDocumentURLs.isEmpty
        menu.addItem(clear)
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

    @objc func exportCurrentTableView(_ sender: Any?) {
        guard let document = currentDocument as? LighTxtDocument,
              !document.isSaving,
              !document.session.isBulkEditing,
              let controller = activeWindowController,
              controller.canExportCurrentView else {
            NSSound.beep()
            return
        }
        controller.exportCurrentView()
    }

    @objc func exportCurrentDocumentAsPDF(_ sender: Any?) {
        guard let document = currentDocument as? LighTxtDocument,
              !document.isSaving,
              !document.session.isBulkEditing,
              let controller = activeWindowController,
              controller.canExportCurrentDocumentAsPDF else {
            NSSound.beep()
            return
        }
        controller.exportCurrentDocumentAsPDF()
    }

    @objc func printCurrentDocument(_ sender: Any?) {
        guard let document = currentDocument as? LighTxtDocument,
              !document.isSaving,
              !document.session.isBulkEditing,
              let controller = activeWindowController,
              controller.canPrintCurrentDocument else {
            NSSound.beep()
            return
        }
        controller.printCurrentDocument()
    }

    @objc func cancelCurrentTableExport(_ sender: Any?) {
        guard let controller = activeWindowController,
              controller.isExportingCurrentView else {
            NSSound.beep()
            return
        }
        controller.cancelExport()
    }

    @objc func reloadCurrentLighTxtDocument(_ sender: Any?) {
        guard let document = currentDocument as? LighTxtDocument,
              document.fileURL != nil,
              !document.isSaving,
              !document.session.isBulkEditing,
              let controller = activeWindowController else {
            NSSound.beep()
            return
        }
        controller.requestReloadFromDisk()
    }

    @objc func toggleFollowEndOfFile(_ sender: Any?) {
        guard let document = currentDocument as? LighTxtDocument,
              document.fileURL != nil,
              !document.session.isReadOnly,
              let controller = activeWindowController else {
            NSSound.beep()
            return
        }
        controller.toggleFollowEndOfFile()
    }

    @objc func toggleAutomaticReloadCleanFiles(_ sender: Any?) {
        guard let controller = activeWindowController else {
            NSSound.beep()
            return
        }
        controller.toggleAutomaticReloadCleanFiles()
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
        alert.informativeText = "Open TXT, SCRIPT, JSON, JSON Lines, Markdown, SQL, XML, CSV, YAML, or Parquet. Text stays file-backed, and Parquet opens in a read-only table."
        alert.addButton(withTitle: "Done")
        alert.runModal()
    }

    override func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let action = menuItem.action
        let document = currentDocument as? LighTxtDocument
        let editor = activeEditorController
        switch action {
        case #selector(openLighTxtDocument(_:)),
             #selector(openLighTxtDocumentInNewWindow(_:)),
             #selector(openAsLighTxtDocument(_:)):
            return true
        case #selector(reopenLastTask(_:)):
            return !isReplayingPersistedTask && !persistedTaskURLs.isEmpty
        case #selector(activatePreviousLighTxtDocument(_:)):
            return documentHistoryTarget(step: -1) != nil
        case #selector(activateNextLighTxtDocument(_:)):
            return documentHistoryTarget(step: 1) != nil
        case #selector(saveCurrentLighTxtDocument(_:)),
             #selector(saveAsCurrentLighTxtDocument(_:)):
            return document != nil
                && document?.session.isReadOnly == false
                && document?.isSaving == false
                && document?.session.isBulkEditing == false
        case #selector(exportCurrentTableView(_:)):
            return document != nil
                && document?.isSaving == false
                && document?.session.isBulkEditing == false
                && activeWindowController?.canExportCurrentView == true
        case #selector(exportCurrentDocumentAsPDF(_:)):
            return document != nil
                && document?.isSaving == false
                && document?.session.isBulkEditing == false
                && activeWindowController?.canExportCurrentDocumentAsPDF == true
        case #selector(printCurrentDocument(_:)):
            return document != nil
                && document?.isSaving == false
                && document?.session.isBulkEditing == false
                && activeWindowController?.canPrintCurrentDocument == true
        case #selector(cancelCurrentTableExport(_:)):
            return activeWindowController?.isExportingCurrentView == true
        case #selector(reloadCurrentLighTxtDocument(_:)):
            return document?.fileURL != nil
                && document?.isSaving == false
                && document?.session.isBulkEditing == false
        case #selector(toggleFollowEndOfFile(_:)):
            menuItem.state = activeWindowController?.isFollowingEndOfFile == true ? .on : .off
            return document?.fileURL != nil && document?.session.isReadOnly == false
        case #selector(toggleAutomaticReloadCleanFiles(_:)):
            menuItem.state = activeWindowController?.automaticallyReloadsCleanFiles == true ? .on : .off
            return activeWindowController != nil
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
             #selector(increaseFontSizeInCurrentLighTxtDocument(_:)),
             #selector(decreaseFontSizeInCurrentLighTxtDocument(_:)),
             #selector(resetFontSizeInCurrentLighTxtDocument(_:)):
            return editor != nil && document?.session.isReadOnly == false
        case #selector(showGoToLineForCurrentLighTxtDocument(_:)):
            menuItem.title = editor?.positionNavigationTitle ?? "Go to Line…"
            return editor?.canNavigatePosition == true
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
        "txt", "text", "log", "script", "json", "jsonl", "ndjson", "md", "markdown", "sql", "xml", "csv", "tsv", "psv", "yml", "yaml", "parquet",
    ]

}

/// Owns any explicit security-scope reference for the lifetime of a document.
/// Open-panel URLs and recent-document bookmarks can lose path access as soon
/// as their originating callback returns unless the scope remains active.
private nonisolated final class DocumentSecurityScope: @unchecked Sendable {
    private let lock = NSLock()
    private var accessedURL: URL?

    init(accessing url: URL? = nil) {
        if let url, url.startAccessingSecurityScopedResource() { accessedURL = url }
    }

    deinit { stop() }

    func transfer(to owner: DocumentSecurityScope, for url: URL) {
        lock.lock()
        let started = accessedURL != nil
        accessedURL = nil
        lock.unlock()
        owner.adopt(url, accessWasStarted: started)
    }

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

/// The file stays scoped from the originating open request until the main
/// actor adopts the finished session. Slow conversions show real byte progress.
@MainActor
private final class DocumentOpeningOperation: NSObject {
    private let url: URL
    private let options: DocumentOpenOptions
    private let showsProgress: Bool
    private let cancellation = CancellationToken()
    private var panel: NSPanel?
    private var bar: NSProgressIndicator?
    private var fraction: Double?
    private var finished = false

    init(url: URL, options: DocumentOpenOptions, showsProgress: Bool) {
        self.url = url
        self.options = options
        self.showsProgress = showsProgress
    }

    func start(_ completion: @escaping (Result<LighTxtDocumentSession, Error>, DocumentSecurityScope) -> Void) {
        let scope = DocumentSecurityScope(accessing: url)
        let target = url.standardizedFileURL
        if showsProgress {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.showProgress() }
        }
        DispatchQueue.global(qos: .userInitiated).async { [self, options, cancellation] in
            var nextUpdate = 0.0
            let result = Result {
                try LighTxtDocumentSession.PreparedOpen(url: target, options: options, cancellation: cancellation) { value in
                    let now = ProcessInfo.processInfo.systemUptime
                    guard now >= nextUpdate || value.sourceBytesProcessed == value.sourceByteCount else { return }
                    nextUpdate = now + 0.1
                    DispatchQueue.main.async {
                        self.fraction = value.fractionCompleted
                        self.bar?.isIndeterminate = false
                        self.bar?.doubleValue = value.fractionCompleted
                    }
                }
            }
            DispatchQueue.main.async {
                self.finished = true
                self.panel?.orderOut(nil)
                self.panel = nil
                do {
                    if cancellation.isCancelled { throw CocoaError(.userCancelled) }
                    let session = try LighTxtDocumentSession(prepared: result.get())
                    completion(.success(session), scope)
                } catch let error as LighTxtCoreError {
                    if case .io(_, let path, ENOENT) = error, path == target.path {
                        let missing = CocoaError(.fileReadNoSuchFile, userInfo: [NSURLErrorKey: target, NSUnderlyingErrorKey: error])
                        completion(.failure(missing), scope)
                    } else {
                        completion(.failure(error), scope)
                    }
                } catch {
                    completion(.failure(error), scope)
                }
            }
        }
    }

    @objc func cancel() { cancellation.cancel() }

    private func showProgress() {
        guard !finished, !cancellation.isCancelled else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 92),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Opening " + url.lastPathComponent
        panel.isReleasedWhenClosed = false
        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 55, width: 320, height: 16))
        bar.minValue = 0
        bar.maxValue = 1
        bar.isIndeterminate = fraction == nil
        if let fraction { bar.doubleValue = fraction } else { bar.startAnimation(nil) }
        panel.contentView?.addSubview(bar)
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        cancel.sizeToFit()
        cancel.setFrameOrigin(NSPoint(x: 340 - cancel.frame.width, y: 10))
        panel.contentView?.addSubview(cancel)
        panel.center()
        self.bar = bar
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
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
    private var hasLoadedContents = false
    private var openingOperation: DocumentOpeningOperation?
    private var saveCancellation: CancellationToken?
    private(set) var isSaving = false
    private let securityScope = DocumentSecurityScope()

    override init() {
        session = LighTxtDocumentSession(memoryOnlyEmptyDocument: ())
        super.init()
        fileType = "public.plain-text"
        hasUndoManager = false
    }

    convenience init(
        opening url: URL,
        ofType typeName: String,
        openOptions: DocumentOpenOptions
    ) throws {
        let scope = DocumentSecurityScope(accessing: url)
        let session = try LighTxtDocumentSession(opening: url.standardizedFileURL, openOptions: openOptions)
        self.init(openedSession: session, url: url, scope: scope)
    }

    fileprivate init(openedSession: LighTxtDocumentSession, url: URL, scope: DocumentSecurityScope) {
        session = openedSession
        super.init()
        hasLoadedContents = true
        fileType = Self.typeIdentifier(for: session.syntaxFileType)
        if session.needsSaveAsDestination {
            updateChangeCount(.changeDone)
        } else {
            scope.transfer(to: securityScope, for: url)
            fileURL = url.standardizedFileURL
            fileModificationDate = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        hasUndoManager = false
    }

    init(recovering recovered: RecoveredDocument, asCopy: Bool = false) throws {
        session = try LighTxtDocumentSession(recovering: recovered, asCopy: asCopy)
        super.init()
        hasLoadedContents = true
        if session.needsSaveAsDestination {
            fileURL = nil
        } else {
            fileURL = recovered.entry.baseURL
            fileModificationDate = try? recovered.entry.baseURL.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
        }
        fileType = Self.typeIdentifier(for: session.syntaxFileType)
        updateChangeCount(.changeDone)
        hasUndoManager = false
    }

    override class var autosavesInPlace: Bool { false }
    override class var preservesVersions: Bool { false }

    /// LighTxt owns external-change policy through `ExternalFileMonitor` so a
    /// change reaches one nonmodal Reload / Don’t Reload decision. Calling the
    /// NSDocument implementation as well lets AppKit present a second generic
    /// OK-only warning for the same revision.
    override func presentedItemDidChange() {
        // The per-window monitor also has a polling fallback, so deliberately
        // leave this notification to that single policy owner.
    }

    override func makeWindowControllers() {
        let controller = LighTxtWindowController(document: self)
        addWindowController(controller)
    }

    override func prepareSavePanel(_ savePanel: NSSavePanel) -> Bool {
        guard super.prepareSavePanel(savePanel) else { return false }
        guard fileURL == nil || session.isScratchDocument else { return true }
        let pathExtension = session.prepareUntitledSaveSuggestion()
        let currentName = savePanel.nameFieldStringValue.isEmpty
            ? "Untitled"
            : savePanel.nameFieldStringValue
        let currentURL = URL(fileURLWithPath: currentName)
        let base = currentURL.pathExtension.isEmpty
            ? currentURL.lastPathComponent
            : currentURL.deletingPathExtension().lastPathComponent
        savePanel.nameFieldStringValue = "\(base.isEmpty ? "Untitled" : base).\(pathExtension)"
        savePanel.isExtensionHidden = false
        fileType = Self.typeIdentifier(for: session.syntaxFileType)
        return true
    }

    override func fileNameExtension(
        forType typeName: String,
        saveOperation: NSDocument.SaveOperationType
    ) -> String? {
        MainActor.assumeIsolated {
            if fileURL == nil || session.isScratchDocument {
                return session.prepareUntitledSaveSuggestion()
            }
            return super.fileNameExtension(forType: typeName, saveOperation: saveOperation)
        }
    }

    override func read(from url: URL, ofType typeName: String) throws {
        let accessedSecurityScope = url.startAccessingSecurityScopedResource()
        let openOptions = MainActor.assumeIsolated {
            hasLoadedContents ? session.reopenOptions : DocumentOpenOptions()
        }
        let replacement: LighTxtDocumentSession
        do {
            replacement = try MainActor.assumeIsolated {
                try LighTxtDocumentSession(
                    opening: url,
                    openOptions: openOptions
                )
            }
        } catch {
            if accessedSecurityScope { url.stopAccessingSecurityScopedResource() }
            throw error
        }
        MainActor.assumeIsolated {
            session.prepareForClose()
            session = replacement
            hasLoadedContents = true
            securityScope.adopt(url, accessWasStarted: accessedSecurityScope)
            fileType = Self.typeIdentifier(for: replacement.syntaxFileType)
        }
    }

    /// Replaces the current file only after preparation succeeds. The caller
    /// keeps the existing session suspended until completion.
    @MainActor
    func replaceContentsForNavigation(
        with url: URL,
        openOptions: DocumentOpenOptions,
        completion: @escaping (Error?) -> Void
    ) {
        guard openingOperation == nil else {
            completion(LighTxtSessionError.documentNavigationInProgress)
            return
        }
        let operation = DocumentOpeningOperation(url: url, options: openOptions, showsProgress: true)
        openingOperation = operation
        operation.start { [weak self] result, scope in
            guard let self, self.openingOperation === operation else {
                completion(CocoaError(.userCancelled))
                return
            }
            self.openingOperation = nil
            switch result {
            case .success(let replacement):
                self.installReplacement(replacement, for: url, scope: scope)
                completion(nil)
            case .failure(let error):
                completion(error)
            }
        }
    }

    private func installReplacement(_ replacement: LighTxtDocumentSession, for target: URL, scope: DocumentSecurityScope) {
        let previous = session
        session = replacement
        hasLoadedContents = true
        if replacement.needsSaveAsDestination {
            securityScope.stop()
            fileURL = nil
            fileType = Self.typeIdentifier(for: replacement.syntaxFileType)
        } else {
            scope.transfer(to: securityScope, for: target)
            fileURL = target
            fileType = Self.typeIdentifier(for: replacement.syntaxFileType)
        }
        // NSDocument uses this token to detect external edits before saving.
        // Carrying the previous file's date into a same-window replacement
        // incorrectly produces a second "changed by another application"
        // prompt even though the new source has not changed.
        if replacement.needsSaveAsDestination {
            fileModificationDate = nil
        } else {
            fileModificationDate = try? target.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
        }
        updateChangeCount(replacement.needsSaveAsDestination ? .changeDone : .changeCleared)
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
            throw MainActor.assumeIsolated { session.readOnlyError }
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
        guard openingOperation == nil else {
            completionHandler(LighTxtSessionError.documentNavigationInProgress)
            return
        }
        let requestedRoute = Self.route(for: saveOperation)
        guard !session.isReadOnly || requestedRoute == .copy else {
            completionHandler(session.readOnlyError)
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
                        let accessedSecurityScope = savedURL.startAccessingSecurityScopedResource()
                        self.securityScope.adopt(
                            savedURL,
                            accessWasStarted: accessedSecurityScope
                        )
                        self.session.adoptSavedURL(savedURL)
                        self.fileType = Self.typeIdentifier(for: self.session.syntaxFileType)
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
                    if case .fileChangedExternally = error as? LighTxtCoreError {
                        for controller in self.windowControllers.compactMap({ $0 as? LighTxtWindowController }) {
                            controller.offerLocalEditExportAfterSaveFailure()
                        }
                    }
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
                pathExtension: fileURL?.pathExtension ?? session.preferredSavePathExtension
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
        openingOperation?.cancel()
        openingOperation = nil
        saveCancellation?.cancel()
        session.prepareForClose()
        securityScope.stop()
        super.close()
    }

    private func copyName() -> String {
        let current = fileURL?.lastPathComponent
            ?? "Untitled.\(session.preferredSavePathExtension)"
        let url = URL(fileURLWithPath: current)
        return "\(url.deletingPathExtension().lastPathComponent) copy.\(url.pathExtension)"
    }

    private static func typeIdentifier(for syntax: SyntaxFileType) -> String {
        switch syntax {
        case .json: "public.json"
        case .jsonLines: "app.lightext.json-lines"
        case .xml: "public.xml"
        case .csv: "public.comma-separated-values-text"
        case .markdown: "net.daringfireball.markdown"
        case .yaml: "public.yaml"
        case .sql: "public.sql"
        case .parquet: "org.apache.parquet"
        case .plainText: "public.plain-text"
        }
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
