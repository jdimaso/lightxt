import AppKit

enum DocumentPresentationMode: Int, CaseIterable {
    case view
    case edit

    var accessibilityLabel: String {
        switch self {
        case .view: return "View"
        case .edit: return "Edit"
        }
    }
}

@MainActor
final class DocumentHeaderView: NSView {
    var onFind: (() -> Void)?
    var onStructure: (() -> Void)?
    var onExport: (() -> Void)?
    var onReload: (() -> Void)?
    var onPrettifyChanged: ((Bool) -> Void)?
    var onOpenFolder: ((URL) -> Void)?
    var onPresentationModeChanged: ((DocumentPresentationMode) -> Void)?

    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "Untitled")
    private let pathControl = BreadcrumbPathControl()
    private let locationHost = NSView()
    private let detailLabel = NSTextField(labelWithString: "Plain Text")
    private let editedDot = NSView()
    private let typeBadge = FileTypeBadgeView()
    private let modeControl = NSSegmentedControl(
        labels: ["Preview", "Source"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let prettifyButton = NSButton(checkboxWithTitle: "Prettify", target: nil, action: nil)
    private let structureButton = HeaderIconButton(
        symbolName: "sidebar.right",
        accessibilityLabel: "Toggle structure sidebar"
    )
    private let exportButton = HeaderIconButton(
        symbolName: "square.and.arrow.up",
        accessibilityLabel: "Export table"
    )
    private let reloadButton = HeaderIconButton(
        symbolName: "arrow.clockwise",
        accessibilityLabel: "Reload file"
    )
    private let findButton = HeaderIconButton(
        symbolName: "magnifyingglass",
        accessibilityLabel: "Find"
    )
    private var currentFileURL: URL?
    private var trailingWidthConstraint: NSLayoutConstraint?
    private var isPrettifyAvailable = false
    private var isExportVisible = false
    private var isReloadVisible = false
    private var presentationChoicesVisible = true
    private var documentTypeName = "Plain Text"
    private var documentByteCount: Int64 = 0
    private var documentEdited = false
    private var presentationEditable = true
    private var presentationEditingReason: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 0.5
        configure()
        applyResolvedAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyResolvedAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyResolvedAppearance()
    }

    func update(
        fileURL: URL?,
        title: String,
        typeName: String,
        typeAbbreviation: String,
        byteCount: Int64,
        edited: Bool,
        structureAvailable: Bool
    ) {
        titleLabel.stringValue = title
        titleLabel.toolTip = title
        currentFileURL = fileURL?.standardizedFileURL
        pathControl.url = currentFileURL
        pathControl.toolTip = currentFileURL?.path
        pathControl.setAccessibilityValue(currentFileURL?.path ?? "")
        pathControl.isHidden = currentFileURL == nil
        titleLabel.isHidden = currentFileURL != nil
        documentTypeName = typeName
        documentByteCount = byteCount
        documentEdited = edited
        updateDetailLabel()
        typeBadge.text = typeAbbreviation.uppercased()
        editedDot.isHidden = !edited
        setStructureAvailable(structureAvailable)
        let location = currentFileURL?.path ?? title
        setAccessibilityLabel("\(location), \(typeName), \(edited ? "edited" : "saved")")
    }

    var presentationMode: DocumentPresentationMode {
        get { DocumentPresentationMode(rawValue: modeControl.selectedSegment) ?? .edit }
        set {
            modeControl.selectedSegment = newValue.rawValue
            modeControl.setAccessibilityValue(modeControl.label(forSegment: newValue.rawValue))
        }
    }

    /// Presentation names describe the content, independently of whether the
    /// current presentation permits changes (CSV tables can be editable).
    func setPresentationLabels(view: String, source: String = "Source") {
        modeControl.setLabel(view, forSegment: DocumentPresentationMode.view.rawValue)
        modeControl.setLabel(source, forSegment: DocumentPresentationMode.edit.rawValue)
        modeControl.setAccessibilityLabel("Document presentation")
        modeControl.setAccessibilityValue(presentationMode == .view ? view : source)
    }

    func setPresentationChoicesVisible(_ visible: Bool) {
        presentationChoicesVisible = visible
        modeControl.isHidden = !visible
        updateTrailingWidth()
    }

    func setPresentationEditable(_ editable: Bool, reason: String? = nil) {
        presentationEditable = editable
        presentationEditingReason = reason
        updateDetailLabel()
    }

    private func updateDetailLabel() {
        let access = presentationEditable ? "Editable" : "Read-only"
        var parts = [documentTypeName, ByteCountFormatter.lighTxt.string(fromByteCount: documentByteCount), access]
        if documentEdited { parts.append("Unsaved changes") }
        detailLabel.stringValue = parts.joined(separator: "  ·  ")
        detailLabel.toolTip = presentationEditingReason ?? detailLabel.stringValue
        detailLabel.setAccessibilityLabel(detailLabel.stringValue)
    }

    func setStructureVisible(_ visible: Bool) {
        structureButton.isSelected = visible
        structureButton.setAccessibilityValue(visible ? "Expanded" : "Collapsed")
    }

    func setStructureAvailable(_ available: Bool) {
        structureButton.isEnabled = available
        structureButton.toolTip = available
            ? "Show or hide the structure sidebar"
            : "Structure is available for JSON, XML, and YAML files"
        if !available { setStructureVisible(false) }
    }

    /// Binary table formats have a rendered, read-only presentation only.
    /// Keep View visible and selected while making the unavailable Edit path
    /// explicit to mouse, keyboard, and accessibility users.
    func setEditingAvailable(_ available: Bool, unavailableReason: String? = nil) {
        modeControl.setEnabled(available, forSegment: DocumentPresentationMode.edit.rawValue)
        if !available {
            presentationMode = .view
        }
        modeControl.toolTip = available
            ? "Choose how to display this document. Editing availability is shown beside the file details."
            : (unavailableReason ?? "Source editing is unavailable for this document")
        modeControl.setAccessibilityHelp(modeControl.toolTip)
    }

    func setFindAvailable(_ available: Bool, unavailableReason: String? = nil) {
        findButton.isEnabled = available
        findButton.toolTip = available
            ? "Find in document (Command-F)"
            : (unavailableReason ?? "Use the column filters to find Parquet rows")
        findButton.setAccessibilityHelp(findButton.toolTip)
    }

    /// Table export is a contextual action: it is absent for ordinary text
    /// presentations, but remains visible and explains itself while a CSV or
    /// Parquet table is temporarily busy or otherwise unavailable.
    func setExportAvailable(
        _ available: Bool,
        visible: Bool,
        unavailableReason: String? = nil
    ) {
        isExportVisible = visible
        exportButton.isHidden = !visible
        exportButton.isEnabled = visible && available
        exportButton.toolTip = available
            ? "Export the current table view"
            : (unavailableReason ?? "Export is temporarily unavailable")
        exportButton.setAccessibilityHelp(exportButton.toolTip)
        updateTrailingWidth()
    }

    /// Parquet is presented as a stable, read-only snapshot. Keep its explicit
    /// disk refresh beside Export so observing a newer revision never implies
    /// that the currently displayed rows have silently changed underneath the
    /// user.
    func setReloadAvailable(
        _ available: Bool,
        visible: Bool,
        unavailableReason: String? = nil
    ) {
        isReloadVisible = visible
        reloadButton.isHidden = !visible
        reloadButton.isEnabled = visible && available
        reloadButton.toolTip = available
            ? "Reload this Parquet file from disk"
            : (unavailableReason ?? "Reload is temporarily unavailable")
        reloadButton.setAccessibilityHelp(reloadButton.toolTip)
        updateTrailingWidth()
    }

    func setPrettifyAvailable(_ available: Bool) {
        isPrettifyAvailable = available
        prettifyButton.isHidden = !available
        prettifyButton.isEnabled = available
        if !available { prettifyButton.state = .off }
        updateTrailingWidth()
    }

    func setPrettifyOn(_ enabled: Bool) {
        prettifyButton.state = enabled ? .on : .off
        prettifyButton.setAccessibilityValue(enabled ? "On" : "Off")
    }

    private func configure() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        iconView.image = NSImage(named: "BrandMark")
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.setAccessibilityHidden(true)

        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = LighTxtTheme.primaryText
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // AppKit marks the old `.navigationBar` style unavailable to Swift on
        // every supported macOS release. `.standard` is the supported native
        // segmented breadcrumb style; this control is noneditable and borderless.
        pathControl.pathStyle = .standard
        pathControl.isEditable = false
        pathControl.backgroundColor = .clear
        pathControl.focusRingType = .none
        pathControl.controlSize = .small
        pathControl.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        pathControl.onActivateItem = { [weak self] url in
            self?.activatePathItem(url)
        }
        pathControl.setAccessibilityLabel("Current file path")
        pathControl.setContentHuggingPriority(.defaultLow, for: .horizontal)
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        [pathControl, titleLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            locationHost.addSubview($0)
        }
        NSLayoutConstraint.activate([
            locationHost.heightAnchor.constraint(equalToConstant: 21),
            pathControl.leadingAnchor.constraint(equalTo: locationHost.leadingAnchor),
            pathControl.trailingAnchor.constraint(equalTo: locationHost.trailingAnchor),
            pathControl.centerYAnchor.constraint(equalTo: locationHost.centerYAnchor),
            pathControl.heightAnchor.constraint(equalToConstant: 21),
            titleLabel.leadingAnchor.constraint(equalTo: locationHost.leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: locationHost.trailingAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: locationHost.centerYAnchor)
        ])
        locationHost.setContentHuggingPriority(.defaultLow, for: .horizontal)
        locationHost.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        detailLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        detailLabel.textColor = LighTxtTheme.secondaryText
        detailLabel.lineBreakMode = .byTruncatingMiddle

        editedDot.wantsLayer = true
        editedDot.layer?.cornerRadius = 3
        editedDot.isHidden = true
        editedDot.toolTip = "Unsaved changes"

        let labels = NSView()
        [locationHost, detailLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            labels.addSubview($0)
        }
        NSLayoutConstraint.activate([
            locationHost.leadingAnchor.constraint(equalTo: labels.leadingAnchor),
            locationHost.trailingAnchor.constraint(equalTo: labels.trailingAnchor),
            locationHost.topAnchor.constraint(equalTo: labels.topAnchor),
            detailLabel.leadingAnchor.constraint(equalTo: labels.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: labels.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: locationHost.bottomAnchor, constant: 2),
            detailLabel.bottomAnchor.constraint(equalTo: labels.bottomAnchor)
        ])
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        modeControl.target = self
        modeControl.action = #selector(modeChanged(_:))
        modeControl.segmentStyle = .capsule
        modeControl.controlSize = .small
        modeControl.selectedSegment = DocumentPresentationMode.edit.rawValue
        modeControl.setWidth(68, forSegment: 0)
        modeControl.setWidth(68, forSegment: 1)
        modeControl.toolTip = "Choose how to display this document. Editing availability is shown beside the file details."
        modeControl.setAccessibilityLabel("Document presentation")
        modeControl.setContentHuggingPriority(.required, for: .horizontal)

        prettifyButton.target = self
        prettifyButton.action = #selector(prettifyChanged(_:))
        prettifyButton.controlSize = .small
        prettifyButton.toolTip = "Show this bounded JSON or YAML viewport formatted in a read-only preview"
        prettifyButton.setAccessibilityLabel("Prettify read-only preview")
        prettifyButton.setAccessibilityHelp("Shows formatted source without changing or saving any document bytes.")
        prettifyButton.isHidden = true
        prettifyButton.setContentHuggingPriority(.required, for: .horizontal)

        structureButton.toolTip = "Show or hide the structure sidebar"
        structureButton.onActivate = { [weak self] in self?.onStructure?() }
        exportButton.toolTip = "Export the current table view"
        exportButton.isHidden = true
        exportButton.onActivate = { [weak self] in self?.onExport?() }
        reloadButton.toolTip = "Reload this Parquet file from disk"
        reloadButton.isHidden = true
        reloadButton.onActivate = { [weak self] in self?.onReload?() }
        findButton.toolTip = "Find in document (Command-F)"
        findButton.keyEquivalent = "f"
        findButton.keyEquivalentModifierMask = [.command]
        findButton.onActivate = { [weak self] in self?.onFind?() }

        let trailing = NSStackView(
            views: [
                modeControl,
                prettifyButton,
                exportButton,
                reloadButton,
                structureButton,
                findButton,
            ]
        )
        trailing.orientation = .horizontal
        trailing.alignment = .centerY
        trailing.spacing = 8
        trailing.setContentHuggingPriority(.required, for: .horizontal)

        [iconView, labels, editedDot, typeBadge, trailing].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        let trailingWidthConstraint = trailing.widthAnchor.constraint(equalToConstant: 217)
        self.trailingWidthConstraint = trailingWidthConstraint
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 82),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 34),
            iconView.heightAnchor.constraint(equalToConstant: 34),

            labels.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            labels.trailingAnchor.constraint(equalTo: editedDot.leadingAnchor, constant: -12),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),

            editedDot.trailingAnchor.constraint(equalTo: typeBadge.leadingAnchor, constant: -12),
            editedDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            editedDot.widthAnchor.constraint(equalToConstant: 6),
            editedDot.heightAnchor.constraint(equalToConstant: 6),

            typeBadge.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -12),
            typeBadge.centerYAnchor.constraint(equalTo: centerYAnchor),

            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingWidthConstraint,
            modeControl.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    private func updateTrailingWidth() {
        // The fixed width prevents the path and type badge from nudging the
        // trailing controls as contextual actions appear. Each icon adds its
        // 32pt hit target plus the stack's 8pt spacing; Prettify adds 84pt.
        trailingWidthConstraint?.constant = (presentationChoicesVisible ? CGFloat(217) : CGFloat(73))
            + (isExportVisible ? CGFloat(40) : 0)
            + (isReloadVisible ? CGFloat(40) : 0)
            + (isPrettifyAvailable ? CGFloat(84) : 0)
    }

    private func applyResolvedAppearance() {
        let appearance = effectiveAppearance
        let accent = LighTxtTheme.resolved(LighTxtTheme.accent, for: appearance)
        layer?.backgroundColor = LighTxtTheme.resolved(
            LighTxtTheme.chromeBackground,
            for: appearance
        ).cgColor
        layer?.borderColor = LighTxtTheme.resolved(
            LighTxtTheme.separator,
            for: appearance
        ).cgColor
        titleLabel.textColor = LighTxtTheme.resolved(LighTxtTheme.primaryText, for: appearance)
        detailLabel.textColor = LighTxtTheme.resolved(LighTxtTheme.secondaryText, for: appearance)
        editedDot.layer?.backgroundColor = accent.cgColor
        typeBadge.applyResolvedAppearance()
    }

    @objc private func modeChanged(_ sender: NSSegmentedControl) {
        guard let mode = DocumentPresentationMode(rawValue: sender.selectedSegment) else { return }
        sender.setAccessibilityValue(sender.label(forSegment: mode.rawValue))
        onPresentationModeChanged?(mode)
    }

    @objc private func prettifyChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        sender.setAccessibilityValue(enabled ? "On" : "Off")
        onPrettifyChanged?(enabled)
    }

#if LIGHTXT_RUNTIME_QA
    var qaPresentationLabels: [String] {
        (0..<modeControl.segmentCount).map { modeControl.label(forSegment: $0) ?? "" }
    }
    var qaPresentationChoicesVisible: Bool { !modeControl.isHidden }
    var qaDetailText: String { detailLabel.stringValue }
    var qaPrettifyIsVisible: Bool { !prettifyButton.isHidden }
    var qaPrettifyIsEnabled: Bool { prettifyButton.isEnabled }
    var qaPrettifyIsOn: Bool { prettifyButton.state == .on }
    var qaPrettifyAccessibilityLabel: String? { prettifyButton.accessibilityLabel() }
    var qaPrettifyFrame: NSRect { prettifyButton.frame }
    func qaActivatePrettify() { prettifyButton.performClick(nil) }
    var qaExportIsVisible: Bool { !exportButton.isHidden }
    var qaExportIsEnabled: Bool { exportButton.isEnabled }
    var qaExportAccessibilityLabel: String? { exportButton.accessibilityLabel() }
    var qaExportAccessibilityHelp: String? { exportButton.accessibilityHelp() }
    var qaExportFrame: NSRect { exportButton.frame }
    func qaActivateExport() { _ = exportButton.accessibilityPerformPress() }
    var qaReloadIsVisible: Bool { !reloadButton.isHidden }
    var qaReloadIsEnabled: Bool { reloadButton.isEnabled }
    var qaReloadAccessibilityLabel: String? { reloadButton.accessibilityLabel() }
    var qaReloadAccessibilityHelp: String? { reloadButton.accessibilityHelp() }
    var qaReloadFrame: NSRect { reloadButton.frame }
    func qaActivateReload() { _ = reloadButton.accessibilityPerformPress() }
#endif

    private func activatePathItem(_ url: URL) {
        let selectedURL = url.standardizedFileURL
        guard let currentFileURL, selectedURL != currentFileURL else { return }
        // Every path item before the final file item is a directory. Opening
        // it through NSWorkspace produces the native Finder behavior without
        // retaining a folder authorization or maintaining a second browser.
        onOpenFolder?(selectedURL)
    }
}

/// NSPathControl's supported `.standard` style exposes native segmented path
/// cells, but its control action is reserved for path changes rather than a
/// reliable single-click notification on modern macOS. Hit-test the native
/// cells directly so every visible folder crumb behaves consistently while
/// leaving the final file crumb inert.
@MainActor
private final class BreadcrumbPathControl: NSPathControl {
    var onActivateItem: ((URL) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let pathCell = cell as? NSPathCell else {
            super.mouseDown(with: event)
            return
        }
        for component in pathCell.pathComponentCells {
            let componentRect = pathCell.rect(
                of: component,
                withFrame: bounds,
                in: self
            )
            guard componentRect.contains(point) else { continue }
            if let url = component.url { onActivateItem?(url) }
            return
        }
        super.mouseDown(with: event)
    }
}

/// A small custom-drawn badge avoids AppKit's label-cell baseline inset, which
/// otherwise makes short file-type names appear pinned to the top of the chip.
@MainActor
private final class FileTypeBadgeView: NSView {
    var text = "TXT" {
        didSet {
            setAccessibilityLabel(text)
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private let font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .semibold)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    override var intrinsicContentSize: NSSize {
        let width = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        return NSSize(width: max(44, width + 18), height: 24)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let appearance = effectiveAppearance
        let accent = LighTxtTheme.resolved(LighTxtTheme.accent, for: appearance)
        let background = accent.withAlphaComponent(0.095)
        background.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: accent,
            .kern: 0.35
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let origin = NSPoint(
            x: floor((bounds.width - size.width) / 2),
            y: floor((bounds.height - size.height) / 2)
        )
        (text as NSString).draw(at: origin, withAttributes: attributes)
    }

    func applyResolvedAppearance() {
        needsDisplay = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Borderless chrome target with a real 32pt hit area. It stays visually quiet
/// until hovered or selected and remains fully usable from the keyboard and
/// accessibility APIs.
@MainActor
final class HeaderIconButton: NSView {
    var onActivate: (() -> Void)?
    var keyEquivalent = ""
    var keyEquivalentModifierMask: NSEvent.ModifierFlags = []
    var isSelected = false {
        didSet { if oldValue != isSelected { applyResolvedAppearance() } }
    }
    var isEnabled = true {
        didSet {
            guard oldValue != isEnabled else { return }
            if !isEnabled {
                isHovered = false
                isPressed = false
            }
            setAccessibilityEnabled(isEnabled)
            applyResolvedAppearance()
        }
    }

    private let imageView = NSImageView()
    private var trackingAreaReference: NSTrackingArea?
    private var isHovered = false
    private var isPressed = false

    init(symbolName: String, accessibilityLabel: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.imageScaling = .scaleProportionallyDown
        imageView.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityLabel
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        imageView.setAccessibilityHidden(true)
        addSubview(imageView)

        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityTitle(accessibilityLabel)
        setAccessibilityLabel(accessibilityLabel)
        setAccessibilityIdentifier("LighTxt.Header.\(accessibilityLabel.replacingOccurrences(of: " ", with: "").lowercased())")

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 32),
            heightAnchor.constraint(equalToConstant: 32),
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: 17),
            imageView.heightAnchor.constraint(equalToConstant: 17)
        ])
        applyResolvedAppearance()
    }

    override var intrinsicContentSize: NSSize { NSSize(width: 32, height: 32) }
    override var acceptsFirstResponder: Bool { isEnabled }

    override func isAccessibilityEnabled() -> Bool { isEnabled }

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
        isPressed = false
        applyResolvedAppearance()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        applyResolvedAppearance()
        var shouldActivate = false
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let inside = bounds.contains(convert(next.locationInWindow, from: nil))
            isPressed = inside
            applyResolvedAppearance()
            if next.type == .leftMouseUp {
                shouldActivate = inside
                break
            }
        }
        isPressed = false
        applyResolvedAppearance()
        if shouldActivate { activate() }
    }

    override func keyDown(with event: NSEvent) {
        guard isEnabled else {
            super.keyDown(with: event)
            return
        }
        guard event.keyCode == 36 || event.keyCode == 49 else {
            super.keyDown(with: event)
            return
        }
        activate()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isEnabled else { return false }
        let compared: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
        guard !keyEquivalent.isEmpty,
              event.charactersIgnoringModifiers?.lowercased() == keyEquivalent.lowercased(),
              event.modifierFlags.intersection(compared) == keyEquivalentModifierMask.intersection(compared) else {
            return super.performKeyEquivalent(with: event)
        }
        activate()
        return true
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        activate()
        return true
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyResolvedAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyResolvedAppearance()
    }

    private func activate() {
        guard isEnabled else { return }
        onActivate?()
    }

    private func applyResolvedAppearance() {
        let appearance = effectiveAppearance
        let accent = LighTxtTheme.resolved(LighTxtTheme.accent, for: appearance)
        let secondary = LighTxtTheme.resolved(LighTxtTheme.secondaryText, for: appearance)
        imageView.contentTintColor = isSelected ? accent : secondary
        imageView.alphaValue = isEnabled ? 1 : 0.34
        let alpha: CGFloat
        if !isEnabled { alpha = 0 }
        else if isPressed { alpha = 0.15 }
        else if isHovered || isSelected { alpha = 0.075 }
        else { alpha = 0 }
        layer?.backgroundColor = accent.withAlphaComponent(alpha).cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@MainActor
final class DocumentStatusBar: NSView {
    /// Return nil after a successful jump, or a message to keep the popover
    /// open with an actionable inline error. Row navigation uses this callback
    /// too; the owner knows which presentation is currently installed.
    var onGoToLine: ((Int64, @escaping (String?) -> Void) -> Void)? {
        didSet { updateNavigationAvailability() }
    }

    private let positionButton = NSButton(title: "Ln 1, Col 1", target: nil, action: nil)
    private let documentStateLabel = NSTextField(labelWithString: "Saved")
    private let stateLabel = NSTextField(labelWithString: "Ready")
    private let progress = NSProgressIndicator()
    private let infoButton = NSButton()
    private var stateIsError = false
    private var documentEdited = false
    private var storageSummary = "BYTE WINDOW"
    private var storageDetail = "Only the visible portion of the document is loaded for editing."
    private var navigationUnit = "line"
    private var navigationCurrent: Int64?
    private var navigationTotal: Int64?
    private var navigationEnabled = false
    private var activePopover: NSPopover?
    private var positionController: DocumentPositionPopoverController?
    private var informationController: DocumentInformationPopoverController?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 0.5
        configure()
        applyResolvedAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyResolvedAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyResolvedAppearance()
    }

    func setDocumentState(edited: Bool, readOnly: Bool = false) {
        documentEdited = edited
        documentStateLabel.stringValue = edited ? "Unsaved changes" : "Saved"
        documentStateLabel.toolTip = readOnly
            ? "This document is read-only. \(edited ? "It contains unsaved changes." : "There are no unsaved changes.")"
            : (edited ? "Save to keep your changes on disk." : "There are no unsaved changes.")
        documentStateLabel.setAccessibilityLabel(documentStateLabel.stringValue)
        applyResolvedAppearance()
    }

    func updatePosition(line: Int64, column: Int, selectionByteCount: Int64 = 0) {
        navigationCurrent = line
        var text = "Ln \(line.formatted()), Col \(column.formatted())"
        if selectionByteCount > 0 {
            text += "  ·  \(ByteCountFormatter.lighTxt.string(fromByteCount: selectionByteCount)) selected"
        }
        positionButton.title = text
        positionButton.setAccessibilityLabel(text)
    }

    func setPositionSummary(_ text: String) {
        positionButton.title = text
        positionButton.setAccessibilityLabel(text)
    }

    var canNavigatePosition: Bool { positionButton.isEnabled }

    func updateTablePosition(row: Int64, selectedRowCount: Int, totalRows: Int) {
        navigationCurrent = row > 0 ? row : nil
        navigationTotal = Int64(max(0, totalRows))
        var text = row > 0 ? "Row \(row.formatted()) of \(totalRows.formatted())" : "\(totalRows.formatted()) rows"
        if selectedRowCount > 0 { text += "  ·  \(selectedRowCount.formatted()) selected" }
        positionButton.title = text
        positionButton.setAccessibilityLabel(text)
        updateNavigationAvailability()
    }

    func configureLineNavigation(currentLine: Int64?, totalLines: Int64?, enabled: Bool) {
        configureNavigation(unit: "line", current: currentLine, total: totalLines, enabled: enabled)
    }

    func configureRowNavigation(currentRow: Int64?, totalRows: Int64?, enabled: Bool) {
        configureNavigation(unit: "row", current: currentRow, total: totalRows, enabled: enabled)
    }

    private func configureNavigation(unit: String, current: Int64?, total: Int64?, enabled: Bool) {
        if positionController != nil, navigationUnit != unit || !enabled {
            activePopover?.close()
            positionController = nil
        }
        navigationUnit = unit
        navigationCurrent = current
        navigationTotal = total
        navigationEnabled = enabled
        updateNavigationAvailability()
    }

    private func updateNavigationAvailability() {
        positionButton.isEnabled = navigationEnabled && onGoToLine != nil && navigationTotal != 0
        positionButton.toolTip = positionButton.isEnabled
            ? "Go to \(navigationUnit)…"
            : "Current document position"
        positionButton.setAccessibilityHelp(positionButton.toolTip)
    }

    func setState(_ text: String, busy: Bool = false, isError: Bool = false) {
        stateLabel.stringValue = Self.singleLineStatusText(text)
        stateLabel.toolTip = text
        stateLabel.setAccessibilityValue(text)
        stateIsError = isError
        applyResolvedAppearance()
        progress.isHidden = !busy
        busy ? progress.startAnimation(nil) : progress.stopAnimation(nil)
        refreshInformation()
    }

    func updateByteWindow(_ range: Range<Int64>, totalByteCount: Int64) {
        let lower = min(max(0, range.lowerBound), totalByteCount)
        let upper = min(max(lower, range.upperBound), totalByteCount)
        storageSummary = "BYTE WINDOW \(lower.formatted())–\(upper.formatted()) OF \(ByteCountFormatter.lighTxt.string(fromByteCount: totalByteCount))"
        storageDetail = "File size: \(ByteCountFormatter.lighTxt.string(fromByteCount: totalByteCount))\nVisible source: bytes \(lower.formatted())–\(upper.formatted())\nOnly the visible portion is loaded for editing."
        refreshInformation()
    }

    func showFileBackedView(totalByteCount: Int64) {
        storageSummary = "FILE-BACKED VIEW · \(ByteCountFormatter.lighTxt.string(fromByteCount: totalByteCount))"
        storageDetail = "File size: \(ByteCountFormatter.lighTxt.string(fromByteCount: totalByteCount))\nContent is read from the file as needed."
        refreshInformation()
    }

    func showMemoryBackedCSV(totalByteCount: Int64) {
        storageSummary = "IN-MEMORY CSV · \(ByteCountFormatter.lighTxt.string(fromByteCount: totalByteCount))"
        storageDetail = "File size: \(ByteCountFormatter.lighTxt.string(fromByteCount: totalByteCount))\nThis table is held in memory for faster sorting and filtering."
        refreshInformation()
    }

    private var informationText: String {
        "\(storageDetail)\n\nCurrent activity\n\(stateLabel.toolTip ?? stateLabel.stringValue)"
    }

    private func refreshInformation() {
        informationController?.update(informationText)
    }

    @objc func showGoToLine(_ sender: Any? = nil) {
        guard positionButton.isEnabled, window != nil else { return }
        activePopover?.close()
        let controller = makePositionController()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        activePopover = popover
        informationController = nil
        controller.onClose = { [weak popover] in popover?.close() }
        popover.show(relativeTo: positionButton.bounds, of: positionButton, preferredEdge: .maxY)
    }

    private func makePositionController() -> DocumentPositionPopoverController {
        let controller = DocumentPositionPopoverController(
            unit: navigationUnit, current: navigationCurrent, total: navigationTotal
        )
        controller.onSubmit = { [weak self] value, completion in
            guard let self, self.positionButton.isEnabled, let action = self.onGoToLine else {
                completion("Navigation is unavailable in this presentation.")
                return
            }
            action(value, completion)
        }
        positionController = controller
        return controller
    }

    @objc private func showInformation(_ sender: Any?) {
        guard window != nil else { return }
        activePopover?.close()
        let controller = DocumentInformationPopoverController(text: informationText)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        activePopover = popover
        positionController = nil
        informationController = controller
        popover.show(relativeTo: infoButton.bounds, of: infoButton, preferredEdge: .maxY)
    }

    private func configure() {
        positionButton.target = self
        positionButton.action = #selector(showGoToLine(_:))
        positionButton.isBordered = false
        positionButton.font = LighTxtTheme.detailFont
        positionButton.setContentHuggingPriority(.required, for: .horizontal)
        positionButton.setAccessibilityIdentifier("LighTxt.Status.Position")
        updateNavigationAvailability()

        documentStateLabel.font = LighTxtTheme.detailFont
        documentStateLabel.setContentHuggingPriority(.required, for: .horizontal)

        stateLabel.font = LighTxtTheme.detailFont
        stateLabel.alignment = .center
        stateLabel.lineBreakMode = .byTruncatingMiddle
        stateLabel.maximumNumberOfLines = 1
        stateLabel.cell?.wraps = false
        stateLabel.cell?.usesSingleLineMode = true
        stateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stateLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.isHidden = true

        infoButton.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: "Document information")
        infoButton.imagePosition = .imageOnly
        infoButton.isBordered = false
        infoButton.target = self
        infoButton.action = #selector(showInformation(_:))
        infoButton.toolTip = "Document information"
        infoButton.setAccessibilityLabel("Document information")
        infoButton.setAccessibilityHelp("Show file size, loading details, and the complete activity message.")
        infoButton.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [positionButton, stateLabel, progress, documentStateLabel, infoButton])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.distribution = .fill
        row.alignment = .centerY
        row.spacing = 12
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            positionButton.heightAnchor.constraint(equalToConstant: 24),
            infoButton.widthAnchor.constraint(equalToConstant: 24),
            infoButton.heightAnchor.constraint(equalToConstant: 24),
            progress.widthAnchor.constraint(equalToConstant: 14),
            progress.heightAnchor.constraint(equalToConstant: 14)
        ])
    }

    private static func singleLineStatusText(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func applyResolvedAppearance() {
        let appearance = effectiveAppearance
        layer?.backgroundColor = LighTxtTheme.resolved(LighTxtTheme.chromeBackground, for: appearance).cgColor
        layer?.borderColor = LighTxtTheme.resolved(LighTxtTheme.separator, for: appearance).cgColor
        positionButton.contentTintColor = LighTxtTheme.resolved(LighTxtTheme.secondaryText, for: appearance)
        documentStateLabel.textColor = LighTxtTheme.resolved(
            documentEdited ? LighTxtTheme.accent : LighTxtTheme.secondaryText, for: appearance
        )
        stateLabel.textColor = LighTxtTheme.resolved(
            stateIsError ? LighTxtTheme.error : LighTxtTheme.secondaryText, for: appearance
        )
        infoButton.contentTintColor = LighTxtTheme.resolved(LighTxtTheme.secondaryText, for: appearance)
    }

#if LIGHTXT_RUNTIME_QA
    var qaStateText: String { stateLabel.stringValue }
    var qaStateToolTip: String? { stateLabel.toolTip }
    var qaStateIsError: Bool { stateIsError }
    var qaStateIsStrictlySingleLine: Bool {
        stateLabel.maximumNumberOfLines == 1
            && stateLabel.cell?.wraps == false
            && stateLabel.cell?.usesSingleLineMode == true
            && stateLabel.lineBreakMode == .byTruncatingMiddle
    }
    var qaMemoryBadgeText: String { storageSummary }
    var qaDocumentStateText: String { documentStateLabel.stringValue }
    var qaInformationText: String { informationText }
    var qaPositionText: String { positionButton.title }
    var qaPositionEnabled: Bool { positionButton.isEnabled }
    var qaJumpError: String? { positionController?.validationText }
    var qaJumpContentView: NSView? { positionController?.view }
    func qaSubmitJump(_ value: String) {
        let controller = makePositionController()
        _ = controller.view
        controller.submit(value)
    }
#endif
}

@MainActor
private final class DocumentInformationPopoverController: NSViewController {
    private let details = NSTextView(frame: NSRect(x: 0, y: 0, width: 308, height: 160))
    private var text: String

    init(text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 230))
        let title = NSTextField(labelWithString: "Document information")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false
        details.font = .systemFont(ofSize: 12)
        details.isEditable = false
        details.isSelectable = true
        details.drawsBackground = false
        details.isVerticallyResizable = true
        details.isHorizontallyResizable = false
        details.autoresizingMask = [.width]
        details.textContainerInset = .zero
        details.textContainer?.lineFragmentPadding = 0
        details.textContainer?.widthTracksTextView = true
        details.textContainer?.containerSize = NSSize(width: 308, height: CGFloat.greatestFiniteMagnitude)
        details.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        details.string = text
        details.setAccessibilityLabel("File details and current activity")
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = details
        view.addSubview(title)
        view.addSubview(scrollView)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            title.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16)
        ])
    }

    func update(_ text: String) {
        self.text = text
        if isViewLoaded { details.string = text }
    }
}

@MainActor
private final class DocumentPositionPopoverController: NSViewController, NSTextFieldDelegate {
    var onSubmit: ((Int64, @escaping (String?) -> Void) -> Void)?
    var onClose: (() -> Void)?
    private let unit: String
    private let current: Int64?
    private let total: Int64?
    private let field = NSTextField(string: "")
    private let validation = NSTextField(wrappingLabelWithString: "")
    private let goButton = NSButton(title: "Go", target: nil, action: nil)
    private var requestGeneration = 0

    init(unit: String, current: Int64?, total: Int64?) {
        self.unit = unit
        self.current = current
        self.total = total
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 290, height: 160))
        let title = NSTextField(labelWithString: "Go to \(unit)")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        field.placeholderString = "\(unit.capitalized) number"
        field.stringValue = current.map(String.init) ?? ""
        field.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        field.delegate = self
        field.target = self
        field.action = #selector(submitField(_:))
        field.setAccessibilityLabel("\(unit.capitalized) number")
        validation.font = .systemFont(ofSize: 11)
        validation.textColor = .secondaryLabelColor
        validation.stringValue = total.map { "Enter a \(unit) from 1 to \($0.formatted())." }
            ?? "Enter a positive \(unit) number."
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        goButton.target = self
        goButton.action = #selector(submitField(_:))
        goButton.bezelStyle = .rounded
        goButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, goButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [title, field, validation, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -16),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor),
            validation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
            field.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
        field.selectText(nil)
    }

    @objc private func submitField(_ sender: Any?) { submit(field.stringValue) }
    @objc private func cancel(_ sender: Any?) {
        requestGeneration += 1
        onClose?()
    }

    func submit(_ text: String) {
        guard goButton.isEnabled else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              let value = Int64(trimmed), value > 0 else {
            showValidation("Enter a positive whole \(unit) number.")
            return
        }
        if let total, value > total {
            showValidation("This document has \(total.formatted()) \(unit)\(total == 1 ? "" : "s").")
            return
        }
        guard let onSubmit else {
            showValidation("Navigation is unavailable in this presentation.")
            return
        }
        requestGeneration += 1
        let generation = requestGeneration
        goButton.isEnabled = false
        field.isEnabled = false
        validation.textColor = .secondaryLabelColor
        validation.stringValue = "Locating \(unit) \(value.formatted())…"
        onSubmit(value) { [weak self] error in
            guard let self, self.requestGeneration == generation else { return }
            self.goButton.isEnabled = true
            self.field.isEnabled = true
            if let error { self.showValidation(error) }
            else { self.onClose?() }
        }
    }

    private func showValidation(_ message: String) {
        validation.stringValue = message
        validation.textColor = .systemRed
        validation.setAccessibilityValue(message)
        preferredContentSize = NSSize(width: 290, height: max(160, view.fittingSize.height))
        NSAccessibility.post(element: validation, notification: .valueChanged)
    }

    var validationText: String { validation.stringValue }
}
