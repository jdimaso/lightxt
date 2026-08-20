#if LIGHTXT_STANDALONE_CSV_QA
import AppKit
import Foundation

enum SyntaxFileType { case csv }
struct EditorLineLocation: Sendable {
    let lineNumber: Int64
    let lineStartByteOffset: Int64
}
struct SyntaxFoldRange: Sendable {}

@MainActor
protocol VirtualTextEditorDelegate: AnyObject {
    var editorDocumentByteCount: Int64 { get }
    var editorSyntaxFileType: SyntaxFileType { get }
    func editorSnapshot() throws -> DocumentSnapshot
    func editorReadBytes(in range: Range<Int64>) throws -> Data
    func editorReplaceBytes(in range: Range<Int64>, with bytes: Data) throws
    func editorLineLocation(at byteOffset: Int64) -> EditorLineLocation
    func editorDidCommitEdit(replaced range: Range<Int64>, insertedByteCount: Int64)
    func editorSelectionDidChange(byteRange: Range<Int64>, line: Int64, column: Int)
    func editorDidLoadViewport(byteRange: Range<Int64>)
    func editorDidExpose(byteRange: Range<Int64>)
    func editorDidDiscoverStructure(
        folds: [SyntaxFoldRange],
        viewportData: Data,
        viewportBaseOffset: Int64
    )
    func editorDidFail(_ error: Error)
}

@MainActor
protocol CSVMutationEditorDelegate: VirtualTextEditorDelegate {
    func editorApplyCSVRowEdits(
        _ edits: [ByteEdit],
        replacing snapshot: DocumentSnapshot,
        completion: @escaping (Result<Void, Error>) -> Void
    )
    func editorApplyCSVColumnMutation(
        _ mutation: CSVColumnMutation,
        snapshot: DocumentSnapshot,
        index: CSVRowIndex,
        progress: @escaping (CSVColumnRewriteProgress) -> Void,
        completion: @escaping (Result<CSVColumnRewriteResult, Error>) -> Void
    )
    func editorCancelCSVMutation()
}

@main
@MainActor
struct CSVTableRuntimeQA {
    static func main() throws {
        guard CommandLine.arguments.count >= 3 else { throw QAError.usage }
        _ = NSApplication.shared
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let fixtureDelegate = try QACSVDelegate(url: fixtureURL)
        let fixtureView = CSVTableView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 720))
        let fixtureWindow = makeWindow(containing: fixtureView, appearance: .aqua)
        fixtureWindow.makeKeyAndOrderFront(nil)
        var fixtureComplete = false
        fixtureView.onStatusChange = { _, busy in fixtureComplete = !busy }
        fixtureView.editorDelegate = fixtureDelegate
        try wait(until: { fixtureComplete }, timeout: 5, failure: "Small CSV fixture did not finish indexing")
        guard let fixtureTable = descendant(of: fixtureView, as: NSTableView.self),
              fixtureTable.numberOfRows == 4,
              fixtureTable.numberOfColumns == 5 else {
            throw QAError.failed("CSV table did not detect a four-row/four-column fixture with fixed header")
        }
        fixtureView.layoutSubtreeIfNeeded()
        fixtureTable.headerView?.layoutSubtreeIfNeeded()

        try assertHeaderLayout(fixtureView, column: 0, label: "initial 1000pt fixture")

        // Exercise the exact production hosting path which regressed: a real
        // titled/resizable window lets NSScrollView take ownership of the
        // table header, tile it, and tile it again during resize. Verify the
        // rendered title glyph and the native Contains label—not merely the
        // ideal cell rectangles—occupy separate, fully visible rows.
        let headerDelegate = try QACSVDelegate(url: fixtureURL)
        let headerView = CSVTableView(frame: NSRect(x: 0, y: 0, width: 1_400, height: 900))
        let headerWindow = makeWindow(
            containing: headerView,
            appearance: .aqua,
            styleMask: [.titled, .closable, .resizable]
        )
        var headerReady = false
        headerView.onStatusChange = { _, busy in headerReady = !busy }
        headerView.editorDelegate = headerDelegate
        try wait(until: { headerReady }, timeout: 5, failure: "Header-layout fixture did not index")
        try settleLayout(window: headerWindow, view: headerView)
        for column in 0..<4 {
            try assertHeaderLayout(headerView, column: column, label: "1400pt light column \(column)")
        }
        try render(
            headerView,
            to: outputDirectory.appendingPathComponent("csv-header-1400-light.png")
        )

        headerWindow.appearance = NSAppearance(named: .darkAqua)
        try settleLayout(window: headerWindow, view: headerView)
        for column in 0..<4 {
            try assertHeaderLayout(headerView, column: column, label: "1400pt dark column \(column)")
        }
        try render(
            headerView,
            to: outputDirectory.appendingPathComponent("csv-header-1400-dark.png")
        )

        // Make the source columns wider than the narrow viewport, resize and
        // reorder them, then use an actual horizontal scroll. Geometry must
        // continue to be resolved by stable source-column identifiers.
        for (column, width) in [CGFloat(300), 360, 320, 340].enumerated() {
            headerView.qaResizeDataColumn(column, width: width)
        }
        headerView.qaMoveDataColumn(3, toVisualIndex: 1)
        headerWindow.setContentSize(NSSize(width: 1_000, height: 720))
        headerView.frame = NSRect(x: 0, y: 0, width: 1_000, height: 720)
        try settleLayout(window: headerWindow, view: headerView)
        headerView.qaScrollDataColumnToVisible(2)
        try settleLayout(window: headerWindow, view: headerView)
        try wait(
            until: { headerView.qaAccessibleFilterButtonColumns.contains(2) },
            timeout: 2,
            failure: "Scrolled dark header column did not materialize its filter controls; "
                + "offset=\(headerView.qaHorizontalOffset), "
                + "controls=\(headerView.qaAccessibleFilterButtonColumns.sorted())"
        )
        try assertHeaderLayout(headerView, column: 2, label: "1000pt reordered/scrolled dark")
        try render(
            headerView,
            to: outputDirectory.appendingPathComponent("csv-header-1000-dark.png")
        )

        headerWindow.appearance = NSAppearance(named: .aqua)
        headerView.qaScrollDataColumnToVisible(3)
        try settleLayout(window: headerWindow, view: headerView)
        try wait(
            until: { headerView.qaAccessibleFilterButtonColumns.contains(3) },
            timeout: 2,
            failure: "Scrolled light header column did not materialize its filter controls"
        )
        try assertHeaderLayout(headerView, column: 3, label: "1000pt reordered/scrolled light")
        try render(
            headerView,
            to: outputDirectory.appendingPathComponent("csv-header-1000-light.png")
        )

        let retileCountAfterResize = headerView.qaHeaderRetileCount
        try settleLayout(window: headerWindow, view: headerView)
        guard headerView.qaHeaderRetileCount == retileCountAfterResize else {
            throw QAError.failed("CSV header-height enforcement did not settle after window retile")
        }
        headerWindow.orderOut(nil)

        let accessibilityLabels = descendants(of: fixtureView, as: NSButton.self)
            .compactMap { $0.accessibilityLabel() }
        guard !accessibilityLabels.contains("Add CSV row or column"),
              !accessibilityLabels.contains("Delete CSV row or column"),
              fixtureView.qaAccessibleFilterButtonColumns.count >= 4 else {
            throw QAError.failed("CSV filter buttons are not accessible, or removed global Add/Delete controls remain")
        }
        guard fixtureView.qaRowContextMenuTitles(row: 0) == [
            "Add Row Above", "Add Row Below", "Delete Row",
        ] else {
            throw QAError.failed("Row mutations did not move to the table body context menu")
        }

        let pristineFixture = try documentString(fixtureDelegate.engine)

        // The header's contains editor owns a draft. Human-paced typing must
        // neither install a filter nor surrender focus; Escape restores the
        // committed value without touching the document or row projection.
        fixtureView.qaBeginInlineContainsFilter(column: 1)
        fixtureView.qaTypeInlineContainsFilter("G")
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.22))
        fixtureView.qaTypeInlineContainsFilter("Grace")
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.35))
        guard fixtureView.qaCommittedFilter(column: 1) == nil,
              fixtureTable.numberOfRows == 4,
              fixtureView.qaInlineFilterHasFocus else {
            throw QAError.failed("Inline contains typing applied early or lost focus")
        }
        fixtureView.qaCancelInlineContainsFilter()
        guard fixtureView.qaCommittedFilter(column: 1) == nil,
              fixtureTable.numberOfRows == 4 else {
            throw QAError.failed("Escape committed an inline contains draft")
        }

        // The unique-values picker keeps its search field alive while typing.
        // It commits text only on Return/focus loss and exact checkboxes as OR.
        fixtureView.qaShowFilterPopover(column: 1)
        try wait(
            until: { fixtureView.qaPopoverUniqueValues.count == 4 },
            timeout: 5,
            failure: "Unique-value picker did not discover the complete name column"
        )
        fixtureView.qaTypePopoverContains("A")
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.22))
        fixtureView.qaTypePopoverContains("Ad")
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.35))
        guard fixtureView.qaCommittedFilter(column: 1) == nil,
              fixtureTable.numberOfRows == 4,
              fixtureView.qaPopoverFilterHasFocus else {
            throw QAError.failed(
                "Popover typing state: committed=\(String(describing: fixtureView.qaCommittedFilter(column: 1))), rows=\(fixtureTable.numberOfRows), focus=\(fixtureView.qaPopoverFilterHasFocus)"
            )
        }
        fixtureComplete = false
        fixtureView.qaCommitPopoverContains()
        try wait(
            until: { fixtureComplete && fixtureTable.numberOfRows == 1 },
            timeout: 5,
            failure: "Committed full contains query did not finish"
        )
        guard fixtureView.qaCommittedFilter(column: 1)?.contains == "Ad",
              fixtureView.qaPopoverFilterHasFocus,
              fixtureView.qaFilterChipCount == 1 else {
            throw QAError.failed("Query launch stole filter focus or active chip did not reflect the full query")
        }
        fixtureComplete = false
        fixtureView.qaClearFilterChip(column: 1)
        try wait(
            until: { fixtureComplete && fixtureTable.numberOfRows == 4 },
            timeout: 5,
            failure: "Clearing the typed filter chip did not restore rows"
        )

        // Clicking to another control follows AppKit's end-editing delegate
        // path. The complete draft must commit once—not once per keystroke and
        // not again when the field editor resigns.
        fixtureView.qaShowFilterPopover(column: 1)
        try wait(
            until: { fixtureView.qaPopoverUniqueValues.count == 4 },
            timeout: 5,
            failure: "Focus-loss picker did not load unique values"
        )
        fixtureView.qaTypePopoverContains("Grace")
        let queriesBeforeFocusLoss = fixtureView.qaQueryLaunchCount
        fixtureComplete = false
        fixtureView.qaEndPopoverContainsEditingByFocusLoss()
        try wait(
            until: { fixtureComplete && fixtureTable.numberOfRows == 1 },
            timeout: 5,
            failure: "Focus loss did not commit the full contains query"
        )
        guard fixtureView.qaCommittedFilter(column: 1)?.contains == "Grace",
              fixtureView.qaQueryLaunchCount == queriesBeforeFocusLoss + 1 else {
            throw QAError.failed("Focus loss committed more than one filter query")
        }
        fixtureComplete = false
        fixtureView.qaClearFilterChip(column: 1)
        try wait(
            until: { fixtureComplete && fixtureTable.numberOfRows == 4 },
            timeout: 5,
            failure: "Clearing the focus-loss filter did not restore rows"
        )

        fixtureView.qaShowFilterPopover(column: 3)
        try wait(
            until: { Set(fixtureView.qaPopoverUniqueValues) == ["false", "true"] },
            timeout: 5,
            failure: "Boolean unique values were not shown"
        )
        fixtureComplete = false
        fixtureView.qaTogglePopoverValue("true")
        try wait(
            until: { fixtureComplete && fixtureTable.numberOfRows == 3 },
            timeout: 5,
            failure: "Exact checkbox selection did not filter rows"
        )
        guard fixtureView.qaPopoverFilterHasFocus,
              fixtureView.qaCommittedFilter(column: 3)?.selected == ["true"] else {
            throw QAError.failed("Checkbox query closed the picker, stole focus, or lost its exact value")
        }
        fixtureComplete = false
        fixtureView.qaTogglePopoverValue("false")
        try wait(
            until: { fixtureComplete && fixtureTable.numberOfRows == 4 },
            timeout: 5,
            failure: "Multi-select values were not ORed within one column"
        )
        guard fixtureView.qaCommittedFilter(column: 3)?.selected == ["false", "true"],
              fixtureView.qaFilterChipCount == 1 else {
            throw QAError.failed("Filter chip lost the multi-select state")
        }

        // Replacing a filter popover with Summary must cancel discovery; the
        // chip then reopens the same logical source column. Reorder first to
        // prove visual position never changes its target.
        fixtureView.qaShowColumnSummary(column: 3)
        fixtureView.qaMoveDataColumn(3, toVisualIndex: 1)
        fixtureView.qaOpenFilterChip(column: 3)
        try wait(
            until: { Set(fixtureView.qaPopoverUniqueValues) == ["false", "true"] },
            timeout: 5,
            failure: "Chip did not reopen its source column after reorder"
        )
        fixtureView.qaTypePopoverContains("t")
        fixtureComplete = false
        fixtureView.qaCommitPopoverContains()
        try wait(
            until: { fixtureComplete && fixtureTable.numberOfRows == 3 },
            timeout: 5,
            failure: "Commit from a chip-anchored popover did not finish"
        )
        guard fixtureView.qaHasPresentedPopover,
              fixtureView.qaPopoverAnchoredToFilterChip,
              fixtureView.qaPopoverFilterHasFocus else {
            throw QAError.failed("Chip rebuild detached its open filter popover")
        }
        fixtureComplete = false
        fixtureView.qaTogglePopoverValue("false")
        try wait(
            until: { fixtureComplete && fixtureTable.numberOfRows == 3 },
            timeout: 5,
            failure: "Checkbox commit from the rebuilt chip popover did not finish"
        )
        guard fixtureView.qaHasPresentedPopover,
              fixtureView.qaPopoverAnchoredToFilterChip,
              fixtureView.qaPopoverFilterHasFocus else {
            throw QAError.failed("Checkbox commit detached the chip-anchored popover")
        }
        fixtureComplete = false
        fixtureView.qaClearFilterChip(column: 3)
        try wait(
            until: { fixtureComplete && fixtureTable.numberOfRows == 4 },
            timeout: 5,
            failure: "Clearing reordered-column chip did not restore rows"
        )
        fixtureView.qaMoveDataColumn(3, toVisualIndex: 4)
        guard try documentString(fixtureDelegate.engine) == pristineFixture else {
            throw QAError.failed("Filter UI interactions mutated CSV document bytes")
        }

        // Drive the real header delegate cycle: ascending, descending, then
        // back to source order. The third click is LighTxt's native three-state
        // behavior layered over NSTableView's two-state descriptor toggle.
        fixtureComplete = false
        fixtureView.qaCycleHeaderSort(column: 0)
        try wait(until: { fixtureComplete }, timeout: 5, failure: "Ascending header sort did not finish")
        guard try cellValues(in: fixtureTable, column: 1, rows: 0..<4) == ["1", "2", "3", "4"] else {
            throw QAError.failed("Ascending header sort returned the wrong row order")
        }
        fixtureComplete = false
        fixtureView.qaCycleHeaderSort(column: 0)
        try wait(until: { fixtureComplete }, timeout: 5, failure: "Descending header sort did not finish")
        guard try cellValues(in: fixtureTable, column: 1, rows: 0..<4) == ["4", "3", "2", "1"] else {
            throw QAError.failed("Descending header sort returned the wrong row order")
        }
        fixtureComplete = false
        fixtureView.qaCycleHeaderSort(column: 0)
        try wait(until: { fixtureComplete }, timeout: 5, failure: "Clearing header sort did not finish")
        guard try cellValues(in: fixtureTable, column: 1, rows: 0..<4) == ["1", "2", "3", "4"] else {
            throw QAError.failed("Third header click did not restore source row order")
        }

        fixtureComplete = false
        fixtureView.qaApplyContainsFilter(column: 3, value: "true")
        try wait(until: { fixtureComplete }, timeout: 5, failure: "Column filter did not finish")
        guard fixtureTable.numberOfRows == 3,
              try cellValues(in: fixtureTable, column: 2, rows: 0..<3) == ["Ada", "Grace", "Zoë"] else {
            throw QAError.failed("Column filter did not map displayed rows to matching source records")
        }
        fixtureComplete = false
        fixtureView.qaClearFilters()
        try wait(until: { fixtureComplete }, timeout: 5, failure: "Clearing the column filter did not finish")
        guard fixtureTable.numberOfRows == 4 else {
            throw QAError.failed("Clearing filters did not restore every source row")
        }

        var fixtureSummary: Result<String, Error>?
        fixtureView.qaRequestColumnSummary(column: 3) { fixtureSummary = $0 }
        try wait(until: { fixtureSummary != nil }, timeout: 5, failure: "Column Summary did not finish")
        let summaryText = try fixtureSummary!.get()
        guard summaryText.contains("Complete dataset"),
              summaryText.contains("Rows=4"),
              summaryText.contains("true:3") else {
            throw QAError.failed("Column Summary did not report complete sampling and top values: \(summaryText)")
        }

        // Capture the requested UX in a meaningful state: a contains draft
        // and an exact-value selection are both active, their chip is visible,
        // and the unique-value picker remains open.
        fixtureView.qaShowFilterPopover(column: 1)
        try wait(
            until: { fixtureView.qaPopoverUniqueValues.count == 4 },
            timeout: 5,
            failure: "Capture picker did not load unique values"
        )
        fixtureView.qaTypePopoverContains("a")
        fixtureComplete = false
        fixtureView.qaCommitPopoverContains()
        try wait(
            until: { fixtureComplete && fixtureTable.numberOfRows == 2 },
            timeout: 5,
            failure: "Capture contains filter did not finish"
        )
        fixtureComplete = false
        fixtureView.qaTogglePopoverValue("Ada")
        try wait(
            until: { fixtureComplete && fixtureTable.numberOfRows == 1 },
            timeout: 5,
            failure: "Capture exact-value filter did not finish"
        )
        guard fixtureView.qaFilterChipCount == 1,
              fixtureView.qaHasPresentedPopover,
              let capturePopover = fixtureView.qaPopoverContentView else {
            throw QAError.failed("Active filter capture did not retain its chip and picker")
        }

        fixtureWindow.appearance = NSAppearance(named: .aqua)
        capturePopover.appearance = fixtureWindow.appearance
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        fixtureView.qaPreparePopoverCaptureBackground()
        fixtureView.layoutSubtreeIfNeeded()
        try render(
            fixtureView,
            overlay: capturePopover,
            to: outputDirectory.appendingPathComponent("csv-light.png")
        )
        fixtureWindow.appearance = NSAppearance(named: .darkAqua)
        capturePopover.appearance = fixtureWindow.appearance
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        fixtureView.qaPreparePopoverCaptureBackground()
        fixtureView.layoutSubtreeIfNeeded()
        guard fixtureView.qaFilterAffordanceContrast >= 3 else {
            throw QAError.failed("Dark CSV filter magnifier/funnel contrast fell below 3:1")
        }
        try render(
            fixtureView,
            overlay: capturePopover,
            to: outputDirectory.appendingPathComponent("csv-dark.png")
        )

        // Mutations use a private fixture copy and the same delegate contract
        // as the document session. Every operation must publish one undoable
        // byte result and survive a controller-style CSV reload.
        let mutationURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LighTxt-CSV-mutation-QA-\(UUID().uuidString).csv"
        )
        try FileManager.default.copyItem(at: fixtureURL, to: mutationURL)
        defer { try? FileManager.default.removeItem(at: mutationURL) }
        let mutationDelegate = try QACSVDelegate(url: mutationURL)
        let mutationView = CSVTableView(frame: NSRect(x: 0, y: 0, width: 900, height: 620))
        let mutationWindow = makeWindow(containing: mutationView, appearance: .aqua)
        _ = mutationWindow
        var mutationReady = false
        mutationView.onStatusChange = { _, busy in mutationReady = !busy }
        mutationDelegate.onDocumentChange = { [weak mutationView] in
            mutationView?.reloadDocument()
        }
        mutationView.editorDelegate = mutationDelegate
        try wait(until: { mutationReady }, timeout: 5, failure: "Mutation fixture did not index")
        let baseline = try documentString(mutationDelegate.engine)
        guard let mutationTable = descendant(of: mutationView, as: NSTableView.self) else {
            throw QAError.failed("Mutation fixture table was not available")
        }

        // A structural rewrite owns column coordinates until publication.
        // Filter affordances must reject drafts during that interval, then
        // resume against the freshly indexed schema.
        mutationDelegate.deferColumnMutations = true
        mutationReady = false
        mutationView.qaAddColumn(at: 1, name: "delayed")
        try wait(
            until: { mutationView.qaStructuralMutationInFlight },
            timeout: 2,
            failure: "Delayed column mutation never entered its guarded phase"
        )
        mutationView.qaShowFilterPopover(column: 1)
        mutationView.qaBeginInlineContainsFilter(column: 1)
        guard !mutationView.qaHasPresentedPopover,
              !mutationView.qaInlineFilterHasFocus,
              mutationView.qaCommittedFilter(column: 1) == nil else {
            throw QAError.failed("Filter committed stale coordinates during a structural mutation")
        }
        mutationDelegate.deferColumnMutations = false
        mutationDelegate.completeDeferredColumnMutation()
        try wait(
            until: { mutationReady && mutationView.qaColumnTitles.contains("delayed") },
            timeout: 5,
            failure: "Delayed column mutation did not publish and reindex"
        )
        guard mutationDelegate.engine.undo(), try documentString(mutationDelegate.engine) == baseline else {
            throw QAError.failed("Could not restore baseline after delayed-mutation filter guard")
        }
        mutationReady = false
        mutationView.reloadDocument()
        try wait(until: { mutationReady }, timeout: 5, failure: "Delayed mutation undo did not reindex")

        // Editing a projected key must discard the pre-edit row map and run a
        // generation-safe replacement query. Membership and order both need
        // to reflect the durable cell value, without switching to text mode.
        mutationReady = false
        mutationView.qaApplyContainsFilter(column: 3, value: "true")
        try wait(until: { mutationReady }, timeout: 5, failure: "Edit regression filter did not finish")
        guard let filteredKeyCell = mutationTable.view(
            atColumn: 4,
            row: 0,
            makeIfNecessary: true
        ) as? NSTextField else {
            throw QAError.failed("Filtered key cell was unavailable")
        }
        mutationView.controlTextDidBeginEditing(Notification(
            name: NSControl.textDidBeginEditingNotification,
            object: filteredKeyCell
        ))
        filteredKeyCell.stringValue = "false"
        mutationView.controlTextDidEndEditing(Notification(
            name: NSControl.textDidEndEditingNotification,
            object: filteredKeyCell
        ))
        try wait(
            until: { mutationReady && mutationTable.numberOfRows == 2 },
            timeout: 5,
            failure: "Editing a filtered key did not update row membership"
        )
        guard try cellValues(in: mutationTable, column: 2, rows: 0..<2) == ["Grace", "Zoë"] else {
            throw QAError.failed("Filtered edit installed a stale display-to-source map")
        }
        mutationReady = false
        mutationView.qaClearFilters()
        try wait(until: { mutationReady }, timeout: 5, failure: "Edit regression filter clear did not finish")
        guard mutationDelegate.engine.undo(), try documentString(mutationDelegate.engine) == baseline else {
            throw QAError.failed("Could not undo filtered-key cell edit")
        }
        mutationReady = false
        mutationView.reloadDocument()
        try wait(until: { mutationReady }, timeout: 5, failure: "Filtered-key undo reload did not finish")

        mutationReady = false
        mutationView.qaCycleHeaderSort(column: 0)
        try wait(until: { mutationReady }, timeout: 5, failure: "Edit regression sort did not finish")
        guard let sortedKeyCell = mutationTable.view(
            atColumn: 1,
            row: 0,
            makeIfNecessary: true
        ) as? NSTextField else {
            throw QAError.failed("Sorted key cell was unavailable")
        }
        mutationView.controlTextDidBeginEditing(Notification(
            name: NSControl.textDidBeginEditingNotification,
            object: sortedKeyCell
        ))
        sortedKeyCell.stringValue = "9"
        mutationView.controlTextDidEndEditing(Notification(
            name: NSControl.textDidEndEditingNotification,
            object: sortedKeyCell
        ))
        try wait(
            until: {
                mutationReady
                    && (try? cellValues(in: mutationTable, column: 1, rows: 0..<4))
                        == ["2", "3", "4", "9"]
            },
            timeout: 5,
            failure: "Editing a sorted key did not update row order"
        )
        mutationReady = false
        mutationView.qaClearSort()
        try wait(until: { mutationReady }, timeout: 5, failure: "Edit regression sort clear did not finish")
        guard mutationDelegate.engine.undo(), try documentString(mutationDelegate.engine) == baseline else {
            throw QAError.failed("Could not undo sorted-key cell edit")
        }
        mutationReady = false
        mutationView.reloadDocument()
        try wait(until: { mutationReady }, timeout: 5, failure: "Sorted-key undo reload did not finish")

        mutationReady = false
        mutationView.qaAddRow(beforeSourceRecord: 2)
        try wait(until: { mutationReady }, timeout: 5, failure: "Adding a CSV row did not finish")
        let rowInserted = try documentString(mutationDelegate.engine)
        guard rowInserted != baseline,
              rowInserted.contains("comma, preserved\",true\n,,,\n2,Grace") else {
            throw QAError.failed("Add Row did not insert a complete empty record at the source location")
        }
        try assertUndoRedo(
            engine: mutationDelegate.engine,
            before: baseline,
            after: rowInserted,
            label: "Add Row"
        )
        guard mutationDelegate.engine.undo() else { throw QAError.failed("Could not restore Add Row baseline") }
        mutationReady = false
        mutationView.reloadDocument()
        try wait(until: { mutationReady }, timeout: 5, failure: "Row undo reload did not finish")

        mutationReady = false
        mutationView.qaDeleteRows(sourceRecords: [2])
        try wait(until: { mutationReady }, timeout: 5, failure: "Deleting a CSV row did not finish")
        let rowDeleted = try documentString(mutationDelegate.engine)
        guard !rowDeleted.contains("2,Grace") else {
            throw QAError.failed("Delete Row retained the selected source record")
        }
        try assertUndoRedo(
            engine: mutationDelegate.engine,
            before: baseline,
            after: rowDeleted,
            label: "Delete Row"
        )
        guard mutationDelegate.engine.undo() else { throw QAError.failed("Could not restore Delete Row baseline") }
        mutationReady = false
        mutationView.reloadDocument()
        try wait(until: { mutationReady }, timeout: 5, failure: "Row deletion undo reload did not finish")

        mutationReady = false
        mutationView.qaAddColumn(at: 2, name: "score")
        try wait(until: { mutationReady }, timeout: 5, failure: "Adding a CSV column did not finish")
        let columnInserted = try documentString(mutationDelegate.engine)
        guard columnInserted.hasPrefix("id,name,score,notes,active\n") else {
            throw QAError.failed("Add Column did not write the prompted header in the requested position")
        }
        try assertUndoRedo(
            engine: mutationDelegate.engine,
            before: baseline,
            after: columnInserted,
            label: "Add Column"
        )
        guard mutationDelegate.engine.undo() else { throw QAError.failed("Could not restore Add Column baseline") }
        mutationReady = false
        mutationView.reloadDocument()
        try wait(until: { mutationReady }, timeout: 5, failure: "Column insertion undo reload did not finish")

        mutationReady = false
        mutationView.qaDeleteColumn(2)
        try wait(until: { mutationReady }, timeout: 5, failure: "Deleting a CSV column did not finish")
        let columnDeleted = try documentString(mutationDelegate.engine)
        guard columnDeleted.hasPrefix("id,name,active\n"),
              !columnDeleted.contains("comma, preserved") else {
            throw QAError.failed("Delete Column did not remove the requested field from every record")
        }
        try assertUndoRedo(
            engine: mutationDelegate.engine,
            before: baseline,
            after: columnDeleted,
            label: "Delete Column"
        )

        let summaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LighTxt-CSV-summary-QA-\(UUID().uuidString).csv"
        )
        defer { try? FileManager.default.removeItem(at: summaryURL) }
        try writeSummaryCSV(to: summaryURL)
        let sampledDelegate = try QACSVDelegate(url: summaryURL)
        let sampledView = CSVTableView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let sampledWindow = makeWindow(containing: sampledView, appearance: .aqua)
        _ = sampledWindow
        var sampledReady = false
        sampledView.onStatusChange = { _, busy in sampledReady = !busy }
        sampledView.editorDelegate = sampledDelegate
        try wait(until: { sampledReady }, timeout: 10, failure: "Summary sample fixture did not index")
        var sampledSummary: Result<String, Error>?
        sampledView.qaRequestColumnSummary(column: 1) { sampledSummary = $0 }
        try wait(until: { sampledSummary != nil }, timeout: 10, failure: "Sampled Column Summary did not finish")
        let sampledText = try sampledSummary!.get()
        guard sampledText.contains("Stratified sample across file"),
              sampledText.contains("Rows sampled=50000") else {
            throw QAError.failed("Sampled summary did not disclose its strategy and row count: \(sampledText)")
        }

        // A header-only file has no body row to right-click. Empty table
        // space must still expose and execute the first Add Row action.
        let headerOnlyURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LighTxt-CSV-header-only-QA-\(UUID().uuidString).csv"
        )
        try Data("id,name\n".utf8).write(to: headerOnlyURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: headerOnlyURL) }
        let headerOnlyDelegate = try QACSVDelegate(url: headerOnlyURL)
        let headerOnlyView = CSVTableView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let headerOnlyWindow = makeWindow(containing: headerOnlyView, appearance: .aqua)
        _ = headerOnlyWindow
        var headerOnlyReady = false
        headerOnlyView.onStatusChange = { _, busy in headerOnlyReady = !busy }
        headerOnlyDelegate.onDocumentChange = { [weak headerOnlyView] in
            headerOnlyView?.reloadDocument()
        }
        headerOnlyView.editorDelegate = headerOnlyDelegate
        try wait(until: { headerOnlyReady }, timeout: 5, failure: "Header-only CSV did not index")
        guard let headerOnlyTable = descendant(of: headerOnlyView, as: NSTableView.self),
              headerOnlyTable.numberOfRows == 0,
              headerOnlyView.qaEmptySpaceContextMenuTitles == ["Add Row"] else {
            throw QAError.failed("Header-only CSV did not expose Add Row from empty table space")
        }
        headerOnlyReady = false
        guard headerOnlyView.qaPerformEmptySpaceContextMenuItem(named: "Add Row") else {
            throw QAError.failed("Header-only Add Row context-menu action was disabled")
        }
        try wait(
            until: { headerOnlyReady && headerOnlyTable.numberOfRows == 1 },
            timeout: 5,
            failure: "Header-only context-menu Add Row did not finish"
        )
        guard try documentString(headerOnlyDelegate.engine) == "id,name\n,\n" else {
            throw QAError.failed("Header-only context-menu Add Row wrote the wrong record")
        }

        let emptyURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LighTxt-CSV-empty-QA-\(UUID().uuidString).csv"
        )
        FileManager.default.createFile(atPath: emptyURL.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: emptyURL) }
        let emptyDelegate = try QACSVDelegate(url: emptyURL)
        let emptyView = CSVTableView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let emptyWindow = makeWindow(containing: emptyView, appearance: .aqua)
        emptyWindow.makeKeyAndOrderFront(nil)
        var emptyReady = false
        emptyView.onStatusChange = { _, busy in emptyReady = !busy }
        emptyDelegate.onDocumentChange = { [weak emptyView] in emptyView?.reloadDocument() }
        emptyView.editorDelegate = emptyDelegate
        try wait(until: { emptyReady }, timeout: 5, failure: "Empty CSV did not initialize")
        guard let emptyTable = descendant(of: emptyView, as: NSTableView.self),
              emptyTable.numberOfRows == 0,
              emptyTable.numberOfColumns == 1,
              emptyView.qaEmptySpaceContextMenuTitles == ["Add Row", "Add Column…"] else {
            throw QAError.failed("Zero-byte CSV did not begin with an empty table")
        }
        emptyReady = false
        guard emptyView.qaPerformEmptySpaceContextMenuItem(named: "Add Row") else {
            throw QAError.failed("Zero-byte Add Row context-menu action was disabled")
        }
        try wait(until: { emptyReady }, timeout: 5, failure: "Empty CSV Add Row did not finish")
        guard try documentString(emptyDelegate.engine) == "\n",
              emptyTable.numberOfRows == 1,
              emptyTable.numberOfColumns == 2 else {
            throw QAError.failed("Empty CSV Add Row did not bootstrap one editable field")
        }
        guard emptyDelegate.engine.undo(), try documentString(emptyDelegate.engine).isEmpty else {
            throw QAError.failed("Empty CSV Add Row was not undoable")
        }
        emptyReady = false
        emptyView.reloadDocument()
        try wait(until: { emptyReady }, timeout: 5, failure: "Empty row undo reload did not finish")

        emptyReady = false
        guard emptyView.qaPerformEmptySpaceContextMenuItem(
            named: "Add Column…",
            columnName: "title"
        ) else {
            throw QAError.failed("Zero-byte Add Column context-menu action was disabled")
        }
        try wait(until: { emptyReady }, timeout: 5, failure: "Empty CSV Add Column did not finish")
        let bootstrappedColumn = try documentString(emptyDelegate.engine)
        guard bootstrappedColumn == "title\n",
              emptyTable.numberOfRows == 0,
              emptyTable.numberOfColumns == 2,
              emptyView.qaColumnTitles == ["title"] else {
            throw QAError.failed("Empty CSV Add Column did not bootstrap a named header")
        }
        try assertUndoRedo(
            engine: emptyDelegate.engine,
            before: "",
            after: bootstrappedColumn,
            label: "Empty CSV Add Column"
        )

        let wideURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LighTxt-CSV-wide-QA-\(UUID().uuidString).csv"
        )
        defer { try? FileManager.default.removeItem(at: wideURL) }
        try writeWideCSV(to: wideURL)
        let wideDelegate = try QACSVDelegate(url: wideURL)
        let wideView = CSVTableView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        let wideWindow = makeWindow(containing: wideView, appearance: .aqua)
        _ = wideWindow
        var wideReady = false
        wideView.onStatusChange = { _, busy in wideReady = !busy }
        wideView.editorDelegate = wideDelegate
        try wait(until: { wideReady }, timeout: 5, failure: "512-column CSV did not initialize")
        let wideBefore = try documentString(wideDelegate.engine)
        wideView.qaAddColumn(at: 512, name: "must-not-be-hidden")
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        guard try documentString(wideDelegate.engine) == wideBefore,
              wideView.qaColumnTitles.count == 512 else {
            throw QAError.failed("Add Column After rewrote a hidden 513th View column")
        }
        wideView.qaScrollDataColumnToVisible(511)
        try wait(
            until: { wideView.qaAccessibleFilterButtonColumns.contains(511) },
            timeout: 2,
            failure: "Horizontal scrolling did not materialize the far-column filter button"
        )
        wideReady = false
        wideView.qaApplyContainsFilter(column: 511, value: "511")
        try wait(until: { wideReady }, timeout: 5, failure: "Far-column filter did not finish")
        wideView.qaScrollDataColumnToVisible(0)
        let offsetBeforeChip = wideView.qaHorizontalOffset
        wideView.qaOpenFilterChip(column: 511)
        guard wideView.qaPopoverAnchoredToFilterChip,
              wideView.qaHorizontalOffset == offsetBeforeChip else {
            throw QAError.failed("Off-screen filter chip navigated back to its column instead of anchoring locally")
        }
        wideReady = false
        wideView.qaClearFilterChip(column: 511)
        try wait(until: { wideReady }, timeout: 5, failure: "Far-column chip did not clear")

        let stressURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LighTxt-CSV-page-QA-\(UUID().uuidString).csv"
        )
        defer { try? FileManager.default.removeItem(at: stressURL) }
        try writeStressCSV(to: stressURL)
        let stressDelegate = try QACSVDelegate(url: stressURL)
        let stressView = CSVTableView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 720))
        let stressWindow = makeWindow(containing: stressView, appearance: .aqua)
        _ = stressWindow
        var stressComplete = false
        var observeEdit = false
        var editRestartedIndexing = false
        var registrationStates: [Bool] = []
        var registrationStateObservedAtCommit: Bool?
        stressView.onStatusChange = { _, busy in
            stressComplete = !busy
            if observeEdit, busy { editRestartedIndexing = true }
        }
        stressView.onEditingRegistrationChange = { editing in
            registrationStates.append(editing)
        }
        stressDelegate.onCommit = {
            registrationStateObservedAtCommit = registrationStates.last
        }
        stressView.editorDelegate = stressDelegate
        try wait(until: { stressComplete }, timeout: 15, failure: "Stress CSV did not finish indexing")
        guard let stressTable = descendant(of: stressView, as: NSTableView.self),
              stressTable.numberOfRows == 96 else {
            throw QAError.failed("Stress CSV row count was not available")
        }

        // Row 63 maps to record 64 after the fixed header. Its page is not in
        // the 32-record initial cache; requesting it exercises the random page
        // miss path with 32 records near the 256 KiB presentation bound.
        let clock = ContinuousClock()
        let start = clock.now
        let initialCell = stressTable.view(atColumn: 2, row: 63, makeIfNecessary: true) as? NSTextField
        let enqueueElapsed = start.duration(to: clock.now)
        let enqueueMilliseconds = milliseconds(enqueueElapsed)
        guard enqueueMilliseconds < 20 else {
            throw QAError.failed("Random page request blocked main for \(enqueueMilliseconds) ms")
        }
        guard initialCell?.stringValue.isEmpty == true else {
            throw QAError.failed("Random page unexpectedly decoded synchronously")
        }

        var heartbeatObserved = false
        let heartbeatStart = clock.now
        DispatchQueue.main.async { heartbeatObserved = true }
        try wait(until: { heartbeatObserved }, timeout: 0.1, failure: "Main queue stalled during CSV page decode")
        let heartbeatMilliseconds = milliseconds(heartbeatStart.duration(to: clock.now))

        try wait(
            until: {
                let cell = stressTable.view(atColumn: 2, row: 63, makeIfNecessary: true) as? NSTextField
                return cell?.stringValue == "person-64"
            },
            timeout: 5,
            failure: "Background CSV page did not populate the requested row"
        )

        guard let editableCell = stressTable.view(
            atColumn: 2,
            row: 63,
            makeIfNecessary: true
        ) as? NSTextField else {
            throw QAError.failed("Could not resolve the random row's editable cell")
        }
        observeEdit = true
        stressView.controlTextDidBeginEditing(Notification(
            name: NSControl.textDidBeginEditingNotification,
            object: editableCell
        ))
        guard registrationStates.last == true else {
            throw QAError.failed("CSV editor did not register before a pending cell edit")
        }
        editableCell.stringValue = "person 64, edited"
        let editStart = clock.now
        stressView.controlTextDidEndEditing(Notification(
            name: NSControl.textDidEndEditingNotification,
            object: editableCell
        ))
        let editMilliseconds = milliseconds(editStart.duration(to: clock.now))
        guard editMilliseconds < 20, !editRestartedIndexing else {
            throw QAError.failed(
                "Middle-row edit discarded the completed sparse index (\(editMilliseconds) ms)"
            )
        }
        guard registrationStates.suffix(2).elementsEqual([true, false]),
              registrationStateObservedAtCommit == false else {
            throw QAError.failed(
                "CSV NSEditor registration was not transferred to the document change count"
            )
        }
        try wait(
            until: {
                let cell = stressTable.view(atColumn: 2, row: 63, makeIfNecessary: true) as? NSTextField
                return cell?.stringValue == "person 64, edited"
            },
            timeout: 5,
            failure: "Rebased index did not repopulate the edited middle row"
        )

        // A discarded active field must unregister and must not publish a
        // piece-table edit. This mirrors Cancel from the unsaved-changes sheet.
        guard let discardedCell = stressTable.view(
            atColumn: 2,
            row: 62,
            makeIfNecessary: true
        ) as? NSTextField else {
            throw QAError.failed("Could not resolve the discard-test cell")
        }
        let commitsBeforeDiscard = stressDelegate.commitCount
        stressView.controlTextDidBeginEditing(Notification(
            name: NSControl.textDidBeginEditingNotification,
            object: discardedCell
        ))
        discardedCell.stringValue = "must not persist"
        stressView.discardEditing()
        guard discardedCell.stringValue == "person-63",
              stressDelegate.commitCount == commitsBeforeDiscard,
              registrationStates.last == false else {
            throw QAError.failed("Discarding a pending CSV cell changed the document")
        }

        // Replace an in-flight query immediately. Only the second generation
        // may install a row map; the abandoned temporary map must be closed.
        stressComplete = false
        stressView.qaApplyContainsFilter(column: 1, value: "person-9")
        stressView.qaApplyContainsFilter(column: 1, value: "person-1")
        try wait(until: { stressComplete }, timeout: 15, failure: "Replacement filter query did not finish")
        guard stressTable.numberOfRows == 11 else {
            throw QAError.failed("A stale filter result replaced the newest 11-row query")
        }
        let replacementValues = try cellValues(
            in: stressTable,
            column: 2,
            rows: 0..<11,
            context: "replacement filter"
        )
        guard replacementValues.allSatisfy({ $0.contains("person-1") }) else {
            throw QAError.failed("Replacement filter displayed rows from a stale query generation")
        }
        stressComplete = false
        stressView.qaClearFilters()
        try wait(until: { stressComplete }, timeout: 15, failure: "Stress filter clear did not finish")

        // The pseudorandom numeric key produces a deliberately scattered
        // display-to-source map. Projected cache misses must decode only the
        // exact requested source record, settle once, and remain bounded.
        stressComplete = false
        stressView.qaCycleHeaderSort(column: 2)
        try wait(until: { stressComplete }, timeout: 15, failure: "Random-key sort did not finish")
        let projectedRows = Array(0..<24)
        let projectedSources = try projectedRows.map {
            try stressView.qaSourceRecord(forDisplayedRow: Int64($0))
        }
        guard Set(projectedSources).count == projectedSources.count,
              zip(projectedSources, projectedSources.dropFirst()).contains(where: {
                  abs($0.0 - $0.1) > 1
              }) else {
            throw QAError.failed("Sort fixture did not create a scattered source-record map")
        }
        stressView.qaResetRecordCache()
        stressView.qaRequestDisplayedRows(projectedRows)
        try wait(
            until: { stressView.qaPendingRecordLoadCount == 0 },
            timeout: 10,
            failure: "Exact-record projected cache requests did not settle"
        )
        let projectedValues = projectedRows.map {
            stressView.qaCachedValue(displayedRow: $0, column: 1) ?? ""
        }
        for (value, sourceRecord) in zip(projectedValues, projectedSources) {
            guard value == "person-\(sourceRecord)" else {
                throw QAError.failed("Projected cell decoded the wrong source record")
            }
        }
        let settledCache = stressView.qaCachedSourceRecords
        guard Set(projectedSources).isSubset(of: settledCache),
              settledCache.count <= 64 else {
            throw QAError.failed("Projected exact-record cache exceeded its 64-row bound")
        }
        stressView.qaRequestDisplayedRows(projectedRows)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        guard stressView.qaPendingRecordLoadCount == 0,
              stressView.qaCachedSourceRecords == settledCache else {
            throw QAError.failed("Settled projected rows re-enqueued and thrashed the cache")
        }


        // Record zero is intentionally absent from the bounded row cache after
        // the scattered requests above. Toggling header mode must still use
        // the dedicated record-zero parse, never an arbitrary cached row.
        stressComplete = false
        stressView.qaSetFirstRowIsHeader(false)
        try wait(until: { stressComplete }, timeout: 15, failure: "Header-off query did not finish")
        stressComplete = false
        stressView.qaSetFirstRowIsHeader(true)
        try wait(until: { stressComplete }, timeout: 15, failure: "Header-on query did not finish")
        guard stressView.qaColumnTitles == ["id", "name", "sort_key", "payload"] else {
            throw QAError.failed("Header toggle used an evicted/arbitrary cached data row for titles")
        }
        print(
            "CSV table QA passed: sort/filter/summary and row/column undo-redo; "
                + "4 fixture rows, 5 visible columns; random 8 MiB-bounded page "
                + "enqueued in \(String(format: "%.3f", enqueueMilliseconds)) ms, main heartbeat "
                + "\(String(format: "%.3f", heartbeatMilliseconds)) ms; middle-row index rebase "
                + "\(String(format: "%.3f", editMilliseconds)) ms; stale-query cancellation and "
                + "exact-record projected cache stable; projected-key edits, retained header, "
                + "empty bootstrap, and 512-column cap verified; accessibility + light/dark captures rendered"
        )
    }

    private static func makeWindow(
        containing view: NSView,
        appearance: NSAppearance.Name,
        styleMask: NSWindow.StyleMask = [.borderless]
    ) -> NSWindow {
        let requestedSize = view.frame.size
        let window = NSWindow(
            contentRect: view.bounds,
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        window.setContentSize(requestedSize)
        view.frame = NSRect(origin: .zero, size: requestedSize)
        window.layoutIfNeeded()
        return window
    }

    private static func settleLayout(window: NSWindow, view: CSVTableView) throws {
        for _ in 0..<3 {
            window.layoutIfNeeded()
            view.needsLayout = true
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.025))
        }
    }

    private static func assertHeaderLayout(
        _ view: CSVTableView,
        column: Int,
        label: String
    ) throws {
        guard let geometry = view.qaHeaderGeometry(column: column) else {
            throw QAError.failed("CSV header geometry unavailable for \(label)")
        }

        let tolerance: CGFloat = 0.75
        func contains(_ outer: NSRect, _ inner: NSRect) -> Bool {
            outer.insetBy(dx: -tolerance, dy: -tolerance).contains(inner)
        }
        func separatedVertically(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
            lhs.maxY <= rhs.minY + tolerance || rhs.maxY <= lhs.minY + tolerance
        }

        guard abs(geometry.header.height - 54) <= tolerance,
              abs(geometry.clipBounds.height - 54) <= tolerance,
              !geometry.title.intersects(geometry.filter),
              contains(geometry.clipBounds, geometry.titleInClip),
              contains(geometry.clipBounds, geometry.filterInClip),
              !geometry.drawnTitleInClip.isEmpty,
              !geometry.actualInputInClip.isEmpty,
              !geometry.actualTextInClip.isEmpty,
              !geometry.actualFunnelInClip.isEmpty,
              contains(geometry.clipBounds, geometry.drawnTitleInClip),
              contains(geometry.clipBounds, geometry.actualInputInClip),
              contains(geometry.clipBounds, geometry.actualTextInClip),
              contains(geometry.clipBounds, geometry.actualFunnelInClip),
              contains(geometry.filterInClip, geometry.actualInputInClip),
              contains(geometry.actualInputInClip, geometry.actualTextInClip),
              contains(geometry.filterInClip, geometry.actualFunnelInClip),
              geometry.interiorFrame.height < geometry.resolvedLayoutFrame.height,
              abs(geometry.resolvedLayoutFrame.height - geometry.header.height) <= tolerance,
              separatedVertically(geometry.drawnTitleInClip, geometry.actualInputInClip),
              separatedVertically(geometry.drawnTitleInClip, geometry.actualFunnelInClip),
              separatedVertically(geometry.drawnTitleInClip, geometry.actualTextInClip) else {
            throw QAError.failed(
                "CSV two-row header presentation failed for \(label): "
                    + "header=\(geometry.header), clip=\(geometry.clipBounds), "
                    + "title=\(geometry.titleInClip), drawnTitle=\(geometry.drawnTitleInClip), "
                    + "filter=\(geometry.filterInClip), input=\(geometry.actualInputInClip), "
                    + "text=\(geometry.actualTextInClip), funnel=\(geometry.actualFunnelInClip), "
                    + "interior=\(geometry.interiorFrame), resolved=\(geometry.resolvedLayoutFrame)"
            )
        }
    }

    private static func writeStressCSV(to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data("id,name,sort_key,payload\n".utf8))
        let payload = Data(repeating: 0x61, count: (256 << 10) - 64)
        for row in 1...96 {
            let sortKey = (row * 37) % 97
            try handle.write(contentsOf: Data("\(row),person-\(row),\(sortKey),".utf8))
            try handle.write(contentsOf: payload)
            try handle.write(contentsOf: Data("\n".utf8))
        }
    }

    private static func writeSummaryCSV(to url: URL) throws {
        var data = Data("id,group\n".utf8)
        for row in 0..<50_128 {
            data.append(contentsOf: "\(row),group-\(row % 7)\n".utf8)
        }
        try data.write(to: url, options: .atomic)
    }

    private static func writeWideCSV(to url: URL) throws {
        let header = (0..<512).map { "column_\($0)" }.joined(separator: ",")
        let values = (0..<512).map(String.init).joined(separator: ",")
        try Data("\(header)\n\(values)\n".utf8).write(to: url, options: .atomic)
    }

    private static func cellValues(
        in table: NSTableView,
        column: Int,
        rows: Range<Int>,
        context: String = "table"
    ) throws -> [String] {
        var values: [String] = []
        values.reserveCapacity(rows.count)
        for row in rows {
            var value: String?
            try wait(
                until: {
                    value = (table.view(
                        atColumn: column,
                        row: row,
                        makeIfNecessary: true
                    ) as? NSTextField)?.stringValue
                    return value?.isEmpty == false
                },
                timeout: 5,
                failure: "CSV \(context) cell \(row),\(column) did not populate"
            )
            values.append(value ?? "")
        }
        return values
    }

    private static func documentString(_ engine: FileBackedPieceTable) throws -> String {
        let snapshot = try engine.snapshot()
        return try snapshot.utf8String(in: 0..<snapshot.byteCount)
    }

    private static func assertUndoRedo(
        engine: FileBackedPieceTable,
        before: String,
        after: String,
        label: String
    ) throws {
        guard engine.undo(), try documentString(engine) == before else {
            throw QAError.failed("\(label) was not installed as one undoable byte result")
        }
        guard engine.redo(), try documentString(engine) == after else {
            throw QAError.failed("\(label) redo did not restore the exact byte result")
        }
    }

    private static func render(_ view: NSView, overlay: NSView? = nil, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let baseBitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw QAError.failed("Could not create CSV capture buffer")
        }
        view.cacheDisplay(in: view.bounds, to: baseBitmap)

        let bitmap: NSBitmapImageRep
        if let overlay {
            overlay.layoutSubtreeIfNeeded()
            guard let overlayBitmap = overlay.bitmapImageRepForCachingDisplay(in: overlay.bounds),
                  let composite = NSBitmapImageRep(
                      bitmapDataPlanes: nil,
                      pixelsWide: Int(view.bounds.width.rounded(.up)),
                      pixelsHigh: Int(view.bounds.height.rounded(.up)),
                      bitsPerSample: 8,
                      samplesPerPixel: 4,
                      hasAlpha: true,
                      isPlanar: false,
                      colorSpaceName: .deviceRGB,
                      bytesPerRow: 0,
                      bitsPerPixel: 0
                  ),
                  let context = NSGraphicsContext(bitmapImageRep: composite) else {
                throw QAError.failed("Could not create active-filter capture buffer")
            }
            overlay.cacheDisplay(in: overlay.bounds, to: overlayBitmap)
            composite.size = view.bounds.size
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            baseBitmap.draw(in: view.bounds)

            let panelRect = NSRect(
                x: min(max(150, view.bounds.width * 0.18), view.bounds.width - overlay.bounds.width - 18),
                y: max(18, view.bounds.height - overlay.bounds.height - 72),
                width: overlay.bounds.width,
                height: overlay.bounds.height
            )
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
            shadow.shadowBlurRadius = 12
            shadow.shadowOffset = NSSize(width: 0, height: -3)
            NSGraphicsContext.saveGraphicsState()
            shadow.set()
            LighTxtTheme.resolved(
                NSColor.windowBackgroundColor,
                for: overlay.effectiveAppearance
            ).setFill()
            NSBezierPath(roundedRect: panelRect, xRadius: 10, yRadius: 10).fill()
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: panelRect, xRadius: 10, yRadius: 10).addClip()
            overlayBitmap.draw(in: panelRect)
            NSGraphicsContext.restoreGraphicsState()
            NSGraphicsContext.restoreGraphicsState()
            bitmap = composite
        } else {
            bitmap = baseBitmap
        }

        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw QAError.failed("Could not encode CSV capture")
        }
        try png.write(to: url, options: .atomic)
    }

    private static func descendant<T: NSView>(of root: NSView, as type: T.Type) -> T? {
        if let match = root as? T { return match }
        for child in root.subviews {
            if let match = descendant(of: child, as: type) { return match }
        }
        return nil
    }

    private static func descendants<T: NSView>(of root: NSView, as type: T.Type) -> [T] {
        var matches: [T] = []
        if let match = root as? T { matches.append(match) }
        for child in root.subviews {
            matches.append(contentsOf: descendants(of: child, as: type))
        }
        return matches
    }

    private static func wait(
        until condition: () -> Bool,
        timeout: TimeInterval,
        failure: String
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        guard condition() else { throw QAError.failed(failure) }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private enum QAError: Error, LocalizedError {
        case usage
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .usage:
                return "Usage: csv-table-qa <small-fixture.csv> <capture-directory>"
            case let .failed(message):
                return message
            }
        }
    }
}

@MainActor
private final class QACSVDelegate: CSVMutationEditorDelegate {
    let engine: FileBackedPieceTable
    private(set) var lastError: Error?
    private(set) var commitCount = 0
    var onCommit: (() -> Void)?
    var onDocumentChange: (() -> Void)?
    var deferColumnMutations = false
    private var deferredColumnMutation: (() -> Void)?

    init(url: URL) throws { engine = try FileBackedPieceTable(opening: url) }

    var editorDocumentByteCount: Int64 { engine.byteCount }
    var editorSyntaxFileType: SyntaxFileType { .csv }
    func editorSnapshot() throws -> DocumentSnapshot { try engine.snapshot() }
    func editorReadBytes(in range: Range<Int64>) throws -> Data {
        try engine.snapshot().data(in: range)
    }
    func editorReplaceBytes(in range: Range<Int64>, with bytes: Data) throws {
        try engine.replace(byteRange: range, with: bytes)
    }
    func editorApplyCSVRowEdits(
        _ edits: [ByteEdit],
        replacing snapshot: DocumentSnapshot,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let result = Result {
            try engine.replaceAtomically(edits: edits, replacing: snapshot)
        }
        if case .success = result { onDocumentChange?() }
        completion(result)
    }
    func editorApplyCSVColumnMutation(
        _ mutation: CSVColumnMutation,
        snapshot: DocumentSnapshot,
        index: CSVRowIndex,
        progress: @escaping (CSVColumnRewriteProgress) -> Void,
        completion: @escaping (Result<CSVColumnRewriteResult, Error>) -> Void
    ) {
        let perform = { [weak self] in
            guard let self else { return }
            let result = Result {
                try self.engine.applyCSVColumnMutation(
                    mutation,
                    snapshot: snapshot,
                    index: index,
                    progress: progress
                )
            }
            if case .success = result { self.onDocumentChange?() }
            completion(result)
        }
        if deferColumnMutations {
            deferredColumnMutation = perform
        } else {
            perform()
        }
    }
    func completeDeferredColumnMutation() {
        let pending = deferredColumnMutation
        deferredColumnMutation = nil
        pending?()
    }
    func editorCancelCSVMutation() {}
    func editorLineLocation(at byteOffset: Int64) -> EditorLineLocation {
        EditorLineLocation(lineNumber: 1, lineStartByteOffset: 0)
    }
    func editorDidCommitEdit(replaced range: Range<Int64>, insertedByteCount: Int64) {
        commitCount += 1
        onCommit?()
    }
    func editorSelectionDidChange(byteRange: Range<Int64>, line: Int64, column: Int) {}
    func editorDidLoadViewport(byteRange: Range<Int64>) {}
    func editorDidExpose(byteRange: Range<Int64>) {}
    func editorDidDiscoverStructure(
        folds: [SyntaxFoldRange],
        viewportData: Data,
        viewportBaseOffset: Int64
    ) {}
    func editorDidFail(_ error: Error) { lastError = error }
}
#endif
