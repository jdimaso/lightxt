import AppKit

@MainActor
final class ExternalChangeBannerView: NSView {
    var onReload: (() -> Void)?
    var onKeep: (() -> Void)?
    var onSaveAs: (() -> Void)?

    private let icon = NSImageView()
    private let message = NSTextField(wrappingLabelWithString: "")
    private lazy var reloadButton = QuietButton(
        title: "Reload",
        symbolName: "arrow.clockwise",
        minimumHeight: 26,
        target: self,
        action: #selector(reload(_:))
    )
    private lazy var keepButton = QuietButton(
        title: "Don’t Reload",
        symbolName: nil,
        minimumHeight: 26,
        target: self,
        action: #selector(keep(_:))
    )
    private lazy var saveAsButton = QuietButton(
        title: "Save As…",
        symbolName: nil,
        minimumHeight: 26,
        target: self,
        action: #selector(saveAs(_:))
    )

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.14).cgColor

        icon.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "File changed on disk"
        )
        icon.contentTintColor = .systemOrange
        icon.translatesAutoresizingMaskIntoConstraints = false

        message.font = .systemFont(ofSize: 12.5, weight: .medium)
        message.textColor = .labelColor
        message.maximumNumberOfLines = 2
        message.lineBreakMode = .byTruncatingTail
        message.translatesAutoresizingMaskIntoConstraints = false

        let actions = NSStackView(views: [reloadButton, keepButton, saveAsButton])
        actions.orientation = .horizontal
        actions.spacing = 6
        actions.alignment = .centerY
        actions.translatesAutoresizingMaskIntoConstraints = false

        [icon, message, actions].forEach(addSubview)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
            message.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            message.centerYAnchor.constraint(equalTo: centerYAnchor),
            message.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -12),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            actions.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel("External file change")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present(_ change: ExternalFileChange) {
        switch change.kind {
        case .appeared:
            message.stringValue = "The file is available on disk again."
        case let .appended(range):
            message.stringValue = "The file grew by \(range.count.formatted()) bytes in another application."
        case let .truncated(from, to):
            message.stringValue = "The file was shortened on disk from \(from.formatted()) to \(to.formatted()) bytes."
        case .modified:
            message.stringValue = "The file changed in another application."
        case .replaced:
            message.stringValue = "A different file replaced this path on disk."
        case .removed:
            message.stringValue = "The file was removed or moved on disk."
        }
        reloadButton.isEnabled = change.current != nil
        isHidden = false
    }

    @objc private func reload(_ sender: Any?) { onReload?() }
    @objc private func keep(_ sender: Any?) { onKeep?() }
    @objc private func saveAs(_ sender: Any?) { onSaveAs?() }

#if LIGHTXT_RUNTIME_QA
    var qaReloadButtonTitle: String { reloadButton.title }
    var qaKeepButtonTitle: String { keepButton.title }
    var qaSaveAsButtonTitle: String { saveAsButton.title }
    var qaReloadIsEnabled: Bool { reloadButton.isEnabled }
    func qaActivateReload() { reloadButton.performClick(nil) }
    func qaActivateKeep() { keepButton.performClick(nil) }
#endif
}
