import AppKit
import Sparkle

@main
enum LighTxtApplication {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = LighTxtAppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

@MainActor
final class LighTxtAppDelegate: NSObject, NSApplicationDelegate {
    private var documentController: LighTxtDocumentController!
    private var appearanceController: LighTxtAppearanceController!
    private var fontController: LighTxtFontController!
    private var updaterController: SPUStandardUpdaterController!

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Apply the persisted preference before creating menus or windows so
        // every AppKit control resolves its initial colors consistently.
        appearanceController = LighTxtAppearanceController()
        appearanceController.applySelectedMode()
        fontController = LighTxtFontController()
        updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )

        // AppKit documents this launch callback as the supported point for
        // installing the first (therefore shared) custom document controller.
        // Constructing it before NSApplication.shared leaves window server and
        // accessibility registration only partially initialized.
        documentController = LighTxtDocumentController()
        NSApp.mainMenu = LighTxtMenu.makeMainMenu(
            documentController: documentController,
            appearanceController: appearanceController,
            fontController: fontController,
            updaterController: updaterController
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        let arguments = ProcessInfo.processInfo.arguments
        // AppKit completes persistent-window restoration just after the launch
        // callback. Presenting an untitled document inside that restoration
        // transaction can cause it to be immediately reconciled away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) { [weak self] in
            guard let self else { return }
            if let flag = arguments.firstIndex(of: "--benchmark-open"),
               arguments.indices.contains(flag + 1) {
                let url = URL(fileURLWithPath: arguments[flag + 1]).standardizedFileURL
                LighTxtSignpost.begin("BenchmarkOpen", bytes: (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0)
                self.documentController.openDocument(withContentsOf: url, display: true) { _, _, error in
                    if let error {
                        NSApp.presentError(error)
                    }
                    LighTxtSignpost.end("BenchmarkOpen", bytes: 0)
                }
                return
            }
            if self.documentController.documents.isEmpty {
                self.documentController.showHomeWindow()
            } else {
                self.documentController.reopenApplication()
            }
        }
    }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldSaveApplicationState(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldRestoreApplicationState(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        documentController.reopenApplication()
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // The shell intentionally has one active document. Finder may deliver
        // several URLs in one event; open the first rather than racing multiple
        // save-review sheets and leaving the final selection nondeterministic.
        guard let url = urls.first else { return }
        documentController.openDocument(withContentsOf: url, display: true) { _, _, error in
            if let error, (error as? CocoaError)?.code != .userCancelled {
                NSApp.presentError(error)
            }
        }
    }
}

@MainActor
final class LighTxtMenu: NSObject {
    static func makeMainMenu(
        documentController: LighTxtDocumentController,
        appearanceController: LighTxtAppearanceController,
        fontController: LighTxtFontController,
        updaterController: SPUStandardUpdaterController
    ) -> NSMenu {
        let main = NSMenu(title: "Main Menu")
        main.addItem(appMenuItem(updaterController: updaterController))
        main.addItem(fileMenuItem(documentController: documentController))
        main.addItem(editMenuItem(documentController: documentController))
        main.addItem(viewMenuItem(
            documentController: documentController,
            appearanceController: appearanceController,
            fontController: fontController
        ))
        main.addItem(windowMenuItem())
        main.addItem(helpMenuItem(documentController: documentController))
        return main
    }

    private static func appMenuItem(
        updaterController: SPUStandardUpdaterController
    ) -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "LighTxt")
        root.submenu = menu

        menu.addItem(item("About LighTxt", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:))))
        menu.addItem(.separator())

        let checkForUpdates = item(
            "Check for Updates…",
            action: #selector(SPUStandardUpdaterController.checkForUpdates(_:))
        )
        checkForUpdates.target = updaterController
        menu.addItem(checkForUpdates)
        menu.addItem(.separator())

        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        NSApp.servicesMenu = services

        menu.addItem(.separator())
        menu.addItem(item("Hide LighTxt", action: #selector(NSApplication.hide(_:)), key: "h"))
        let hideOthers = item("Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), key: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(item("Show All", action: #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Quit LighTxt", action: #selector(NSApplication.terminate(_:)), key: "q"))
        return root
    }

    private static func fileMenuItem(documentController: LighTxtDocumentController) -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "File")
        root.submenu = menu

        let newDocument = item("New", action: #selector(NSDocumentController.newDocument(_:)), key: "n")
        newDocument.target = documentController
        menu.addItem(newDocument)
        let openDocument = item(
            "Open…",
            action: #selector(LighTxtDocumentController.openLighTxtDocument(_:)),
            key: "o"
        )
        openDocument.target = documentController
        menu.addItem(openDocument)
        menu.addItem(recentDocumentsItem(documentController: documentController))
        menu.addItem(.separator())
        menu.addItem(item("Close", action: #selector(NSWindow.performClose(_:)), key: "w"))
        let save = item(
            "Save",
            action: #selector(LighTxtDocumentController.saveCurrentLighTxtDocument(_:)),
            key: "s"
        )
        save.target = documentController
        menu.addItem(save)
        let saveAs = item(
            "Save As…",
            action: #selector(LighTxtDocumentController.saveAsCurrentLighTxtDocument(_:)),
            key: "s"
        )
        saveAs.keyEquivalentModifierMask = [.command, .shift]
        saveAs.target = documentController
        menu.addItem(saveAs)
        let saveCopy = item(
            "Save a Copy…",
            action: #selector(LighTxtDocumentController.saveCopyOfCurrentLighTxtDocument(_:)),
            key: ""
        )
        saveCopy.target = documentController
        menu.addItem(saveCopy)
        let duplicate = item(
            "Duplicate",
            action: #selector(LighTxtDocumentController.duplicateCurrentLighTxtDocument(_:)),
            key: "d",
            modifiers: [.command, .shift]
        )
        duplicate.target = documentController
        menu.addItem(duplicate)
        return root
    }

    private static func recentDocumentsItem(documentController: LighTxtDocumentController) -> NSMenuItem {
        let root = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Open Recent")
        root.submenu = menu
        for url in documentController.recentDocumentURLs.prefix(12) {
            let recent = NSMenuItem(
                title: url.lastPathComponent,
                action: #selector(LighTxtDocumentController.openRecentLighTxtDocument(_:)),
                keyEquivalent: ""
            )
            recent.target = documentController
            recent.representedObject = url
            recent.toolTip = url.path
            menu.addItem(recent)
        }
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }
        let clear = item("Clear Menu", action: #selector(NSDocumentController.clearRecentDocuments(_:)))
        clear.target = documentController
        menu.addItem(clear)
        return root
    }

    private static func editMenuItem(documentController: LighTxtDocumentController) -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        root.submenu = menu

        let undo = item(
            "Undo",
            action: #selector(LighTxtDocumentController.undoCurrentLighTxtDocument(_:)),
            key: "z"
        )
        undo.target = documentController
        menu.addItem(undo)
        let redo = item(
            "Redo",
            action: #selector(LighTxtDocumentController.redoCurrentLighTxtDocument(_:)),
            key: "z",
            modifiers: [.command, .shift]
        )
        redo.target = documentController
        menu.addItem(redo)
        menu.addItem(.separator())
        menu.addItem(item("Cut", action: #selector(NSText.cut(_:)), key: "x"))
        menu.addItem(item("Copy", action: #selector(NSText.copy(_:)), key: "c"))
        menu.addItem(item("Paste", action: #selector(NSText.paste(_:)), key: "v"))
        menu.addItem(item("Delete", action: #selector(NSText.delete(_:))))
        menu.addItem(item("Select All", action: #selector(NSText.selectAll(_:)), key: "a"))
        menu.addItem(.separator())
        let find = item(
            "Find…",
            action: #selector(LighTxtDocumentController.showFindForCurrentLighTxtDocument(_:)),
            key: "f"
        )
        find.target = documentController
        menu.addItem(find)
        let next = item(
            "Find Next",
            action: #selector(LighTxtDocumentController.findNextInCurrentLighTxtDocument(_:)),
            key: "g"
        )
        next.target = documentController
        menu.addItem(next)
        let previous = item(
            "Find Previous",
            action: #selector(LighTxtDocumentController.findPreviousInCurrentLighTxtDocument(_:)),
            key: "g",
            modifiers: [.command, .shift]
        )
        previous.target = documentController
        menu.addItem(previous)
        let useSelection = item(
            "Use Selection for Find",
            action: #selector(LighTxtDocumentController.useSelectionForFindInCurrentLighTxtDocument(_:)),
            key: "e"
        )
        useSelection.target = documentController
        menu.addItem(useSelection)
        return root
    }

    private static func viewMenuItem(
        documentController: LighTxtDocumentController,
        appearanceController: LighTxtAppearanceController,
        fontController: LighTxtFontController
    ) -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "View")
        root.submenu = menu
        let showFind = item(
            "Show Find & Replace",
            action: #selector(LighTxtDocumentController.showFindForCurrentLighTxtDocument(_:)),
            key: "f"
        )
        showFind.target = documentController
        menu.addItem(showFind)
        let goToLine = item(
            "Go to Line…",
            action: #selector(LighTxtDocumentController.showGoToLineForCurrentLighTxtDocument(_:)),
            key: "l"
        )
        goToLine.target = documentController
        menu.addItem(goToLine)
        menu.addItem(.separator())
        let biggerText = item(
            "Bigger Text",
            action: #selector(LighTxtDocumentController.increaseFontSizeInCurrentLighTxtDocument(_:)),
            key: "+"
        )
        biggerText.target = documentController
        menu.addItem(biggerText)
        let smallerText = item(
            "Smaller Text",
            action: #selector(LighTxtDocumentController.decreaseFontSizeInCurrentLighTxtDocument(_:)),
            key: "-"
        )
        smallerText.target = documentController
        menu.addItem(smallerText)
        let actualSize = item(
            "Actual Size",
            action: #selector(LighTxtDocumentController.resetFontSizeInCurrentLighTxtDocument(_:)),
            key: "0"
        )
        actualSize.target = documentController
        menu.addItem(actualSize)
        menu.addItem(fontMenuItem(controller: fontController))
        menu.addItem(.separator())
        menu.addItem(appearanceMenuItem(controller: appearanceController))
        menu.addItem(.separator())
        let toggleStructure = item(
            "Toggle Structure",
            action: #selector(LighTxtDocumentController.toggleStructureForCurrentLighTxtDocument(_:)),
            key: "0",
            modifiers: [.command, .option]
        )
        toggleStructure.target = documentController
        menu.addItem(toggleStructure)
        menu.addItem(item("Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), key: "f", modifiers: [.command, .control]))
        return root
    }

    private static func fontMenuItem(controller: LighTxtFontController) -> NSMenuItem {
        let root = NSMenuItem(title: "Font", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Font")
        root.submenu = menu

        for font in LighTxtEditorFontChoice.allCases {
            let choice = NSMenuItem(
                title: font.title,
                action: #selector(LighTxtFontController.selectEditorFont(_:)),
                keyEquivalent: ""
            )
            choice.target = controller
            choice.representedObject = font.rawValue
            choice.identifier = font.menuIdentifier
            choice.state = font == controller.selectedChoice ? .on : .off
            menu.addItem(choice)
        }
        return root
    }

    private static func appearanceMenuItem(
        controller: LighTxtAppearanceController
    ) -> NSMenuItem {
        let root = NSMenuItem(title: "Appearance", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Appearance")
        root.submenu = menu

        for mode in LighTxtAppearanceMode.allCases {
            let choice = NSMenuItem(
                title: mode.title,
                action: #selector(LighTxtAppearanceController.selectAppearance(_:)),
                keyEquivalent: ""
            )
            choice.target = controller
            choice.representedObject = mode.rawValue
            choice.identifier = mode.menuIdentifier
            choice.state = mode == controller.selectedMode ? .on : .off
            menu.addItem(choice)
        }
        return root
    }

    private static func windowMenuItem() -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "Window")
        root.submenu = menu
        menu.addItem(item("Minimize", action: #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        menu.addItem(item("Zoom", action: #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(item("Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:))))
        NSApp.windowsMenu = menu
        return root
    }

    private static func helpMenuItem(documentController: LighTxtDocumentController) -> NSMenuItem {
        let root = NSMenuItem()
        let menu = NSMenu(title: "Help")
        root.submenu = menu
        let help = item(
            "LighTxt Help",
            action: #selector(LighTxtDocumentController.showHelpForCurrentLighTxtDocument(_:))
        )
        help.target = documentController
        menu.addItem(help)
        NSApp.helpMenu = menu
        return root
    }

    private static func item(
        _ title: String,
        action: Selector?,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        return item
    }
}
