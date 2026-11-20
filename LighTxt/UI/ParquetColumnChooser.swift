import AppKit

@MainActor
final class ParquetColumnChooser: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let columns: [ParquetColumn]
    private let originalOrder: [Int]
    private let defaultSelection: [Int]
    private var selected: Set<Int>
    private var matches: [ParquetColumn]
    private let applySelection: ([Int]) -> Void
    private let search = NSSearchField()
    private let table = NSTableView()
    private let status = NSTextField(labelWithString: "")
    private lazy var applyButton = NSButton(title: "Apply", target: self, action: #selector(apply))

    init(metadata: ParquetMetadata, visible: [ParquetColumn], apply: @escaping ([Int]) -> Void) {
        columns = metadata.allColumns
        matches = metadata.allColumns
        originalOrder = visible.map(\.index)
        selected = Set(originalOrder)
        defaultSelection = metadata.columns.map(\.index)
        applySelection = apply
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 340))
        preferredContentSize = view.frame.size
        search.placeholderString = "Find columns"
        search.setAccessibilityLabel("Find columns")
        search.delegate = self

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("column")))
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.headerView = nil
        table.rowHeight = 23
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Columns")
        scroll.documentView = table

        let clear = NSButton(title: "Clear", target: self, action: #selector(clearSelection))
        let restore = NSButton(title: "Reset", target: self, action: #selector(restoreDefaults))
        restore.toolTip = "Select the original columns"
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let buttons = NSStackView(views: [clear, restore, NSView(), applyButton])
        let stack = NSStackView(views: [search, scroll, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -12),
            search.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        refreshSelection()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(search)
    }

    func controlTextDidChange(_ notification: Notification) {
        let needle = search.stringValue
        matches = needle.isEmpty ? columns : columns.filter { $0.name.localizedCaseInsensitiveContains(needle) }
        table.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let column = matches[row]
        let identifier = NSUserInterfaceItemIdentifier("column-choice")
        let button = (table.makeView(withIdentifier: identifier, owner: self) as? NSButton)
            ?? NSButton(checkboxWithTitle: "", target: self, action: #selector(toggle(_:)))
        button.identifier = identifier
        button.tag = column.index
        button.title = column.name
        button.toolTip = "\(column.name) · \(column.typeName)"
        button.state = selected.contains(column.index) ? .on : .off
        return button
    }

    @objc private func toggle(_ button: NSButton) {
        if button.state == .on { selected.insert(button.tag) } else { selected.remove(button.tag) }
        refreshSelection()
    }

    @objc private func clearSelection() {
        selected.removeAll()
        table.reloadData()
        refreshSelection()
    }

    @objc private func restoreDefaults() {
        selected = Set(defaultSelection)
        table.reloadData()
        refreshSelection()
    }

    private func refreshSelection() {
        let maximum = defaultSelection.count
        status.stringValue = "\(selected.count.formatted()) selected · maximum \(maximum.formatted())"
        applyButton.isEnabled = !selected.isEmpty && selected.count <= maximum
    }

#if LIGHTXT_STANDALONE_PARQUET_QA
    func qaSelectMatchingColumns(_ names: [String]) -> Bool {
        view.layoutSubtreeIfNeeded()
        clearSelection()
        for name in names {
            search.stringValue = name
            controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
            guard let row = matches.firstIndex(where: { $0.name == name }) else { return false }
            table.scrollRowToVisible(row)
            guard let toggle = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? NSButton else { return false }
            toggle.performClick(nil)
        }
        guard applyButton.isEnabled else { return false }
        applyButton.performClick(nil)
        return true
    }
#endif

    @objc private func apply() {
        guard applyButton.isEnabled else { return }
        let retained = originalOrder.filter(selected.contains)
        let additions = selected.subtracting(retained).sorted()
        applySelection(retained + additions)
    }
}
