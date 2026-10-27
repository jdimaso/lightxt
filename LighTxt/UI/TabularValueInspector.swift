import AppKit

/// A read-only view of one bounded cell value. The table keeps its selection
/// and scroll position while this independently resizable window is open.
@MainActor
final class TabularValueInspector: NSWindowController, NSWindowDelegate {
    private let heading = NSTextField(labelWithString: "")
    private let context = NSTextField(labelWithString: "")
    private let notice = NSTextField(wrappingLabelWithString: "")
    private let textView = InspectorTextView()
    private let copyButton = NSButton(title: "Copy Value", target: nil, action: nil)
    private weak var sourceWindow: NSWindow?
    private weak var sourceResponder: NSResponder?
    private var currentIsTruncated = false
    private var hasBeenPresented = false
    var onClose: (() -> Void)?

    static func isInspectShortcut(_ event: NSEvent) -> Bool {
        event.charactersIgnoringModifiers?.lowercased() == "i"
            && event.modifierFlags.intersection([.command, .control, .option, .shift]) == [.command, .option]
    }

    init() {
        let panel = InspectorPanel(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 440),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Inspect Value"
        panel.minSize = NSSize(width: 400, height: 320)
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        panel.onDismiss = { [weak self] in self?.dismiss() }
        textView.onDismiss = { [weak self] in self?.dismiss() }
        configure()
        panel.setContentSize(NSSize(width: 660, height: 440))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(
        value: String,
        columnTitle: String,
        sourceRowNumber: Int64,
        isTruncated: Bool,
        isNull: Bool = false,
        parentWindow: NSWindow?
    ) {
        let wasVisible = window?.isVisible == true
        if !wasVisible {
            sourceWindow = parentWindow
            sourceResponder = parentWindow?.firstResponder
            NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
            if let parentWindow {
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(sourceWillClose(_:)),
                    name: NSWindow.willCloseNotification,
                    object: parentWindow
                )
            }
        }
        window?.appearance = parentWindow?.effectiveAppearance
        heading.stringValue = columnTitle
        context.stringValue = "Source row \(sourceRowNumber.formatted()) · Read-only"
        setValue(value, isTruncated: isTruncated, isNull: isNull)
        if !wasVisible {
            window?.center()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        if !hasBeenPresented {
            window?.setContentSize(NSSize(width: 660, height: 440))
            window?.center()
            hasBeenPresented = true
        }
        window?.makeFirstResponder(textView)
    }

    func setValue(_ value: String, isTruncated: Bool, loading: Bool = false, error: String? = nil, isNull: Bool = false) {
        // Every producer is bounded already; this final cap also protects
        // TextKit from a future caller accidentally providing a whole field.
        let displayLimit = 262_144
        let clipped = String(value.prefix(displayLimit))
        currentIsTruncated = isTruncated || clipped.utf8.count < value.utf8.count
        textView.string = clipped
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
        copyButton.title = currentIsTruncated ? "Copy Visible Text" : "Copy Value"
        if let error {
            notice.stringValue = "Showing the available preview. \(error)"
        } else if loading {
            notice.stringValue = "Loading a longer preview…"
        } else if currentIsTruncated {
            notice.stringValue = "Preview limited to \(clipped.count.formatted()) characters. This is not the complete value."
        } else if isNull {
            notice.stringValue = "Null value · No text is stored in this cell"
        } else if clipped.isEmpty {
            notice.stringValue = "Empty value"
        } else {
            notice.stringValue = "\(clipped.count.formatted()) characters · Complete value"
        }
        notice.setAccessibilityLabel(notice.stringValue)
    }

    func dismiss() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: nil)
        onClose?()
        textView.string = ""
        if let sourceWindow, sourceWindow.isVisible {
            sourceWindow.makeKeyAndOrderFront(nil)
            if let sourceResponder { sourceWindow.makeFirstResponder(sourceResponder) }
        }
        sourceWindow = nil
        sourceResponder = nil
    }

    private func configure() {
        guard let content = window?.contentView else { return }
        heading.font = .systemFont(ofSize: 16, weight: .semibold)
        heading.lineBreakMode = .byTruncatingMiddle
        heading.setAccessibilityLabel("Column")
        context.font = .systemFont(ofSize: 12)
        context.textColor = .secondaryLabelColor
        notice.font = .systemFont(ofSize: 12)
        notice.textColor = .secondaryLabelColor

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        textView.textColor = .textColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 620, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel("Cell value, read-only")

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.documentView = textView
        copyButton.target = self
        copyButton.action = #selector(copyValue(_:))
        copyButton.bezelStyle = .rounded
        copyButton.toolTip = "Copy the text displayed in this inspector"
        let done = NSButton(title: "Done", target: self, action: #selector(done(_:)))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\u{1b}"
        for view in [heading, context, scroll, notice, copyButton, done] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            heading.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            context.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 5),
            context.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            context.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: context.bottomAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            notice.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            notice.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            notice.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            copyButton.topAnchor.constraint(equalTo: notice.bottomAnchor, constant: 12),
            copyButton.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            copyButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -14),
            done.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            done.centerYAnchor.constraint(equalTo: copyButton.centerYAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100)
        ])
    }

    @objc private func copyValue(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(textView.string, forType: .string)
    }

    @objc private func done(_ sender: Any?) { dismiss() }

    @objc private func sourceWillClose(_ notification: Notification) {
        sourceWindow = nil
        sourceResponder = nil
        dismiss()
    }

#if LIGHTXT_STANDALONE_CSV_QA || LIGHTXT_STANDALONE_PARQUET_QA
    var qaText: String { textView.string }
    var qaContext: String { context.stringValue }
    var qaNotice: String { notice.stringValue }
    var qaCopyTitle: String { copyButton.title }
    var qaIsReadOnlyAndWrapped: Bool {
        !textView.isEditable && textView.isSelectable
            && textView.textContainer?.widthTracksTextView == true
            && !textView.isHorizontallyResizable
            && window?.styleMask.contains(.resizable) == true
    }
    func qaDismissWithEscape() { textView.cancelOperation(nil) }
#endif
}

@MainActor
private final class InspectorPanel: NSPanel {
    var onDismiss: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
}

@MainActor
private final class InspectorTextView: NSTextView {
    var onDismiss: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onDismiss?() }
}
