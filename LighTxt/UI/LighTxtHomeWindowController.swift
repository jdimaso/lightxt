import AppKit

/// A lightweight launcher shown only when no document window is visible.
/// It deliberately owns no NSDocument or editor session; every Open action is
/// handed back to LighTxtDocumentController so the single-document review and
/// security-scope paths remain authoritative.
@MainActor
final class LighTxtHomeWindowController: NSWindowController, NSWindowDelegate {
    var onOpenFromDisk: (() -> Void)?
    var onOpenRecent: ((URL) -> Void)?

    private let homeViewController = LighTxtHomeViewController()
    private var needsInitialCenter = true

    init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: 760, height: 620)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Open File"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = LighTxtTheme.windowBackground
        window.collectionBehavior = [.managed]
        window.tabbingMode = .disallowed
        // Keep the launcher independent from NSDocument's view-controller
        // fitting pass. AppKit can otherwise collapse a controller-backed
        // window to its compressed Auto Layout width the first time it is
        // ordered front.
        let homeView = homeViewController.view
        homeView.frame = NSRect(origin: .zero, size: NSSize(width: 760, height: 620))
        homeView.autoresizingMask = [.width, .height]
        window.contentView = homeView
        window.minSize = NSSize(width: 620, height: 500)
        window.setContentSize(NSSize(width: 760, height: 620))
        window.isReleasedWhenClosed = false

        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = false

        homeViewController.onOpenFromDisk = { [weak self] in
            self?.onOpenFromDisk?()
        }
        homeViewController.onOpenRecent = { [weak self] url in
            self?.onOpenRecent?(url)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateRecentFiles(_ urls: [URL]) {
        homeViewController.updateRecentFiles(urls)
    }

    func showUnavailableFile(_ url: URL) {
        homeViewController.showStatus(
            "“\(url.lastPathComponent)” is no longer available.",
            isError: true
        )
    }

    func showOpenError(_ error: Error) {
        homeViewController.showStatus(error.localizedDescription, isError: true)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        if needsInitialCenter {
            window?.setContentSize(NSSize(width: 760, height: 620))
            window?.center()
            needsInitialCenter = false
        }
        window?.makeKeyAndOrderFront(sender)
        homeViewController.focusPrimaryAction()
    }
}

@MainActor
private final class LighTxtHomeViewController: NSViewController {
    var onOpenFromDisk: (() -> Void)?
    var onOpenRecent: ((URL) -> Void)?

    private let brandView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Open a file")
    private let subtitleLabel = NSTextField(
        labelWithString: "Fast, focused viewing and editing for text, JSON, Markdown, CSV, and more."
    )
    private let openButton = LighTxtHomePrimaryButton(title: "Open from Disk…")
    private let recentTitleLabel = NSTextField(labelWithString: "Recent Files")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let scrollView = NSScrollView()
    private let recentContentView = NSView()
    private let recentStack = NSStackView()
    private let emptyRecentLabel = NSTextField(
        wrappingLabelWithString: "No recent files yet. Open a file from disk to get started."
    )

    override func loadView() {
        let root = LighTxtHomeRootView()
        root.wantsLayer = true
        root.onAppearanceChange = { [weak self] in self?.applyResolvedAppearance() }
        root.setAccessibilityElement(true)
        root.setAccessibilityRole(.group)
        root.setAccessibilityLabel("Open File")
        view = root
        configure()
        applyResolvedAppearance()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        focusPrimaryAction()
    }

    func focusPrimaryAction() {
        view.window?.makeFirstResponder(openButton)
    }

    func updateRecentFiles(_ urls: [URL]) {
        statusLabel.isHidden = true
        recentStack.arrangedSubviews.forEach { child in
            recentStack.removeArrangedSubview(child)
            child.removeFromSuperview()
        }

        var seen = Set<URL>()
        var displayedCount = 0
        for candidate in urls {
            guard displayedCount < 12 else { break }
            let url = candidate.standardizedFileURL
            guard seen.insert(url).inserted else { continue }
            let isAvailable = Self.isAvailable(url)
            let button = LighTxtRecentFileButton(url: url, isAvailable: isAvailable)
            button.target = self
            button.action = #selector(openRecent(_:))
            recentStack.addArrangedSubview(button)
            button.widthAnchor.constraint(equalTo: recentStack.widthAnchor).isActive = true
            displayedCount += 1
        }

        emptyRecentLabel.isHidden = !recentStack.arrangedSubviews.isEmpty
        recentStack.isHidden = recentStack.arrangedSubviews.isEmpty
    }

    func showStatus(_ text: String, isError: Bool) {
        statusLabel.stringValue = text
        statusLabel.textColor = isError ? LighTxtTheme.error : LighTxtTheme.secondaryText
        statusLabel.isHidden = false
        statusLabel.setAccessibilityLabel(text)
    }

    private func configure() {
        brandView.image = NSImage(named: "BrandMark")
        brandView.imageScaling = .scaleProportionallyUpOrDown
        brandView.setAccessibilityHidden(true)

        titleLabel.font = NSFont.systemFont(ofSize: 28, weight: .semibold)
        titleLabel.alignment = .center
        subtitleLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.alignment = .center
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.lineBreakMode = .byWordWrapping

        openButton.target = self
        openButton.action = #selector(openFromDisk(_:))
        openButton.keyEquivalent = "\r"
        openButton.setAccessibilityLabel("Open from Disk")
        openButton.setAccessibilityHelp("Choose a supported text file to open")

        recentTitleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)

        statusLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .medium)
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.isHidden = true

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .none
        recentContentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = recentContentView
        scrollView.setAccessibilityLabel("Recent Files")

        recentStack.orientation = .vertical
        recentStack.alignment = .leading
        recentStack.spacing = 8
        recentStack.distribution = .fill

        emptyRecentLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        emptyRecentLabel.alignment = .center
        emptyRecentLabel.maximumNumberOfLines = 2
        emptyRecentLabel.lineBreakMode = .byWordWrapping
        emptyRecentLabel.setAccessibilityLabel("No recent files")

        [brandView, titleLabel, subtitleLabel, openButton, recentTitleLabel, statusLabel, scrollView]
            .forEach {
                $0.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview($0)
            }
        [recentStack, emptyRecentLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            recentContentView.addSubview($0)
        }

        NSLayoutConstraint.activate([
            brandView.topAnchor.constraint(equalTo: view.topAnchor, constant: 44),
            brandView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            brandView.widthAnchor.constraint(equalToConstant: 62),
            brandView.heightAnchor.constraint(equalToConstant: 62),

            titleLabel.topAnchor.constraint(equalTo: brandView.bottomAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 40),
            titleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -40),

            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7),
            subtitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 72),
            subtitleLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -72),

            openButton.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 20),
            openButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            openButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 180),
            openButton.heightAnchor.constraint(equalToConstant: 38),

            recentTitleLabel.topAnchor.constraint(equalTo: openButton.bottomAnchor, constant: 30),
            recentTitleLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 54),

            statusLabel.centerYAnchor.constraint(equalTo: recentTitleLabel.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: recentTitleLabel.trailingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -54),

            scrollView.topAnchor.constraint(equalTo: recentTitleLabel.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 46),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -46),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -34),

            recentContentView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            recentStack.topAnchor.constraint(equalTo: recentContentView.topAnchor),
            recentStack.leadingAnchor.constraint(equalTo: recentContentView.leadingAnchor, constant: 8),
            recentStack.trailingAnchor.constraint(equalTo: recentContentView.trailingAnchor, constant: -8),
            recentStack.bottomAnchor.constraint(lessThanOrEqualTo: recentContentView.bottomAnchor),

            emptyRecentLabel.topAnchor.constraint(equalTo: recentContentView.topAnchor, constant: 34),
            emptyRecentLabel.leadingAnchor.constraint(equalTo: recentContentView.leadingAnchor, constant: 24),
            emptyRecentLabel.trailingAnchor.constraint(equalTo: recentContentView.trailingAnchor, constant: -24),
            recentContentView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor)
        ])
    }

    private func applyResolvedAppearance() {
        let appearance = view.effectiveAppearance
        view.layer?.backgroundColor = LighTxtTheme.resolved(
            LighTxtTheme.windowBackground,
            for: appearance
        ).cgColor
        titleLabel.textColor = LighTxtTheme.resolved(LighTxtTheme.primaryText, for: appearance)
        subtitleLabel.textColor = LighTxtTheme.resolved(LighTxtTheme.secondaryText, for: appearance)
        recentTitleLabel.textColor = LighTxtTheme.resolved(LighTxtTheme.primaryText, for: appearance)
        emptyRecentLabel.textColor = LighTxtTheme.resolved(LighTxtTheme.secondaryText, for: appearance)
        openButton.applyResolvedAppearance()
        recentStack.arrangedSubviews
            .compactMap { $0 as? LighTxtRecentFileButton }
            .forEach { $0.applyResolvedAppearance() }
    }

    @objc private func openFromDisk(_ sender: Any?) {
        onOpenFromDisk?()
    }

    @objc private func openRecent(_ sender: LighTxtRecentFileButton) {
        guard Self.isAvailable(sender.fileURL) else {
            showStatus("“\(sender.fileURL.lastPathComponent)” is no longer available.", isError: true)
            NSSound.beep()
            return
        }
        onOpenRecent?(sender.fileURL)
    }

    private static func isAvailable(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]) else { return false }
        return values.isRegularFile == true
    }
}

@MainActor
private final class LighTxtHomeRootView: NSView {
    var onAppearanceChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearanceChange?()
    }
}

@MainActor
private final class LighTxtHomePrimaryButton: NSButton {
    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        controlSize = .large
        font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        image = NSImage(
            systemSymbolName: "folder",
            accessibilityDescription: "Open from Disk"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        imagePosition = .imageLeading
        applyResolvedAppearance()
    }

    func applyResolvedAppearance() {
        contentTintColor = LighTxtTheme.resolved(LighTxtTheme.accent, for: effectiveAppearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyResolvedAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
private final class LighTxtRecentFileButton: NSButton {
    let fileURL: URL
    private let isFileAvailable: Bool
    private var trackingAreaReference: NSTrackingArea?
    private var isHovered = false

    init(url: URL, isAvailable: Bool) {
        fileURL = url
        isFileAvailable = isAvailable
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        isBordered = false
        bezelStyle = .regularSquare
        imagePosition = .imageLeading
        imageScaling = .scaleProportionallyDown
        image = NSWorkspace.shared.icon(forFile: url.path)
        image?.size = NSSize(width: 24, height: 24)
        alignment = .left
        toolTip = url.path
        setAccessibilityLabel(
            isAvailable ? "Open \(url.lastPathComponent)" : "\(url.lastPathComponent), unavailable"
        )
        setAccessibilityHelp(url.path)
        heightAnchor.constraint(equalToConstant: 54).isActive = true
        applyResolvedAppearance()
    }

    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingAreaReference { removeTrackingArea(trackingAreaReference) }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        trackingAreaReference = tracking
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        applyResolvedAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        applyResolvedAppearance()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 {
            performClick(nil)
            return
        }
        super.keyDown(with: event)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyResolvedAppearance()
    }

    func applyResolvedAppearance() {
        let appearance = effectiveAppearance
        let primary = LighTxtTheme.resolved(LighTxtTheme.primaryText, for: appearance)
        let secondary = LighTxtTheme.resolved(LighTxtTheme.secondaryText, for: appearance)
        let accent = LighTxtTheme.resolved(LighTxtTheme.accent, for: appearance)
        let filename = fileURL.lastPathComponent
        let parent = fileURL.deletingLastPathComponent().path
        let detail = isFileAvailable ? parent : "File not found  ·  \(parent)"
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        paragraph.maximumLineHeight = 18
        let title = NSMutableAttributedString(
            string: filename,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: isFileAvailable ? primary : secondary,
                .paragraphStyle: paragraph,
            ]
        )
        title.append(NSAttributedString(
            string: "\n\(detail)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .regular),
                .foregroundColor: secondary,
                .paragraphStyle: paragraph,
            ]
        ))
        attributedTitle = title
        contentTintColor = isFileAvailable ? accent : secondary
        alphaValue = isFileAvailable ? 1 : 0.72
        let fillAlpha: CGFloat = isHovered ? 0.11 : 0.055
        layer?.backgroundColor = accent.withAlphaComponent(fillAlpha).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
