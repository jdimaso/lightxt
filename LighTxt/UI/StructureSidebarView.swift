import AppKit
import QuartzCore

enum StructureSidebarPresentation {
    case sidebar
    case fullWorkspace
}

enum StructureSidebarChildState {
    case leaf
    case unloaded
    case loading
    case loaded
}

enum StructureSidebarNodeRole {
    case content
    case loadMore
}

/// A bounded, source-faithful search row. `highlightUTF16Range` points into
/// `text`, allowing AppKit to emphasize the exact bytes represented by a match
/// without guessing how a decoded JSON escape maps back to its source spelling.
struct StructureSearchResult: Sendable, Equatable {
    let match: SearchMatch
    let text: String
    let highlightUTF16Range: Range<Int>
}

/// UI-facing tree node used by both the bounded viewport discovery path and a
/// future streaming whole-document index. Stable identifiers let the outline
/// preserve expansion while children arrive in batches.
@MainActor
final class StructureSidebarNode: NSObject {
    let identifier: String
    let title: String
    let subtitle: String
    let range: Range<Int64>
    let kind: SyntaxFoldKind?
    let role: StructureSidebarNodeRole
    let highlightUTF16Range: Range<Int>?
    let isSearchMatch: Bool
    var children: [StructureSidebarNode]
    var childState: StructureSidebarChildState

    init(
        identifier: String? = nil,
        title: String,
        subtitle: String,
        range: Range<Int64>,
        kind: SyntaxFoldKind?,
        role: StructureSidebarNodeRole = .content,
        highlightUTF16Range: Range<Int>? = nil,
        isSearchMatch: Bool = false,
        children: [StructureSidebarNode] = [],
        childState: StructureSidebarChildState? = nil
    ) {
        self.identifier = identifier ?? "\(range.lowerBound):\(range.upperBound):\(title)"
        self.title = title
        self.subtitle = subtitle
        self.range = range
        self.kind = kind
        self.role = role
        self.highlightUTF16Range = highlightUTF16Range
        self.isSearchMatch = isSearchMatch
        self.children = children
        self.childState = childState ?? (children.isEmpty ? .leaf : .loaded)
    }

    var isExpandable: Bool {
        !children.isEmpty || childState == .unloaded || childState == .loading
    }
}

struct StructureSidebarLoadingState {
    let title: String
    let detail: String
    let fractionCompleted: Double?
    let processedByteCount: Int64?
    let totalByteCount: Int64?

    init(
        title: String = "Mapping JSON",
        detail: String = "Discovering the document structure without materializing the editor.",
        fractionCompleted: Double? = nil,
        processedByteCount: Int64? = nil,
        totalByteCount: Int64? = nil
    ) {
        self.title = title
        self.detail = detail
        self.fractionCompleted = fractionCompleted.map { min(1, max(0, $0)) }
        self.processedByteCount = processedByteCount
        self.totalByteCount = totalByteCount
    }
}

@MainActor
protocol StructureSidebarDelegate: AnyObject {
    func structureSidebar(_ sidebar: StructureSidebarView, revealByteRange range: Range<Int64>)
    func structureSidebar(
        _ sidebar: StructureSidebarView,
        didRequestChildrenFor node: StructureSidebarNode
    )
    func structureSidebarDidRequestClose(_ sidebar: StructureSidebarView)
    func structureSidebar(
        _ sidebar: StructureSidebarView,
        didActivate node: StructureSidebarNode
    ) -> Bool
    func structureSidebar(
        _ sidebar: StructureSidebarView,
        contextMenuFor node: StructureSidebarNode
    ) -> NSMenu?
}

extension StructureSidebarDelegate {
    func structureSidebar(
        _ sidebar: StructureSidebarView,
        didRequestChildrenFor node: StructureSidebarNode
    ) {}

    func structureSidebarDidRequestClose(_ sidebar: StructureSidebarView) {}

    func structureSidebar(
        _ sidebar: StructureSidebarView,
        didActivate node: StructureSidebarNode
    ) -> Bool { false }

    func structureSidebar(
        _ sidebar: StructureSidebarView,
        contextMenuFor node: StructureSidebarNode
    ) -> NSMenu? { nil }
}

@MainActor
final class StructureSidebarView: NSView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    weak var delegate: StructureSidebarDelegate?

    var presentation: StructureSidebarPresentation = .sidebar {
        didSet {
            guard oldValue != presentation else { return }
            applyPresentation()
        }
    }

    private let titleLabel = NSTextField(labelWithString: "Structure")
    private let scopeLabel = NSTextField(labelWithString: "Document outline")
    private let locationLabel = NSTextField(labelWithString: "")
    private let outline = StructureOutlineView()
    private let scrollView = NSScrollView()
    private let collapseAllButton = HeaderIconButton(
        symbolName: "rectangle.compress.vertical",
        accessibilityLabel: "Collapse all groups"
    )
    private let closeButton = HeaderIconButton(
        symbolName: "chevron.right",
        accessibilityLabel: "Close structure sidebar"
    )

    private let emptyIcon = NSImageView()
    private let emptyTitle = NSTextField(labelWithString: "No structure yet")
    private let emptyLabel = NSTextField(
        wrappingLabelWithString: "Groups appear here as LighTxt discovers objects, arrays, elements, and mappings."
    )
    private let emptyState = NSStackView()

    private let loadingIndicator = JSONLoadingIndicatorView()
    private let loadingTitle = NSTextField(labelWithString: "Mapping JSON")
    private let loadingDetail = NSTextField(wrappingLabelWithString: "Discovering document structure…")
    private let loadingProgress = NSProgressIndicator()
    private let loadingBytes = NSTextField(labelWithString: "Starting…")
    private let loadingState = NSStackView()

    private var headingLeadingConstraint: NSLayoutConstraint!
    private var headingTrailingConstraint: NSLayoutConstraint!
    private var roots: [StructureSidebarNode] = []
    private var currentLoadingState: StructureSidebarLoadingState?
    private var fullWorkspaceFontSize: CGFloat = 15
    /// Authoritative size for a whole-document snapshot. Bounded viewport and
    /// search trees leave this nil so their selected offsets are never shown
    /// against a misleading partial-range denominator.
    private var locationDocumentByteCount: Int64?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 0.5
        configure()
        applyPresentation()
        applyResolvedAppearance(reloadOutline: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyResolvedAppearance()
        if currentLoadingState != nil, window != nil { loadingIndicator.startAnimating() }
        else { loadingIndicator.stopAnimating() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyResolvedAppearance()
    }

    // MARK: - Streaming tree API

    func applyTreeSnapshot(
        _ nodes: [StructureSidebarNode],
        title: String = "Structure",
        scope: String = "Document outline",
        documentByteCount: Int64? = nil,
        preservingExpansion: Bool = true
    ) {
        let expanded = preservingExpansion ? expandedIdentifiers() : []
        roots = nodes
        titleLabel.stringValue = title
        scopeLabel.stringValue = scope
        locationDocumentByteCount = documentByteCount.flatMap { $0 > 0 ? $0 : nil }
        clearLoadingState()
        outline.reloadData()
        restoreExpansion(expanded)
        clearLocation()
        if !preservingExpansion, roots.count == 1, roots[0].isExpandable {
            outline.expandItem(roots[0])
        }
        showEmptyStateIfNeeded(
            title: "No structure found",
            detail: "This document does not contain any expandable groups."
        )
    }

    /// Replaces a deferred node's children in place. A whole-document parser
    /// can call this repeatedly without rebuilding or retaining visible cells.
    func replaceChildren(
        of parentIdentifier: String,
        with children: [StructureSidebarNode],
        final: Bool
    ) {
        guard let parent = node(withIdentifier: parentIdentifier, in: roots) else { return }
        parent.children = children
        parent.childState = final ? (children.isEmpty ? .leaf : .loaded) : .unloaded
        outline.reloadItem(parent, reloadChildren: true)
        if outline.isItemExpanded(parent) { outline.expandItem(parent) }
    }

    /// Appends one bounded page without discarding rows already published for
    /// the parent. The optional continuation row is replaced on every call, so
    /// even million-item arrays retain only the pages the user has requested.
    func appendChildren(
        of parentIdentifier: String,
        page: [StructureSidebarNode],
        continuation: StructureSidebarNode?,
        final: Bool
    ) {
        guard let parent = node(withIdentifier: parentIdentifier, in: roots) else { return }
        parent.children.removeAll { $0.role == .loadMore }
        parent.children.append(contentsOf: page)
        if let continuation { parent.children.append(continuation) }
        parent.childState = final && parent.children.isEmpty ? .leaf : .loaded
        outline.reloadItem(parent, reloadChildren: true)
        if outline.isItemExpanded(parent) { outline.expandItem(parent) }
    }

    func setChildState(
        _ state: StructureSidebarChildState,
        for nodeIdentifier: String
    ) {
        guard let item = node(withIdentifier: nodeIdentifier, in: roots) else { return }
        item.childState = state
        outline.reloadItem(item)
    }

    func showMessage(title: String, detail: String, scope: String) {
        roots = []
        locationDocumentByteCount = nil
        titleLabel.stringValue = presentation == .fullWorkspace ? "JSON Explorer" : "Structure"
        scopeLabel.stringValue = scope
        clearLoadingState()
        outline.reloadData()
        outline.deselectAll(nil)
        clearLocation()
        showEmptyState(title: title, detail: detail)
    }

    func showLoading(_ state: StructureSidebarLoadingState) {
        currentLoadingState = state
        locationDocumentByteCount = state.totalByteCount.flatMap { $0 > 0 ? $0 : nil }
        titleLabel.stringValue = presentation == .fullWorkspace ? "JSON Explorer" : "Structure"
        scopeLabel.stringValue = loadingScopeText(for: state)
        loadingTitle.stringValue = state.title
        loadingDetail.stringValue = state.detail

        if let fraction = state.fractionCompleted {
            loadingProgress.isIndeterminate = false
            loadingProgress.doubleValue = fraction * 100
        } else {
            loadingProgress.isIndeterminate = true
            loadingProgress.startAnimation(nil)
        }
        loadingBytes.stringValue = loadingByteText(for: state)
        loadingState.isHidden = false
        scrollView.isHidden = true
        emptyState.isHidden = true
        loadingIndicator.progress = state.fractionCompleted
        if window != nil { loadingIndicator.startAnimating() }
        setAccessibilityLabel("\(state.title). \(loadingBytes.stringValue)")
    }

    func clearLoadingState() {
        currentLoadingState = nil
        loadingProgress.stopAnimation(nil)
        loadingIndicator.stopAnimating()
        loadingState.isHidden = true
        scrollView.isHidden = false
        setAccessibilityLabel("Document structure")
    }

    // MARK: - Existing bounded-viewport adapter

    func update(
        folds: [SyntaxFoldRange],
        viewportData: Data,
        viewportBaseOffset: Int64,
        fileType: SyntaxFileType
    ) {
        locationDocumentByteCount = nil
        titleLabel.stringValue = presentation == .fullWorkspace ? "Document Structure" : "Structure"
        guard fileType == .json || fileType == .xml || fileType == .yaml else {
            roots = []
            clearLoadingState()
            outline.reloadData()
            scopeLabel.stringValue = "Not available for this format"
            showEmptyState(
                title: "No outline for this format",
                detail: "Structure view is available for JSON, XML, and YAML documents."
            )
            return
        }

        let sorted = folds
            .filter { $0.range.length > 1 }
            .sorted {
                if $0.range.start == $1.range.start { return $0.range.length > $1.range.length }
                return $0.range.start < $1.range.start
            }
            .prefix(2_048)

        var builtRoots: [StructureSidebarNode] = []
        var stack: [StructureSidebarNode] = []
        for fold in sorted {
            let globalStart = Int64(fold.range.start)
            let globalEnd = globalStart + Int64(fold.range.length)
            let item = StructureSidebarNode(
                title: label(
                    for: fold,
                    data: viewportData,
                    base: viewportBaseOffset,
                    fileType: fileType
                ),
                subtitle: "\(fold.kind.rawValue.capitalized)  ·  \(ByteCountFormatter.lighTxt.string(fromByteCount: Int64(fold.range.length)))",
                range: globalStart..<globalEnd,
                kind: fold.kind
            )
            while let parent = stack.last, !parent.range.contains(globalStart) {
                stack.removeLast()
            }
            if let parent = stack.last, globalEnd <= parent.range.upperBound {
                parent.children.append(item)
                parent.childState = .loaded
            } else {
                builtRoots.append(item)
            }
            stack.append(item)
        }

        let expanded = expandedIdentifiers()
        roots = builtRoots
        scopeLabel.stringValue = "Current edit window  ·  \(folds.count.formatted()) groups"
        clearLoadingState()
        outline.reloadData()
        clearLocation()
        restoreExpansion(expanded)
        if expanded.isEmpty, roots.count == 1, roots[0].isExpandable {
            outline.expandItem(roots[0])
        }
        showEmptyStateIfNeeded(
            title: "No groups in this window",
            detail: "Move through the document to discover nearby expandable groups."
        )
    }

    func updateSearchResults(
        _ results: [StructureSearchResult],
        total: Int,
        truncated: Bool,
        title: String = "Find Results"
    ) {
        locationDocumentByteCount = nil
        titleLabel.stringValue = title
        let retained = results.prefix(20_000)
        roots = retained.enumerated().map { index, match in
            StructureSidebarNode(
                identifier: "search:\(match.match.byteRange.lowerBound):\(match.match.byteRange.upperBound):\(index)",
                title: match.text,
                subtitle: "Match \((index + 1).formatted())  ·  byte \(match.match.byteRange.lowerBound.formatted())  ·  \(match.match.byteRange.count.formatted()) bytes",
                range: match.match.byteRange,
                kind: nil,
                highlightUTF16Range: match.highlightUTF16Range,
                isSearchMatch: true
            )
        }
        let suffix = truncated ? "  ·  first \(roots.count.formatted()) shown" : ""
        scopeLabel.stringValue = "\(total.formatted()) matches\(suffix)"
        clearLoadingState()
        outline.reloadData()
        // Find All intentionally publishes an unselected list. A subsequent
        // user click/keyboard selection must emit one activation and resolve
        // the focused hierarchy; a stale selection could swallow that click.
        outline.deselectAll(nil)
        clearLocation()
        showEmptyStateIfNeeded(title: "No matches", detail: "Try a different search term or pattern.")
    }

    func selectSearchResult(matching range: Range<Int64>) {
        guard let row = (0..<outline.numberOfRows).first(where: {
            (outline.item(atRow: $0) as? StructureSidebarNode)?.range == range
        }) else { return }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    /// Expands the exact in-memory ancestor chain and scrolls/selects the
    /// requested node. Focused search trees use this after constructing a
    /// bounded source path, so the highlighted match cannot remain hidden
    /// below a collapsed ancestor.
    func revealNode(withIdentifier identifier: String) {
        guard let path = nodePath(withIdentifier: identifier, in: roots),
              let target = path.last else { return }
        for ancestor in path.dropLast() where ancestor.isExpandable {
            outline.expandItem(ancestor)
        }
        outline.reloadData()
        guard let row = (0..<outline.numberOfRows).first(where: {
            (outline.item(atRow: $0) as? StructureSidebarNode) === target
        }) else { return }
        outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        outline.scrollRowToVisible(row)
    }

    func changeFullWorkspaceFontSize(by delta: CGFloat) {
        setFullWorkspaceFontSize(fullWorkspaceFontSize + delta)
    }

    func resetFullWorkspaceFontSize() {
        setFullWorkspaceFontSize(15)
    }

    private func setFullWorkspaceFontSize(_ size: CGFloat) {
        let bounded = min(28, max(11, size))
        guard bounded != fullWorkspaceFontSize else { return }
        fullWorkspaceFontSize = bounded
        if presentation == .fullWorkspace {
            outline.rowHeight = fullWorkspaceRowHeight
            outline.reloadData()
        }
    }

    private var fullWorkspaceRowHeight: CGFloat {
        let subtitleSize = max(11.5, fullWorkspaceFontSize - 2.5)
        return max(40, ceil(fullWorkspaceFontSize + subtitleSize + 13))
    }

    // MARK: - NSOutlineView

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? StructureSidebarNode)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? StructureSidebarNode)?.children[index] ?? roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? StructureSidebarNode)?.isExpandable ?? false
    }

    func outlineView(
        _ outlineView: NSOutlineView,
        viewFor tableColumn: NSTableColumn?,
        item: Any
    ) -> NSView? {
        guard let node = item as? StructureSidebarNode else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("StructureCell")
        let cell = (outlineView.makeView(withIdentifier: identifier, owner: self) as? StructureRowView)
            ?? StructureRowView(identifier: identifier)
        cell.update(
            node: node,
            presentation: presentation,
            fullWorkspaceFontSize: fullWorkspaceFontSize,
            appearance: effectiveAppearance
        )
        cell.toolTip = node.isSearchMatch
            ? "\(node.title)\n\(node.subtitle)"
            : "Byte \(node.range.lowerBound.formatted())"
        return cell
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? StructureSidebarNode,
              node.childState == .unloaded else { return }
        node.childState = .loading
        outline.reloadItem(node)
        delegate?.structureSidebar(self, didRequestChildrenFor: node)
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        let row = outline.selectedRow
        guard row >= 0, let item = outline.item(atRow: row) as? StructureSidebarNode else {
            clearLocation()
            return
        }
        showLocation(for: item)
        if delegate?.structureSidebar(self, didActivate: item) == true { return }
        delegate?.structureSidebar(self, revealByteRange: item.range)
    }

    func outlineView(_ outlineView: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? {
        StructureSelectionRowView(
            showsSearchMatch: (item as? StructureSidebarNode)?.isSearchMatch == true
        )
    }

    // MARK: - View construction

    private func configure() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Document structure")

        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = LighTxtTheme.primaryText
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scopeLabel.font = NSFont.systemFont(ofSize: 11.5, weight: .regular)
        scopeLabel.textColor = LighTxtTheme.secondaryText
        scopeLabel.lineBreakMode = .byTruncatingTail
        locationLabel.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        locationLabel.textColor = LighTxtTheme.secondaryText
        locationLabel.lineBreakMode = .byTruncatingMiddle
        locationLabel.isHidden = true
        locationLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let headingLabels = NSStackView(views: [titleLabel, scopeLabel, locationLabel])
        headingLabels.orientation = .vertical
        headingLabels.alignment = .leading
        headingLabels.spacing = 2
        headingLabels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headingLabels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        collapseAllButton.toolTip = "Collapse all groups"
        collapseAllButton.onActivate = { [weak self] in self?.outline.collapseItem(nil, collapseChildren: true) }
        closeButton.toolTip = "Close structure sidebar"
        closeButton.onActivate = { [weak self] in
            guard let self else { return }
            self.delegate?.structureSidebarDidRequestClose(self)
        }

        let headingActions = NSStackView(views: [collapseAllButton, closeButton])
        headingActions.orientation = .horizontal
        headingActions.alignment = .centerY
        headingActions.spacing = 2
        headingActions.setContentHuggingPriority(.required, for: .horizontal)

        let headingSpacer = NSView()
        headingSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        headingSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let heading = NSStackView(views: [headingLabels, headingSpacer, headingActions])
        heading.translatesAutoresizingMaskIntoConstraints = false
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 8
        addSubview(heading)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Structure"))
        column.title = "Structure"
        column.minWidth = 220
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.rowHeight = 34
        outline.intercellSpacing = NSSize(width: 0, height: 1)
        outline.indentationPerLevel = 15
        outline.indentationMarkerFollowsCell = true
        outline.backgroundColor = .clear
        // A plain outline keeps the pane on LighTxt's blue-green surface;
        // source-list style paints an opaque system gray behind every row.
        outline.style = .plain
        outline.allowsEmptySelection = true
        outline.dataSource = self
        outline.delegate = self
        outline.contextMenuProvider = { [weak self] node in
            guard let self else { return nil }
            return self.delegate?.structureSidebar(self, contextMenuFor: node)
        }
        outline.rowGestureHandler = { [weak self] node, clickCount in
            self?.handleRowGesture(node, clickCount: clickCount)
        }
        outline.setAccessibilityLabel("Document structure outline")

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = outline
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.contentView.backgroundColor = .clear
        scrollView.borderType = .noBorder
        addSubview(scrollView)

        configureEmptyState()
        configureLoadingState()

        headingLeadingConstraint = heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16)
        headingTrailingConstraint = heading.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10)
        NSLayoutConstraint.activate([
            headingLeadingConstraint,
            headingTrailingConstraint,
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 13),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            scrollView.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            emptyState.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            emptyState.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            emptyState.centerXAnchor.constraint(equalTo: centerXAnchor),
            emptyState.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -10),
            emptyState.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            loadingState.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            loadingState.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            loadingState.centerXAnchor.constraint(equalTo: centerXAnchor),
            loadingState.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -12),
            loadingState.widthAnchor.constraint(lessThanOrEqualToConstant: 340)
        ])
    }

    private func configureEmptyState() {
        emptyIcon.imageScaling = .scaleProportionallyDown
        emptyIcon.image = NSImage(
            systemSymbolName: "list.bullet.indent",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 24, weight: .light))
        emptyIcon.setAccessibilityHidden(true)
        emptyTitle.font = NSFont.systemFont(ofSize: 13.5, weight: .semibold)
        emptyTitle.alignment = .center
        emptyLabel.font = NSFont.systemFont(ofSize: 12, weight: .regular)
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 4

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 8
        [emptyIcon, emptyTitle, emptyLabel].forEach { emptyState.addArrangedSubview($0) }
        addSubview(emptyState)
        emptyState.setAccessibilityElement(true)
        emptyState.setAccessibilityRole(.group)
    }

    private func configureLoadingState() {
        loadingTitle.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        loadingTitle.alignment = .center
        loadingDetail.font = NSFont.systemFont(ofSize: 12.5, weight: .regular)
        loadingDetail.alignment = .center
        loadingDetail.maximumNumberOfLines = 3
        loadingBytes.font = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .medium)
        loadingBytes.alignment = .center

        loadingProgress.style = .bar
        loadingProgress.controlSize = .small
        loadingProgress.minValue = 0
        loadingProgress.maxValue = 100

        loadingState.translatesAutoresizingMaskIntoConstraints = false
        loadingState.orientation = .vertical
        loadingState.alignment = .centerX
        loadingState.spacing = 9
        [loadingIndicator, loadingTitle, loadingDetail, loadingProgress, loadingBytes].forEach {
            loadingState.addArrangedSubview($0)
        }
        loadingState.setCustomSpacing(14, after: loadingIndicator)
        loadingState.setCustomSpacing(4, after: loadingTitle)
        addSubview(loadingState)
        loadingState.isHidden = true
        loadingState.setAccessibilityElement(true)
        loadingState.setAccessibilityRole(.group)

        NSLayoutConstraint.activate([
            loadingIndicator.widthAnchor.constraint(equalToConstant: 76),
            loadingIndicator.heightAnchor.constraint(equalToConstant: 76),
            loadingProgress.widthAnchor.constraint(equalToConstant: 230)
        ])
    }

    private func applyPresentation() {
        let full = presentation == .fullWorkspace
        titleLabel.font = NSFont.systemFont(ofSize: full ? 18 : 15, weight: .semibold)
        scopeLabel.font = NSFont.systemFont(ofSize: full ? 12.5 : 11.5, weight: .regular)
        outline.rowHeight = full ? fullWorkspaceRowHeight : 34
        outline.indentationPerLevel = full ? 17 : 15
        closeButton.isHidden = full
        headingLeadingConstraint?.constant = full ? 24 : 16
        headingTrailingConstraint?.constant = full ? -18 : -10
        outline.reloadData()
    }

    private func applyResolvedAppearance(reloadOutline: Bool = true) {
        let appearance = effectiveAppearance
        let primary = LighTxtTheme.resolved(LighTxtTheme.primaryText, for: appearance)
        let secondary = LighTxtTheme.resolved(LighTxtTheme.secondaryText, for: appearance)
        let accent = LighTxtTheme.resolved(LighTxtTheme.accent, for: appearance)
        layer?.backgroundColor = LighTxtTheme.resolved(
            LighTxtTheme.chromeBackground,
            for: appearance
        ).cgColor
        layer?.borderColor = LighTxtTheme.resolved(
            LighTxtTheme.separator,
            for: appearance
        ).cgColor
        titleLabel.textColor = primary
        scopeLabel.textColor = secondary
        locationLabel.textColor = secondary
        emptyIcon.contentTintColor = accent.withAlphaComponent(0.72)
        emptyTitle.textColor = primary
        emptyLabel.textColor = secondary
        loadingTitle.textColor = primary
        loadingDetail.textColor = secondary
        loadingBytes.textColor = accent
        loadingIndicator.applyResolvedAppearance()
        if reloadOutline { outline.reloadData() }
    }

    // MARK: - Helpers

    private func showEmptyStateIfNeeded(title: String, detail: String) {
        if roots.isEmpty { showEmptyState(title: title, detail: detail) }
        else { emptyState.isHidden = true }
    }

    private func showEmptyState(title: String, detail: String) {
        emptyTitle.stringValue = title
        emptyLabel.stringValue = detail
        emptyState.setAccessibilityLabel("\(title). \(detail)")
        emptyState.isHidden = false
        scrollView.isHidden = true
        loadingState.isHidden = true
    }

    private func expandedIdentifiers() -> Set<String> {
        var identifiers: Set<String> = []
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? StructureSidebarNode,
                  outline.isItemExpanded(node) else { continue }
            identifiers.insert(node.identifier)
        }
        return identifiers
    }

    private func restoreExpansion(_ identifiers: Set<String>) {
        guard !identifiers.isEmpty else { return }
        func visit(_ nodes: [StructureSidebarNode]) {
            for node in nodes {
                if identifiers.contains(node.identifier) { outline.expandItem(node) }
                visit(node.children)
            }
        }
        visit(roots)
    }

    private func node(
        withIdentifier identifier: String,
        in nodes: [StructureSidebarNode]
    ) -> StructureSidebarNode? {
        for node in nodes {
            if node.identifier == identifier { return node }
            if let match = self.node(withIdentifier: identifier, in: node.children) { return match }
        }
        return nil
    }

    private func nodePath(
        withIdentifier identifier: String,
        in nodes: [StructureSidebarNode]
    ) -> [StructureSidebarNode]? {
        for node in nodes {
            if node.identifier == identifier { return [node] }
            if let descendants = nodePath(withIdentifier: identifier, in: node.children) {
                return [node] + descendants
            }
        }
        return nil
    }

    private func handleRowGesture(_ node: StructureSidebarNode, clickCount: Int) {
        guard node.role == .content, node.isExpandable else { return }
        if clickCount >= 2 {
            if outline.isItemExpanded(node) {
                outline.collapseItem(node, collapseChildren: false)
            }
        } else if clickCount == 1, !outline.isItemExpanded(node) {
            outline.expandItem(node)
        }
    }

#if LIGHTXT_STANDALONE_STRUCTURE_QA
    var qaFullWorkspaceFontSize: CGFloat { fullWorkspaceFontSize }
    var qaRowHeight: CGFloat { outline.rowHeight }
    var qaTitle: String { titleLabel.stringValue }
    var qaScope: String { scopeLabel.stringValue }
    var qaSelectedRange: Range<Int64>? {
        guard outline.selectedRow >= 0 else { return nil }
        return (outline.item(atRow: outline.selectedRow) as? StructureSidebarNode)?.range
    }

    func qaPerformRowGesture(identifier: String, clickCount: Int) {
        guard let node = node(withIdentifier: identifier, in: roots) else { return }
        handleRowGesture(node, clickCount: clickCount)
    }

    func qaIsExpanded(identifier: String) -> Bool {
        guard let node = node(withIdentifier: identifier, in: roots) else { return false }
        return outline.isItemExpanded(node)
    }

    func qaAttributedTitle(identifier: String) -> NSAttributedString? {
        guard let node = node(withIdentifier: identifier, in: roots),
              let row = (0..<outline.numberOfRows).first(where: {
                  (outline.item(atRow: $0) as? StructureSidebarNode) === node
              }),
              let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true)
                as? StructureRowView else { return nil }
        return cell.qaAttributedTitle
    }

    func qaToolTip(identifier: String) -> String? {
        guard let node = node(withIdentifier: identifier, in: roots),
              let row = (0..<outline.numberOfRows).first(where: {
                  (outline.item(atRow: $0) as? StructureSidebarNode) === node
              }),
              let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: true)
                as? StructureRowView else { return nil }
        return cell.toolTip
    }
#endif

    private func showLocation(for node: StructureSidebarNode) {
        guard node.role == .content else { return }
        let path = path(to: node, in: roots) ?? [node.title]
        let renderedPath = jsonStylePath(path)
        let byte = max(0, node.range.lowerBound)
        let percent: String
        if let documentByteCount = locationDocumentByteCount {
            let fraction = min(1, max(0, Double(byte) / Double(documentByteCount)))
            percent = "  ·  \((fraction * 100).formatted(.number.precision(.fractionLength(fraction < 0.001 ? 4 : 2))))%"
        } else {
            percent = ""
        }
        locationLabel.stringValue = "\(renderedPath)  ·  byte \(byte.formatted())\(percent)"
        locationLabel.toolTip = locationLabel.stringValue
        locationLabel.isHidden = false
    }

    private func clearLocation() {
        locationLabel.stringValue = ""
        locationLabel.isHidden = true
    }

    private func path(
        to target: StructureSidebarNode,
        in nodes: [StructureSidebarNode]
    ) -> [String]? {
        for node in nodes {
            if node === target { return [node.title] }
            if let descendant = path(to: target, in: node.children) {
                return [node.title] + descendant
            }
        }
        return nil
    }

    private func jsonStylePath(_ components: [String]) -> String {
        var result = "$"
        for component in components.dropFirst() {
            if component.hasPrefix("[") {
                result += component
            } else if component.unicodeScalars.allSatisfy({
                CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_$")).contains($0)
            }), component.first?.isNumber != true {
                result += ".\(component)"
            } else {
                let escaped = component.replacingOccurrences(of: "\"", with: "\\\"")
                result += "[\"\(escaped)\"]"
            }
        }
        return result
    }

    private func loadingScopeText(for state: StructureSidebarLoadingState) -> String {
        guard let fraction = state.fractionCompleted else { return "Indexing document" }
        return "Indexing document  ·  \(Int(fraction * 100))%"
    }

    private func loadingByteText(for state: StructureSidebarLoadingState) -> String {
        if let processed = state.processedByteCount, let total = state.totalByteCount {
            return "\(ByteCountFormatter.lighTxt.string(fromByteCount: processed)) of \(ByteCountFormatter.lighTxt.string(fromByteCount: total))"
        }
        if let processed = state.processedByteCount {
            return "\(ByteCountFormatter.lighTxt.string(fromByteCount: processed)) mapped"
        }
        if let fraction = state.fractionCompleted { return "\(Int(fraction * 100))% complete" }
        return "Preparing the stream…"
    }

    private func label(
        for fold: SyntaxFoldRange,
        data: Data,
        base: Int64,
        fileType: SyntaxFileType
    ) -> String {
        let localStart = max(0, Int64(fold.range.start) - base)
        switch fileType {
        case .json:
            if let key = jsonKey(before: Int(localStart), in: data) { return key }
            if localStart == 0 { return fold.kind == .array ? "Root array" : "Root object" }
            if fold.kind == .object,
               let identity = jsonObjectIdentity(at: Int(localStart), in: data) {
                return identity
            }
            return fold.kind == .array ? "Array item" : "Object"
        case .xml:
            if let name = xmlElementName(at: Int(localStart), in: data) { return name }
        default:
            break
        }

        let localHeaderStart = max(0, Int64(fold.headerRange.start) - base)
        let localHeaderEnd = min(Int64(data.count), Int64(fold.headerRange.end) - base)
        if localHeaderEnd > localHeaderStart {
            let range = Int(localHeaderStart)..<Int(min(localHeaderEnd, localHeaderStart + 160))
            var text = String(decoding: data[range], as: UTF8.self)
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }
            if !text.isEmpty { return String(text.prefix(72)) }
        }
        switch fold.kind {
        case .object: return "Object"
        case .array: return "Array"
        case .element: return "Element"
        case .mapping: return "Mapping"
        case .sequence: return "Sequence"
        case .scalar: return "Scalar"
        case .comment: return "Comment"
        }
    }

    private func jsonKey(before opening: Int, in data: Data) -> String? {
        guard opening > 0, opening <= data.count else { return nil }
        var index = opening - 1
        while index >= 0, data[index] == 0x20 || data[index] == 0x09 || data[index] == 0x0A || data[index] == 0x0D {
            index -= 1
        }
        guard index >= 0, data[index] == 0x3A else { return nil }
        index -= 1
        while index >= 0, data[index] == 0x20 || data[index] == 0x09 || data[index] == 0x0A || data[index] == 0x0D {
            index -= 1
        }
        guard index >= 0, data[index] == 0x22 else { return nil }
        let closingQuote = index
        index -= 1
        while index >= 0 {
            if data[index] == 0x22 {
                var slashCount = 0
                var probe = index - 1
                while probe >= 0, data[probe] == 0x5C { slashCount += 1; probe -= 1 }
                if slashCount.isMultiple(of: 2) {
                    let bytes = data[(index + 1)..<closingQuote]
                    let value = String(decoding: bytes, as: UTF8.self)
                    return value.isEmpty ? nil : value
                }
            }
            index -= 1
        }
        return nil
    }

    /// Finds a compact identity from the first few scalar members of an array
    /// object. This turns repeated “Object item” rows into useful landmarks
    /// such as `plan_name · FlexPOS…` without materializing the object.
    private func jsonObjectIdentity(at opening: Int, in data: Data) -> String? {
        guard opening >= 0, opening < data.count, data[opening] == 0x7b else { return nil }
        let limit = min(data.count, opening + 768)
        let preferred = ["name", "title", "id", "plan_name", "plan_id", "reporting_entity_name"]
        var candidates: [(key: String, value: String)] = []
        var cursor = opening + 1
        while cursor < limit, candidates.count < 8 {
            while cursor < limit, isJSONSpace(data[cursor]) || data[cursor] == 0x2c { cursor += 1 }
            guard cursor < limit, data[cursor] == 0x22,
                  let key = simpleJSONString(at: &cursor, limit: limit, data: data) else { break }
            while cursor < limit, isJSONSpace(data[cursor]) { cursor += 1 }
            guard cursor < limit, data[cursor] == 0x3a else { break }
            cursor += 1
            while cursor < limit, isJSONSpace(data[cursor]) { cursor += 1 }
            let value: String?
            if cursor < limit, data[cursor] == 0x22 {
                value = simpleJSONString(at: &cursor, limit: limit, data: data)
            } else {
                let start = cursor
                while cursor < limit,
                      data[cursor] != 0x2c,
                      data[cursor] != 0x7d,
                      data[cursor] != 0x5b,
                      data[cursor] != 0x7b { cursor += 1 }
                let raw = String(decoding: data[start..<cursor], as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                value = raw.isEmpty ? nil : raw
            }
            if let value, !value.isEmpty {
                candidates.append((key, String(value.prefix(44))))
            }
            while cursor < limit, data[cursor] != 0x2c, data[cursor] != 0x7d { cursor += 1 }
            if cursor < limit, data[cursor] == 0x7d { break }
        }
        guard !candidates.isEmpty else { return nil }
        let chosen = preferred.lazy.compactMap { wanted in
            candidates.first { $0.key.caseInsensitiveCompare(wanted) == .orderedSame }
        }.first ?? candidates[0]
        return "\(chosen.key)  ·  \(chosen.value)"
    }

    private func simpleJSONString(at cursor: inout Int, limit: Int, data: Data) -> String? {
        guard cursor < limit, data[cursor] == 0x22 else { return nil }
        cursor += 1
        let start = cursor
        var escaped = false
        while cursor < limit {
            let byte = data[cursor]
            if escaped { escaped = false; cursor += 1; continue }
            if byte == 0x5c { escaped = true; cursor += 1; continue }
            if byte == 0x22 {
                let text = String(decoding: data[start..<cursor], as: UTF8.self)
                cursor += 1
                return text.replacingOccurrences(of: "\\\"", with: "\"")
            }
            cursor += 1
        }
        return nil
    }

    private func isJSONSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d
    }

    private func xmlElementName(at opening: Int, in data: Data) -> String? {
        guard opening >= 0, opening < data.count, data[opening] == 0x3C else { return nil }
        var index = opening + 1
        if index < data.count, data[index] == 0x2F { index += 1 }
        let start = index
        while index < data.count {
            let byte = data[index]
            guard (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) ||
                    (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x5F ||
                    byte == 0x3A || byte == 0x2E else { break }
            index += 1
        }
        guard index > start else { return nil }
        return String(decoding: data[start..<index], as: UTF8.self)
    }
}

/// Supplies a contextual menu only for a concrete row accepted by the owning
/// sidebar delegate. Search results and viewport-derived XML/YAML trees return
/// nil, so they cannot accidentally inherit JSON copy actions or stale state.
@MainActor
private final class StructureOutlineView: NSOutlineView {
    var contextMenuProvider: ((StructureSidebarNode) -> NSMenu?)?
    var rowGestureHandler: ((StructureSidebarNode, Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        let clickedDisclosure = clickedRow >= 0
            && frameOfOutlineCell(atRow: clickedRow).contains(point)
        let node = clickedRow >= 0 ? item(atRow: clickedRow) as? StructureSidebarNode : nil
        super.mouseDown(with: event)
        guard !clickedDisclosure, let node else { return }
        rowGestureHandler?(node, event.clickCount)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let clickedRow = row(at: point)
        guard clickedRow >= 0,
              let node = item(atRow: clickedRow) as? StructureSidebarNode,
              let menu = contextMenuProvider?(node),
              !menu.items.isEmpty else {
            return super.menu(for: event)
        }
        if !selectedRowIndexes.contains(clickedRow) {
            selectRowIndexes(IndexSet(integer: clickedRow), byExtendingSelection: false)
        }
        return menu
    }
}

/// Replaces AppKit's saturated source-list blue with a quiet brand-tinted
/// selection that keeps both title and metadata readable in light and dark UI.
@MainActor
private final class StructureSelectionRowView: NSTableRowView {
    private let showsSearchMatch: Bool

    init(showsSearchMatch: Bool) {
        self.showsSearchMatch = showsSearchMatch
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle { .normal }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard showsSearchMatch else { return }
        let accent = LighTxtTheme.resolved(LighTxtTheme.accent, for: effectiveAppearance)
        accent.withAlphaComponent(
            effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.13 : 0.09
        ).setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 3, dy: 1),
            xRadius: 5,
            yRadius: 5
        ).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let color = LighTxtTheme.resolved(LighTxtTheme.selection, for: effectiveAppearance)
            .withAlphaComponent(effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.5 : 0.42)
        color.setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 3, dy: 1),
            xRadius: 5,
            yRadius: 5
        ).fill()
    }
}

@MainActor
private final class StructureRowView: NSTableCellView {
    private let kindIcon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        kindIcon.translatesAutoresizingMaskIntoConstraints = false
        kindIcon.imageScaling = .scaleProportionallyDown
        kindIcon.setAccessibilityHidden(true)
        addSubview(kindIcon)

        titleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.lineBreakMode = .byTruncatingTail
        let labels = NSStackView(views: [titleLabel, subtitleLabel])
        labels.translatesAutoresizingMaskIntoConstraints = false
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2
        addSubview(labels)

        NSLayoutConstraint.activate([
            kindIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            kindIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
            kindIcon.widthAnchor.constraint(equalToConstant: 16),
            kindIcon.heightAnchor.constraint(equalToConstant: 16),
            labels.leadingAnchor.constraint(equalTo: kindIcon.trailingAnchor, constant: 8),
            labels.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func update(
        node: StructureSidebarNode,
        presentation: StructureSidebarPresentation,
        fullWorkspaceFontSize: CGFloat,
        appearance: NSAppearance
    ) {
        subtitleLabel.stringValue = node.childState == .loading ? "Loading children…" : node.subtitle
        let titleFontSize = presentation == .fullWorkspace ? fullWorkspaceFontSize : 13
        let titleFont = NSFont.systemFont(ofSize: titleFontSize, weight: .medium)
        titleLabel.font = titleFont
        subtitleLabel.font = NSFont.systemFont(
            ofSize: presentation == .fullWorkspace ? max(11.5, titleFontSize - 2.5) : 10.5,
            weight: .regular
        )
        let primary = LighTxtTheme.resolved(LighTxtTheme.primaryText, for: appearance)
        let secondary = LighTxtTheme.resolved(LighTxtTheme.secondaryText, for: appearance)
        let accent = LighTxtTheme.resolved(LighTxtTheme.accent, for: appearance)
        let titleColor = node.role == .loadMore ? accent : primary
        if let highlight = node.highlightUTF16Range {
            let attributed = NSMutableAttributedString(
                string: node.title,
                attributes: [.font: titleFont, .foregroundColor: titleColor]
            )
            let safeLower = min(max(0, highlight.lowerBound), attributed.length)
            let safeUpper = min(max(safeLower, highlight.upperBound), attributed.length)
            if safeUpper > safeLower {
                attributed.addAttributes(
                    [
                        .backgroundColor: accent.withAlphaComponent(
                            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.46 : 0.28
                        ),
                        .foregroundColor: primary,
                        .font: NSFont.systemFont(ofSize: titleFontSize, weight: .bold),
                    ],
                    range: NSRange(location: safeLower, length: safeUpper - safeLower)
                )
            }
            titleLabel.attributedStringValue = attributed
        } else {
            titleLabel.stringValue = node.title
            titleLabel.textColor = titleColor
        }
        subtitleLabel.textColor = secondary
        kindIcon.contentTintColor = accent.withAlphaComponent(node.role == .loadMore ? 1 : 0.78)
        kindIcon.image = NSImage(
            systemSymbolName: symbolName(for: node),
            accessibilityDescription: nil
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12.5, weight: .regular))
        setAccessibilityLabel(
            node.isSearchMatch
                ? "Search match, \(node.title), \(node.subtitle)"
                : "\(node.title), \(node.subtitle)"
        )
    }

    private func symbolName(for node: StructureSidebarNode) -> String {
        if node.role == .loadMore { return "ellipsis.circle" }
        switch node.kind {
        case .object: return "curlybraces"
        case .array: return "list.number"
        case .element: return "chevron.left.forwardslash.chevron.right"
        case .mapping: return "point.3.connected.trianglepath.dotted"
        case .sequence: return "list.bullet.indent"
        case .scalar: return "textformat"
        case .comment: return "text.bubble"
        case nil: return "magnifyingglass"
        }
    }

#if LIGHTXT_STANDALONE_STRUCTURE_QA
    var qaAttributedTitle: NSAttributedString { titleLabel.attributedStringValue }
#endif

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

/// Lightweight layer animation used while a large JSON structure index is
/// streaming. The orbit suggests progressive traversal while the stable brace
/// glyph keeps the state unmistakably JSON-specific.
@MainActor
final class JSONLoadingIndicatorView: NSView {
    var progress: Double? {
        didSet {
            progressRing.strokeEnd = CGFloat(progress.map { min(1, max(0, $0)) } ?? 0.72)
            progressRing.lineDashPattern = progress == nil ? [4, 7] : nil
        }
    }

    private let orbitContainer = CALayer()
    private let orbitRing = CAShapeLayer()
    private let progressRing = CAShapeLayer()
    private let braceLayer = CATextLayer()
    private var nodeLayers: [CALayer] = []
    private var isAnimating = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Mapping JSON structure")

        orbitRing.fillColor = NSColor.clear.cgColor
        orbitRing.lineWidth = 1
        orbitContainer.addSublayer(orbitRing)

        progressRing.fillColor = NSColor.clear.cgColor
        progressRing.lineWidth = 2
        progressRing.lineCap = .round
        orbitContainer.addSublayer(progressRing)

        for _ in 0..<4 {
            let node = CALayer()
            node.cornerRadius = 3
            nodeLayers.append(node)
            orbitContainer.addSublayer(node)
        }
        layer?.addSublayer(orbitContainer)

        braceLayer.alignmentMode = .center
        braceLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(braceLayer)
        progress = nil
        applyResolvedAppearance()
    }

    override func layout() {
        super.layout()
        let square = min(bounds.width, bounds.height)
        let frame = NSRect(
            x: floor((bounds.width - square) / 2),
            y: floor((bounds.height - square) / 2),
            width: square,
            height: square
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        orbitContainer.frame = frame
        orbitContainer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        orbitContainer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let ringRect = CGRect(x: 8, y: 8, width: square - 16, height: square - 16)
        let ringPath = CGPath(ellipseIn: ringRect, transform: nil)
        orbitRing.frame = orbitContainer.bounds
        orbitRing.path = ringPath
        progressRing.frame = orbitContainer.bounds
        progressRing.path = ringPath
        let centers = [
            CGPoint(x: square / 2, y: 8),
            CGPoint(x: square - 8, y: square / 2),
            CGPoint(x: square / 2, y: square - 8),
            CGPoint(x: 8, y: square / 2)
        ]
        for (node, center) in zip(nodeLayers, centers) {
            node.bounds = CGRect(x: 0, y: 0, width: 7, height: 7)
            node.position = center
        }
        braceLayer.frame = CGRect(x: bounds.midX - 26, y: bounds.midY - 16, width: 52, height: 32)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyResolvedAppearance()
    }

    func applyResolvedAppearance() {
        let appearance = effectiveAppearance
        let accent = LighTxtTheme.resolved(LighTxtTheme.accent, for: appearance)
        let secondary = LighTxtTheme.resolved(LighTxtTheme.secondaryText, for: appearance)
        orbitRing.strokeColor = secondary.withAlphaComponent(0.18).cgColor
        progressRing.strokeColor = accent.withAlphaComponent(0.9).cgColor
        nodeLayers.enumerated().forEach { index, node in
            node.backgroundColor = (index.isMultiple(of: 2) ? accent : secondary)
                .withAlphaComponent(index.isMultiple(of: 2) ? 0.95 : 0.55)
                .cgColor
        }
        let font = NSFont.monospacedSystemFont(ofSize: 20, weight: .medium)
        braceLayer.string = NSAttributedString(
            string: "{  }",
            attributes: [.font: font, .foregroundColor: accent]
        )
    }

    func startAnimating() {
        guard !isAnimating else { return }
        isAnimating = true
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

        let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
        rotation.fromValue = 0
        rotation.toValue = CGFloat.pi * 2
        rotation.duration = 3.8
        rotation.repeatCount = .infinity
        rotation.timingFunction = CAMediaTimingFunction(name: .linear)
        orbitContainer.add(rotation, forKey: "json.orbit")

        let pulse = CAKeyframeAnimation(keyPath: "opacity")
        pulse.values = [0.62, 1, 0.62]
        pulse.keyTimes = [0, 0.5, 1]
        pulse.duration = 1.8
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        braceLayer.add(pulse, forKey: "json.bracePulse")

        for (index, node) in nodeLayers.enumerated() {
            let scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [0.72, 1.18, 0.72]
            scale.keyTimes = [0, 0.5, 1]
            scale.duration = 1.55
            scale.beginTime = CACurrentMediaTime() + Double(index) * 0.16
            scale.repeatCount = .infinity
            scale.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            node.add(scale, forKey: "json.nodePulse")
        }
    }

    func stopAnimating() {
        isAnimating = false
        orbitContainer.removeAllAnimations()
        braceLayer.removeAllAnimations()
        nodeLayers.forEach { $0.removeAllAnimations() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
