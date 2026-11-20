import AppKit

@MainActor
private final class CSVRangeHighlight: NSView {
    var outline: NSRect = .zero

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.withAlphaComponent(0.17).setFill()
        bounds.fill()
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: outline.insetBy(dx: 0.75, dy: 0.75))
        border.lineWidth = 1.5
        border.stroke()
    }
}

@MainActor
class CSVRangeTableView: NSTableView {
    struct Cell: Equatable {
        let row: Int
        let column: Int
    }

    private enum Drag {
        case cells
        case rows(anchor: Int, baseline: IndexSet, removing: Bool)
    }

    /// Parquet retains native row interaction. Both CSV presentations use spreadsheet interaction.
    var cellMode = false {
        didSet {
            if cellMode != oldValue { clearCellRange() }
        }
    }
    var isDataColumn: ((Int) -> Bool)?
    var canBeginSelection: (() -> Bool)?
    var activateCell: ((Cell) -> Bool)?
    var rangeChanged: ((IndexSet, [Int]) -> Void)?
    var cellFocusChanged: (() -> Void)?
    private var anchorCell: Cell?
    private(set) var focusCell: Cell?
    private var rowAnchor: Int?
    private var drag: Drag?
    private let highlight = CSVRangeHighlight()
    private weak var observedClip: NSClipView?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observedClip {
            NotificationCenter.default.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedClip)
        }
        observedClip = window == nil ? nil : enclosingScrollView?.contentView
        if let observedClip {
            observedClip.postsBoundsChangedNotifications = true
            NotificationCenter.default.addObserver(self, selector: #selector(updateTint),
                name: NSView.boundsDidChangeNotification, object: observedClip)
        }
    }

    func clearCellRange() {
        anchorCell = nil
        focusCell = nil
        rowAnchor = nil
        drag = nil
        highlight.removeFromSuperview()
        rangeChanged?([], [])
        cellFocusChanged?()
    }

    /// Includes programmatic selection from Go to Row, Find, and accessibility.
    func synchronizeRowSelection() {
        guard cellMode, focusCell == nil || !selectedRowIndexes.isEmpty else { return }
        anchorCell = nil
        focusCell = nil
        if drag == nil { rowAnchor = selectedRow >= 0 ? selectedRow : nil }
        highlight.removeFromSuperview()
        rangeChanged?(selectedRowIndexes, selectedRowIndexes.isEmpty ? [] : dataColumns)
    }

    private var dataColumns: [Int] {
        tableColumns.indices.filter { isDataColumn?($0) == true }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let target = super.hitTest(point) else { return nil }
        guard cellMode else { return target }
        // Once editing starts, TextKit owns selection, insertion, and mouse tracking inside its field.
        if let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor,
           target === editor || target.isDescendant(of: editor) { return target }
        return self
    }

    override func selectAll(_ sender: Any?) {
        guard cellMode, selectedRowIndexes.isEmpty else { super.selectAll(sender); return }
        let columns = dataColumns
        guard let first = columns.first, let last = columns.last, numberOfRows > 0 else { return }
        anchorCell = Cell(row: 0, column: first)
        focusCell = nil
        selectCell(Cell(row: numberOfRows - 1, column: last), extending: true)
    }

    override func mouseDown(with event: NSEvent) {
        guard cellMode else { super.mouseDown(with: event); return }
        guard canBeginSelection?() != false, window?.makeFirstResponder(self) != false else { return }
        let point = convert(event.locationInWindow, from: nil)
        let row = row(at: point), column = column(at: point)
        guard row >= 0, tableColumns.indices.contains(column) else {
            clearCellRange()
            deselectAll(nil)
            return
        }
        if isDataColumn?(column) == true {
            let cell = Cell(row: row, column: column)
            selectCell(cell, extending: event.modifierFlags.contains(.shift))
            drag = .cells
            if event.clickCount == 2 { _ = activateCell?(cell) }
        } else {
            let extending = event.modifierFlags.contains(.shift)
            let toggling = event.modifierFlags.contains(.command)
            let anchor = extending ? (rowAnchor ?? focusCell?.row ?? (selectedRow >= 0 ? selectedRow : row)) : row
            let baseline = toggling ? selectedRowIndexes : IndexSet()
            anchorCell = nil
            focusCell = nil
            highlight.removeFromSuperview()
            rowAnchor = anchor
            drag = .rows(anchor: anchor, baseline: baseline, removing: toggling && !extending && baseline.contains(row))
            selectGutterRows(through: row)
        }
    }

    private func selectGutterRows(through row: Int) {
        guard case let .rows(anchor, baseline, removing) = drag else { return }
        let interval = IndexSet(integersIn: min(anchor, row)...max(anchor, row))
        let next = removing ? baseline.subtracting(interval) : baseline.union(interval)
        if next != selectedRowIndexes {
            selectRowIndexes(next, byExtendingSelection: false)
        } else {
            synchronizeRowSelection()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard cellMode else { super.mouseDragged(with: event); return }
        autoscroll(with: event)
        guard let drag, numberOfRows > 0 else { return }
        var point = convert(event.locationInWindow, from: nil)
        // Keep extending when a pointer passes the last visible cell while autoscrolling.
        point.y = min(max(point.y, rect(ofRow: 0).minY), rect(ofRow: numberOfRows - 1).maxY - 0.5)
        let row = row(at: point)
        guard row >= 0 else { return }
        switch drag {
        case .rows: selectGutterRows(through: row)
        case .cells:
            guard let first = dataColumns.first, let last = dataColumns.last else { return }
            point.x = min(max(point.x, rect(ofColumn: first).minX + 0.5), rect(ofColumn: last).maxX - 0.5)
            let column = column(at: point)
            if isDataColumn?(column) == true { selectCell(Cell(row: row, column: column), extending: true) }
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard cellMode else { super.mouseUp(with: event); return }
        drag = nil
    }

    override func keyDown(with event: NSEvent) {
        guard cellMode, selectedRowIndexes.isEmpty else { super.keyDown(with: event); return }
        if event.keyCode == 53 { clearCellRange(); return }
        if let focusCell, [36, 76].contains(event.keyCode), activateCell?(focusCell) == true { return }
        guard [123, 124, 125, 126].contains(event.keyCode), let first = dataColumns.first,
              numberOfRows > 0 else { super.keyDown(with: event); return }
        let current = focusCell ?? Cell(row: 0, column: first)
        var row = current.row, column = current.column
        switch event.keyCode {
        case 123, 124:
            let step = event.keyCode == 123 ? -1 : 1
            repeat { column += step } while tableColumns.indices.contains(column) && isDataColumn?(column) != true
            guard tableColumns.indices.contains(column) else { return }
        case 125: row = min(numberOfRows - 1, row + 1)
        default: row = max(0, row - 1)
        }
        scrollRowToVisible(row)
        scrollColumnToVisible(column)
        selectCell(Cell(row: row, column: column), extending: event.modifierFlags.contains(.shift))
    }

    func includesCell(_ cell: Cell) -> Bool {
        guard let a = anchorCell, let b = focusCell else { return false }
        return (min(a.row, b.row)...max(a.row, b.row)).contains(cell.row)
            && (min(a.column, b.column)...max(a.column, b.column)).contains(cell.column)
    }

    func selectCell(_ cell: Cell, extending: Bool) {
        guard tableColumns.indices.contains(cell.column), isDataColumn?(cell.column) == true,
              (0..<numberOfRows).contains(cell.row) else { return }
        if !extending || anchorCell == nil { anchorCell = cell }
        guard let anchorCell else { return }
        if extending && cell == focusCell { return }
        focusCell = cell
        rowAnchor = nil
        if !selectedRowIndexes.isEmpty { deselectAll(nil) }
        let rows = IndexSet(integersIn: min(anchorCell.row, cell.row)...max(anchorCell.row, cell.row))
        let columns = (min(anchorCell.column, cell.column)...max(anchorCell.column, cell.column))
            .filter { isDataColumn?($0) == true }
        updateTint()
        rangeChanged?(rows, columns)
        cellFocusChanged?()
    }

    override func layout() { super.layout(); updateTint() }

    @objc private func updateTint() {
        guard let a = anchorCell, let b = focusCell,
              tableColumns.indices.contains(a.column), tableColumns.indices.contains(b.column),
              a.row < numberOfRows, b.row < numberOfRows else { highlight.removeFromSuperview(); return }
        let rect = frameOfCell(atColumn: a.column, row: a.row)
            .union(frameOfCell(atColumn: b.column, row: b.row))
        let visible = rect.intersection(visibleRect)
        guard !visible.isEmpty else { highlight.removeFromSuperview(); return }
        if highlight.superview == nil {
            highlight.wantsLayer = true
            highlight.layer?.zPosition = 20
            addSubview(highlight, positioned: .above, relativeTo: nil)
        }
        highlight.frame = visible
        // Convert using AppKit's flipped table coordinates. Keep the overlay and
        // stroke near the screen even when the range covers millions of rows.
        highlight.outline = highlight.convert(rect.intersection(visible.insetBy(dx: -3, dy: -3)), from: self)
        highlight.needsDisplay = true
    }
}

@MainActor
final class CSVAnalysisBar: NSView {
    struct Source {
        let title: String
        let fields: [CSVAnalysisField]
        let rowCount: Int64
        let scan: CSVAnalysisScan
    }
    var source: ((_ forPivot: Bool) throws -> Source)?
    var physicalColumn: ((Int) -> Int?)?
    private weak var table: CSVRangeTableView?
    private let pivot = NSButton(title: "PivotViz…", target: nil, action: nil)
    private let status = NSTextField(labelWithString: "")
    private var task: Task<Void, Never>?
    private var revision: UInt64 = 0

    init() {
        super.init(frame: .zero)
        pivot.target = self
        pivot.action = #selector(openPivot)
        pivot.toolTip = "Analyze the filtered CSV in a separate window"
        status.lineBreakMode = .byTruncatingTail
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [pivot, status])
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityLabel("CSV analysis")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { task?.cancel() }

    func connect(_ table: CSVRangeTableView) {
        self.table = table
        table.isDataColumn = { [weak self] in self?.physicalColumn?($0) != nil }
        table.rangeChanged = { [weak self] in self?.update(rows: $0, columns: $1) }
        NotificationCenter.default.addObserver(self, selector: #selector(columnsMoved),
            name: NSTableView.columnDidMoveNotification, object: table)
    }

    @objc private func columnsMoved() {
        if table?.focusCell != nil { reset() }
    }
    func reset() { table?.clearCellRange() }
    @objc func openPivot() {
        do {
            guard let source = try source?(true) else { return }
            CSVPivotWindow.open(beside: window, title: source.title, fields: source.fields, rowCount: source.rowCount, scan: source.scan)
            message("")
        } catch { message(error.localizedDescription) }
    }

    private func message(_ text: String) {
        status.stringValue = text
        status.toolTip = text
        status.setAccessibilityValue(text)
    }

    private func update(rows: IndexSet, columns: [Int]) {
        task?.cancel()
        revision &+= 1
        guard !rows.isEmpty, !columns.isEmpty else {
            message("")
            return
        }
        let physical = columns.compactMap { physicalColumn?($0) }
        let version = revision
        do {
            guard let source = try source?(false) else { return }
            message("Calculating…")
            task = Task { [weak self] in
                do {
                    // A drag can cross many rows within a single frame.
                    try await Task.sleep(for: .milliseconds(90))
                    let result = try await CSVCellStatistics.calculate(columns: physical, rows: rows, scan: source.scan)
                    guard !Task.isCancelled, self?.revision == version else { return }
                    var parts = ["Cells \(result.cells.formatted())", "Filled \(result.filled.formatted())",
                                 "Numeric \(result.numeric.formatted())"]
                    for (label, value) in [("Sum", result.sum), ("Avg", result.average), ("Median", result.median),
                                           ("Min", result.minimum), ("Max", result.maximum)] {
                        if let value { parts.append("\(label) \(value.formatted(.number.precision(.significantDigits(1...10))))") }
                    }
                    self?.message(parts.joined(separator: "   ·   "))
                } catch {
                    if !Task.isCancelled, self?.revision == version { self?.message(error.localizedDescription) }
                }
            }
        } catch { message(error.localizedDescription) }
    }
}
