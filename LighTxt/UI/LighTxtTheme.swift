import AppKit

enum LighTxtTheme {
    static let editorFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let gutterFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    static let detailFont = NSFont.systemFont(ofSize: 11, weight: .regular)

    static let windowBackground = dynamic(
        light: NSColor(calibratedRed: 0.973, green: 0.986, blue: 0.987, alpha: 1),
        dark: NSColor(calibratedRed: 0.071, green: 0.086, blue: 0.093, alpha: 1)
    )
    static let editorBackground = dynamic(
        light: NSColor(calibratedRed: 0.993, green: 0.997, blue: 0.997, alpha: 1),
        dark: NSColor(calibratedRed: 0.054, green: 0.064, blue: 0.071, alpha: 1)
    )
    static let chromeBackground = dynamic(
        light: NSColor(calibratedRed: 0.949, green: 0.978, blue: 0.979, alpha: 0.96),
        dark: NSColor(calibratedRed: 0.085, green: 0.112, blue: 0.119, alpha: 0.96)
    )
    static let gutterBackground = dynamic(
        light: NSColor(calibratedRed: 0.966, green: 0.984, blue: 0.984, alpha: 1),
        dark: NSColor(calibratedRed: 0.065, green: 0.081, blue: 0.087, alpha: 1)
    )
    static let separator = dynamic(
        light: NSColor(calibratedRed: 0.81, green: 0.89, blue: 0.89, alpha: 0.7),
        dark: NSColor(calibratedRed: 0.19, green: 0.29, blue: 0.30, alpha: 0.75)
    )
    static let primaryText = dynamic(
        light: NSColor(calibratedWhite: 0.16, alpha: 1),
        dark: NSColor(calibratedWhite: 0.88, alpha: 1)
    )
    static let secondaryText = dynamic(
        light: NSColor(calibratedRed: 0.35, green: 0.44, blue: 0.46, alpha: 1),
        dark: NSColor(calibratedRed: 0.58, green: 0.68, blue: 0.69, alpha: 1)
    )
    static let accent = dynamic(
        light: NSColor(calibratedRed: 0.06, green: 0.48, blue: 0.51, alpha: 1),
        dark: NSColor(calibratedRed: 0.28, green: 0.75, blue: 0.72, alpha: 1)
    )
    static let selection = dynamic(
        light: NSColor(calibratedRed: 0.55, green: 0.84, blue: 0.84, alpha: 0.48),
        dark: NSColor(calibratedRed: 0.13, green: 0.47, blue: 0.48, alpha: 0.68)
    )
    static let match = dynamic(
        light: NSColor(calibratedRed: 0.72, green: 0.92, blue: 0.78, alpha: 0.72),
        dark: NSColor(calibratedRed: 0.19, green: 0.48, blue: 0.35, alpha: 0.82)
    )
    static let currentLine = dynamic(
        light: NSColor(calibratedRed: 0.89, green: 0.96, blue: 0.96, alpha: 0.65),
        dark: NSColor(calibratedRed: 0.10, green: 0.17, blue: 0.18, alpha: 0.82)
    )
    static let error = dynamic(
        light: NSColor(calibratedRed: 0.76, green: 0.22, blue: 0.27, alpha: 1),
        dark: NSColor(calibratedRed: 1.0, green: 0.42, blue: 0.45, alpha: 1)
    )

    /// Converts an adaptive color into a concrete color using the appearance
    /// of the view that will draw it. This is required before bridging to
    /// CGColor, and keeps attributed text and its surface on the same palette
    /// when a window is attached or macOS changes appearance at runtime.
    static func resolved(_ color: NSColor, for appearance: NSAppearance) -> NSColor {
        var result = color
        appearance.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.deviceRGB) ?? color
        }
        return result
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua ? dark : light
        }
    }
}

final class QuietButton: NSButton {
    init(
        title: String,
        symbolName: String? = nil,
        minimumHeight: CGFloat = 28,
        target: AnyObject?,
        action: Selector?
    ) {
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        bezelStyle = .rounded
        controlSize = .regular
        isBordered = true
        font = NSFont.systemFont(ofSize: 12, weight: .medium)
        contentTintColor = LighTxtTheme.secondaryText
        if let symbolName, let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: title) {
            image = symbol.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            )
            imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        }
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight).isActive = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyResolvedAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyResolvedAppearance()
    }

    private func applyResolvedAppearance() {
        contentTintColor = LighTxtTheme.resolved(
            LighTxtTheme.secondaryText,
            for: effectiveAppearance
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

extension ByteCountFormatter {
    static let lighTxt: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()
}
