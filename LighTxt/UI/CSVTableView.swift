import AppKit

/// A virtual NSTableView backed directly by a sparse CSV byte index. AppKit
/// creates views only for visible rows; the index stores a hard-capped set of
/// offsets, and individual cells commit exact byte-range piece-table edits.
@MainActor
final class CSVTableView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSEditor, NSPopoverDelegate {
    private static let indexingQueue = DispatchQueue(
        label: "app.lightxt.csv-index",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )
    /// Page decoding must never share the serial full-file indexing queue. A
    /// user can jump to any already-indexed row while a multi-gigabyte scan is
    /// still running, and the table should remain responsive while those
    /// bounded pages are decoded.
    private static let pageDecodingQueue = DispatchQueue(
        label: "app.lightxt.csv-page-decode",
        qos: .userInitiated,
        attributes: .concurrent,
        autoreleaseFrequency: .workItem
    )
    private static let queryQueue = DispatchQueue(
        label: "app.lightxt.csv-query",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )
    private static let summaryQueue = DispatchQueue(
        label: "app.lightxt.csv-column-summary",
        qos: .userInitiated,
        attributes: .concurrent,
        autoreleaseFrequency: .workItem
    )
    private static let mutationQueue = DispatchQueue(
        label: "app.lightxt.csv-mutation-plan",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )
    private static let maximumSelectedRowMutationCount = 50_000
    private static let maximumPresentedColumns = 512
    private static let sampledRowsForColumns = 32
    private static let recordPageSize: Int64 = 32
    private static let maximumCachedRows = 64
    private static let presentationParseLimits = CSVRecordParser.Limits(
        maximumFields: maximumPresentedColumns,
        maximumPreviewBytesPerField: 64 << 10,
        maximumPreviewBytesPerRecord: 256 << 10
    )

    weak var editorDelegate: VirtualTextEditorDelegate? {
        didSet {
            if oldValue !== editorDelegate {
                resetViewQuery()
                reloadDocument()
            }
        }
    }
    var onStatusChange: ((String, Bool) -> Void)?
    var onEditingRegistrationChange: ((Bool) -> Void)?

    private let controls = NSView()
    private let headerCheckbox = NSButton(checkboxWithTitle: "First row is header", target: nil, action: nil)
    private lazy var addButton = QuietButton(
        title: "Add",
        symbolName: "plus",
        minimumHeight: 28,
        target: self,
        action: #selector(showAddMenu(_:))
    )
    private lazy var deleteButton = QuietButton(
        title: "Delete",
        symbolName: "minus",
        minimumHeight: 28,
        target: self,
        action: #selector(showDeleteMenu(_:))
    )
    private lazy var clearFiltersButton = QuietButton(
        title: "Clear Filters",
        symbolName: "line.3.horizontal.decrease.circle.fill",
        minimumHeight: 28,
        target: self,
        action: #selector(clearAllFilters(_:))
    )
    private lazy var actionButtons: NSStackView = {
        let stack = NSStackView(views: [addButton, deleteButton, clearFiltersButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.detachesHiddenViews = true
        return stack
    }()
    private let statusLabel = NSTextField(labelWithString: "Preparing table…")
    private let progressIndicator = NSProgressIndicator()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

    private var snapshot: DocumentSnapshot?
    private var rowIndex: CSVRowIndex?
    private var latestProgress: CSVRowIndex.Progress?
    private var indexingCancellation: CancellationToken?
    private var queryCancellation: CancellationToken?
    private var summaryCancellation: CancellationToken?
    private var mutationCancellation: CancellationToken?
    private var generation: UInt64 = 0
    private var pageDecodeGeneration: UInt64 = 0
    private var queryGeneration: UInt64 = 0
    private var summaryGeneration: UInt64 = 0
    private var mutationGeneration: UInt64 = 0
    private var firstRowIsHeader = false
    private var headerDetectionCompleted = false
    private var columnCount = 0
    private var cachedRecords: [Int64: CSVParsedRecord] = [:]
    private var cacheOrder: [Int64] = []
    /// Record zero supplies stable header titles even after ordinary row cache
    /// eviction. It is bounded to one parsed record and refreshed separately
    /// whenever record zero changes.
    private var firstParsedRecord: CSVParsedRecord?
    private var pendingPages: Set<Int64> = []
    private var displayedRowMap: CSVRowMap?
    private var lastReportedError: String?
    private var pendingScrollTarget: (displayedRow: Int64, record: Int64, column: Int)?
    private var suppressNextControllerReload = false
    private var pendingCommitFailed = false
    private weak var activeEditingField: CSVEditableTextField?
    private var isEditingRegistered = false
    private var focusedDataColumn = 0
    private var activeFilters: [Int: CSVFilterDraft] = [:]
    private var presentedPopover: NSPopover?
    private var activeSort: (column: Int, ascending: Bool)?
    private var isTableOperationInFlight = false
    private var isSettingSortDescriptors = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureControls()
        configureTable()
        configureLayout()
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        indexingCancellation?.cancel()
        queryCancellation?.cancel()
        summaryCancellation?.cancel()
        mutationCancellation?.cancel()
        displayedRowMap?.close()
    }

    func reloadDocument() {
        generation &+= 1
        let currentGeneration = generation
        indexingCancellation?.cancel()
        cancelQueryAndCloseRowMap()
        cancelColumnSummaryRequest()
        cancelCSVMutation()
        presentedPopover?.close()
        presentedPopover = nil
        let cancellation = CancellationToken()
        indexingCancellation = cancellation
        cachedRecords.removeAll(keepingCapacity: true)
        cacheOrder.removeAll(keepingCapacity: true)
        firstParsedRecord = nil
        pendingPages.removeAll(keepingCapacity: true)
        lastReportedError = nil
        latestProgress = nil
        rowIndex = nil
        snapshot = nil
        columnCount = 0
        removeDataColumns()
        tableView.reloadData()

        guard let delegate = editorDelegate else {
            setBusy(false, text: "No CSV document")
            return
        }

        do {
            let captured = try delegate.editorSnapshot()
            let index = try CSVRowIndex(snapshot: captured)
            snapshot = captured
            rowIndex = index
            latestProgress = index.progress
            setBusy(true, text: "Indexing rows…")
            startIndexing(
                snapshot: captured,
                index: index,
                generation: currentGeneration,
                cancellation: cancellation
            )
        } catch {
            report(error)
        }
    }

    func deactivate() {
        guard commitPendingEdit() else { return }
        generation &+= 1
        indexingCancellation?.cancel()
        indexingCancellation = nil
        cancelQueryAndCloseRowMap()
        cancelColumnSummaryRequest()
        cancelCSVMutation()
        presentedPopover?.close()
        presentedPopover = nil
        rowIndex = nil
        snapshot = nil
        latestProgress = nil
        cachedRecords.removeAll(keepingCapacity: false)
        cacheOrder.removeAll(keepingCapacity: false)
        firstParsedRecord = nil
        pendingPages.removeAll(keepingCapacity: true)
        tableView.reloadData()
        setBusy(false, text: "CSV table paused")
    }

    @discardableResult
    func commitPendingEdit() -> Bool {
        pendingCommitFailed = false
        window?.endEditing(for: self)
        // NSWindow ends its field editor synchronously. Remaining registered
        // means validation or model commit did not complete, so callers must
        // block save, close, mode changes, and document-level undo/redo.
        return !pendingCommitFailed && !isEditingRegistered
    }

    func commitEditing() -> Bool { commitPendingEdit() }

    func commitEditing(
        withDelegate delegate: Any?,
        didCommit didCommitSelector: Selector?,
        contextInfo: UnsafeMutableRawPointer?
    ) {
        let committed = commitPendingEdit()
        guard let object = delegate as? NSObject, let selector = didCommitSelector else { return }
        typealias Callback = @convention(c) (
            AnyObject,
            Selector,
            AnyObject,
            Bool,
            UnsafeMutableRawPointer?
        ) -> Void
        let callback = unsafeBitCast(object.method(for: selector), to: Callback.self)
        callback(object, selector, self, committed, contextInfo)
    }

    func commitEditingWithoutPresentingError() throws {
        guard commitPendingEdit() else {
            throw NSError(
                domain: "app.lightxt.csv-editing",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "The active CSV cell could not be committed. Correct the value and try again."
                ]
            )
        }
    }

    func discardEditing() {
        if let field = activeEditingField {
            window?.fieldEditor(false, for: field)?.string = field.originalValue
            field.stringValue = field.originalValue
        }
        pendingCommitFailed = false
        window?.endEditing(for: self)
        finishEditingRegistration()
    }

    func setFirstRowIsHeader(_ enabled: Bool) {
        guard !isTableOperationInFlight else {
            NSSound.beep()
            headerCheckbox.state = firstRowIsHeader ? .on : .off
            return
        }
        firstRowIsHeader = enabled
        headerCheckbox.state = enabled ? .on : .off
        configureColumnsFromAvailableRecords()
        tableView.reloadData()
        requestApplyQuery()
    }

    /// A table cell commit installs a rebased sparse index before notifying
    /// the document session. The window controller consumes this one-shot flag
    /// so the same synchronous callback does not discard that index and start
    /// a duplicate scan from byte zero.
    func consumeDocumentReloadSuppression() -> Bool {
        guard suppressNextControllerReload else { return false }
        suppressNextControllerReload = false
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
        tableView.reloadData()
    }

    private func configureControls() {
        controls.wantsLayer = true
        headerCheckbox.target = self
        headerCheckbox.action = #selector(headerSettingChanged(_:))
        headerCheckbox.controlSize = .regular
        headerCheckbox.font = .systemFont(ofSize: 13)
        headerCheckbox.setAccessibilityHelp("Keep the first CSV row fixed as column headings")

        addButton.toolTip = "Add a row or column"
        addButton.setAccessibilityLabel("Add CSV row or column")
        deleteButton.toolTip = "Delete the selected rows or current column"
        deleteButton.setAccessibilityLabel("Delete CSV row or column")
        clearFiltersButton.toolTip = "Remove every CSV column filter"
        clearFiltersButton.setAccessibilityLabel("Clear all CSV filters")
        clearFiltersButton.isHidden = true

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.maximumNumberOfLines = 1
        statusLabel.setAccessibilityLabel("CSV table status")

        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.doubleValue = 0
        progressIndicator.setAccessibilityLabel("CSV indexing progress")
    }

    private func configureTable() {
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = 28
        tableView.intercellSpacing = NSSize(width: 1, height: 1)
        tableView.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        let headerView = LighTxtCSVHeaderView()
        headerView.menuProvider = { [weak self] tableColumn in
            self?.columnMenu(forTableColumn: tableColumn)
        }
        tableView.headerView = headerView
        tableView.setAccessibilityLabel("CSV table")

        let rowNumber = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row-number"))
        rowNumber.title = "#"
        rowNumber.headerCell = LighTxtCSVHeaderCell(textCell: "#")
        rowNumber.width = 62
        rowNumber.minWidth = 48
        rowNumber.maxWidth = 100
        rowNumber.resizingMask = .userResizingMask
        tableView.addTableColumn(rowNumber)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
    }

    private func configureLayout() {
        [controls, scrollView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        [headerCheckbox, actionButtons, statusLabel, progressIndicator].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            controls.addSubview($0)
        }

        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor),
            controls.topAnchor.constraint(equalTo: topAnchor),
            controls.heightAnchor.constraint(equalToConstant: 48),

            headerCheckbox.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 16),
            headerCheckbox.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            actionButtons.leadingAnchor.constraint(equalTo: headerCheckbox.trailingAnchor, constant: 14),
            actionButtons.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: actionButtons.trailingAnchor, constant: 14),
            statusLabel.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: progressIndicator.leadingAnchor, constant: -14),
            progressIndicator.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -18),
            progressIndicator.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            progressIndicator.widthAnchor.constraint(equalToConstant: 150),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: controls.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func applyAppearance() {
        let appearance = effectiveAppearance
        let background = LighTxtTheme.resolved(LighTxtTheme.editorBackground, for: appearance)
        let gutter = LighTxtTheme.resolved(LighTxtTheme.gutterBackground, for: appearance)
        controls.layer?.backgroundColor = gutter.cgColor
        statusLabel.textColor = LighTxtTheme.resolved(LighTxtTheme.secondaryText, for: appearance)
        scrollView.backgroundColor = background
        tableView.backgroundColor = background
        tableView.gridColor = LighTxtTheme.resolved(LighTxtTheme.separator, for: appearance)
        applyColumnHeaderAppearance()
    }

    private func startIndexing(
        snapshot: DocumentSnapshot,
        index: CSVRowIndex,
        generation: UInt64,
        cancellation: CancellationToken
    ) {
        let sampleRowCount = Self.sampledRowsForColumns
        let parseLimits = Self.presentationParseLimits
        Self.indexingQueue.async { [weak self] in
            do {
                // Resolve a bounded sample first so useful headers and rows
                // appear immediately; the remainder continues in the same job.
                var sample: [CSVParsedRecord] = []
                let locations = try index.recordLocations(
                    startingAt: 0,
                    limit: sampleRowCount,
                    cancellation: { cancellation.isCancelled }
                )
                for location in locations {
                    if cancellation.isCancelled { throw CancellationError() }
                    sample.append(try CSVRecordParser.parse(
                        snapshot: snapshot,
                        location: location,
                        limits: parseLimits,
                        cancellation: { cancellation.isCancelled }
                    ))
                }
                let sampleProgress = index.progress
                DispatchQueue.main.async { [weak self] in
                    self?.receiveInitialSample(
                        sample,
                        progress: sampleProgress,
                        generation: generation,
                        cancellation: cancellation
                    )
                }

                var lastUpdate = ContinuousClock.now
                let result = try index.scanToEnd(
                    cancellation: { cancellation.isCancelled },
                    progressHandler: { progress in
                        let now = ContinuousClock.now
                        guard progress.isComplete || now - lastUpdate >= .milliseconds(140) else { return }
                        lastUpdate = now
                        DispatchQueue.main.async { [weak self] in
                            self?.receiveProgress(
                                progress,
                                generation: generation,
                                cancellation: cancellation
                            )
                        }
                    }
                )
                if result.stopReason == .cancelled { return }
            } catch is CancellationError {
                return
            } catch CSVRowIndex.IndexError.cancelled {
                return
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard self?.generation == generation else { return }
                    self?.report(error)
                }
            }
        }
    }

    private func resumeIndexing(
        index: CSVRowIndex,
        generation: UInt64,
        cancellation: CancellationToken
    ) {
        Self.indexingQueue.async { [weak self] in
            do {
                var lastUpdate = ContinuousClock.now
                let result = try index.scanToEnd(
                    cancellation: { cancellation.isCancelled },
                    progressHandler: { progress in
                        let now = ContinuousClock.now
                        guard progress.isComplete || now - lastUpdate >= .milliseconds(140) else { return }
                        lastUpdate = now
                        DispatchQueue.main.async { [weak self] in
                            self?.receiveProgress(
                                progress,
                                generation: generation,
                                cancellation: cancellation
                            )
                        }
                    }
                )
                if result.stopReason == .cancelled { return }
            } catch is CancellationError {
                return
            } catch CSVRowIndex.IndexError.cancelled {
                return
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard self?.generation == generation else { return }
                    self?.report(error)
                }
            }
        }
    }

    private func receiveInitialSample(
        _ sample: [CSVParsedRecord],
        progress: CSVRowIndex.Progress,
        generation: UInt64,
        cancellation: CancellationToken
    ) {
        guard self.generation == generation, !cancellation.isCancelled else { return }
        latestProgress = progress
        firstParsedRecord = sample.first
        for (record, parsed) in sample.enumerated() {
            storeCached(parsed, for: Int64(record))
        }
        if !headerDetectionCompleted, let first = sample.first {
            firstRowIsHeader = CSVHeaderDetector.isLikelyHeader(
                first: first,
                second: sample.count > 1 ? sample[1] : nil
            )
            headerDetectionCompleted = true
            headerCheckbox.state = firstRowIsHeader ? .on : .off
        }
        configureColumns(sample: sample)
        tableView.reloadData()
        restorePendingScrollIfPossible()
        if progress.isComplete,
           (!activeFilters.isEmpty || activeSort != nil),
           queryCancellation == nil {
            requestApplyQuery()
        }
    }

    private func receiveProgress(
        _ progress: CSVRowIndex.Progress,
        generation: UInt64,
        cancellation: CancellationToken
    ) {
        guard self.generation == generation, !cancellation.isCancelled else { return }
        latestProgress = progress
        let rows = progress.totalRecordCount ?? progress.knownRecordCount
        if progress.isComplete {
            setBusy(false, text: "\(rows.formatted()) rows")
        } else {
            setBusy(
                true,
                text: "Indexing \(Int(progress.fractionCompleted * 100))%  ·  \(rows.formatted()) rows"
            )
        }
        tableView.reloadData()
        restorePendingScrollIfPossible()
        if progress.isComplete,
           (!activeFilters.isEmpty || activeSort != nil),
           queryCancellation == nil {
            requestApplyQuery()
        }
    }

    private func configureColumnsFromAvailableRecords() {
        var sample: [CSVParsedRecord] = []
        sample.reserveCapacity(Self.sampledRowsForColumns)
        if let firstParsedRecord { sample.append(firstParsedRecord) }
        sample.append(contentsOf: cacheOrder.sorted().lazy
            .filter { $0 != 0 }
            .prefix(max(0, Self.sampledRowsForColumns - sample.count))
            .compactMap { self.cachedRecords[$0] })
        configureColumns(sample: sample)
    }

    private func configureColumns<S: Sequence>(sample: S) where S.Element == CSVParsedRecord {
        let records = Array(sample)
        let detectedCount = records.map(\.fields.count).max() ?? 0
        let desired = min(Self.maximumPresentedColumns, detectedCount)
        guard desired != columnCount || tableView.tableColumns.count != desired + 1 else {
            updateColumnTitles(from: firstRowIsHeader ? firstParsedRecord : records.first)
            return
        }

        removeDataColumns()
        columnCount = desired
        let header = firstRowIsHeader ? firstParsedRecord : records.first
        for column in 0..<desired {
            let tableColumn = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier("csv-column-\(column)")
            )
            tableColumn.title = columnTitle(column, header: header)
            let headerCell = LighTxtCSVHeaderCell(textCell: tableColumn.title)
            headerCell.isFiltered = activeFilters[column] != nil
            tableColumn.headerCell = headerCell
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(
                key: tableColumn.identifier.rawValue,
                ascending: true
            )
            tableColumn.width = suggestedWidth(column, sample: records)
            tableColumn.minWidth = 72
            tableColumn.maxWidth = 800
            tableColumn.resizingMask = .userResizingMask
            tableView.addTableColumn(tableColumn)
        }
        if detectedCount >= Self.maximumPresentedColumns {
            statusLabel.toolTip = "Showing the first \(Self.maximumPresentedColumns) columns to keep the table responsive. Every byte remains available in Edit mode."
        } else {
            statusLabel.toolTip = nil
        }
        applyColumnHeaderAppearance()
    }

    private func updateColumnTitles(from header: CSVParsedRecord?) {
        for column in 0..<columnCount {
            tableView.tableColumns[column + 1].title = columnTitle(column, header: header)
            (tableView.tableColumns[column + 1].headerCell as? LighTxtCSVHeaderCell)?.isFiltered =
                activeFilters[column] != nil
        }
        applyColumnHeaderAppearance()
    }

    private func applyColumnHeaderAppearance() {
        let color = LighTxtTheme.resolved(LighTxtTheme.primaryText, for: effectiveAppearance)
        for column in tableView.tableColumns {
            let title = column.title
            column.headerCell.font = .systemFont(ofSize: 12, weight: .medium)
            column.headerCell.textColor = color
            column.headerCell.attributedStringValue = NSAttributedString(
                string: title,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: color,
                ]
            )
        }
        tableView.headerView?.needsDisplay = true
    }

    private func columnTitle(_ column: Int, header: CSVParsedRecord?) -> String {
        if firstRowIsHeader,
           let value = header?.fields[safe: column]?.value,
           !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return value
        }
        return spreadsheetColumnName(column)
    }

    private func suggestedWidth(_ column: Int, sample: [CSVParsedRecord]) -> CGFloat {
        let longest = sample.compactMap { $0.fields[safe: column]?.value.count }.max() ?? 8
        return min(360, max(110, CGFloat(min(longest, 42) * 7 + 26)))
    }

    private func removeDataColumns() {
        for column in tableView.tableColumns.dropFirst() { tableView.removeTableColumn(column) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if let displayedRowMap { return Int(clamping: displayedRowMap.rowCount) }
        let records = latestProgress?.totalRecordCount ?? latestProgress?.knownRecordCount ?? 0
        let visible = max(0, records - (firstRowIsHeader ? 1 : 0))
        return Int(clamping: visible)
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let tableColumn else { return nil }
        guard let record = try? sourceRecord(forDisplayedRow: Int64(row)) else { return nil }
        if tableColumn.identifier.rawValue == "row-number" {
            let cell = reusableLabel(identifier: "csv-row-number")
            cell.stringValue = (record + 1).formatted()
            cell.alignment = .right
            cell.textColor = LighTxtTheme.resolved(LighTxtTheme.secondaryText, for: effectiveAppearance)
            return cell
        }

        guard let column = Int(tableColumn.identifier.rawValue.dropFirst("csv-column-".count)) else {
            return nil
        }
        let cell = reusableEditableField(identifier: "csv-value")
        cell.displayedRow = Int64(row)
        cell.record = record
        cell.column = column
        cell.originalValue = ""
        cell.originalFieldCount = 0
        cell.byteRange = nil
        cell.stringValue = ""
        cell.placeholderString = nil
        cell.isEditable = false
        cell.toolTip = nil

        if let parsed = recordForDisplay(record) {
            // An absent field is intentionally editable: committing it appends
            // the required delimiters to this record without touching any
            // other bytes.
            cell.isEditable = !isTableOperationInFlight
            cell.originalFieldCount = parsed.fields.count
            if let field = parsed.fields[safe: column] {
                cell.stringValue = field.value
                cell.originalValue = field.value
                cell.byteRange = field.byteRange
                cell.isEditable = !field.wasTruncated && !isTableOperationInFlight
                if field.wasTruncated {
                    cell.toolTip = "This field is larger than the table preview limit. Edit it safely in text mode."
                }
            }
        } else {
            cell.placeholderString = "Loading…"
            cell.toolTip = "This bounded row page is loading in the background."
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard tableView.clickedColumn > 0 else { return }
        focusedDataColumn = tableView.clickedColumn - 1
    }

    func tableView(
        _ tableView: NSTableView,
        sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]
    ) {
        guard !isSettingSortDescriptors else { return }
        guard canStartDatasetOperation else {
            restoreSortDescriptorChrome()
            NSSound.beep()
            return
        }
        guard let descriptor = tableView.sortDescriptors.first,
              let column = dataColumn(fromSortDescriptor: descriptor) else {
            activeSort = nil
            requestSort(column: nil, ascending: true)
            return
        }
        if let old = oldDescriptors.first,
           let oldColumn = dataColumn(fromSortDescriptor: old),
           oldColumn == column,
           old.ascending == false,
           descriptor.ascending {
            activeSort = nil
            isSettingSortDescriptors = true
            tableView.sortDescriptors = []
            isSettingSortDescriptors = false
            requestSort(column: nil, ascending: true)
            return
        }
        focusedDataColumn = column
        requestSort(column: column, ascending: descriptor.ascending)
    }

    private func reusableLabel(identifier: String) -> NSTextField {
        let id = NSUserInterfaceItemIdentifier(identifier)
        if let existing = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField {
            return existing
        }
        let field = NSTextField(labelWithString: "")
        field.identifier = id
        field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private func reusableEditableField(identifier: String) -> CSVEditableTextField {
        let id = NSUserInterfaceItemIdentifier(identifier)
        if let existing = tableView.makeView(withIdentifier: id, owner: self) as? CSVEditableTextField {
            return existing
        }
        let field = CSVEditableTextField(string: "")
        field.identifier = id
        field.delegate = self
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .exterior
        field.font = .systemFont(ofSize: 13)
        field.lineBreakMode = .byTruncatingTail
        field.usesSingleLineMode = true
        field.cell?.wraps = false
        field.setAccessibilityRole(.textField)
        return field
    }

    private func sourceRecord(forDisplayedRow displayedRow: Int64) throws -> Int64 {
        if let displayedRowMap { return try displayedRowMap.record(at: displayedRow) }
        return displayedRow + (firstRowIsHeader ? 1 : 0)
    }

    private func sourceRecords(forDisplayedRows rows: IndexSet) throws -> [Int64] {
        if let displayedRowMap {
            var records: [Int64] = []
            records.reserveCapacity(rows.count)
            for contiguous in rows.rangeView {
                var lower = Int64(contiguous.lowerBound)
                let upper = Int64(contiguous.upperBound)
                while lower < upper {
                    let pageUpper = min(upper, lower + 4_096)
                    records.append(contentsOf: try displayedRowMap.records(in: lower..<pageUpper))
                    lower = pageUpper
                }
            }
            return records
        }
        let offset: Int64 = firstRowIsHeader ? 1 : 0
        return rows.map { Int64($0) + offset }
    }

    private func recordForDisplay(_ record: Int64) -> CSVParsedRecord? {
        if let cached = cachedRecords[record] {
            touchCache(record)
            return cached
        }
        guard let snapshot, let rowIndex, let indexingCancellation else { return nil }
        let usesProjection = displayedRowMap != nil
        let pageStart = usesProjection ? record : (record / Self.recordPageSize) * Self.recordPageSize
        schedulePageDecode(
            pageStart: pageStart,
            pageRecordCount: usesProjection ? 1 : Int(Self.recordPageSize),
            snapshot: snapshot,
            rowIndex: rowIndex,
            generation: generation,
            pageGeneration: pageDecodeGeneration,
            cancellation: indexingCancellation
        )
        return nil
    }

    private func schedulePageDecode(
        pageStart: Int64,
        pageRecordCount: Int,
        snapshot: DocumentSnapshot,
        rowIndex: CSVRowIndex,
        generation: UInt64,
        pageGeneration: UInt64,
        cancellation: CancellationToken
    ) {
        guard pendingPages.insert(pageStart).inserted else { return }
        let limits = Self.presentationParseLimits
        Self.pageDecodingQueue.async { [weak self] in
            do {
                let locations = try rowIndex.recordLocations(
                    startingAt: pageStart,
                    limit: pageRecordCount,
                    cancellation: { cancellation.isCancelled }
                )
                var parsedPage: [(Int64, CSVParsedRecord)] = []
                parsedPage.reserveCapacity(locations.count)
                for location in locations {
                    parsedPage.append((
                        location.record,
                        try CSVRecordParser.parse(
                            snapshot: snapshot,
                            location: location,
                            limits: limits,
                            cancellation: { cancellation.isCancelled }
                        )
                    ))
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard self.generation == generation,
                          self.pageDecodeGeneration == pageGeneration else { return }
                    self.pendingPages.remove(pageStart)
                    for (row, parsed) in parsedPage { self.storeCached(parsed, for: row) }
                    self.reloadVisibleRows(
                        containingSourceRecords: Set(parsedPage.map(\.0))
                    )
                }
            } catch is CancellationError {
                return
            } catch CSVRowIndex.IndexError.cancelled {
                return
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    guard self.generation == generation,
                          self.pageDecodeGeneration == pageGeneration else { return }
                    self.pendingPages.remove(pageStart)
                    self.reportOnce(error)
                }
            }
        }
    }

    private func reloadVisibleRows(containingSourceRecords records: Set<Int64>) {
        guard !records.isEmpty else { return }
        let visibleRows = tableView.rows(in: tableView.visibleRect)
        guard visibleRows.location != NSNotFound, visibleRows.length > 0 else { return }
        var rows = IndexSet()
        for displayedRow in visibleRows.location..<(visibleRows.location + visibleRows.length) {
            if let source = try? sourceRecord(forDisplayedRow: Int64(displayedRow)),
               records.contains(source) {
                rows.insert(displayedRow)
            }
        }
        guard !rows.isEmpty else { return }
        var columns = IndexSet()
        if tableView.tableColumns.count > 1 {
            for column in 1..<tableView.tableColumns.count
            where tableView.rect(ofColumn: column).intersects(tableView.visibleRect) {
                columns.insert(column)
            }
        }
        guard !columns.isEmpty else { return }
        tableView.reloadData(forRowIndexes: rows, columnIndexes: columns)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        pendingCommitFailed = false
        guard let field = notification.object as? CSVEditableTextField else { return }
        activeEditingField = field
        guard field.stringValue != field.originalValue else {
            finishEditingRegistration()
            return
        }
        guard let delegate = editorDelegate, let rowIndex else {
            pendingCommitFailed = true
            return
        }
        do {
            let replacement = CSVRecordParser.encodedField(field.stringValue)
            let editRange: Range<Int64>
            let replacementBytes: Data
            if let existing = field.byteRange {
                editRange = existing
                replacementBytes = replacement
            } else {
                guard let location = try rowIndex.recordLocation(forRecord: field.record) else {
                    throw CSVRowIndex.IndexError.inconsistentCheckpointData
                }
                let missingSeparators = max(1, field.column - field.originalFieldCount + 1)
                var appended = Data(repeating: 0x2C, count: missingSeparators)
                appended.append(replacement)
                editRange = location.contentRange.upperBound..<location.contentRange.upperBound
                replacementBytes = appended
            }

            try delegate.editorReplaceBytes(in: editRange, with: replacementBytes)
            pendingScrollTarget = (field.displayedRow, field.record, field.column)
            do {
                let updatedSnapshot = try delegate.editorSnapshot()
                let rebased = try rowIndex.rebased(
                    onto: updatedSnapshot,
                    replacing: editRange,
                    insertedByteCount: Int64(replacementBytes.count)
                )
                installRebasedIndex(
                    rebased,
                    snapshot: updatedSnapshot,
                    editedRecord: field.record
                )
            } catch {
                // The edit is already in the piece table. Fall back to one
                // ordinary rebuild rather than withholding the document
                // change notification or leaving stale table coordinates.
                // Transfer NSEditor's registration-only dirty state to the
                // session change count before publishing documentChanged.
                // Otherwise the controller sees `isDocumentEdited == true`,
                // skips changeDone, and unregistering could make the document
                // incorrectly clean even though the piece table changed.
                finishEditingRegistration()
                suppressNextControllerReload = true
                delegate.editorDidCommitEdit(
                    replaced: editRange,
                    insertedByteCount: Int64(replacementBytes.count)
                )
                reloadDocument()
                return
            }
            // End NSEditor registration before publishing the durable piece-
            // table edit so NSDocument records a real change-count entry.
            finishEditingRegistration()
            suppressNextControllerReload = true
            delegate.editorDidCommitEdit(
                replaced: editRange,
                insertedByteCount: Int64(replacementBytes.count)
            )
            // If this table is hosted without the window controller (for
            // example a focused harness), do not let the one-shot suppression
            // leak into a later unrelated document change.
            DispatchQueue.main.async { [weak self] in
                self?.suppressNextControllerReload = false
            }
        } catch {
            pendingCommitFailed = true
            report(error)
            NSSound.beep()
        }
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? CSVEditableTextField else { return }
        activeEditingField = field
        guard !isEditingRegistered else { return }
        isEditingRegistered = true
        onEditingRegistrationChange?(true)
    }

    private func finishEditingRegistration() {
        activeEditingField = nil
        guard isEditingRegistered else { return }
        isEditingRegistered = false
        onEditingRegistrationChange?(false)
    }

    private func installRebasedIndex(
        _ index: CSVRowIndex,
        snapshot: DocumentSnapshot,
        editedRecord: Int64
    ) {
        let needsProjectionRefresh = !activeFilters.isEmpty || activeSort != nil
        if needsProjectionRefresh {
            // Never expose a row map computed from the pre-edit snapshot. The
            // replacement query below installs a new map atomically after the
            // durable cell edit has finished its current main-actor turn.
            cancelQueryAndCloseRowMap()
        }
        generation &+= 1
        let currentGeneration = generation
        indexingCancellation?.cancel()
        let cancellation = CancellationToken()
        indexingCancellation = cancellation
        self.snapshot = snapshot
        rowIndex = index
        latestProgress = index.progress
        cachedRecords.removeAll(keepingCapacity: true)
        cacheOrder.removeAll(keepingCapacity: true)
        if editedRecord == 0 { firstParsedRecord = nil }
        pendingPages.removeAll(keepingCapacity: true)
        lastReportedError = nil

        let rows = index.progress.totalRecordCount ?? index.progress.knownRecordCount
        if index.progress.isComplete {
            setBusy(false, text: "\(rows.formatted()) rows")
        } else {
            setBusy(
                true,
                text: "Indexing \(Int(index.progress.fractionCompleted * 100))%  ·  \(rows.formatted()) rows"
            )
            resumeIndexing(
                index: index,
                generation: currentGeneration,
                cancellation: cancellation
            )
        }
        tableView.reloadData()
        let pageStart = (editedRecord / Self.recordPageSize) * Self.recordPageSize
        schedulePageDecode(
            pageStart: pageStart,
            pageRecordCount: Int(Self.recordPageSize),
            snapshot: snapshot,
            rowIndex: index,
            generation: currentGeneration,
            pageGeneration: pageDecodeGeneration,
            cancellation: cancellation
        )
        restorePendingScrollIfPossible()
        if needsProjectionRefresh {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.requestApplyQuery()
            }
        }
    }

    @objc private func headerSettingChanged(_ sender: NSButton) {
        setFirstRowIsHeader(sender.state == .on)
    }

    @objc private func showAddMenu(_ sender: NSButton) {
        let menu = NSMenu(title: "Add")
        menu.addItem(menuItem("Row Above", symbol: "arrow.up.to.line.compact", action: #selector(addRowAbove(_:))))
        menu.addItem(menuItem("Row Below", symbol: "arrow.down.to.line.compact", action: #selector(addRowBelow(_:))))
        menu.addItem(.separator())
        let before = menuItem("Column Before", symbol: "arrow.left.to.line.compact", action: #selector(addColumnBefore(_:)))
        before.isEnabled = snapshot?.byteCount == 0 || focusedDataColumn < Self.maximumPresentedColumns
        menu.addItem(before)
        let after = menuItem("Column After", symbol: "arrow.right.to.line.compact", action: #selector(addColumnAfter(_:)))
        after.isEnabled = snapshot?.byteCount == 0 || focusedDataColumn + 1 < Self.maximumPresentedColumns
        menu.addItem(after)
        present(menu, from: sender)
    }

    @objc private func showDeleteMenu(_ sender: NSButton) {
        let selectedRows = selectedVisibleRows()
        let rowTitle = selectedRows.count > 1
            ? "Delete \(selectedRows.count.formatted()) Rows"
            : "Delete Row"
        let menu = NSMenu(title: "Delete")
        let deleteRows = menuItem(rowTitle, symbol: "minus.rectangle", action: #selector(deleteSelectedRows(_:)))
        deleteRows.isEnabled = !selectedRows.isEmpty
        menu.addItem(deleteRows)
        let columnName = currentColumnTitle
        let deleteColumn = menuItem(
            "Delete Column \u{201c}\(columnName)\u{201d}",
            symbol: "rectangle.split.1x2",
            action: #selector(deleteCurrentColumn(_:))
        )
        deleteColumn.isEnabled = columnCount > 0
        menu.addItem(deleteColumn)
        present(menu, from: sender)
    }

    private func columnMenu(forTableColumn tableColumn: Int) -> NSMenu? {
        guard tableColumn > 0, tableColumn <= columnCount else { return nil }
        let column = tableColumn - 1
        focusedDataColumn = column
        let title = tableView.tableColumns[tableColumn].title
        let menu = NSMenu(title: title)

        let ascending = menuItem("Sort Ascending", symbol: "arrow.up", action: #selector(sortAscending(_:)))
        ascending.representedObject = column
        ascending.state = activeSort?.column == column && activeSort?.ascending == true ? .on : .off
        ascending.isEnabled = canStartDatasetOperation
        menu.addItem(ascending)

        let descending = menuItem("Sort Descending", symbol: "arrow.down", action: #selector(sortDescending(_:)))
        descending.representedObject = column
        descending.state = activeSort?.column == column && activeSort?.ascending == false ? .on : .off
        descending.isEnabled = canStartDatasetOperation
        menu.addItem(descending)

        let clearSort = menuItem("Clear Sort", symbol: "arrow.up.arrow.down", action: #selector(clearSort(_:)))
        clearSort.isEnabled = activeSort != nil
        menu.addItem(clearSort)
        menu.addItem(.separator())

        let filter = menuItem("Filter…", symbol: "line.3.horizontal.decrease", action: #selector(showColumnFilter(_:)))
        filter.representedObject = column
        filter.isEnabled = canStartDatasetOperation
        menu.addItem(filter)
        if activeFilters[column] != nil {
            let clearFilter = menuItem("Clear Filter", symbol: "xmark", action: #selector(clearColumnFilter(_:)))
            clearFilter.representedObject = column
            menu.addItem(clearFilter)
        }

        let summary = menuItem("Column Summary…", symbol: "chart.bar.xaxis", action: #selector(showColumnSummary(_:)))
        summary.representedObject = column
        summary.isEnabled = canStartDatasetOperation
        menu.addItem(summary)
        menu.addItem(.separator())

        let before = menuItem("Add Column Before", symbol: "arrow.left.to.line.compact", action: #selector(addColumnBefore(_:)))
        before.representedObject = column
        before.isEnabled = canStartDatasetOperation
        menu.addItem(before)
        let after = menuItem("Add Column After", symbol: "arrow.right.to.line.compact", action: #selector(addColumnAfter(_:)))
        after.representedObject = column
        after.isEnabled = canStartDatasetOperation
            && column + 1 < Self.maximumPresentedColumns
        menu.addItem(after)
        let delete = menuItem("Delete Column…", symbol: "trash", action: #selector(deleteCurrentColumn(_:)))
        delete.representedObject = column
        delete.isEnabled = canStartDatasetOperation
        menu.addItem(delete)
        return menu
    }

    private func menuItem(_ title: String, symbol: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    private func present(_ menu: NSMenu, from button: NSButton) {
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: 0, y: button.bounds.minY - 4),
            in: button
        )
    }

    private var currentColumnTitle: String {
        guard columnCount > 0 else { return "" }
        let column = min(max(0, focusedDataColumn), columnCount - 1)
        return tableView.tableColumns[column + 1].title
    }

    private func selectedVisibleRows() -> IndexSet {
        if !tableView.selectedRowIndexes.isEmpty { return tableView.selectedRowIndexes }
        guard tableView.clickedRow >= 0 else { return [] }
        return IndexSet(integer: tableView.clickedRow)
    }

    private func representedColumn(_ sender: Any?) -> Int {
        if let item = sender as? NSMenuItem, let column = item.representedObject as? Int {
            return min(max(0, column), max(0, columnCount - 1))
        }
        return min(max(0, focusedDataColumn), max(0, columnCount - 1))
    }

    @objc private func sortAscending(_ sender: Any?) {
        guard guardDatasetOperationAvailable() else { return }
        setSort(column: representedColumn(sender), ascending: true)
    }

    @objc private func sortDescending(_ sender: Any?) {
        guard guardDatasetOperationAvailable() else { return }
        setSort(column: representedColumn(sender), ascending: false)
    }

    @objc private func clearSort(_ sender: Any?) {
        activeSort = nil
        isSettingSortDescriptors = true
        tableView.sortDescriptors = []
        isSettingSortDescriptors = false
        requestSort(column: nil, ascending: true)
    }

    private func setSort(column: Int, ascending: Bool) {
        guard canStartDatasetOperation else { return }
        guard column >= 0, column < columnCount else { return }
        focusedDataColumn = column
        let descriptor = NSSortDescriptor(
            key: tableView.tableColumns[column + 1].identifier.rawValue,
            ascending: ascending
        )
        activeSort = (column, ascending)
        isSettingSortDescriptors = true
        tableView.sortDescriptors = [descriptor]
        isSettingSortDescriptors = false
        requestSort(column: column, ascending: ascending)
    }

    private var canStartDatasetOperation: Bool {
        latestProgress?.isComplete == true && !isTableOperationInFlight
    }

    @discardableResult
    private func guardDatasetOperationAvailable() -> Bool {
        guard canStartDatasetOperation else {
            NSSound.beep()
            return false
        }
        return true
    }

    private func restoreSortDescriptorChrome() {
        isSettingSortDescriptors = true
        if let activeSort,
           activeSort.column >= 0,
           activeSort.column < columnCount {
            tableView.sortDescriptors = [NSSortDescriptor(
                key: tableView.tableColumns[activeSort.column + 1].identifier.rawValue,
                ascending: activeSort.ascending
            )]
        } else {
            tableView.sortDescriptors = []
        }
        isSettingSortDescriptors = false
    }

    private func dataColumn(fromSortDescriptor descriptor: NSSortDescriptor) -> Int? {
        guard let key = descriptor.key,
              key.hasPrefix("csv-column-"),
              let column = Int(key.dropFirst("csv-column-".count)),
              column >= 0,
              column < columnCount else { return nil }
        return column
    }

    @objc private func addRowAbove(_ sender: Any?) {
        guard guardDatasetOperationAvailable() else { return }
        do {
            let sourceRecord: Int64
            if let selected = selectedVisibleRows().first {
                sourceRecord = try self.sourceRecord(forDisplayedRow: Int64(selected))
            } else {
                sourceRecord = firstRowIsHeader ? 1 : 0
            }
            requestAddRow(atSourceRecord: sourceRecord)
        } catch {
            report(error)
        }
    }

    @objc private func addRowBelow(_ sender: Any?) {
        guard guardDatasetOperationAvailable() else { return }
        do {
            let sourceRecord: Int64
            if let selected = selectedVisibleRows().last {
                sourceRecord = try self.sourceRecord(forDisplayedRow: Int64(selected)) + 1
            } else {
                sourceRecord = latestProgress?.totalRecordCount
                    ?? latestProgress?.knownRecordCount
                    ?? (firstRowIsHeader ? 1 : 0)
            }
            requestAddRow(atSourceRecord: sourceRecord)
        } catch {
            report(error)
        }
    }

    @objc private func addColumnBefore(_ sender: Any?) {
        guard guardDatasetOperationAvailable() else { return }
        requestAddColumn(at: representedColumn(sender))
    }

    @objc private func addColumnAfter(_ sender: Any?) {
        guard guardDatasetOperationAvailable() else { return }
        requestAddColumn(at: representedColumn(sender) + 1)
    }

    @objc private func deleteSelectedRows(_ sender: Any?) {
        guard guardDatasetOperationAvailable() else { return }
        let rows = selectedVisibleRows()
        guard !rows.isEmpty else { return }
        guard rows.count <= Self.maximumSelectedRowMutationCount else {
            let message = "Row deletion is limited to \(Self.maximumSelectedRowMutationCount.formatted()) selected rows at a time."
            setBusy(false, text: message)
            statusLabel.setAccessibilityValue(message)
            NSSound.beep()
            return
        }
        let records: [Int64]
        do {
            records = try sourceRecords(forDisplayedRows: rows)
        } catch {
            report(error)
            return
        }
        let perform: () -> Void = { [weak self] in
            self?.requestDeleteRows(sourceRecords: records)
        }
        guard rows.count > 1 else {
            perform()
            return
        }
        confirmDestructiveChange(
            title: "Delete \(rows.count.formatted()) rows?",
            information: "The rows will be removed from the CSV. You can undo this change.",
            buttonTitle: "Delete Rows",
            completion: perform
        )
    }

    @objc private func deleteCurrentColumn(_ sender: Any?) {
        guard guardDatasetOperationAvailable() else { return }
        guard columnCount > 0 else { return }
        let column = representedColumn(sender)
        let title = tableView.tableColumns[column + 1].title
        confirmDestructiveChange(
            title: "Delete column \u{201c}\(title)\u{201d}?",
            information: "This removes the column from every row. The change is applied transactionally and can be undone.",
            buttonTitle: "Delete Column"
        ) { [weak self] in
            self?.requestDeleteColumn(column)
        }
    }

    private func confirmDestructiveChange(
        title: String,
        information: String,
        buttonTitle: String,
        completion: @escaping () -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = information
        alert.alertStyle = .warning
        alert.addButton(withTitle: buttonTitle).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        if let window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn { completion() }
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            completion()
        }
    }

    @objc private func showColumnFilter(_ sender: Any?) {
        guard guardDatasetOperationAvailable() else { return }
        guard columnCount > 0 else { return }
        let column = representedColumn(sender)
        let title = tableView.tableColumns[column + 1].title
        let controller = CSVFilterPopoverViewController(
            columnTitle: title,
            filter: activeFilters[column]
        )
        controller.onApply = { [weak self, weak controller] filter in
            guard let self else { return }
            self.activeFilters[column] = filter
            self.dismissPopover(containing: controller)
            self.updateFilterChrome()
            self.requestApplyQuery()
        }
        controller.onClear = { [weak self, weak controller] in
            guard let self else { return }
            self.activeFilters.removeValue(forKey: column)
            self.dismissPopover(containing: controller)
            self.updateFilterChrome()
            self.requestApplyQuery()
        }
        presentPopover(controller, forDataColumn: column)
    }

    @objc private func clearColumnFilter(_ sender: Any?) {
        activeFilters.removeValue(forKey: representedColumn(sender))
        updateFilterChrome()
        requestApplyQuery()
    }

    @objc private func clearAllFilters(_ sender: Any?) {
        guard !activeFilters.isEmpty else { return }
        activeFilters.removeAll(keepingCapacity: true)
        updateFilterChrome()
        requestApplyQuery()
    }

    private func updateFilterChrome() {
        clearFiltersButton.isHidden = activeFilters.isEmpty
        clearFiltersButton.title = activeFilters.count == 1
            ? "Clear Filter"
            : "Clear Filters (\(activeFilters.count))"
        for column in 0..<columnCount {
            (tableView.tableColumns[column + 1].headerCell as? LighTxtCSVHeaderCell)?.isFiltered =
                activeFilters[column] != nil
        }
        tableView.headerView?.needsDisplay = true
    }

    @objc private func showColumnSummary(_ sender: Any?) {
        guard guardDatasetOperationAvailable() else { return }
        guard columnCount > 0 else { return }
        let column = representedColumn(sender)
        let title = tableView.tableColumns[column + 1].title
        let controller = CSVColumnSummaryPopoverViewController(columnTitle: title)
        presentPopover(controller, forDataColumn: column)
        requestColumnSummary(
            column: column,
            progress: { [weak self, weak controller] progress in
                guard let self,
                      let controller,
                      self.presentedPopover?.contentViewController === controller else { return }
                controller.show(progress: progress)
            }
        ) { [weak self, weak controller] result in
            guard let self, let controller, self.presentedPopover?.contentViewController === controller else {
                return
            }
            switch result {
            case let .success(summary): controller.show(summary)
            case let .failure(error): controller.show(error: error)
            }
        }
    }

    private func presentPopover(_ controller: NSViewController, forDataColumn column: Int) {
        presentedPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = controller
        presentedPopover = popover
        guard let header = tableView.headerView else { return }
        let tableColumn = min(max(1, column + 1), tableView.tableColumns.count - 1)
        popover.show(
            relativeTo: header.headerRect(ofColumn: tableColumn),
            of: header,
            preferredEdge: .maxY
        )
    }

    private func dismissPopover(containing controller: NSViewController?) {
        guard let controller, presentedPopover?.contentViewController === controller else { return }
        presentedPopover?.close()
        presentedPopover = nil
    }

    func popoverDidClose(_ notification: Notification) {
        if notification.object as? NSPopover === presentedPopover {
            presentedPopover = nil
            cancelColumnSummaryRequest()
        }
    }

    // MARK: - Query and mutation adapters

    /// Core integration lives behind these methods so the native AppKit state
    /// machine stays independent from the bounded, file-backed algorithms.
    private func requestSort(column: Int?, ascending: Bool) {
        activeSort = column.map { ($0, ascending) }
        requestApplyQuery()
    }

    private func requestApplyQuery() {
        guard commitPendingEdit() else { return }
        queryGeneration &+= 1
        let currentQueryGeneration = queryGeneration
        queryCancellation?.cancel()
        queryCancellation = nil

        let hasProjection = !activeFilters.isEmpty || activeSort != nil
        guard hasProjection else {
            let oldMap = displayedRowMap
            displayedRowMap = nil
            oldMap?.close()
            pageDecodeGeneration &+= 1
            pendingPages.removeAll(keepingCapacity: true)
            isTableOperationInFlight = false
            tableView.deselectAll(nil)
            tableView.reloadData()
            restoreTableStatus()
            return
        }
        guard latestProgress?.isComplete == true else {
            let rows = latestProgress?.knownRecordCount ?? 0
            setOperationBusy(
                text: "Preparing \(projectionVerb.lowercased())…  ·  \(rows.formatted()) rows indexed",
                fraction: latestProgress?.fractionCompleted
            )
            return
        }
        guard let snapshot, let rowIndex else { return }

        let filters = activeFilters.keys.sorted().compactMap { column -> CSVColumnFilter? in
            guard let draft = activeFilters[column] else { return nil }
            return CSVColumnFilter(column: column, predicate: predicate(for: draft))
        }
        let sortDescriptors: [CSVSortDescriptor]
        if let activeSort {
            sortDescriptors = [CSVSortDescriptor(
                column: activeSort.column,
                order: activeSort.ascending ? .ascending : .descending,
                valueKind: .automatic,
                caseSensitive: false
            )]
        } else {
            sortDescriptors = []
        }
        let query = CSVRowQuery(
            firstRecord: firstRowIsHeader ? 1 : 0,
            filters: filters,
            sortDescriptors: sortDescriptors
        )
        let cancellation = CancellationToken()
        queryCancellation = cancellation
        isTableOperationInFlight = true
        setOperationBusy(text: "\(projectionVerb)…", fraction: 0)

        Self.queryQueue.async { [weak self] in
            do {
                var lastUpdate = ContinuousClock.now
                let map = try CSVRowQueryEngine.execute(
                    snapshot: snapshot,
                    index: rowIndex,
                    query: query,
                    cancellation: { cancellation.isCancelled },
                    progress: { progress in
                        let now = ContinuousClock.now
                        let isFinal = progress.totalRecordCount.map {
                            progress.scannedRecordCount >= max(0, $0 - query.firstRecord)
                        } ?? false
                        guard progress.scannedRecordCount == 0
                                || isFinal
                                || now - lastUpdate >= .milliseconds(120) else { return }
                        lastUpdate = now
                        DispatchQueue.main.async { [weak self] in
                            self?.receiveQueryProgress(
                                progress,
                                generation: currentQueryGeneration,
                                cancellation: cancellation
                            )
                        }
                    }
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.queryGeneration == currentQueryGeneration,
                          !cancellation.isCancelled else {
                        map.close()
                        return
                    }
                    let oldMap = self.displayedRowMap
                    self.displayedRowMap = map
                    oldMap?.close()
                    self.pageDecodeGeneration &+= 1
                    self.pendingPages.removeAll(keepingCapacity: true)
                    self.queryCancellation = nil
                    self.isTableOperationInFlight = false
                    self.tableView.deselectAll(nil)
                    self.tableView.reloadData()
                    self.restorePendingScrollIfPossible()
                    self.restoreTableStatus()
                }
            } catch is CancellationError {
                return
            } catch CSVRowIndex.IndexError.cancelled {
                return
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.queryGeneration == currentQueryGeneration,
                          !cancellation.isCancelled else { return }
                    self.cancelQueryAndCloseRowMap()
                    self.activeFilters.removeAll(keepingCapacity: true)
                    self.activeSort = nil
                    self.isSettingSortDescriptors = true
                    self.tableView.sortDescriptors = []
                    self.isSettingSortDescriptors = false
                    self.updateFilterChrome()
                    self.tableView.deselectAll(nil)
                    self.tableView.reloadData()
                    self.report(error)
                }
            }
        }
    }

    private var projectionVerb: String {
        switch (activeFilters.isEmpty, activeSort == nil) {
        case (false, false): "Filtering and sorting"
        case (false, true): "Filtering"
        case (true, false): "Sorting"
        case (true, true): "Preparing table"
        }
    }

    private func predicate(for draft: CSVFilterDraft) -> CSVFilterPredicate {
        switch draft.predicate {
        case .contains:
            .contains(draft.value, caseSensitive: draft.isCaseSensitive)
        case .equals:
            .equals(draft.value, caseSensitive: draft.isCaseSensitive)
        case .doesNotEqual:
            .notEquals(draft.value, caseSensitive: draft.isCaseSensitive)
        case .startsWith:
            .beginsWith(draft.value, caseSensitive: draft.isCaseSensitive)
        case .endsWith:
            .endsWith(draft.value, caseSensitive: draft.isCaseSensitive)
        case .isEmpty:
            .isEmpty
        case .isNotEmpty:
            .isNotEmpty
        case .greaterThan:
            .numeric(.greaterThan, Double(draft.value) ?? .nan)
        case .lessThan:
            .numeric(.lessThan, Double(draft.value) ?? .nan)
        }
    }

    private func receiveQueryProgress(
        _ progress: CSVQueryProgress,
        generation: UInt64,
        cancellation: CancellationToken
    ) {
        guard queryGeneration == generation, !cancellation.isCancelled else { return }
        let total = progress.totalRecordCount.map {
            max(0, $0 - (firstRowIsHeader ? 1 : 0))
        }
        let fraction = total.flatMap { $0 > 0 ? Double(progress.scannedRecordCount) / Double($0) : 1 }
        let percent = Int(min(1, max(0, fraction ?? progress.indexedFractionCompleted)) * 100)
        setOperationBusy(
            text: "\(projectionVerb) \(percent)%  ·  \(progress.matchedRecordCount.formatted()) matches",
            fraction: fraction ?? progress.indexedFractionCompleted
        )
    }

    private func cancelQueryAndCloseRowMap() {
        queryGeneration &+= 1
        queryCancellation?.cancel()
        queryCancellation = nil
        displayedRowMap?.close()
        displayedRowMap = nil
        pageDecodeGeneration &+= 1
        pendingPages.removeAll(keepingCapacity: true)
        isTableOperationInFlight = false
    }

    private func requestAddRow(atSourceRecord record: Int64) {
        guard guardDatasetOperationAvailable(),
              commitPendingEdit(),
              let snapshot,
              let rowIndex,
              let mutationDelegate = editorDelegate as? CSVMutationEditorDelegate else {
            if !(editorDelegate is CSVMutationEditorDelegate) {
                report(CSVTableViewOperationError.mutationUnavailable)
            }
            return
        }
        beginMutationPlanning(status: "Adding row…") { [columnCount] cancellation in
            if cancellation.isCancelled { throw CancellationError() }
            if snapshot.byteCount == 0 {
                // A zero-byte file has no representable empty record until a
                // terminator exists. Bootstrap one LF record so View exposes a
                // real editable cell instead of planning a filtered no-op.
                return [ByteEdit(byteRange: 0..<0, replacement: Data([0x0A]))]
            }
            return [try CSVRowMutationPlanner.insert(
                values: Array(repeating: "", count: columnCount),
                beforeRecord: record,
                snapshot: snapshot,
                index: rowIndex
            )]
        } apply: { [weak self] edits, generation, cancellation in
            guard let self else { return }
            mutationDelegate.editorApplyCSVRowEdits(edits, replacing: snapshot) { [weak self] result in
                self?.finishRowMutation(
                    result,
                    generation: generation,
                    cancellation: cancellation
                )
            }
        }
    }

    private func requestDeleteRows(sourceRecords: [Int64]) {
        guard sourceRecords.count <= Self.maximumSelectedRowMutationCount else {
            let message = "Row deletion is limited to \(Self.maximumSelectedRowMutationCount.formatted()) rows at a time. Filter the table and delete in smaller batches."
            setBusy(false, text: message)
            statusLabel.setAccessibilityValue(message)
            NSSound.beep()
            return
        }
        guard guardDatasetOperationAvailable(),
              commitPendingEdit(),
              let snapshot,
              let rowIndex,
              let mutationDelegate = editorDelegate as? CSVMutationEditorDelegate else {
            if !(editorDelegate is CSVMutationEditorDelegate) {
                report(CSVTableViewOperationError.mutationUnavailable)
            }
            return
        }
        let records = Array(Set(sourceRecords)).sorted()
        beginMutationPlanning(status: "Preparing row deletion…") { cancellation in
            var edits: [ByteEdit] = []
            edits.reserveCapacity(min(records.count, 256))

            func appendRun(from firstRecord: Int64, through lastRecord: Int64) throws {
                var nextRecord = firstRecord
                var pendingRange: Range<Int64>?
                while nextRecord <= lastRecord {
                    if cancellation.isCancelled { throw CancellationError() }
                    let remaining = lastRecord - nextRecord + 1
                    let locations = try rowIndex.recordLocations(
                        startingAt: nextRecord,
                        limit: Int(min(4_096, remaining)),
                        cancellation: { cancellation.isCancelled }
                    )
                    guard !locations.isEmpty else {
                        throw CSVDataOperationError.invalidRecord(nextRecord)
                    }
                    for location in locations {
                        guard location.record <= lastRecord else { break }
                        if let range = pendingRange,
                           range.upperBound == location.completeRange.lowerBound {
                            pendingRange = range.lowerBound..<location.completeRange.upperBound
                        } else {
                            if let range = pendingRange {
                                edits.append(ByteEdit(byteRange: range, replacement: Data()))
                            }
                            pendingRange = location.completeRange
                        }
                        nextRecord = location.record + 1
                    }
                }
                if let range = pendingRange {
                    edits.append(ByteEdit(byteRange: range, replacement: Data()))
                }
            }

            var runStart: Int64?
            var previous: Int64?
            for record in records {
                if cancellation.isCancelled { throw CancellationError() }
                if let prior = previous, record != prior + 1,
                   let first = runStart {
                    try appendRun(from: first, through: prior)
                    runStart = record
                } else if runStart == nil {
                    runStart = record
                }
                previous = record
            }
            if let first = runStart, let last = previous {
                try appendRun(from: first, through: last)
            }
            return edits
        } apply: { [weak self] edits, generation, cancellation in
            guard let self else { return }
            mutationDelegate.editorApplyCSVRowEdits(edits, replacing: snapshot) { [weak self] result in
                self?.finishRowMutation(
                    result,
                    generation: generation,
                    cancellation: cancellation
                )
            }
        }
    }

    private func requestAddColumn(at column: Int) {
        guard guardDatasetOperationAvailable() else { return }
        guard guardVisibleColumnInsertion(at: column) else { return }
        let isEmptyDocument = snapshot?.byteCount == 0
        guard firstRowIsHeader || isEmptyDocument else {
            applyColumnMutation(.insert(CSVColumnInsertion(column: column)), label: "Adding column")
            return
        }
        let alert = NSAlert()
        alert.messageText = "Add Column"
        alert.informativeText = "Choose a name for the new column."
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        let nameField = NSTextField(string: "New Column")
        nameField.placeholderString = "Column name"
        nameField.setAccessibilityLabel("New CSV column name")
        nameField.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = nameField
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                NSSound.beep()
                return
            }
            if isEmptyDocument {
                self.firstRowIsHeader = true
                self.headerDetectionCompleted = true
                self.headerCheckbox.state = .on
                self.requestBootstrapColumn(named: name)
            } else {
                self.applyColumnMutation(
                    .insert(CSVColumnInsertion(
                        column: column,
                        headerRecord: 0,
                        headerValue: name,
                        defaultValue: ""
                    )),
                    label: "Adding column"
                )
            }
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(alert.runModal())
        }
    }

    private func requestDeleteColumn(_ column: Int) {
        guard guardDatasetOperationAvailable() else { return }
        applyColumnMutation(.delete(column: column), label: "Deleting column")
    }

    private func requestBootstrapColumn(named name: String) {
        guard guardDatasetOperationAvailable(),
              commitPendingEdit(),
              let snapshot,
              snapshot.byteCount == 0,
              let mutationDelegate = editorDelegate as? CSVMutationEditorDelegate else {
            if !(editorDelegate is CSVMutationEditorDelegate) {
                report(CSVTableViewOperationError.mutationUnavailable)
            }
            return
        }
        beginMutationPlanning(status: "Adding column…") { cancellation in
            if cancellation.isCancelled { throw CancellationError() }
            var bytes = CSVRecordParser.encodedField(name)
            bytes.append(0x0A)
            return [ByteEdit(byteRange: 0..<0, replacement: bytes)]
        } apply: { [weak self] edits, generation, cancellation in
            guard let self else { return }
            mutationDelegate.editorApplyCSVRowEdits(edits, replacing: snapshot) { [weak self] result in
                self?.finishRowMutation(
                    result,
                    generation: generation,
                    cancellation: cancellation
                )
            }
        }
    }

    @discardableResult
    private func guardVisibleColumnInsertion(at column: Int) -> Bool {
        if snapshot?.byteCount == 0 { return true }
        guard column >= 0, column < Self.maximumPresentedColumns else {
            let message = "View supports adding columns only within its first \(Self.maximumPresentedColumns.formatted()) visible columns."
            setBusy(false, text: message)
            statusLabel.setAccessibilityValue(message)
            NSSound.beep()
            return false
        }
        return true
    }

    private func beginMutationPlanning(
        status: String,
        plan: @escaping (CancellationToken) throws -> [ByteEdit],
        apply: @escaping ([ByteEdit], UInt64, CancellationToken) -> Void
    ) {
        mutationGeneration &+= 1
        let currentMutationGeneration = mutationGeneration
        mutationCancellation?.cancel()
        let cancellation = CancellationToken()
        mutationCancellation = cancellation
        setOperationBusy(text: status, fraction: 0)
        Self.mutationQueue.async { [weak self] in
            do {
                let edits = try plan(cancellation)
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.mutationGeneration == currentMutationGeneration,
                          !cancellation.isCancelled else { return }
                    apply(edits, currentMutationGeneration, cancellation)
                }
            } catch is CancellationError {
                return
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.mutationGeneration == currentMutationGeneration,
                          !cancellation.isCancelled else { return }
                    self.mutationCancellation = nil
                    self.isTableOperationInFlight = false
                    self.report(error)
                }
            }
        }
    }

    private func finishRowMutation(
        _ result: Result<Void, Error>,
        generation: UInt64,
        cancellation: CancellationToken
    ) {
        guard mutationGeneration == generation, !cancellation.isCancelled else { return }
        mutationCancellation = nil
        isTableOperationInFlight = false
        switch result {
        case .success:
            restoreTableStatus()
        case let .failure(error as CancellationError):
            _ = error
            restoreTableStatus()
        case let .failure(error):
            report(error)
        }
    }

    private func applyColumnMutation(_ mutation: CSVColumnMutation, label: String) {
        guard guardDatasetOperationAvailable(),
              commitPendingEdit(),
              let snapshot,
              let rowIndex,
              let mutationDelegate = editorDelegate as? CSVMutationEditorDelegate else {
            if !(editorDelegate is CSVMutationEditorDelegate) {
                report(CSVTableViewOperationError.mutationUnavailable)
            }
            return
        }
        // A structural change invalidates every column-coordinate query. Clear
        // the projection before handing the rewrite to the session so its
        // controller-owned reload can never apply an old filter or sort to a
        // newly shifted column.
        cancelQueryAndCloseRowMap()
        activeFilters.removeAll(keepingCapacity: true)
        activeSort = nil
        isSettingSortDescriptors = true
        tableView.sortDescriptors = []
        isSettingSortDescriptors = false
        updateFilterChrome()
        tableView.deselectAll(nil)
        tableView.reloadData()

        mutationGeneration &+= 1
        let currentMutationGeneration = mutationGeneration
        mutationCancellation?.cancel()
        let cancellation = CancellationToken()
        mutationCancellation = cancellation
        setOperationBusy(text: "\(label)…", fraction: 0)
        mutationDelegate.editorApplyCSVColumnMutation(
            mutation,
            snapshot: snapshot,
            index: rowIndex,
            progress: { [weak self] progress in
                guard let self,
                      self.mutationGeneration == currentMutationGeneration,
                      !cancellation.isCancelled else { return }
                let percent = Int(progress.fractionCompleted * 100)
                self.setOperationBusy(
                    text: "\(label) \(percent)%  ·  \(progress.processedRecordCount.formatted()) rows",
                    fraction: progress.fractionCompleted
                )
            },
            completion: { [weak self] result in
                guard let self,
                      self.mutationGeneration == currentMutationGeneration,
                      !cancellation.isCancelled else { return }
                self.mutationCancellation = nil
                self.isTableOperationInFlight = false
                switch result {
                case .success:
                    self.restoreTableStatus()
                case let .failure(error as CancellationError):
                    _ = error
                    self.restoreTableStatus()
                case let .failure(error):
                    self.report(error)
                }
            }
        )
    }

    private func cancelCSVMutation() {
        let wasRunning = mutationCancellation != nil
        mutationGeneration &+= 1
        mutationCancellation?.cancel()
        mutationCancellation = nil
        (editorDelegate as? CSVMutationEditorDelegate)?.editorCancelCSVMutation()
        if wasRunning { isTableOperationInFlight = false }
    }

    private func requestColumnSummary(
        column: Int,
        progress: @escaping (CSVQueryProgress) -> Void,
        completion: @escaping (Result<CSVColumnSummaryPresentation, Error>) -> Void
    ) {
        summaryGeneration &+= 1
        let currentSummaryGeneration = summaryGeneration
        summaryCancellation?.cancel()
        guard let snapshot, let rowIndex else {
            completion(.failure(CSVDataOperationError.invalidColumn(column)))
            return
        }
        let cancellation = CancellationToken()
        summaryCancellation = cancellation
        let firstRecord: Int64 = firstRowIsHeader ? 1 : 0
        Self.summaryQueue.async { [weak self] in
            do {
                var lastUpdate = ContinuousClock.now
                let profile = try CSVColumnProfiler.profile(
                    snapshot: snapshot,
                    index: rowIndex,
                    column: column,
                    firstRecord: firstRecord,
                    cancellation: { cancellation.isCancelled },
                    progress: { update in
                        let now = ContinuousClock.now
                        guard update.scannedRecordCount == 0
                                || now - lastUpdate >= .milliseconds(120) else { return }
                        lastUpdate = now
                        DispatchQueue.main.async { [weak self] in
                            guard let self,
                                  self.summaryGeneration == currentSummaryGeneration,
                                  !cancellation.isCancelled else { return }
                            progress(update)
                        }
                    }
                )
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.summaryGeneration == currentSummaryGeneration,
                          !cancellation.isCancelled else { return }
                    self.summaryCancellation = nil
                    completion(.success(self.presentation(for: profile)))
                }
            } catch is CancellationError {
                return
            } catch CSVRowIndex.IndexError.cancelled {
                return
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.summaryGeneration == currentSummaryGeneration,
                          !cancellation.isCancelled else { return }
                    self.summaryCancellation = nil
                    completion(.failure(error))
                }
            }
        }
    }

    private func cancelColumnSummaryRequest() {
        summaryGeneration &+= 1
        summaryCancellation?.cancel()
        summaryCancellation = nil
    }

    private func presentation(for profile: CSVColumnProfile) -> CSVColumnSummaryPresentation {
        let numeric = profile.minimumNumericValue != nil || profile.maximumNumericValue != nil
        let minimum = numeric
            ? profile.minimumNumericValue.map(formatSummaryNumber)
            : profile.minimumUTF8Length.map { "\($0.formatted()) bytes" }
        let maximum = numeric
            ? profile.maximumNumericValue.map(formatSummaryNumber)
            : profile.maximumUTF8Length.map { "\($0.formatted()) bytes" }
        let samplingDescription: String
        switch profile.samplingStrategy {
        case .complete:
            samplingDescription = "Complete dataset"
        case .prefix:
            samplingDescription = "Prefix sample from the start of the file"
        case .stratified:
            samplingDescription = "Stratified sample across file"
        }
        return CSVColumnSummaryPresentation(
            type: profile.inferredKind.rawValue.capitalized,
            samplingDescription: samplingDescription,
            rowLabel: profile.isCompleteDataset ? "Rows" : "Rows sampled",
            rowCount: profile.sampledRecordCount,
            emptyCount: profile.emptyValueCount + profile.missingValueCount,
            distinctValueDescription: "≈ \(profile.approximateDistinctValueCount.formatted())",
            minimum: minimum,
            maximum: maximum,
            frequentValues: profile.topValues.map {
                CSVColumnSummaryPresentation.FrequentValue(
                    value: $0.value,
                    count: $0.estimatedCount,
                    isEstimated: !profile.isCompleteDataset || $0.maximumError > 0
                )
            },
            isApproximate: !profile.isCompleteDataset
        )
    }

    private func formatSummaryNumber(_ number: Double) -> String {
        number.formatted(.number.precision(.fractionLength(0...6)))
    }

#if LIGHTXT_STANDALONE_CSV_QA
    /// Focused hooks for the standalone AppKit runtime harness. These drive
    /// the same state machine and mutation adapters as user interaction while
    /// keeping test-only surface out of release builds.
    func qaCycleHeaderSort(column: Int) {
        guard column >= 0, column < columnCount else { return }
        let oldDescriptors = tableView.sortDescriptors
        let nextDescriptor: NSSortDescriptor
        if activeSort?.column == column, activeSort?.ascending == true {
            nextDescriptor = NSSortDescriptor(
                key: tableView.tableColumns[column + 1].identifier.rawValue,
                ascending: false
            )
        } else {
            nextDescriptor = NSSortDescriptor(
                key: tableView.tableColumns[column + 1].identifier.rawValue,
                ascending: true
            )
        }
        isSettingSortDescriptors = true
        tableView.sortDescriptors = [nextDescriptor]
        isSettingSortDescriptors = false
        self.tableView(tableView, sortDescriptorsDidChange: oldDescriptors)
    }

    func qaApplyContainsFilter(column: Int, value: String) {
        guard column >= 0, column < columnCount else { return }
        activeFilters[column] = CSVFilterDraft(
            predicate: .contains,
            value: value,
            isCaseSensitive: false
        )
        updateFilterChrome()
        requestApplyQuery()
    }

    func qaClearFilters() { clearAllFilters(nil) }
    func qaClearSort() { clearSort(nil) }

    func qaRequestColumnSummary(
        column: Int,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        requestColumnSummary(column: column, progress: { _ in }) { result in
            completion(result.map { presentation in
                let values = presentation.frequentValues.map {
                    "\($0.value):\($0.count)\($0.isEstimated ? "~" : "")"
                }.joined(separator: ",")
                return [
                    presentation.type,
                    presentation.samplingDescription,
                    "\(presentation.rowLabel)=\(presentation.rowCount)",
                    "empty=\(presentation.emptyCount)",
                    values,
                ].joined(separator: "|")
            })
        }
    }

    func qaAddRow(beforeSourceRecord record: Int64) {
        requestAddRow(atSourceRecord: record)
    }

    func qaDeleteRows(sourceRecords: [Int64]) {
        requestDeleteRows(sourceRecords: sourceRecords)
    }

    func qaAddColumn(at column: Int, name: String) {
        guard guardDatasetOperationAvailable(), guardVisibleColumnInsertion(at: column) else { return }
        if snapshot?.byteCount == 0 {
            firstRowIsHeader = true
            headerDetectionCompleted = true
            headerCheckbox.state = .on
            requestBootstrapColumn(named: name)
        } else {
            let insertion = firstRowIsHeader
                ? CSVColumnInsertion(
                    column: column,
                    headerRecord: 0,
                    headerValue: name,
                    defaultValue: ""
                )
                : CSVColumnInsertion(column: column)
            applyColumnMutation(.insert(insertion), label: "Adding column")
        }
    }

    func qaDeleteColumn(_ column: Int) {
        requestDeleteColumn(column)
    }

    func qaSourceRecord(forDisplayedRow row: Int64) throws -> Int64 {
        try sourceRecord(forDisplayedRow: row)
    }

    func qaSetFirstRowIsHeader(_ enabled: Bool) { setFirstRowIsHeader(enabled) }
    var qaColumnTitles: [String] { Array(tableView.tableColumns.dropFirst().map(\.title)) }

    func qaRequestDisplayedRows(_ rows: [Int]) {
        for row in rows {
            guard let source = try? sourceRecord(forDisplayedRow: Int64(row)) else { continue }
            _ = recordForDisplay(source)
        }
    }

    func qaCachedValue(displayedRow row: Int, column: Int) -> String? {
        guard let source = try? sourceRecord(forDisplayedRow: Int64(row)) else { return nil }
        return cachedRecords[source]?.fields[safe: column]?.value
    }

    var qaCachedSourceRecords: Set<Int64> { Set(cachedRecords.keys) }
    var qaPendingRecordLoadCount: Int { pendingPages.count }
    func qaResetRecordCache() {
        cachedRecords.removeAll(keepingCapacity: true)
        cacheOrder.removeAll(keepingCapacity: true)
        pendingPages.removeAll(keepingCapacity: true)
        pageDecodeGeneration &+= 1
        tableView.reloadData()
    }
#endif

    private func resetViewQuery() {
        cancelQueryAndCloseRowMap()
        cancelColumnSummaryRequest()
        activeSort = nil
        activeFilters.removeAll(keepingCapacity: true)
        isSettingSortDescriptors = true
        tableView.sortDescriptors = []
        isSettingSortDescriptors = false
        updateFilterChrome()
    }

    private func setBusy(_ busy: Bool, text: String) {
        statusLabel.stringValue = text
        statusLabel.setAccessibilityValue(text)
        progressIndicator.doubleValue = latestProgress?.fractionCompleted ?? (busy ? 0 : 1)
        progressIndicator.isHidden = !busy
        let canMutate = latestProgress?.isComplete == true && !isTableOperationInFlight
        headerCheckbox.isEnabled = canMutate
        addButton.isEnabled = canMutate
        deleteButton.isEnabled = canMutate
        onStatusChange?(text, busy)
    }

    private func setOperationBusy(text: String, fraction: Double?) {
        isTableOperationInFlight = true
        statusLabel.stringValue = text
        statusLabel.setAccessibilityValue(text)
        progressIndicator.doubleValue = min(1, max(0, fraction ?? 0))
        progressIndicator.isHidden = false
        headerCheckbox.isEnabled = false
        addButton.isEnabled = false
        deleteButton.isEnabled = false
        onStatusChange?(text, true)
        reloadVisibleEditableCells()
    }

    private func restoreTableStatus() {
        let sourceRows = max(
            0,
            (latestProgress?.totalRecordCount ?? latestProgress?.knownRecordCount ?? 0)
                - (firstRowIsHeader ? 1 : 0)
        )
        if let displayedRowMap {
            let descriptor: String
            switch (activeFilters.isEmpty, activeSort == nil) {
            case (false, false): descriptor = "filtered and sorted"
            case (false, true): descriptor = "filtered"
            case (true, false): descriptor = "sorted"
            case (true, true): descriptor = "visible"
            }
            setBusy(
                false,
                text: "\(displayedRowMap.rowCount.formatted()) of \(sourceRows.formatted()) rows  ·  \(descriptor)"
            )
        } else {
            setBusy(false, text: "\(sourceRows.formatted()) rows")
        }
        reloadVisibleEditableCells()
    }

    private func reloadVisibleEditableCells() {
        let visible = tableView.rows(in: tableView.visibleRect)
        guard visible.location != NSNotFound,
              visible.length > 0,
              tableView.tableColumns.count > 1 else { return }
        tableView.reloadData(
            forRowIndexes: IndexSet(
                integersIn: visible.location..<(visible.location + visible.length)
            ),
            columnIndexes: IndexSet(integersIn: 1..<tableView.tableColumns.count)
        )
    }

    private func report(_ error: Error) {
        setBusy(false, text: error.localizedDescription)
        editorDelegate?.editorDidFail(error)
    }

    private func reportOnce(_ error: Error) {
        guard lastReportedError != error.localizedDescription else { return }
        lastReportedError = error.localizedDescription
        report(error)
    }

    private func storeCached(_ record: CSVParsedRecord, for row: Int64) {
        if row == 0 {
            firstParsedRecord = record
            if firstRowIsHeader, columnCount > 0 {
                updateColumnTitles(from: record)
            }
        }
        cachedRecords[row] = record
        touchCache(row)
        while cacheOrder.count > Self.maximumCachedRows {
            let evicted = cacheOrder.removeFirst()
            cachedRecords.removeValue(forKey: evicted)
        }
    }

    private func touchCache(_ row: Int64) {
        if let existing = cacheOrder.firstIndex(of: row) { cacheOrder.remove(at: existing) }
        cacheOrder.append(row)
    }

    private func restorePendingScrollIfPossible() {
        guard let pendingScrollTarget else { return }
        let visibleRow = displayedRowMap == nil
            ? pendingScrollTarget.record - (firstRowIsHeader ? 1 : 0)
            : pendingScrollTarget.displayedRow
        guard visibleRow >= 0, visibleRow < Int64(numberOfRows(in: tableView)) else { return }
        tableView.scrollRowToVisible(Int(visibleRow))
        if pendingScrollTarget.column + 1 < tableView.tableColumns.count {
            tableView.scrollColumnToVisible(pendingScrollTarget.column + 1)
        }
        self.pendingScrollTarget = nil
    }

    private func spreadsheetColumnName(_ zeroBasedColumn: Int) -> String {
        var value = zeroBasedColumn + 1
        var output = ""
        while value > 0 {
            value -= 1
            output.insert(Character(UnicodeScalar(65 + value % 26)!), at: output.startIndex)
            value /= 26
        }
        return output
    }
}

@MainActor
private final class CSVEditableTextField: NSTextField {
    var displayedRow: Int64 = 0
    var record: Int64 = 0
    var column = 0
    var byteRange: Range<Int64>?
    var originalValue = ""
    var originalFieldCount = 0
}

private struct CSVFilterDraft: Equatable {
    enum Predicate: Int, CaseIterable {
        case contains
        case equals
        case doesNotEqual
        case startsWith
        case endsWith
        case isEmpty
        case isNotEmpty
        case greaterThan
        case lessThan

        var title: String {
            switch self {
            case .contains: "Contains"
            case .equals: "Equals"
            case .doesNotEqual: "Does Not Equal"
            case .startsWith: "Starts With"
            case .endsWith: "Ends With"
            case .isEmpty: "Is Empty"
            case .isNotEmpty: "Is Not Empty"
            case .greaterThan: "Greater Than"
            case .lessThan: "Less Than"
            }
        }

        var needsValue: Bool {
            self != .isEmpty && self != .isNotEmpty
        }

        var needsNumber: Bool {
            self == .greaterThan || self == .lessThan
        }
    }

    var predicate: Predicate
    var value: String
    var isCaseSensitive: Bool
}

@MainActor
private final class CSVFilterPopoverViewController: NSViewController, NSSearchFieldDelegate {
    var onApply: ((CSVFilterDraft) -> Void)?
    var onClear: (() -> Void)?

    private let columnTitle: String
    private let initialFilter: CSVFilterDraft?
    private let predicateButton = NSPopUpButton()
    private let valueField = NSSearchField()
    private let caseButton = NSButton(checkboxWithTitle: "Case sensitive", target: nil, action: nil)
    private lazy var applyButton = NSButton(title: "Apply", target: self, action: #selector(apply(_:)))
    private lazy var clearButton = NSButton(title: "Clear", target: self, action: #selector(clear(_:)))

    init(columnTitle: String, filter: CSVFilterDraft?) {
        self.columnTitle = columnTitle
        self.initialFilter = filter
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 326, height: 190)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root

        let title = NSTextField(labelWithString: "Filter \u{201c}\(columnTitle)\u{201d}")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setAccessibilityLabel("Filter column \(columnTitle)")

        predicateButton.addItems(withTitles: CSVFilterDraft.Predicate.allCases.map(\.title))
        predicateButton.target = self
        predicateButton.action = #selector(predicateChanged(_:))
        predicateButton.setAccessibilityLabel("Filter condition")

        valueField.placeholderString = "Value"
        valueField.delegate = self
        valueField.target = self
        valueField.action = #selector(apply(_:))
        valueField.setAccessibilityLabel("Filter value")

        caseButton.setAccessibilityHelp("Match uppercase and lowercase letters exactly")

        applyButton.bezelStyle = .rounded
        applyButton.keyEquivalent = "\r"
        applyButton.setAccessibilityLabel("Apply column filter")
        clearButton.bezelStyle = .rounded
        clearButton.isEnabled = initialFilter != nil
        clearButton.setAccessibilityLabel("Clear column filter")

        let buttons = NSStackView(views: [clearButton, NSView(), applyButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8

        let content = NSStackView(views: [title, predicateButton, valueField, caseButton, buttons])
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 10
        root.addSubview(content)

        predicateButton.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        valueField.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        buttons.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: preferredContentSize.width),
            root.heightAnchor.constraint(equalToConstant: preferredContentSize.height),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            content.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -14),
        ])

        let filter = initialFilter ?? CSVFilterDraft(
            predicate: .contains,
            value: "",
            isCaseSensitive: false
        )
        predicateButton.selectItem(at: filter.predicate.rawValue)
        valueField.stringValue = filter.value
        caseButton.state = filter.isCaseSensitive ? .on : .off
        updateValueControls()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if selectedPredicate.needsValue { view.window?.makeFirstResponder(valueField) }
    }

    private var selectedPredicate: CSVFilterDraft.Predicate {
        CSVFilterDraft.Predicate(rawValue: predicateButton.indexOfSelectedItem) ?? .contains
    }

    @objc private func predicateChanged(_ sender: Any?) { updateValueControls() }

    private func updateValueControls() {
        let predicate = selectedPredicate
        let needsValue = predicate.needsValue
        valueField.isEnabled = needsValue
        valueField.placeholderString = predicate.needsNumber ? "Number" : "Value"
        caseButton.isEnabled = needsValue
            && !predicate.needsNumber
        let hasValidValue = !valueField.stringValue.isEmpty
            && (!predicate.needsNumber || Double(valueField.stringValue)?.isFinite == true)
        applyButton.isEnabled = !needsValue || hasValidValue
    }

    func controlTextDidChange(_ notification: Notification) { updateValueControls() }

    @objc private func apply(_ sender: Any?) {
        let predicate = selectedPredicate
        let validValue = !valueField.stringValue.isEmpty
            && (!predicate.needsNumber || Double(valueField.stringValue)?.isFinite == true)
        guard !predicate.needsValue || validValue else {
            NSSound.beep()
            view.window?.makeFirstResponder(valueField)
            return
        }
        onApply?(CSVFilterDraft(
            predicate: predicate,
            value: valueField.stringValue,
            isCaseSensitive: caseButton.state == .on
        ))
    }

    @objc private func clear(_ sender: Any?) { onClear?() }
}

private struct CSVColumnSummaryPresentation {
    struct FrequentValue {
        let value: String
        let count: Int64
        let isEstimated: Bool
    }

    let type: String
    let samplingDescription: String
    let rowLabel: String
    let rowCount: Int64
    let emptyCount: Int64
    let distinctValueDescription: String
    let minimum: String?
    let maximum: String?
    let frequentValues: [FrequentValue]
    let isApproximate: Bool
}

@MainActor
private final class CSVColumnSummaryPopoverViewController: NSViewController {
    private let columnTitle: String
    private let content = NSStackView()
    private let progress = NSProgressIndicator()
    private let loadingLabel = NSTextField(labelWithString: "Scanning this column…")

    init(columnTitle: String) {
        self.columnTitle = columnTitle
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 360, height: 330)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root

        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 9
        root.addSubview(content)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: preferredContentSize.width),
            root.heightAnchor.constraint(equalToConstant: preferredContentSize.height),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            content.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -16),
        ])
        showLoading()
    }

    private func showLoading() {
        removeContent()
        content.addArrangedSubview(titleLabel())
        loadingLabel.stringValue = "Scanning this column…"
        loadingLabel.textColor = .secondaryLabelColor
        progress.style = .spinning
        progress.isIndeterminate = true
        progress.controlSize = .small
        progress.startAnimation(nil)
        let row = NSStackView(views: [progress, loadingLabel])
        row.orientation = .horizontal
        row.spacing = 8
        row.alignment = .centerY
        content.addArrangedSubview(row)
        content.setAccessibilityLabel("Loading column summary")
    }

    func show(_ summary: CSVColumnSummaryPresentation) {
        removeContent()
        content.addArrangedSubview(titleLabel())
        let qualifierLabel = NSTextField(labelWithString: summary.samplingDescription)
        qualifierLabel.font = .systemFont(ofSize: 11)
        qualifierLabel.textColor = .secondaryLabelColor
        content.addArrangedSubview(qualifierLabel)

        let nonempty = max(0, summary.rowCount - summary.emptyCount)
        let grid = NSGridView(views: [
            [metricLabel("Type"), valueLabel(summary.type)],
            [metricLabel(summary.rowLabel), valueLabel(summary.rowCount.formatted())],
            [metricLabel("Filled"), valueLabel(nonempty.formatted())],
            [metricLabel("Empty"), valueLabel(summary.emptyCount.formatted())],
            [metricLabel("Distinct"), valueLabel(summary.distinctValueDescription)],
        ])
        grid.rowSpacing = 5
        grid.columnSpacing = 16
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        content.addArrangedSubview(grid)

        if summary.minimum != nil || summary.maximum != nil {
            let range = NSGridView(views: [
                [metricLabel("Minimum"), valueLabel(summary.minimum ?? "—")],
                [metricLabel("Maximum"), valueLabel(summary.maximum ?? "—")],
            ])
            range.rowSpacing = 5
            range.columnSpacing = 16
            range.column(at: 0).xPlacement = .trailing
            range.column(at: 1).xPlacement = .leading
            content.addArrangedSubview(range)
        }

        if !summary.frequentValues.isEmpty {
            let heading = NSTextField(labelWithString: "Top values\(summary.isApproximate ? " (sample)" : "")")
            heading.font = .systemFont(ofSize: 12, weight: .semibold)
            content.addArrangedSubview(heading)
            for frequent in summary.frequentValues.prefix(5) {
                let value = frequent.value.isEmpty ? "(empty)" : frequent.value
                let count = "\(frequent.isEstimated ? "≈ " : "")\(frequent.count.formatted())"
                let label = NSTextField(labelWithString: "\(value)   \(count)")
                label.lineBreakMode = .byTruncatingMiddle
                label.maximumNumberOfLines = 1
                label.toolTip = frequent.value
                label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                content.addArrangedSubview(label)
                label.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor).isActive = true
            }
        }
        content.setAccessibilityLabel("Column summary for \(columnTitle)")
    }

    func show(progress update: CSVQueryProgress) {
        let available = update.totalRecordCount.map { max(0, $0) }
        let fraction = available.flatMap {
            $0 > 0 ? Double(update.scannedRecordCount) / Double($0) : 1
        }
        let suffix = available.map { " of \($0.formatted())" } ?? ""
        let percent = fraction.map { "  ·  \(Int(min(1, max(0, $0)) * 100))%" } ?? ""
        loadingLabel.stringValue = "Scanned \(update.scannedRecordCount.formatted())\(suffix) rows\(percent)…"
    }

    func show(error: Error) {
        removeContent()
        content.addArrangedSubview(titleLabel())
        let label = NSTextField(wrappingLabelWithString: error.localizedDescription)
        label.textColor = .secondaryLabelColor
        label.maximumNumberOfLines = 4
        content.addArrangedSubview(label)
        content.setAccessibilityLabel("Column summary failed")
    }

    private func titleLabel() -> NSTextField {
        let label = NSTextField(labelWithString: "Column Summary: \(columnTitle)")
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.toolTip = columnTitle
        label.setAccessibilityLabel("Column Summary: \(columnTitle)")
        return label
    }

    private func metricLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func valueLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingMiddle
        label.maximumNumberOfLines = 1
        label.toolTip = text
        return label
    }

    private func removeContent() {
        for view in content.arrangedSubviews {
            content.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }
}

/// NSTableHeaderCell's cached attributed title can retain its light-mode
/// foreground after a window changes appearance. Drawing only the title here
/// preserves AppKit's native header surface while guaranteeing readable text
/// in both appearances.
private final class LighTxtCSVHeaderCell: NSTableHeaderCell {
    var isFiltered = false

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.alignment = alignment
        let attributedTitle = NSAttributedString(
            string: stringValue,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                // A semantic label color is essential here: NSTableHeaderView
                // draws with a vibrant appearance, which intentionally dims
                // arbitrary RGB foregrounds in dark mode.
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
        )
        let indicatorWidth: CGFloat = isFiltered ? 18 : 0
        var titleFrame = cellFrame.insetBy(dx: 4, dy: 0)
        titleFrame.size.width = max(0, titleFrame.width - indicatorWidth)
        let titleHeight = attributedTitle.size().height
        let verticallyCentered = NSRect(
            x: titleFrame.minX,
            y: titleFrame.midY - titleHeight / 2,
            width: titleFrame.width,
            height: titleHeight
        )
        if let context = NSGraphicsContext.current {
            context.saveGraphicsState()
            context.compositingOperation = .sourceOver
            attributedTitle.draw(
                with: verticallyCentered,
                options: NSString.DrawingOptions([
                    .usesLineFragmentOrigin,
                    .truncatesLastVisibleLine,
                ])
            )
            context.restoreGraphicsState()
        } else {
            attributedTitle.draw(with: verticallyCentered)
        }

        if isFiltered,
           let indicator = NSImage(
               systemSymbolName: "line.3.horizontal.decrease",
               accessibilityDescription: "Filtered"
           )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)) {
            indicator.isTemplate = true
            let frame = NSRect(
                x: cellFrame.maxX - 17,
                y: cellFrame.midY - 6,
                width: 12,
                height: 12
            )
            NSColor.controlAccentColor.set()
            indicator.draw(in: frame)
        }
    }
}

/// The standard header opts into vibrancy. That is attractive over window
/// materials, but our opaque editor surface has no material backdrop and dark
/// vibrancy can suppress custom header titles almost completely. A non-vibrant
/// header keeps native resizing/dragging while drawing predictable contrast.
private final class LighTxtCSVHeaderView: NSTableHeaderView {
    var menuProvider: ((Int) -> NSMenu?)?

    override var allowsVibrancy: Bool { false }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let tableView else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        return menuProvider?(tableView.column(at: point))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private enum CSVTableViewOperationError: LocalizedError {
    case mutationUnavailable

    var errorDescription: String? {
        switch self {
        case .mutationUnavailable:
            "CSV row and column editing is unavailable for this document."
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
