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
    static let readingFontPreferenceKey = "LighTxt.prettifiedReadingFontSize"
    private var fontSize: CGFloat = {
        let saved = UserDefaults.standard.double(forKey: PrettifiedViewportView.readingFontPreferenceKey)
        return saved.isFinite && saved >= 9 && saved <= 30 ? CGFloat(saved) : 15
    }()
    private var syntaxTask: Task<Void, Never>?
    private var syntaxGeneration: UInt64 = 0
    private var decorations: [PrettifiedSyntaxDecoration] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
        applyResolvedAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        syntaxTask?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

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
        cancelSyntax()
        statusLabel.stringValue = "Preparing read-only \(fileType.displayName) preview for bytes \(byteRange.lowerBound.formatted())–\(byteRange.upperBound.formatted())…"
        statusLabel.toolTip = statusLabel.stringValue
        textView.string = ""
    }

    func show(_ result: ViewportPrettifier.Result, fileType: SyntaxFileType = .json) {
        cancelSyntax()
        statusLabel.stringValue = result.status
        statusLabel.toolTip = result.status
        statusLabel.textColor = LighTxtTheme.resolved(
            result.didPrettify ? LighTxtTheme.secondaryText : LighTxtTheme.error,
            for: effectiveAppearance
        )
        textView.string = result.text
        applyFont()
        // Highlight only the formatter's bounded output. A fallback may begin
        // inside a token, so retain its source-faithful plain-text treatment.
        if result.didPrettify {
            highlight(result.text, as: fileType, skippingPartialLine: result.preservedLeadingPartialLine)
        }
        textView.scrollToBeginningOfDocument(nil)
        textView.setAccessibilityValueDescription(
            result.didPrettify ? "Prettified bounded source preview" : "Exact bounded source fallback"
        )
    }

    func changeFontSize(by delta: CGFloat) { setFontSize(fontSize + delta) }
    func resetFontSize() { setFontSize(15) }

    private func setFontSize(_ value: CGFloat) {
        fontSize = min(30, max(9, value))
        UserDefaults.standard.set(Double(fontSize), forKey: Self.readingFontPreferenceKey)
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
        applySyntaxAppearance()
    }

    private func cancelSyntax() {
        syntaxTask?.cancel()
        syntaxTask = nil
        syntaxGeneration &+= 1
        decorations.removeAll(keepingCapacity: false)
    }

    private func highlight(_ text: String, as fileType: SyntaxFileType, skippingPartialLine: Bool) {
        let generation = syntaxGeneration
        syntaxTask = Task.detached(priority: .userInitiated) { [weak self] in
            let decorations = PrettifiedSyntaxDecoration.build(
                text, fileType: fileType, skippingPartialLine: skippingPartialLine
            )
            guard !Task.isCancelled else { return }
            await self?.install(decorations, generation: generation)
        }
    }

    private func install(_ decorations: [PrettifiedSyntaxDecoration], generation: UInt64) {
        guard generation == syntaxGeneration else { return }
        syntaxTask = nil
        self.decorations = decorations
        applySyntaxAppearance()
    }

    private func applySyntaxAppearance() {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let fontChoice = LighTxtEditorFontChoice.persisted()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        storage.beginEditing()
        storage.setAttributes([
            .font: fontChoice.font(ofSize: fontSize),
            .foregroundColor: LighTxtTheme.resolved(LighTxtTheme.primaryText, for: effectiveAppearance),
            .paragraphStyle: paragraph,
        ], range: NSRange(location: 0, length: storage.length))
        for decoration in decorations where NSMaxRange(decoration.range) <= storage.length {
            var attributes = SyntaxPalette.attributes(for: decoration.kind, appearance: effectiveAppearance)
            attributes[.font] = fontChoice.font(
                ofSize: fontSize,
                emphasized: decoration.kind == .key || decoration.kind == .keyword
            )
            storage.addAttributes(attributes, range: decoration.range)
        }
        storage.endEditing()
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
        applySyntaxAppearance()
    }

#if LIGHTXT_RUNTIME_QA
    var qaText: String { textView.string }
    var qaStatus: String { statusLabel.stringValue }
    var qaIsEditable: Bool { textView.isEditable }
    var qaIsSelectable: Bool { textView.isSelectable }
    var qaFontSize: CGFloat { fontSize }
    var qaHighlightedSpanCount: Int { decorations.count }
    var qaHighlightingInProgress: Bool { syntaxTask != nil }
    var qaAccessibilityLabel: String? { accessibilityLabel() }
    var qaTextAccessibilityLabel: String? { textView.accessibilityLabel() }
#endif
}

/// Maps lexer byte ranges to AppKit's UTF-16 coordinates in one linear scan.
/// This owns only the already bounded formatted viewport, never the document.
private struct PrettifiedSyntaxDecoration: Sendable {
    let range: NSRange
    let kind: SyntaxSemanticKind

    nonisolated static func build(_ text: String, fileType: SyntaxFileType, skippingPartialLine: Bool) -> [Self] {
        let data = Data(text.utf8)
        guard data.count <= ViewportPrettifier.defaultMaximumOutputBytes, !Task.isCancelled else { return [] }
        // The formatter can preserve a leading fragment of a quoted value.
        // Its lexical state is intentionally unknown; begin at the next line
        // instead of allowing a dangling quote to invert all later colors.
        let start: Int
        if skippingPartialLine {
            guard let newline = data.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) else { return [] }
            start = newline + 1
        } else {
            start = 0
        }
        let highlighted = ViewportSyntaxHighlighter.highlight(
            data.subdata(in: start..<data.count), as: fileType, baseByteOffset: start
        )
        let spans = highlighted.spans.sorted { $0.range.start < $1.range.start }
        var result: [Self] = []
        result.reserveCapacity(spans.count)
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var byteOffset = 0
            var utf16Offset = 0
            func advance(to requested: Int) -> Int {
                let target = min(requested, bytes.count)
                while byteOffset < target {
                    let byte = bytes[byteOffset]
                    if byte < 0x80 || byte >= 0xC0 { utf16Offset += byte >= 0xF0 ? 2 : 1 }
                    byteOffset += 1
                }
                return utf16Offset
            }
            for span in spans {
                if Task.isCancelled { return }
                guard span.range.start >= byteOffset else { continue }
                let lower = advance(to: span.range.start)
                let upper = advance(to: span.range.end)
                if upper > lower {
                    result.append(Self(range: NSRange(location: lower, length: upper - lower), kind: span.kind))
                }
            }
        }
        return result
    }
}
