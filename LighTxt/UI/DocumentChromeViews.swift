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
        labels: ["View", "Edit"],
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
    private let findButton = HeaderIconButton(
        symbolName: "magnifyingglass",
        accessibilityLabel: "Find"
    )
    private var currentFileURL: URL?
    private var trailingWidthConstraint: NSLayoutConstraint?
    private var isPrettifyAvailable = false
    private var isExportVisible = false

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
        detailLabel.stringValue = "\(typeName)  ·  \(ByteCountFormatter.lighTxt.string(fromByteCount: byteCount))"
        typeBadge.text = typeAbbreviation.uppercased()
        editedDot.isHidden = !edited
        setStructureAvailable(structureAvailable)
        let location = currentFileURL?.path ?? title
        setAccessibilityLabel("\(location), \(typeName), \(edited ? "edited" : "saved")")
    }

    var presentationMode: DocumentPresentationMode {
        get { DocumentPresentationMode(rawValue: modeControl.selectedSegment) ?? .edit }
        set { modeControl.selectedSegment = newValue.rawValue }
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
            modeControl.selectedSegment = DocumentPresentationMode.view.rawValue
        }
        modeControl.toolTip = available
            ? "Switch between a rendered view and byte-window editing"
            : (unavailableReason ?? "This document is available in read-only View mode")
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
        modeControl.setWidth(58, forSegment: 0)
        modeControl.setWidth(58, forSegment: 1)
        modeControl.toolTip = "Switch between a rendered view and byte-window editing"
        modeControl.setAccessibilityLabel("Document mode")
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
        findButton.toolTip = "Find in document (Command-F)"
        findButton.keyEquivalent = "f"
        findButton.keyEquivalentModifierMask = [.command]
        findButton.onActivate = { [weak self] in self?.onFind?() }

        let trailing = NSStackView(
            views: [modeControl, prettifyButton, exportButton, structureButton, findButton]
        )
        trailing.orientation = .horizontal
        trailing.alignment = .centerY
        trailing.spacing = 8
        trailing.setContentHuggingPriority(.required, for: .horizontal)

        [iconView, labels, editedDot, typeBadge, trailing].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }

        let trailingWidthConstraint = trailing.widthAnchor.constraint(equalToConstant: 197)
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
        trailingWidthConstraint?.constant = CGFloat(197)
            + (isExportVisible ? CGFloat(40) : 0)
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
        onPresentationModeChanged?(mode)
    }

    @objc private func prettifyChanged(_ sender: NSButton) {
        let enabled = sender.state == .on
        sender.setAccessibilityValue(enabled ? "On" : "Off")
        onPrettifyChanged?(enabled)
    }

#if LIGHTXT_RUNTIME_QA
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
    private let positionLabel = NSTextField(labelWithString: "Ln 1, Col 1")
    private let stateLabel = NSTextField(labelWithString: "Ready")
    private let progress = NSProgressIndicator()
    private let memoryBadge = NSTextField(labelWithString: "BYTE WINDOW")
    private var stateIsError = false

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

    func updatePosition(line: Int64, column: Int, selectionByteCount: Int64 = 0) {
        var text = "Ln \(line.formatted()), Col \(column.formatted())"
        if selectionByteCount > 0 {
            text += "  ·  \(ByteCountFormatter.lighTxt.string(fromByteCount: selectionByteCount)) selected"
        }
        positionLabel.stringValue = text
    }

    func setState(_ text: String, busy: Bool = false, isError: Bool = false) {
        stateLabel.stringValue = text
        stateLabel.toolTip = text
        stateIsError = isError
        applyResolvedAppearance()
        progress.isHidden = !busy
        busy ? progress.startAnimation(nil) : progress.stopAnimation(nil)
    }

    func updateByteWindow(_ range: Range<Int64>, totalByteCount: Int64) {
        let lower = min(max(0, range.lowerBound), totalByteCount)
        let upper = min(max(lower, range.upperBound), totalByteCount)
        memoryBadge.stringValue = "BYTE WINDOW \(lower.formatted())–\(upper.formatted()) OF \(ByteCountFormatter.lighTxt.string(fromByteCount: totalByteCount))"
        memoryBadge.toolTip = "Editing bytes \(lower.formatted()) through \(upper.formatted()) of \(totalByteCount.formatted()) total bytes"
    }

    func showFileBackedView(totalByteCount: Int64) {
        memoryBadge.stringValue = "FILE-BACKED VIEW · \(ByteCountFormatter.lighTxt.string(fromByteCount: totalByteCount))"
        memoryBadge.toolTip = "The document remains file-backed while this view is open"
    }

    private func configure() {
        positionLabel.font = LighTxtTheme.detailFont
        positionLabel.textColor = LighTxtTheme.secondaryText
        positionLabel.setContentHuggingPriority(.required, for: .horizontal)

        stateLabel.font = LighTxtTheme.detailFont
        stateLabel.textColor = LighTxtTheme.secondaryText
        stateLabel.alignment = .center
        stateLabel.lineBreakMode = .byTruncatingMiddle
        stateLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.isHidden = true

        memoryBadge.font = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
        memoryBadge.textColor = LighTxtTheme.accent
        memoryBadge.toolTip = "Only the displayed byte window is materialized for editing"
        memoryBadge.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [positionLabel, stateLabel, progress, memoryBadge])
        row.translatesAutoresizingMaskIntoConstraints = false
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 9
        addSubview(row)

        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            progress.widthAnchor.constraint(equalToConstant: 14),
            progress.heightAnchor.constraint(equalToConstant: 14)
        ])
    }

    private func applyResolvedAppearance() {
        let appearance = effectiveAppearance
        layer?.backgroundColor = LighTxtTheme.resolved(
            LighTxtTheme.chromeBackground,
            for: appearance
        ).cgColor
        layer?.borderColor = LighTxtTheme.resolved(
            LighTxtTheme.separator,
            for: appearance
        ).cgColor
        positionLabel.textColor = LighTxtTheme.resolved(
            LighTxtTheme.secondaryText,
            for: appearance
        )
        stateLabel.textColor = LighTxtTheme.resolved(
            stateIsError ? LighTxtTheme.error : LighTxtTheme.secondaryText,
            for: appearance
        )
        memoryBadge.textColor = LighTxtTheme.resolved(LighTxtTheme.accent, for: appearance)
    }
}
