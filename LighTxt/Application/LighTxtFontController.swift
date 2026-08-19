import AppKit

enum LighTxtEditorFontChoice: String, CaseIterable, Sendable {
    case systemMonospaced
    case menlo
    case systemSans
    case georgia

    static let defaultChoice: Self = .systemMonospaced

    var title: String {
        switch self {
        case .systemMonospaced: "System Mono"
        case .menlo: "Menlo"
        case .systemSans: "System Sans"
        case .georgia: "Georgia"
        }
    }

    var menuIdentifier: NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("LighTxt.Font.\(rawValue)")
    }

    @MainActor
    func font(ofSize size: CGFloat, emphasized: Bool = false) -> NSFont {
        switch self {
        case .systemMonospaced:
            return NSFont.monospacedSystemFont(
                ofSize: size,
                weight: emphasized ? .semibold : .regular
            )
        case .menlo:
            let name = emphasized ? "Menlo-Bold" : "Menlo-Regular"
            return NSFont(name: name, size: size)
                ?? NSFont.monospacedSystemFont(
                    ofSize: size,
                    weight: emphasized ? .semibold : .regular
                )
        case .systemSans:
            return NSFont.systemFont(
                ofSize: size,
                weight: emphasized ? .semibold : .regular
            )
        case .georgia:
            let name = emphasized ? "Georgia-Bold" : "Georgia"
            return NSFont(name: name, size: size)
                ?? NSFont.systemFont(
                    ofSize: size,
                    weight: emphasized ? .semibold : .regular
                )
        }
    }

    @MainActor
    static func persisted(in defaults: UserDefaults = .standard) -> Self {
        guard let rawValue = defaults.string(forKey: LighTxtFontController.preferenceKey),
              let choice = Self(rawValue: rawValue) else { return .defaultChoice }
        return choice
    }
}

extension Notification.Name {
    static let lighTxtEditorFontDidChange = Notification.Name("LighTxt.EditorFontDidChange")
}

/// Owns the lightweight, application-wide editor font preference. Existing
/// editor viewports receive a notification and repaint in place; future
/// windows read the same persisted choice without materializing more text.
@MainActor
final class LighTxtFontController: NSObject, NSMenuItemValidation {
    static let preferenceKey = "LighTxt.editorFont"
    static let notificationChoiceKey = "choice"

    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private(set) var selectedChoice: LighTxtEditorFontChoice

    override convenience init() {
        self.init(defaults: .standard, notificationCenter: .default)
    }

    init(defaults: UserDefaults, notificationCenter: NotificationCenter) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        selectedChoice = LighTxtEditorFontChoice.persisted(in: defaults)
        super.init()
    }

    @objc func selectEditorFont(_ sender: NSMenuItem) {
        guard let choice = choice(representedBy: sender) else { return }
        selectedChoice = choice
        defaults.set(choice.rawValue, forKey: Self.preferenceKey)
        notificationCenter.post(
            name: .lighTxtEditorFontDidChange,
            object: self,
            userInfo: [Self.notificationChoiceKey: choice.rawValue]
        )
        updateCheckmarks(in: sender.menu)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(selectEditorFont(_:)),
              let choice = choice(representedBy: menuItem) else { return true }
        menuItem.state = choice == selectedChoice ? .on : .off
        return true
    }

    private func updateCheckmarks(in menu: NSMenu?) {
        menu?.items.forEach { item in
            guard let choice = choice(representedBy: item) else { return }
            item.state = choice == selectedChoice ? .on : .off
        }
    }

    private func choice(representedBy menuItem: NSMenuItem) -> LighTxtEditorFontChoice? {
        guard let rawValue = menuItem.representedObject as? String else { return nil }
        return LighTxtEditorFontChoice(rawValue: rawValue)
    }
}
