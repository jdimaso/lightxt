import AppKit

@MainActor
final class TabularQueryLoadingOverlayView: NSView {
    var blocksInteraction = false

    private let card = NSVisualEffectView()
    private let indicator = TabularQueryLoadingIndicatorView()
    private let titleLabel = NSTextField(labelWithString: "Filtering")
    private let detailLabel = NSTextField(labelWithString: "")

    init(title: String, accessibilityLabel: String, preferredWidth: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(accessibilityLabel)
        titleLabel.stringValue = title

        card.material = .popover
        card.blendingMode = .withinWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 16
        card.layer?.masksToBounds = true

        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 12.5, weight: .regular)
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 2

        addSubview(card)
        [indicator, titleLabel, detailLabel].forEach { card.addSubview($0) }
        [card, indicator, titleLabel, detailLabel].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        let widthConstraint = card.widthAnchor.constraint(equalToConstant: preferredWidth)
        widthConstraint.priority = .defaultHigh
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            card.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
            widthConstraint,
            card.heightAnchor.constraint(equalToConstant: 112),

            indicator.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 24),
            indicator.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            indicator.widthAnchor.constraint(equalToConstant: 104),
            indicator.heightAnchor.constraint(equalToConstant: 64),

            titleLabel.leadingAnchor.constraint(equalTo: indicator.trailingAnchor, constant: 20),
            titleLabel.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -24),
            titleLabel.topAnchor.constraint(equalTo: card.topAnchor, constant: 27),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7),
            detailLabel.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -22),
        ])
        applyResolvedAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyResolvedAppearance()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        blocksInteraction ? super.hitTest(point) : nil
    }

    func update(title: String, detail: String, progress: Double? = nil) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        indicator.progress = progress
        setAccessibilityLabel(title)
        setAccessibilityHelp(detail)
        setAccessibilityValue(progress.map { Int(min(1, max(0, $0)) * 100) })
    }

    func startAnimating() {
        indicator.startAnimating()
    }

    func stopAnimating() {
        indicator.stopAnimating()
    }

    private func applyResolvedAppearance() {
        let appearance = effectiveAppearance
        let background = LighTxtTheme.resolved(LighTxtTheme.editorBackground, for: appearance)
        let primary = LighTxtTheme.resolved(LighTxtTheme.primaryText, for: appearance)
        let secondary = LighTxtTheme.resolved(LighTxtTheme.secondaryText, for: appearance)
        let separator = LighTxtTheme.resolved(LighTxtTheme.separator, for: appearance)
        layer?.backgroundColor = background.withAlphaComponent(0.46).cgColor
        card.layer?.borderColor = separator.withAlphaComponent(0.48).cgColor
        card.layer?.borderWidth = 1
        titleLabel.textColor = primary
        detailLabel.textColor = secondary
        indicator.applyResolvedAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Rows drift beneath a scanning beam; matching cells pulse as the projected
/// row map is assembled. It is intentionally table-shaped rather than a
/// generic spinner so the animation explains the work without extra copy.
@MainActor
private final class TabularQueryLoadingIndicatorView: NSView {
    var progress: Double? {
        didSet {
            if let progress {
                setAccessibilityValue(Int(min(1, max(0, progress)) * 100))
            } else {
                setAccessibilityValue(nil)
            }
            positionStaticScannerIfNeeded()
        }
    }

    private let viewportLayer = CALayer()
    private let outlineLayer = CAShapeLayer()
    private let scannerLayer = CAGradientLayer()
    private var cellLayers: [CALayer] = []
    private let highlightedCells: Set<Int> = [2, 6, 13, 17]
    private var isAnimating = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(false)

        viewportLayer.masksToBounds = true
        viewportLayer.cornerRadius = 8
        layer?.addSublayer(viewportLayer)

        outlineLayer.fillColor = NSColor.clear.cgColor
        outlineLayer.lineWidth = 1
        viewportLayer.addSublayer(outlineLayer)

        for _ in 0..<20 {
            let cell = CALayer()
            cell.cornerRadius = 2.5
            cellLayers.append(cell)
            viewportLayer.addSublayer(cell)
        }

        scannerLayer.startPoint = CGPoint(x: 0, y: 0.5)
        scannerLayer.endPoint = CGPoint(x: 1, y: 0.5)
        scannerLayer.locations = [0, 0.48, 0.52, 1]
        viewportLayer.addSublayer(scannerLayer)
        progress = nil
        applyResolvedAppearance()
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        viewportLayer.frame = bounds.insetBy(dx: 2, dy: 4)
        outlineLayer.frame = viewportLayer.bounds
        outlineLayer.path = CGPath(
            roundedRect: viewportLayer.bounds.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: 8,
            cornerHeight: 8,
            transform: nil
        )

        let horizontalInset: CGFloat = 8
        let verticalInset: CGFloat = 7
        let columnGap: CGFloat = 4
        let rowGap: CGFloat = 6
        let columns: CGFloat = 5
        let rows: CGFloat = 4
        let cellWidth = max(
            4,
            (viewportLayer.bounds.width - horizontalInset * 2 - columnGap * (columns - 1)) / columns
        )
        let cellHeight = max(
            4,
            (viewportLayer.bounds.height - verticalInset * 2 - rowGap * (rows - 1)) / rows
        )
        for (index, cell) in cellLayers.enumerated() {
            let row = CGFloat(index / 5)
            let column = CGFloat(index % 5)
            cell.frame = CGRect(
                x: horizontalInset + column * (cellWidth + columnGap),
                y: verticalInset + row * (cellHeight + rowGap),
                width: cellWidth,
                height: cellHeight
            )
        }
        scannerLayer.frame = CGRect(
            x: -34,
            y: 1,
            width: 34,
            height: max(0, viewportLayer.bounds.height - 2)
        )
        CATransaction.commit()
        positionStaticScannerIfNeeded()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyResolvedAppearance()
    }

    func applyResolvedAppearance() {
        let appearance = effectiveAppearance
        let accent = LighTxtTheme.resolved(LighTxtTheme.accent, for: appearance)
        let secondary = LighTxtTheme.resolved(LighTxtTheme.secondaryText, for: appearance)
        viewportLayer.backgroundColor = secondary.withAlphaComponent(0.055).cgColor
        outlineLayer.strokeColor = secondary.withAlphaComponent(0.24).cgColor
        for (index, cell) in cellLayers.enumerated() {
            cell.backgroundColor = (highlightedCells.contains(index) ? accent : secondary)
                .withAlphaComponent(highlightedCells.contains(index) ? 0.92 : 0.25)
                .cgColor
        }
        scannerLayer.colors = [
            accent.withAlphaComponent(0).cgColor,
            accent.withAlphaComponent(0.08).cgColor,
            accent.withAlphaComponent(0.72).cgColor,
            accent.withAlphaComponent(0).cgColor,
        ]
    }

    func startAnimating() {
        guard !isAnimating else { return }
        isAnimating = true
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            positionStaticScannerIfNeeded()
            return
        }
        layoutSubtreeIfNeeded()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scannerLayer.setAffineTransform(.identity)
        CATransaction.commit()

        let scan = CABasicAnimation(keyPath: "transform.translation.x")
        scan.fromValue = 0
        scan.toValue = viewportLayer.bounds.width + 68
        scan.duration = 1.18
        scan.repeatCount = .infinity
        scan.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        scannerLayer.add(scan, forKey: "table.queryScan")

        for (order, index) in highlightedCells.sorted().enumerated() {
            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = [0.42, 1, 0.42]
            pulse.keyTimes = [0, 0.48, 1]
            pulse.duration = 1.25
            pulse.beginTime = CACurrentMediaTime() + Double(order) * 0.14
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            cellLayers[index].add(pulse, forKey: "table.matchPulse")
        }
    }

    func stopAnimating() {
        isAnimating = false
        scannerLayer.removeAllAnimations()
        cellLayers.forEach { $0.removeAllAnimations() }
    }

    private func positionStaticScannerIfNeeded() {
        guard NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let fraction = CGFloat(min(1, max(0, progress ?? 0.5)))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scannerLayer.setAffineTransform(
            CGAffineTransform(translationX: fraction * (viewportLayer.bounds.width + 34), y: 0)
        )
        CATransaction.commit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
