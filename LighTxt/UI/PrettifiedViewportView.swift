import AppKit

/// A presentation-only surface for a prettified bounded editor viewport.
/// The editable `VirtualTextEditorView` remains alive offscreen, preserving its
/// exact selection and scroll geometry until this view is removed.
@MainActor
final class PrettifiedViewportView: NSView {
    private let banner = NSView()
    private let statusLabel = NSTextField(labelWithString: "Preparing read-only preview…")
    private let scrollView = NSScrollView()
    private let textView = NSTextView(frame: .zero)
    private var fontSize: CGFloat = 13

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
        applyResolvedAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(textView)
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyResolvedAppearance()
    }

    func showLoading(fileType: SyntaxFileType, byteRange: Range<Int64>) {
        statusLabel.stringValue = "Preparing read-only \(fileType.displayName) preview for bytes \(byteRange.lowerBound.formatted())–\(byteRange.upperBound.formatted())…"
        statusLabel.toolTip = statusLabel.stringValue
        textView.string = ""
    }

    func show(_ result: ViewportPrettifier.Result) {
        statusLabel.stringValue = result.status
        statusLabel.toolTip = result.status
        statusLabel.textColor = LighTxtTheme.resolved(
            result.didPrettify ? LighTxtTheme.secondaryText : LighTxtTheme.error,
            for: effectiveAppearance
        )
        textView.string = result.text
        applyFont()
        textView.scrollToBeginningOfDocument(nil)
        textView.setAccessibilityValueDescription(
            result.didPrettify ? "Prettified bounded source preview" : "Exact bounded source fallback"
        )
    }

    func changeFontSize(by delta: CGFloat) { setFontSize(fontSize + delta) }
    func resetFontSize() { setFontSize(13) }

    private func setFontSize(_ value: CGFloat) {
        fontSize = min(30, max(9, value))
        applyFont()
    }

    private func configure() {
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Read-only prettified viewport")
        setAccessibilityHelp("Uncheck Prettify to return to the exact editable source without changing the document.")

        banner.wantsLayer = true
        statusLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 1
        statusLabel.setAccessibilityLabel("Prettify status")

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.setAccessibilityLabel("Read-only prettified source")
        scrollView.documentView = textView

        [banner, scrollView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            banner.leadingAnchor.constraint(equalTo: leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: trailingAnchor),
            banner.topAnchor.constraint(equalTo: topAnchor),
            banner.heightAnchor.constraint(equalToConstant: 30),
            statusLabel.leadingAnchor.constraint(equalTo: banner.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: banner.trailingAnchor, constant: -12),
            statusLabel.centerYAnchor.constraint(equalTo: banner.centerYAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: banner.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(editorFontDidChange(_:)),
            name: .lighTxtEditorFontDidChange,
            object: nil
        )
        applyFont()
    }

    @objc private func editorFontDidChange(_ notification: Notification) { applyFont() }

    private func applyFont() {
        let font = LighTxtEditorFontChoice.persisted().font(ofSize: fontSize)
        textView.font = font
        if let storage = textView.textStorage, storage.length > 0 {
            storage.addAttribute(.font, value: font, range: NSRange(location: 0, length: storage.length))
        }
    }

    private func applyResolvedAppearance() {
        let appearance = effectiveAppearance
        let background = LighTxtTheme.resolved(LighTxtTheme.editorBackground, for: appearance)
        layer?.backgroundColor = background.cgColor
        banner.layer?.backgroundColor = LighTxtTheme.resolved(
            LighTxtTheme.chromeBackground,
            for: appearance
        ).cgColor
        scrollView.backgroundColor = background
        textView.backgroundColor = background
        textView.textColor = LighTxtTheme.resolved(LighTxtTheme.primaryText, for: appearance)
        statusLabel.textColor = LighTxtTheme.resolved(LighTxtTheme.secondaryText, for: appearance)
    }

#if LIGHTXT_RUNTIME_QA
    var qaText: String { textView.string }
    var qaStatus: String { statusLabel.stringValue }
    var qaIsEditable: Bool { textView.isEditable }
    var qaIsSelectable: Bool { textView.isSelectable }
    var qaFontSize: CGFloat { fontSize }
    var qaAccessibilityLabel: String? { accessibilityLabel() }
    var qaTextAccessibilityLabel: String? { textView.accessibilityLabel() }
#endif
}
