import AppKit

enum LighTxtAppearanceMode: String, CaseIterable, Sendable {
    case light
    case dark
    case system

    var title: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        case .system: "System"
        }
    }

    var menuIdentifier: NSUserInterfaceItemIdentifier {
        switch self {
        case .light: NSUserInterfaceItemIdentifier("LighTxt.Appearance.Light")
        case .dark: NSUserInterfaceItemIdentifier("LighTxt.Appearance.Dark")
        case .system: NSUserInterfaceItemIdentifier("LighTxt.Appearance.System")
        }
    }

    var applicationAppearance: NSAppearance? {
        switch self {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        case .system: nil
        }
    }
}

/// Owns the application-wide appearance preference. Applying the choice at
/// the NSApplication level lets every current and future document window use
/// the same effective appearance, while System continues to follow macOS.
@MainActor
final class LighTxtAppearanceController: NSObject, NSMenuItemValidation {
    static let preferenceKey = "LighTxt.appearanceMode"

    private let defaults: UserDefaults
    private let application: NSApplication
    private(set) var selectedMode: LighTxtAppearanceMode

    override convenience init() {
        self.init(defaults: .standard, application: .shared)
    }

    init(defaults: UserDefaults, application: NSApplication) {
        self.defaults = defaults
        self.application = application
        if let stored = defaults.string(forKey: Self.preferenceKey),
           let mode = LighTxtAppearanceMode(rawValue: stored) {
            selectedMode = mode
        } else {
            selectedMode = .light
        }
        super.init()
    }

    func applySelectedMode() {
        application.appearance = selectedMode.applicationAppearance
    }

    @objc func selectAppearance(_ sender: NSMenuItem) {
        guard let mode = mode(representedBy: sender) else { return }
        selectedMode = mode
        defaults.set(mode.rawValue, forKey: Self.preferenceKey)
        applySelectedMode()
        updateCheckmarks(in: sender.menu)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(selectAppearance(_:)),
              let mode = mode(representedBy: menuItem) else { return true }
        menuItem.state = mode == selectedMode ? .on : .off
        return true
    }

    private func updateCheckmarks(in menu: NSMenu?) {
        menu?.items.forEach { item in
            guard let mode = mode(representedBy: item) else { return }
            item.state = mode == selectedMode ? .on : .off
        }
    }

    private func mode(representedBy menuItem: NSMenuItem) -> LighTxtAppearanceMode? {
        guard let rawValue = menuItem.representedObject as? String else { return nil }
        return LighTxtAppearanceMode(rawValue: rawValue)
    }
}
