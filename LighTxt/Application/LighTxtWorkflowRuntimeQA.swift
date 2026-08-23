#if LIGHTXT_RUNTIME_QA
import AppKit
import Darwin
import Foundation

/// Invocation parsed only into the QA-flavoured application build. Normal
/// LighTxt binaries contain neither this type nor the hosted test body.
struct LighTxtWorkflowRuntimeQAInvocation {
    let workspaceURL: URL

    init?(arguments: [String]) {
        guard let flag = arguments.firstIndex(of: "--workflow-runtime-qa"),
              arguments.indices.contains(flag + 1) else { return nil }
        workspaceURL = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
            .standardizedFileURL
    }
}

@MainActor
final class LighTxtWorkflowRuntimeQA {
    private enum QAError: Error, LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .failed(let message): message
            }
        }
    }

    private static var retainedRunner: LighTxtWorkflowRuntimeQA?

    private let invocation: LighTxtWorkflowRuntimeQAInvocation
    private let documentController: LighTxtDocumentController
    private var assertionCount = 0

    static func start(
        invocation: LighTxtWorkflowRuntimeQAInvocation,
        documentController: LighTxtDocumentController
    ) {
        try? Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(
            to: invocation.workspaceURL.appendingPathComponent("workflow-runtime-qa.pid"),
            options: .atomic
        )
        let runner = LighTxtWorkflowRuntimeQA(
            invocation: invocation,
            documentController: documentController
        )
        retainedRunner = runner
        Task { @MainActor in
            await runner.runAndExit()
        }
    }

    private init(
        invocation: LighTxtWorkflowRuntimeQAInvocation,
        documentController: LighTxtDocumentController
    ) {
        self.invocation = invocation
        self.documentController = documentController
    }

    private func runAndExit() async {
        do {
            try await run()
            let result = "LIGHTXT_WORKFLOW_RUNTIME_QA_PASS assertions=\(assertionCount)\n"
            writeResult(result)
            writeStandardOutput(result)
            Darwin.exit(EXIT_SUCCESS)
        } catch {
            let result = "LIGHTXT_WORKFLOW_RUNTIME_QA_FAIL \(error.localizedDescription)\n"
            writeResult(result)
            writeStandardError(result)
            Darwin.exit(EXIT_FAILURE)
        }
    }

    private func run() async throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: invocation.workspaceURL,
            withIntermediateDirectories: true
        )

        // The runner gives this build a distinct bundle identifier. Starting
        // from an empty domain proves replay came from this run's real capture,
        // never from a developer's existing preferences.
        guard let defaultsDomain = Bundle.main.bundleIdentifier,
              defaultsDomain.hasSuffix(".RuntimeQA") else {
            throw QAError.failed("QA build does not have its isolated bundle identifier")
        }
        UserDefaults.standard.removePersistentDomain(forName: defaultsDomain)

        try verifyOpenPanelAndMenuConfiguration()

        let requestedURLs = try makeFixtures(in: invocation.workspaceURL)
        guard let applicationDelegate = NSApp.delegate as? LighTxtAppDelegate else {
            throw QAError.failed("the production application delegate is not installed")
        }
        applicationDelegate.application(NSApp, open: requestedURLs)
        try await waitUntil("three documents and windows to open") {
            self.documentController.documents.count == requestedURLs.count
                && self.documentController.documents.allSatisfy {
                    $0.windowControllers.first is LighTxtWindowController
                        && $0.windowControllers.first?.window != nil
                }
        }

        let firstDocuments = try documentsByURL(requestedURLs)
        try expect(
            Set(firstDocuments.map { ObjectIdentifier($0) }).count == requestedURLs.count,
            "multi-open reused an NSDocument"
        )
        let firstWindows = try firstDocuments.map { document -> NSWindow in
            guard let window = document.windowControllers.first?.window else {
                throw QAError.failed("an opened document has no window")
            }
            return window
        }
        try expect(
            Set(firstWindows.map { ObjectIdentifier($0) }).count == requestedURLs.count,
            "multi-open reused a document window"
        )
        try expect(
            firstDocuments.allSatisfy {
                $0.windowControllers.first is LighTxtWindowController
            },
            "multi-open did not install the production window controller"
        )
        try expect(
            firstWindows.allSatisfy {
                $0.tabbingIdentifier == "app.lightext.LighTxt.document"
                    && $0.tabbingMode == .automatic
            },
            "document windows are not opted into the shared tab group"
        )

        // Normalize any tabs restored by the host preference, make a real tab
        // group, then drive Open in New Window's force-detach branch using the
        // already-open beta URL.
        for window in firstWindows where (window.tabbedWindows?.count ?? 0) > 1 {
            window.moveTabToNewWindow(nil)
        }
        try await waitUntil("the QA windows to start independently") {
            firstWindows.allSatisfy { ($0.tabbedWindows?.count ?? 0) <= 1 }
        }
        firstWindows[0].addTabbedWindow(firstWindows[1], ordered: .above)
        try await waitUntil("the real alpha/beta tab group to form") {
            (firstWindows[1].tabbedWindows?.count ?? 0) == 2
        }
        var forceDetachResult: Bool?
        documentController.qaOpenDocumentsInNewWindows(
            at: [requestedURLs[1]],
            forceSeparateWindow: true
        ) { forceDetachResult = $0 }
        try await waitUntil("Open in New Window to detach the existing tab") {
            forceDetachResult != nil
                && (firstWindows[1].tabbedWindows?.count ?? 0) <= 1
        }
        try expect(forceDetachResult == true, "Open in New Window reported a failure")
        try expect(
            (firstWindows[1].tabbedWindows?.count ?? 0) <= 1,
            "Open in New Window left the document attached as a tab"
        )

        // The forced-detach open above leaves B as the current visit. Deliver
        // the AppKit delegate callback through the real window.delegate wiring;
        // this remains deterministic on test hosts that forbid focus stealing.
        try deliverWindowDidBecomeKey(firstWindows[0])
        try expect(
            documentController.qaCurrentHistoryURL == requestedURLs[0],
            "the real window delegate did not record alpha's activation"
        )
        documentController.activatePreviousLighTxtDocument(nil)
        try expect(
            documentController.qaCurrentHistoryURL == requestedURLs[1],
            "Previous Document selected the wrong history entry"
        )

        documentController.activateNextLighTxtDocument(nil)
        try expect(
            documentController.qaCurrentHistoryURL == requestedURLs[0],
            "Next Document selected the wrong history entry"
        )

        // Cross the production editor error callback and external-file monitor
        // with the same disk revision. They must coalesce into one nonmodal
        // banner; declining that exact revision stays quiet, while a later
        // write receives a new decision. Finish through the public manual
        // Reload command to prove declining does not disable it.
        guard let textWindowController = firstDocuments[0].windowControllers.first
            as? LighTxtWindowController else {
            throw QAError.failed("the text document has no production window controller")
        }
        textWindowController.automaticallyReloadsCleanFiles = false
        let firstExternalText = "alpha external revision one\n"
        try Data(firstExternalText.utf8).write(to: requestedURLs[0], options: .atomic)
        textWindowController.qaDeliverDocumentError(
            LighTxtCoreError.fileChangedExternally(path: requestedURLs[0].path)
        )
        try await waitUntil("one external-change banner for the first revision") {
            textWindowController.qaExternalChangeBannerIsVisible
                && textWindowController.qaExternalChangePresentationCount == 1
        }
        try expect(
            textWindowController.qaExternalChangeActionTitles.reload == "Reload"
                && textWindowController.qaExternalChangeActionTitles.keep == "Don’t Reload",
            "the external-change banner does not offer exact Reload / Don’t Reload actions"
        )
        try expect(
            firstWindows[0].attachedSheet == nil,
            "an external editor error also presented a generic modal sheet"
        )
        textWindowController.qaActivateDontReload()
        try await waitUntil("Don’t Reload to dismiss the first decision") {
            !textWindowController.qaExternalChangeBannerIsVisible
        }
        textWindowController.qaDeliverDocumentError(
            LighTxtCoreError.fileChangedExternally(path: requestedURLs[0].path)
        )
        try await Task.sleep(nanoseconds: 200_000_000)
        try expect(
            !textWindowController.qaExternalChangeBannerIsVisible
                && textWindowController.qaExternalChangePresentationCount == 1,
            "the declined disk revision prompted again during later interaction"
        )
        try expect(
            firstWindows[0].attachedSheet == nil,
            "the declined disk revision fell through to an OK-only error sheet"
        )

        textWindowController.requestReloadFromDisk()
        let firstExpectedReloadedData = Data(firstExternalText.utf8)
        try await waitUntil("manual Reload after declining the first external change") {
            guard firstDocuments[0].session.byteCount
                    == Int64(firstExpectedReloadedData.count) else { return false }
            return (try? firstDocuments[0].session.editorReadBytes(
                in: 0..<Int64(firstExpectedReloadedData.count)
            )) == firstExpectedReloadedData
        }
        try expect(
            firstWindows[0].attachedSheet == nil,
            "manual Reload of a clean document requested redundant confirmation"
        )

        let secondExternalText = "alpha external revision two, with a distinct size\n"
        try Data(secondExternalText.utf8).write(to: requestedURLs[0], options: .atomic)
        textWindowController.qaDeliverDocumentError(
            LighTxtCoreError.fileChangedExternally(path: requestedURLs[0].path)
        )
        try await waitUntil("a later disk revision to present a fresh decision") {
            textWindowController.qaExternalChangeBannerIsVisible
                && textWindowController.qaExternalChangePresentationCount == 2
        }
        try expect(
            firstWindows[0].attachedSheet == nil,
            "the later disk revision presented both a banner and a modal sheet"
        )
        textWindowController.qaActivateExternalReload()
        let expectedReloadedData = Data(secondExternalText.utf8)
        try await waitUntil("the real external-change Reload action") {
            guard firstDocuments[0].session.byteCount == Int64(expectedReloadedData.count) else {
                return false
            }
            return (try? firstDocuments[0].session.editorReadBytes(
                in: 0..<Int64(expectedReloadedData.count)
            )) == expectedReloadedData
        }
        try expect(
            !textWindowController.qaExternalChangeBannerIsVisible
                && firstWindows[0].attachedSheet == nil,
            "the real external-change Reload action left duplicate decision UI"
        )
        textWindowController.automaticallyReloadsCleanFiles = true

        // Cross the real CSV header callback and editor export dispatch. The
        // QA-only probe sits immediately before the save-panel entry point so
        // no modal UI is presented, while readiness still comes from the real
        // indexed CSV table.
        guard let csvWindowController = firstDocuments[1].windowControllers.first
            as? LighTxtWindowController else {
            throw QAError.failed("the CSV document has no production window controller")
        }
        var exportInvocationCount = 0
        csvWindowController.qaPrepareCSVExportProbe {
            exportInvocationCount += 1
        }
        try await waitUntil("the real CSV Export header control to become ready") {
            csvWindowController.qaIsExportControlReady
        }
        try expect(exportInvocationCount == 0, "Export routed before the header was activated")
        csvWindowController.qaActivateExportControl()
        try await waitUntil("the CSV Export header action to route") {
            exportInvocationCount == 1
        }
        try await Task.sleep(nanoseconds: 80_000_000)
        try expect(exportInvocationCount == 1, "one Export activation routed more than once")

        // Inject only the scheduler's size threshold and delay, then observe
        // both the production editor and its installed CSV table enter their
        // purged states after resignation and leave them on reactivation.
        csvWindowController.qaConfigureInactiveResidentPurge(
            minimumDocumentByteCount: 0,
            delay: 0.08
        )
        firstWindows[1].orderOut(nil)
        try deliverWindowDidResignKey(firstWindows[1])
        try await waitUntil("the inactive CSV window to purge its resident presentation") {
            csvWindowController.runtimeQAInactivePurgeAcceptedCount == 1
                && csvWindowController.qaIsResidentPresentationPurged
        }
        try expect(
            csvWindowController.runtimeQAInactivePurgeAttemptCount == 1,
            "inactive purge did not run exactly once"
        )
        try expect(
            csvWindowController.qaIsResidentPresentationPurged,
            "inactive purge did not change the actual editor and CSV table state"
        )
        try deliverWindowDidBecomeKey(firstWindows[1])
        try await waitUntil("the purged CSV window to reactivate its presentation") {
            csvWindowController.runtimeQAResidentReactivationCount == 1
                && !csvWindowController.qaIsResidentPresentationPurged
        }
        try expect(
            csvWindowController.runtimeQAResidentReactivationCount == 1,
            "window activation did not rehydrate the purged presentation exactly once"
        )

        // Exercise the production bookmark capture and the public replay
        // action. Closing every clean document must not erase the last task.
        documentController.captureCurrentTask()
        let originalIdentities = Set(firstDocuments.map { ObjectIdentifier($0) })
        // Simulate process teardown rather than ordinary one-by-one user
        // closes. Remove the complete set first so close notifications cannot
        // replace the captured task with a shrinking subset.
        firstDocuments.forEach { documentController.removeDocument($0) }
        firstDocuments.forEach { $0.close() }
        try await waitUntil("the original task to close") {
            self.documentController.documents.isEmpty
        }

        documentController.reopenLastTask(nil)
        try await waitUntil("Reopen Last Task to recreate every document") {
            self.documentController.documents.count == requestedURLs.count
                && self.documentController.documents.allSatisfy {
                    $0.windowControllers.first is LighTxtWindowController
                        && $0.windowControllers.first?.window != nil
                }
        }
        let replayedDocuments = try documentsByURL(requestedURLs)
        try expect(
            replayedDocuments.allSatisfy { !originalIdentities.contains(ObjectIdentifier($0)) },
            "Reopen Last Task retained an old document instead of recreating it"
        )
        try expect(
            Set(replayedDocuments.compactMap { $0.fileURL?.standardizedFileURL })
                == Set(requestedURLs.map(\.standardizedFileURL)),
            "Reopen Last Task did not restore the complete URL set"
        )
        try expect(
            Set(replayedDocuments.compactMap { $0.windowControllers.first?.window }
                .map { ObjectIdentifier($0) }).count == requestedURLs.count,
            "Reopen Last Task did not restore independent windows"
        )

        replayedDocuments.forEach { $0.close() }
        UserDefaults.standard.removePersistentDomain(forName: defaultsDomain)
    }

    private func verifyOpenPanelAndMenuConfiguration() throws {
        let ordinary = documentController.qaConfiguredOpenPanel(
            openAs: false,
            forceSeparateWindow: false
        )
        let separate = documentController.qaConfiguredOpenPanel(
            openAs: false,
            forceSeparateWindow: true
        )
        let openAs = documentController.qaConfiguredOpenPanel(
            openAs: true,
            forceSeparateWindow: false
        )
        try expect(
            ordinary.title == "Open Files" && ordinary.allowsMultipleSelection,
            "ordinary Open is not configured for multi-selection"
        )
        try expect(
            separate.title == "Open in New Window" && separate.allowsMultipleSelection,
            "Open in New Window is not configured for multi-selection"
        )
        try expect(
            openAs.title == "Open Any File As"
                && !openAs.allowsMultipleSelection
                && openAs.accessoryView is DocumentOpenAsAccessoryView,
            "Open As is not configured as a single-file interpreted open"
        )
        try expect(
            ordinary.canChooseFiles && !ordinary.canChooseDirectories
                && !ordinary.allowedContentTypes.isEmpty
                && openAs.allowedContentTypes.isEmpty,
            "Open panel file/type restrictions regressed"
        )

        guard let fileMenu = LighTxtMenu.qaFileMenu(documentController: documentController),
              let windowMenu = LighTxtMenu.qaWindowMenu(documentController: documentController) else {
            throw QAError.failed("production File or Window menu could not be constructed")
        }
        try expectMenuItem(
            in: fileMenu,
            title: "Open…",
            action: #selector(LighTxtDocumentController.openLighTxtDocument(_:)),
            target: documentController
        )
        try expectMenuItem(
            in: fileMenu,
            title: "Open in New Window…",
            action: #selector(LighTxtDocumentController.openLighTxtDocumentInNewWindow(_:)),
            target: documentController
        )
        try expectMenuItem(
            in: fileMenu,
            title: "Open As…",
            action: #selector(LighTxtDocumentController.openAsLighTxtDocument(_:)),
            target: documentController
        )
        let tabCommands: [(String, Selector)] = [
            ("Show Tab Bar", #selector(NSWindow.toggleTabBar(_:))),
            ("Previous Tab", #selector(NSWindow.selectPreviousTab(_:))),
            ("Next Tab", #selector(NSWindow.selectNextTab(_:))),
            ("Move Tab to New Window", #selector(NSWindow.moveTabToNewWindow(_:))),
            ("Merge All Windows", #selector(NSWindow.mergeAllWindows(_:))),
        ]
        for (title, action) in tabCommands {
            try expectMenuItem(in: windowMenu, title: title, action: action, target: nil)
        }
    }

    private func expectMenuItem(
        in menu: NSMenu,
        title: String,
        action: Selector,
        target: AnyObject?
    ) throws {
        guard let item = menu.items.first(where: { $0.title == title }) else {
            throw QAError.failed("menu item \(title) is missing")
        }
        try expect(item.action == action, "menu item \(title) has the wrong selector")
        if let target {
            try expect(item.target === target, "menu item \(title) has the wrong target")
        } else {
            try expect(item.target == nil, "menu item \(title) bypasses the responder chain")
        }
    }

    private func makeFixtures(in directory: URL) throws -> [URL] {
        let fixtures: [(String, String)] = [
            ("workflow-alpha.txt", "alpha\nplain text\n"),
            ("workflow-beta.csv", "name,value\nbeta,2\n"),
            ("workflow-gamma.json", "{\"name\":\"gamma\",\"value\":3}\n"),
        ]
        return try fixtures.map { name, contents in
            let url = directory.appendingPathComponent(name)
            try Data(contents.utf8).write(to: url, options: .atomic)
            return url.standardizedFileURL
        }
    }

    private func documentsByURL(_ requestedURLs: [URL]) throws -> [LighTxtDocument] {
        try requestedURLs.map { requestedURL in
            guard let document = documentController.documents
                .compactMap({ $0 as? LighTxtDocument })
                .first(where: { $0.fileURL?.standardizedFileURL == requestedURL.standardizedFileURL }) else {
                throw QAError.failed("missing document for \(requestedURL.lastPathComponent)")
            }
            return document
        }
    }

    private func deliverWindowDidBecomeKey(_ window: NSWindow) throws {
        guard let delegate = window.delegate else {
            throw QAError.failed("a production document window has no delegate")
        }
        delegate.windowDidBecomeKey?(
            Notification(name: NSWindow.didBecomeKeyNotification, object: window)
        )
    }

    private func deliverWindowDidResignKey(_ window: NSWindow) throws {
        guard let delegate = window.delegate else {
            throw QAError.failed("a production document window has no delegate")
        }
        delegate.windowDidResignKey?(
            Notification(name: NSWindow.didResignKeyNotification, object: window)
        )
    }

    private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw QAError.failed(message) }
        assertionCount += 1
    }

    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 12,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                throw QAError.failed("timed out waiting for \(description)")
            }
            try await Task.sleep(nanoseconds: 40_000_000)
        }
    }

    private func writeStandardOutput(_ text: String) {
        FileHandle.standardOutput.write(Data(text.utf8))
        try? FileHandle.standardOutput.synchronize()
    }

    private func writeStandardError(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
        try? FileHandle.standardError.synchronize()
    }

    private func writeResult(_ text: String) {
        try? Data(text.utf8).write(
            to: invocation.workspaceURL.appendingPathComponent("workflow-runtime-qa.result"),
            options: .atomic
        )
    }
}
#endif
