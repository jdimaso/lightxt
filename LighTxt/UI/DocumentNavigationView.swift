import AppKit

/// Separate views retain their own tree expansion, selection and scroll position.
@MainActor
final class DocumentNavigationView: NSView {
    let outline: StructureSidebarView
    let results: StructureSidebarView
    var onSelectResults: ((Bool) -> Void)?
    private let tabs = NSSegmentedControl(labels: ["Outline", "Results"], trackingMode: .selectOne, target: nil, action: nil)

    private var outlineAvailable = true
    private var resultsSelected = false
    var showsResults: Bool {
        get { resultsSelected }
        set {
            resultsSelected = newValue || !outlineAvailable
            tabs.selectedSegment = resultsSelected ? 1 : 0
            outline.isHidden = resultsSelected
            results.isHidden = !resultsSelected
        }
    }

    init(outline: StructureSidebarView, results: StructureSidebarView) {
        self.outline = outline
        self.results = results
        super.init(frame: .zero)
        wantsLayer = true
        applyAppearance()
        tabs.target = self
        tabs.action = #selector(selectTab(_:))
        tabs.selectedSegment = 0
        tabs.segmentStyle = .rounded
        tabs.setAccessibilityLabel("Document navigation")
        tabs.setAccessibilityHelp("Switch between the outline and search results without losing your place.")
        results.isHidden = true
        results.showMessage(title: "Search results", detail: "Use Find to search this document.", scope: "No search yet")
        [tabs, outline, results].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            tabs.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            tabs.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            tabs.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            tabs.heightAnchor.constraint(equalToConstant: 26),
        ])
        for pane in [outline, results] {
            NSLayoutConstraint.activate([
                pane.leadingAnchor.constraint(equalTo: leadingAnchor),
                pane.trailingAnchor.constraint(equalTo: trailingAnchor),
                pane.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 6),
                pane.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func applyAppearance() {
        layer?.backgroundColor = LighTxtTheme.resolved(LighTxtTheme.chromeBackground, for: effectiveAppearance).cgColor
    }

    func setOutlineAvailable(_ available: Bool) {
        outlineAvailable = available
        tabs.setEnabled(available, forSegment: 0)
        if !available { showsResults = true }
    }

    func setResultCount(_ count: Int, exact: Bool) {
        tabs.setLabel("Results (\(count.formatted())\(exact ? "" : "+"))", forSegment: 1)
    }

    func clearResults() {
        tabs.setLabel("Results", forSegment: 1)
        results.showMessage(title: "Search results", detail: "Use Find to search this document.", scope: "No active search")
    }

    @objc private func selectTab(_ sender: NSSegmentedControl) {
        showsResults = sender.selectedSegment == 1
        onSelectResults?(showsResults)
    }

#if LIGHTXT_RUNTIME_QA
    func qaSelectResults(_ selected: Bool) {
        tabs.selectedSegment = selected ? 1 : 0
        selectTab(tabs)
    }
    var qaResultTitle: String { tabs.label(forSegment: 1) ?? "" }
#endif
}
