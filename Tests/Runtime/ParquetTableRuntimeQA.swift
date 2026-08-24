#if LIGHTXT_STANDALONE_PARQUET_QA
import AppKit
import Foundation

// The production Parquet table reuses the CSV filter/header chrome. These
// compact declarations are the data-only pieces that chrome expects when the
// mutable CSV table itself is deliberately excluded from this read-only QA.
struct CSVUniqueValuesProgress: Sendable, Equatable {
    let indexedFractionCompleted: Double
    let scannedRecordCount: Int64
    let eligibleRecordCount: Int64
    let uniqueValueCount: Int
    let totalRecordCount: Int64?
}

enum CSVUniqueValuesTruncationReason: Sendable, Equatable {
    case uniqueValueCountLimit
    case retainedValueBytesLimit
    case valueByteLimit
}

struct CSVUniqueValuesResult: Sendable, Equatable {
    let column: Int
    let values: [String]
    let scannedRecordCount: Int64
    let eligibleRecordCount: Int64
    let totalRecordCount: Int64?
    let isCompleteDataset: Bool
    let truncationReason: CSVUniqueValuesTruncationReason?
    let maximumUniqueValueCount: Int
    let maximumRetainedValueBytes: Int
    var isTruncated: Bool { truncationReason != nil }
}

struct CSVQueryProgress: Sendable, Equatable {
    let scannedRecordCount: Int64
    let totalRecordCount: Int64?
}

enum LighTxtTheme {
    static let primaryText = NSColor.labelColor
    static let secondaryText = NSColor.secondaryLabelColor
    static let separator = NSColor.separatorColor
    static let editorBackground = NSColor.textBackgroundColor
    static let gutterBackground = NSColor.controlBackgroundColor
    static let accent = NSColor.controlAccentColor

    static func resolved(_ color: NSColor, for appearance: NSAppearance) -> NSColor {
        var result = color
        appearance.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.deviceRGB) ?? color
        }
        return result
    }
}

@main
@MainActor
struct ParquetTableRuntimeQA {
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { throw QAError.usage }
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let view = ParquetTableView(frame: NSRect(x: 0, y: 0, width: 1_300, height: 760))
        let window = host(view, appearance: .aqua)
        window.title = "Parquet Runtime QA"
        window.makeKeyAndOrderFront(nil)
        window.setContentSize(NSSize(width: 1_300, height: 760))
        window.layoutIfNeeded()
        app.activate(ignoringOtherApps: true)
        defer {
            view.deactivate()
            window.close()
        }

        let pickerRecoveryProbe = CSVFilterPopoverViewController(
            columnTitle: "Picker recovery probe",
            filter: nil
        )
        pickerRecoveryProbe.loadView()
        pickerRecoveryProbe.showUniqueValues(
            error: NSError(domain: "LighTxtRuntimeQA", code: 1)
        )
        guard pickerRecoveryProbe.qaUniqueValuesToolTip != nil else {
            throw QAError.failed("Unique-value errors did not expose diagnostic help")
        }
        pickerRecoveryProbe.showRemoteUniqueValuesLoading(replacing: true)
        guard pickerRecoveryProbe.qaUniqueValuesToolTip == nil else {
            throw QAError.failed("Remote unique-value loading retained a stale error tooltip")
        }
        pickerRecoveryProbe.showUniqueValues(
            error: NSError(domain: "LighTxtRuntimeQA", code: 2)
        )
        pickerRecoveryProbe.showRemoteUniqueValues(
            ["recovered"],
            totalValueCount: 1,
            hasMore: false,
            replacing: true
        )
        guard pickerRecoveryProbe.qaUniqueValuesToolTip == nil else {
            throw QAError.failed("Recovered remote unique values retained a stale error tooltip")
        }

        view.load(url: fixtureURL)
        guard view.qaIsQueryLoadingOverlayVisible,
              view.qaQueryOverlayBlocksTable else {
            throw QAError.failed("Initial Parquet load did not use the blocking animated table overlay")
        }
        try wait(until: { view.qaIsReady }, failure: "Parquet schema/first page did not load")
        guard view.qaRowCount == 8,
              view.qaColumnNames == ["id", "group_key", "value", "amount", "file_row_number", "nested"],
              view.qaValue(row: 0, column: 0) == "1",
              view.qaValue(row: 0, column: 2) == nil,
              view.qaValue(row: 1, column: 2) == "",
              view.qaValue(row: 2, column: 2) == "NULL",
              view.qaTableAccessibilityLabel == "Read-only Parquet table",
              view.qaVisibleDataCellsAreReadOnly else {
            throw QAError.failed("Initial schema, NULL/empty/literal values, or read-only accessibility is incorrect")
        }
        view.qaBeginQueryOverlayAnimationProbe()
        runLoop(0.24)
        guard view.qaQueryOverlayHasFadedTable else {
            throw QAError.failed("Parquet query cover did not fade the stale table beneath it")
        }
        view.qaEndQueryOverlayAnimationProbe()
        runLoop(0.20)
        guard view.qaTablePresentationIsInteractive else {
            throw QAError.failed("Parquet query cover did not restore table interaction after completion")
        }
        // Do not call any QA synchronization helper before this assertion.
        // The async Parquet schema install itself must materialize both the
        // Contains proxy and value-filter button in every initially visible
        // header cell.
        guard view.qaMaterializedHeaderFilterControlColumns.isSuperset(of: [0, 1, 2, 3]) else {
            throw QAError.failed(
                "Parquet header controls were invisible until interaction: "
                    + "\(view.qaMaterializedHeaderFilterControlColumns.sorted())"
            )
        }
        guard view.qaBodyMenuTitles(row: 0, visualColumn: 1) == ["Copy Cell", "Copy Row"] else {
            throw QAError.failed("Parquet body exposed a mutation action")
        }
        guard view.qaCacheAndRequestLimits == (4, 2),
              view.qaCachedPageCount <= 4,
              view.qaPendingPageCount <= 2 else {
            throw QAError.failed("Parquet page cache/request bounds changed")
        }

        try settle(window, view)
        guard let table = descendant(of: view, as: NSTableView.self),
              let scrollView = table.enclosingScrollView else {
            throw QAError.failed("Parquet table was not hosted by its production scroll view")
        }
        try assertComfortScrollers(scrollView)
        for column in 0..<6 {
            guard let geometry = view.qaHeaderRows(column: column),
                  geometry.header.contains(geometry.title),
                  geometry.header.contains(geometry.filter),
                  geometry.title.maxY <= geometry.filter.minY + 0.5 else {
                throw QAError.failed("Column \(column) title and Contains control are not separate header rows")
            }
        }
        guard view.qaAccessibleFilterButtonColumns.isSuperset(of: [0, 1, 2, 3]) else {
            throw QAError.failed("Visible Parquet column filters are not accessible")
        }
        try render(view, to: outputDirectory.appendingPathComponent("parquet-table-light.png"))

        // Draft typing must remain local until Return.
        view.qaBeginInlineContainsFilter(column: 2)
        view.qaTypeInlineContainsFilter("zet")
        runLoop(0.30)
        guard view.qaRowCount == 8, view.qaInlineFilterHasFocus else {
            throw QAError.failed("Inline Parquet Contains applied while typing or lost focus")
        }
        view.qaCommitInlineContainsFilter()
        guard view.qaIsQueryLoadingOverlayVisible,
              view.qaQueryOverlayBlocksTable,
              view.qaRowCount == 8,
              view.qaValue(row: 0, column: 0) == "1" else {
            throw QAError.failed(
                "Parquet filtering did not fade/block the last complete rows transactionally"
            )
        }
        try wait(until: { view.qaIsReady && view.qaRowCount == 1 }, failure: "Inline Contains did not apply")
        guard view.qaValue(row: 0, column: 0) == "6",
              view.qaTablePresentationIsInteractive else {
            throw QAError.failed("Contains filter did not reveal the expected row")
        }
        view.qaClearFilters()
        try wait(until: { view.qaIsReady && view.qaRowCount == 8 }, failure: "Clearing Contains did not restore rows")

        // Commit before facet discovery can finish. resetQuery must prioritize
        // the page and restart the still-open exclusion-of-self facet using
        // the popover text as its server-side value search.
        view.qaShowFilterPopover(column: 2)
        try wait(until: {
            view.qaHasPresentedPopover && view.qaPopoverFilterHasFocus
        }, failure: "Filter popover did not become shown/focused")
        view.qaTypePopoverContains("zet")
        view.qaCommitPopoverContains()
        try wait(until: {
            view.qaIsReady && view.qaRowCount == 1
                && view.qaPopoverUniqueValueLabels.contains("“zeta”")
                && applicationTextValues().contains { value in
                    value.contains("matching value") && !value.contains("…")
                }
        }, failure: "Early popover commit stranded facet discovery")
        guard view.qaHasPresentedPopover, view.qaPopoverFilterHasFocus else {
            throw QAError.failed("Popover closed or lost focus after a committed query")
        }

        view.qaTypePopoverContains("")
        view.qaCommitPopoverContains()
        try wait(until: {
            let labels = Set(view.qaPopoverUniqueValueLabels)
            return view.qaIsReady
                && view.qaRowCount == 8
                && labels.contains("NULL")
                && labels.contains("Empty string")
                && labels.contains("“NULL”")
        }, failure: "Clearing popover text or refreshing its remote facet failed")
        let facetLabels = Set(view.qaPopoverUniqueValueLabels)
        guard facetLabels.contains("NULL"),
              facetLabels.contains("Empty string"),
              facetLabels.contains("“NULL”") else {
            throw QAError.failed("Facet labels do not distinguish NULL, empty string, and literal NULL: \(facetLabels)")
        }
        view.qaTogglePopoverValue(label: "NULL")
        try wait(until: { view.qaIsReady && view.qaRowCount == 1 }, failure: "NULL checkbox did not filter")
        view.qaTogglePopoverValue(label: "“NULL”")
        try wait(until: { view.qaIsReady && view.qaRowCount == 2 }, failure: "Exact values were not ORed")
        guard view.qaHasPresentedPopover, view.qaPopoverFilterHasFocus, view.qaFilterChipCount == 1 else {
            throw QAError.failed("Repeated checkbox commits detached the filter popover/chip")
        }
        view.qaOpenFilterChip(column: 2)
        try wait(until: {
            view.qaHasPresentedPopover && view.qaPopoverUniqueValueLabels.contains("NULL")
        }, failure: "Filter chip did not reopen and refresh its popover")
        view.qaTogglePopoverValue(label: "NULL")
        try wait(until: { view.qaIsReady && view.qaRowCount == 1 }, failure: "Chip-anchored popover could not toggle again")
        guard view.qaHasPresentedPopover, view.qaPopoverFilterHasFocus else {
            throw QAError.failed("Chip rebuild detached its stable popover anchor")
        }
        view.qaClearFilterChip(column: 2)
        try wait(until: { view.qaIsReady && view.qaRowCount == 8 }, failure: "Clearing chip did not restore rows")

        // Across-column filters combine with AND.
        view.qaApplyContainsFilter(column: 1, value: "same")
        try wait(until: { view.qaIsReady && view.qaRowCount == 6 }, failure: "First cross-column filter failed")
        view.qaApplyContainsFilter(column: 2, value: "zet")
        try wait(until: { view.qaIsReady && view.qaRowCount == 1 }, failure: "Cross-column filters were not ANDed")
        guard view.qaValue(row: 0, column: 0) == "6" else {
            throw QAError.failed("Cross-column filters returned the wrong row")
        }
        view.qaClearFilters()
        try wait(until: { view.qaIsReady && view.qaRowCount == 8 }, failure: "Cross-filter clear failed")

        // Native header sort cycles ascending, descending, source order; the
        // service adds a source-row tie breaker so every page is deterministic.
        view.qaCycleHeaderSort(column: 1)
        try wait(until: { view.qaIsReady }, failure: "Ascending sort failed")
        guard view.qaValue(row: 0, column: 0) == "4" else { throw QAError.failed("Ascending sort was unstable") }
        view.qaCycleHeaderSort(column: 1)
        try wait(until: { view.qaIsReady }, failure: "Descending sort failed")
        let descendingIDs = (0..<view.qaRowCount).compactMap { view.qaValue(row: $0, column: 0) }
        guard descendingIDs == ["1", "2", "3", "6", "7", "8", "4", "5"] else {
            throw QAError.failed("Descending sort was unstable: \(descendingIDs)")
        }
        view.qaCycleHeaderSort(column: 1)
        try wait(until: { view.qaIsReady }, failure: "Clearing sort failed")
        guard view.qaValue(row: 0, column: 0) == "1" else { throw QAError.failed("Third sort state did not restore source order") }

        // Parquet is already file-backed and bounded. Losing focus must not
        // tear down its stable page or replace visible values with Loading…;
        // reactivation must therefore require no reopen/query cycle.
        view.qaClosePopover()
        view.qaApplyContainsFilter(column: 1, value: "same")
        try wait(until: { view.qaIsReady && view.qaRowCount == 6 }, failure: "Purge filter setup failed")
        let purgeSelection = IndexSet([1, 3])
        view.qaSelectRows(purgeSelection)
        let valuesBeforePurge = [
            view.qaValue(row: 1, column: 0),
            view.qaValue(row: 3, column: 0),
        ]
        guard view.purgeRebuildableResidentMemory(),
              !view.purgeRebuildableResidentMemory(),
              view.qaIsResidentStatePurged,
              view.qaCachedPageCount > 0,
              view.qaRowCount == 6,
              view.qaSelectedRows == purgeSelection,
              [view.qaValue(row: 1, column: 0), view.qaValue(row: 3, column: 0)] == valuesBeforePurge,
              view.qaTablePresentationIsInteractive else {
            throw QAError.failed("Inactive Parquet state replaced stable visible rows or lost selection")
        }
        view.reactivateAfterResidentPurge()
        view.reactivateAfterResidentPurge()
        guard view.qaIsReady,
              !view.qaIsResidentStatePurged,
              view.qaRowCount == 6,
              view.qaSelectedRows == purgeSelection,
              view.qaFilterChipCount == 1,
              [view.qaValue(row: 1, column: 0), view.qaValue(row: 3, column: 0)] == valuesBeforePurge else {
            throw QAError.failed("Parquet reactivation queried again or lost its stable presentation")
        }
        view.qaClearFilters()
        try wait(until: { view.qaIsReady && view.qaRowCount == 8 }, failure: "Post-purge filter clear failed")

        view.qaShowColumnSummary(column: 3)
        try wait(until: {
            let text = view.qaSummaryText
            return text.contains("Column Summary: amount") && text.contains("Rows") && !text.contains("Scanning")
        }, failure: "Column summary did not finish")
        guard view.qaSummaryText.contains("8"), view.qaSummaryText.contains("Minimum"), view.qaSummaryText.contains("Maximum") else {
            throw QAError.failed("Column summary omitted rows or typed extrema: \(view.qaSummaryText)")
        }

        view.qaCopyCell(row: 2, column: 2)
        let copiedCell = NSPasteboard.general.string(forType: .string)
        guard copiedCell == "NULL" else {
            throw QAError.failed(
                "Copy Cell did not copy the displayed value; source="
                    + "\(String(describing: view.qaValue(row: 2, column: 2))), "
                    + "pasteboard=\(String(describing: copiedCell))"
            )
        }
        view.qaCopyRow(0)
        guard NSPasteboard.general.string(forType: .string)?.split(separator: "\t", omittingEmptySubsequences: false).count == 6 else {
            throw QAError.failed("Copy Row did not copy six tab-separated fields")
        }

        for column in 0..<6 { view.qaResizeDataColumn(column, width: 300 + CGFloat(column * 8)) }
        view.qaMoveDataColumn(5, toVisualIndex: 1)
        window.setContentSize(NSSize(width: 900, height: 620))
        view.frame.size = NSSize(width: 900, height: 620)
        try settle(window, view)
        view.qaScrollDataColumnToVisible(4)
        try settle(window, view)
        guard view.qaMaterializedHeaderFilterControlColumns.contains(4),
              view.qaAccessibleFilterButtonColumns.contains(4),
              view.qaCachedPageCount <= 4,
              view.qaPendingPageCount <= 2 else {
            throw QAError.failed(
                "Resize/reorder/scroll state: filters=\(view.qaAccessibleFilterButtonColumns.sorted()), "
                    + "cache=\(view.qaCachedPageCount), pending=\(view.qaPendingPageCount)"
            )
        }

        window.appearance = NSAppearance(named: .darkAqua)
        try settle(window, view)
        guard !view.qaMaterializedHeaderFilterControlColumns.isEmpty else {
            throw QAError.failed("Parquet header controls disappeared in dark appearance")
        }
        try render(view, to: outputDirectory.appendingPathComponent("parquet-table-dark.png"))

        // A second fixture exercises top-level STRUCT, LIST, and MAP columns,
        // stable source-row expansion identity, bounded detail rendering, and
        // values containing JSON punctuation, quotes, newlines, and Unicode.
        let structuredURL = outputDirectory.appendingPathComponent("structured-values.parquet")
        try structuredFixtureData(beside: fixtureURL).write(to: structuredURL)
        do {
            let latchView = ParquetTableView(
                frame: NSRect(x: 0, y: 0, width: 1_000, height: 620)
            )
            let latchWindow = host(latchView, appearance: .aqua)
            defer {
                latchView.deactivate()
                latchWindow.close()
            }
            latchView.load(url: structuredURL)
            try wait(until: { latchView.qaIsReady }, failure: "Source-latch fixture did not load")

            // A source revision failure must terminate both active and queued
            // structured detail placeholders. Expansions attempted afterward
            // also explain that Reload is required instead of spinning forever.
            for row in [2, 3, 4] {
                latchView.qaToggleStructuredCell(row: row, column: 1)
            }
            latchView.qaLatchSourceChanged()
            guard latchView.qaPendingStructuredDetailCount == 0,
                  latchView.qaStructuredDetailTaskOrderCount == 0,
                  [2, 3, 4].allSatisfy({
                      latchView.qaStructuredDetailError(row: $0, column: 1)?
                          .contains("Reload") == true
                  }) else {
                throw QAError.failed("Source-change latch left a structured detail visibly loading")
            }
            latchView.qaToggleStructuredCell(row: 5, column: 1)
            guard latchView.qaStructuredDetailError(row: 5, column: 1)?
                .contains("Reload") == true else {
                throw QAError.failed("Post-latch structured expansion did not require Reload")
            }
        }
        let structuredView = ParquetTableView(frame: NSRect(x: 0, y: 0, width: 1_300, height: 760))
        let structuredWindow = host(structuredView, appearance: .aqua)
        structuredWindow.title = "Structured Parquet Runtime QA"
        structuredWindow.makeKeyAndOrderFront(nil)
        structuredWindow.setContentSize(NSSize(width: 1_300, height: 760))
        structuredWindow.layoutIfNeeded()
        defer {
            structuredView.deactivate()
            structuredWindow.close()
        }
        structuredView.load(url: structuredURL)
        try wait(until: { structuredView.qaIsReady }, failure: "Structured Parquet fixture did not load")
        guard structuredView.qaRowCount == 18,
              structuredView.qaColumnNames == ["id", "nested", "items", "attributes", "scalar_text"],
              structuredView.qaExpansionAndDetailLimits == (16, 2),
              structuredView.qaPendingStructuredDetailCount == 0,
              structuredView.qaStructuredCellReuseResetIsClean else {
            throw QAError.failed("Structured Parquet schema, bounds, or reusable-cell reset is incorrect")
        }
        guard structuredView.qaMaterializedHeaderFilterControlColumns.isSuperset(of: [0, 1, 2, 3]) else {
            throw QAError.failed(
                "Structured Parquet header controls required a click: "
                    + "\(structuredView.qaMaterializedHeaderFilterControlColumns.sorted())"
            )
        }
        let emptyObject = structuredView.qaPrettyFormattedJSON("{}")
        let emptyArray = structuredView.qaPrettyFormattedJSON("[]")
        guard emptyObject == ("{}", 1), emptyArray == ("[]", 1) else {
            throw QAError.failed("Empty structured containers gained blank interior rows")
        }
        guard structuredView.qaBodyMenuTitles(row: 0, visualColumn: 2).contains("Expand Structured Value"),
              structuredView.qaStructuredDisclosureIsVisible(row: 0, column: 1),
              structuredView.qaStructuredCellIsReadOnly(row: 0, column: 1),
              !structuredView.qaStructuredDisclosureIsVisible(row: 1, column: 1),
              !structuredView.qaStructuredDisclosureIsVisible(row: 0, column: 4) else {
            throw QAError.failed("Structured disclosure, read-only, NULL, scalar, or context-menu state is incorrect")
        }

        // Keyboard activation must work before any mouse has established a
        // selected column. The first non-NULL structured cell is deterministic.
        structuredView.qaKeyboardToggleStructuredCell(row: 0)
        try wait(until: {
            structuredView.qaStructuredCellIsExpanded(row: 0, column: 1)
                && structuredView.qaPendingStructuredDetailCount == 0
        }, failure: "Keyboard structured expansion did not finish")
        let firstStructuredText = structuredView.qaStructuredCellText(row: 0, column: 1) ?? ""
        guard firstStructuredText.contains("\n  \"message\": "),
              firstStructuredText.contains(#"quote \" comma, braces {} newline\n雪"#),
              firstStructuredText.contains("\n  \"nums\": ["),
              structuredView.qaRowHeight(0) > 28,
              structuredView.qaRowHeight(0) <= 360,
              structuredView.qaStructuredDisclosureAccessibilityLabel(row: 0, column: 1)?.hasPrefix("Collapse") == true else {
            throw QAError.failed("Expanded STRUCT formatting, height, special text, or accessibility is incorrect")
        }
        structuredView.qaKeyboardToggleStructuredCell(row: 0)
        guard !structuredView.qaStructuredCellIsExpanded(row: 0, column: 1),
              structuredView.qaRowHeight(0) == 28 else {
            throw QAError.failed("Keyboard collapse did not restore the compact row")
        }

        structuredView.qaToggleStructuredDisclosure(row: 0, column: 2)
        structuredView.qaToggleStructuredCell(row: 0, column: 3)
        try wait(until: { structuredView.qaPendingStructuredDetailCount == 0 }, failure: "LIST/MAP details did not finish")
        guard structuredView.qaStructuredCellText(row: 0, column: 2)?.contains(#""item,1""#) == true,
              structuredView.qaStructuredCellText(row: 0, column: 2)?.contains(#""雪\"1""#) == true,
              structuredView.qaStructuredCellText(row: 0, column: 3)?.contains(#""braces{}": "line\n1""#) == true else {
            throw QAError.failed("LIST/MAP detail formatting altered punctuation or Unicode")
        }
        structuredView.qaCopyCell(row: 0, column: 1)
        guard NSPasteboard.general.string(forType: .string) == structuredView.qaValue(row: 0, column: 1) else {
            throw QAError.failed("Expanded Copy Cell must preserve the compact bounded source value")
        }

        // Query changes clear expansion/detail state and invalidate variable
        // row heights before any filtered/sorted offset can be reused.
        structuredView.qaApplyContainsFilter(column: 0, value: "no such id")
        try wait(until: { structuredView.qaIsReady && structuredView.qaRowCount == 0 }, failure: "Structured reset filter failed")
        guard structuredView.qaExpandedCellCount == 0,
              structuredView.qaPendingStructuredDetailCount == 0 else {
            throw QAError.failed("Query reset retained structured expansion state")
        }
        structuredView.qaClearFilters()
        try wait(until: { structuredView.qaIsReady && structuredView.qaRowCount == 18 }, failure: "Structured reset clear failed")
        guard structuredView.qaRowHeight(0) == 28 else {
            throw QAError.failed("Query reset did not restore the compact structured row height")
        }

        // More expansion clicks than the active-query cap remain expanded and
        // visibly queued instead of collapsing an earlier user choice. Only
        // two DuckDB detail requests may be active at once.
        for row in [0, 2, 3] {
            structuredView.qaToggleStructuredCell(row: row, column: 1)
        }
        guard [0, 2, 3].allSatisfy({ structuredView.qaStructuredCellIsExpanded(row: $0, column: 1) }),
              structuredView.qaPendingStructuredDetailCount <= 2 else {
            throw QAError.failed("Rapid structured expansions collapsed a choice or exceeded the query cap")
        }
        try wait(until: {
            structuredView.qaPendingStructuredDetailCount == 0
                && [0, 2, 3].allSatisfy {
                    structuredView.qaStructuredCellText(row: $0, column: 1)?.contains("message") == true
                }
        }, failure: "Queued structured expansion details did not drain")
        for row in [0, 2, 3] {
            structuredView.qaToggleStructuredCell(row: row, column: 1)
        }

        // Seventeen non-NULL STRUCT cells exercise deterministic cap eviction.
        let expandableRows = [0] + Array(2..<18)
        for row in expandableRows {
            structuredView.qaToggleStructuredCell(row: row, column: 1)
            try wait(until: {
                structuredView.qaStructuredCellIsExpanded(row: row, column: 1)
                    && structuredView.qaPendingStructuredDetailCount == 0
            }, failure: "Structured detail did not finish for row \(row + 1)")
        }
        guard structuredView.qaExpandedCellCount == 16,
              !structuredView.qaStructuredCellIsExpanded(row: 0, column: 1),
              structuredView.qaStructuredCellIsExpanded(row: 2, column: 1) else {
            throw QAError.failed("The 17th structured expansion did not evict the oldest cell deterministically")
        }
        let boundedText = structuredView.qaStructuredCellText(row: 17, column: 1) ?? ""
        guard boundedText.contains("Structured value shortened at 65,536 characters"),
              boundedText.split(separator: "\n", omittingEmptySubsequences: false).count <= 20,
              structuredView.qaRowHeight(17) <= 360 else {
            throw QAError.failed("Long structured detail did not expose its visible size bound")
        }

        // Reset once more, then leave STRUCT/LIST/MAP expanded for visual QA.
        structuredView.qaApplyContainsFilter(column: 0, value: "1")
        try wait(until: { structuredView.qaIsReady }, failure: "Final expansion reset failed")
        structuredView.qaClearFilters()
        try wait(until: { structuredView.qaIsReady && structuredView.qaRowCount == 18 }, failure: "Final expansion clear failed")
        for column in 1...3 {
            structuredView.qaToggleStructuredCell(row: 0, column: column)
            try wait(until: {
                structuredView.qaStructuredCellIsExpanded(row: 0, column: column)
                    && structuredView.qaPendingStructuredDetailCount == 0
            }, failure: "Visible structured detail did not finish for column \(column + 1)")
        }
        try settle(structuredWindow, structuredView)
        guard structuredView.qaMaterializedHeaderFilterControlColumns.isSuperset(of: [0, 1, 2, 3]) else {
            throw QAError.failed("Header controls disappeared after structured row-height changes")
        }
        try render(
            structuredView,
            to: outputDirectory.appendingPathComponent("parquet-structured-expanded-light.png")
        )
        structuredWindow.appearance = NSAppearance(named: .darkAqua)
        try settle(structuredWindow, structuredView)
        guard !structuredView.qaMaterializedHeaderFilterControlColumns.isEmpty else {
            throw QAError.failed("Structured header controls disappeared in dark appearance")
        }
        try render(
            structuredView,
            to: outputDirectory.appendingPathComponent("parquet-structured-expanded-dark.png")
        )

        let malformedURL = outputDirectory.appendingPathComponent("malformed.parquet")
        try Data("not parquet".utf8).write(to: malformedURL)
        let errorView = ParquetTableView(frame: NSRect(x: 0, y: 0, width: 900, height: 500))
        let errorWindow = host(errorView, appearance: .aqua)
        defer {
            errorView.deactivate()
            errorWindow.close()
        }
        errorView.load(url: malformedURL)
        try wait(until: { errorView.qaStatus.contains("not a readable Parquet") }, failure: "Malformed Parquet diagnostic was not visible")

        print(
            "Parquet table runtime QA passed: read-only 8-row table, exact NULL/empty/literal facets, "
                + "deferred Contains, repeated chip/popover commits, OR/AND filters, three-state stable sort, "
                + "typed summary, copy, bounded cache/requests, resize/reorder/scroll, malformed diagnostics, "
                + "no-click header controls, bounded STRUCT/LIST/MAP expansion, stable source-row identity, "
                + "light/dark rendering, keyboard/context-menu actions, accessibility labels, and native "
                + "auto-hiding +2 pt scrollers."
        )
    }

    private static func assertComfortScrollers(_ scrollView: NSScrollView) throws {
        guard let verticalScroller = scrollView.verticalScroller as? LighTxtComfortScroller,
              let horizontalScroller = scrollView.horizontalScroller as? LighTxtComfortScroller else {
            throw QAError.failed("Parquet did not install both production comfort scrollers")
        }
        guard scrollView.autohidesScrollers else {
            throw QAError.failed("Parquet comfort scrollers were forced to remain visible")
        }
        guard LighTxtComfortScroller.isCompatibleWithOverlayScrollers else {
            throw QAError.failed("Parquet comfort scrollers disabled overlay compatibility")
        }
        for style in [NSScroller.Style.overlay, .legacy] {
            let native = NSScroller.scrollerWidth(for: .regular, scrollerStyle: style)
            let comfortable = LighTxtComfortScroller.scrollerWidth(
                for: .regular,
                scrollerStyle: style
            )
            guard abs((comfortable - native) - 2) < 0.01 else {
                throw QAError.failed(
                    "Parquet comfort delta changed for \(style): "
                        + "native \(native), comfortable \(comfortable)"
                )
            }
        }
        let nativeVerticalWidth = NSScroller.scrollerWidth(
            for: verticalScroller.controlSize,
            scrollerStyle: verticalScroller.scrollerStyle
        )
        let expectedVerticalWidth = LighTxtComfortScroller.scrollerWidth(
            for: verticalScroller.controlSize,
            scrollerStyle: verticalScroller.scrollerStyle
        )
        let nativeHorizontalHeight = NSScroller.scrollerWidth(
            for: horizontalScroller.controlSize,
            scrollerStyle: horizontalScroller.scrollerStyle
        )
        let expectedHorizontalHeight = LighTxtComfortScroller.scrollerWidth(
            for: horizontalScroller.controlSize,
            scrollerStyle: horizontalScroller.scrollerStyle
        )
        guard abs(verticalScroller.bounds.width - expectedVerticalWidth) < 0.5,
              verticalScroller.bounds.width >= nativeVerticalWidth + 1.5,
              abs(horizontalScroller.bounds.height - expectedHorizontalHeight) < 0.5,
              horizontalScroller.bounds.height >= nativeHorizontalHeight + 1.5 else {
            throw QAError.failed(
                "Parquet managed scrollers were not physically widened: "
                    + "vertical actual/native/expected \(verticalScroller.bounds.width)/"
                    + "\(nativeVerticalWidth)/\(expectedVerticalWidth), horizontal "
                    + "\(horizontalScroller.bounds.height)/\(nativeHorizontalHeight)/"
                    + "\(expectedHorizontalHeight)"
            )
        }
    }

    private static func structuredFixtureData(beside fixtureURL: URL) throws -> Data {
        let encodedURL = fixtureURL.deletingLastPathComponent()
            .appendingPathComponent("structured-values.parquet.base64")
        let encoded = try String(contentsOf: encodedURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: encoded) else {
            throw QAError.failed("The structured Parquet runtime fixture is not valid base64")
        }
        return data
    }

    private static func host(_ view: NSView, appearance: NSAppearance.Name) -> NSWindow {
        let requestedSize = view.frame.size
        let container = NSView(frame: NSRect(origin: .zero, size: requestedSize))
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: requestedSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.contentView = container
        window.setContentSize(requestedSize)
        window.contentMinSize = NSSize(width: 700, height: 420)
        window.layoutIfNeeded()
        return window
    }

    private static func descendant<T: NSView>(of root: NSView, as type: T.Type) -> T? {
        if let match = root as? T { return match }
        for child in root.subviews {
            if let match = descendant(of: child, as: type) { return match }
        }
        return nil
    }

    private static func applicationTextValues() -> [String] {
        func collect(from view: NSView) -> [String] {
            var values = (view as? NSTextField).map { [$0.stringValue] } ?? []
            for child in view.subviews { values.append(contentsOf: collect(from: child)) }
            return values
        }
        return NSApp.windows.compactMap(\.contentView).flatMap(collect)
    }

    private static func wait(
        until condition: @escaping @MainActor () -> Bool,
        timeout: TimeInterval = 10,
        failure: String
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            runLoop(0.02)
        }
        throw QAError.failed("\(failure); status=timeout")
    }

    private static func settle(_ window: NSWindow, _ view: NSView) throws {
        window.contentView?.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
        runLoop(0.08)
        window.contentView?.layoutSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()
    }

    private static func runLoop(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.01)))
        }
    }

    private static func render(_ view: ParquetTableView, to url: URL) throws {
        view.qaPrepareForCapture()
        view.displayIfNeeded()
        guard let pdf = NSPDFImageRep(data: view.dataWithPDF(inside: view.bounds)) else {
            throw QAError.failed("Could not create a Parquet table PDF snapshot")
        }
        let pixelsWide = max(1, Int(view.bounds.width.rounded(.up)))
        let pixelsHigh = max(1, Int(view.bounds.height.rounded(.up)))
        guard let opaque = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelsWide,
            pixelsHigh: pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 32
        ), let context = NSGraphicsContext(bitmapImageRep: opaque) else {
            throw QAError.failed("Could not create an opaque Parquet table bitmap")
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        LighTxtTheme.resolved(NSColor.windowBackgroundColor, for: view.effectiveAppearance).setFill()
        let destination = NSRect(x: 0, y: 0, width: pixelsWide, height: pixelsHigh)
        destination.fill()
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(pdf)
        image.draw(
            in: destination,
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = opaque.representation(using: .png, properties: [:]) else {
            throw QAError.failed("Could not encode a Parquet table PNG")
        }
        try data.write(to: url)
    }
}

private enum QAError: LocalizedError {
    case usage
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .usage:
            "Usage: ParquetTableRuntimeQA <fixture.parquet> <output-directory>"
        case let .failed(message):
            message
        }
    }
}
#endif
