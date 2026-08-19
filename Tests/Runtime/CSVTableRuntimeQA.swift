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
        var fixtureComplete = false
        fixtureView.onStatusChange = { _, busy in fixtureComplete = !busy }
        fixtureView.editorDelegate = fixtureDelegate
        try wait(until: { fixtureComplete }, timeout: 5, failure: "Small CSV fixture did not finish indexing")
        guard let fixtureTable = descendant(of: fixtureView, as: NSTableView.self),
              fixtureTable.numberOfRows == 4,
              fixtureTable.numberOfColumns == 5 else {
            throw QAError.failed("CSV table did not detect a four-row/four-column fixture with fixed header")
        }

        let accessibilityLabels = descendants(of: fixtureView, as: NSButton.self)
            .compactMap { $0.accessibilityLabel() }
        guard accessibilityLabels.contains("Add CSV row or column"),
              accessibilityLabels.contains("Delete CSV row or column"),
              accessibilityLabels.contains("Clear all CSV filters") else {
            throw QAError.failed("CSV table actions are missing accessible labels")
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

        fixtureWindow.appearance = NSAppearance(named: .aqua)
        fixtureView.layoutSubtreeIfNeeded()
        try render(fixtureView, to: outputDirectory.appendingPathComponent("csv-light.png"))
        fixtureWindow.appearance = NSAppearance(named: .darkAqua)
        fixtureView.layoutSubtreeIfNeeded()
        try render(fixtureView, to: outputDirectory.appendingPathComponent("csv-dark.png"))

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

        let emptyURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LighTxt-CSV-empty-QA-\(UUID().uuidString).csv"
        )
        FileManager.default.createFile(atPath: emptyURL.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: emptyURL) }
        let emptyDelegate = try QACSVDelegate(url: emptyURL)
        let emptyView = CSVTableView(frame: NSRect(x: 0, y: 0, width: 700, height: 500))
        let emptyWindow = makeWindow(containing: emptyView, appearance: .aqua)
        _ = emptyWindow
        var emptyReady = false
        emptyView.onStatusChange = { _, busy in emptyReady = !busy }
        emptyDelegate.onDocumentChange = { [weak emptyView] in emptyView?.reloadDocument() }
        emptyView.editorDelegate = emptyDelegate
        try wait(until: { emptyReady }, timeout: 5, failure: "Empty CSV did not initialize")
        guard let emptyTable = descendant(of: emptyView, as: NSTableView.self),
              emptyTable.numberOfRows == 0,
              emptyTable.numberOfColumns == 1 else {
            throw QAError.failed("Zero-byte CSV did not begin with an empty table")
        }
        emptyReady = false
        emptyView.qaAddRow(beforeSourceRecord: 0)
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
        emptyView.qaAddColumn(at: 0, name: "title")
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
        appearance: NSAppearance.Name
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: view.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        window.layoutIfNeeded()
        return window
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

    private static func render(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw QAError.failed("Could not create CSV capture buffer")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
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
        let result = Result {
            try engine.applyCSVColumnMutation(
                mutation,
                snapshot: snapshot,
                index: index,
                progress: progress
            )
        }
        if case .success = result { onDocumentChange?() }
        completion(result)
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
