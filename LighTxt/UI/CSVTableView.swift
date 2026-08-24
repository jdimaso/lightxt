import AppKit

#if !LIGHTXT_STANDALONE_PARQUET_QA
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
    private static let exportQueue = DispatchQueue(
        label: "app.lightxt.csv-export",
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
    private let delimiterPopup = NSPopUpButton()
    private let headerCheckbox = NSButton(checkboxWithTitle: "First row is header", target: nil, action: nil)
    private lazy var clearFiltersButton = QuietButton(
        title: "Clear Filters",
        symbolName: "xmark.circle",
        minimumHeight: 28,
        target: self,
        action: #selector(clearAllFilters(_:))
    )
    private let filterStripScrollView = NSScrollView()
    private let filterChipContainer = NSView()
    private var filterStripWidthConstraint: NSLayoutConstraint?
    private let statusLabel = NSTextField(labelWithString: "Preparing table…")
    private let progressIndicator = NSProgressIndicator()
    private let scrollView = NSScrollView()
    private let tableView = LighTxtCSVTableView()
    private let queryLoadingOverlay = CSVQueryLoadingOverlayView()

    private var snapshot: DocumentSnapshot?
    private var rowIndex: CSVRowIndex?
    private var latestProgress: CSVRowIndex.Progress?
    private var indexingCancellation: CancellationToken?
    private var queryCancellation: CancellationToken?
    private var summaryCancellation: CancellationToken?
    private var mutationCancellation: CancellationToken?
    private var exportCancellation: CancellationToken?
    private var generation: UInt64 = 0
    private var pageDecodeGeneration: UInt64 = 0
    private var queryGeneration: UInt64 = 0
    private var summaryGeneration: UInt64 = 0
    private var mutationGeneration: UInt64 = 0
    private var firstRowIsHeader = false
    private var delimiter: DelimitedTextDelimiter = .comma
    private var headerDetectionCompleted = false
    private var columnCount = 0
    private var cachedRecords: [Int64: CSVParsedRecord] = [:]
    private var cacheOrder: [Int64] = []
    private var isResidentPresentationPurged = false
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
    private enum PopoverAnchor: Equatable {
        case tableHeader(column: Int)
        case filterChip(column: Int)
    }
    private var presentedPopover: NSPopover?
    private var presentedPopoverAnchor: PopoverAnchor?
    private var uniqueValuesTask: Task<Void, Never>?
    private var pendingFilterQuery: DispatchWorkItem?
    private var activeSort: (column: Int, ascending: Bool)?
    private var publishedFilters: [Int: CSVFilterDraft] = [:]
    private var publishedSort: (column: Int, ascending: Bool)?
    private var isTableOperationInFlight = false
    private var isQueryLoadingOverlayVisible = false
    private var isSettingSortDescriptors = false
#if LIGHTXT_STANDALONE_CSV_QA
    private var qaQueryLaunchCountStorage = 0
    private var qaNextColumnName: String?
    private var qaHeaderRetileCountStorage = 0
#endif

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureControls()
        configureTable()
        configureLayout()
        applyAppearance()
    }

    override func layout() {
        super.layout()
        enforceTwoRowHeaderHeight()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        indexingCancellation?.cancel()
        queryCancellation?.cancel()
        summaryCancellation?.cancel()
        mutationCancellation?.cancel()
        exportCancellation?.cancel()
        uniqueValuesTask?.cancel()
        pendingFilterQuery?.cancel()
        displayedRowMap?.close()
    }

    func reloadDocument() {
        isResidentPresentationPurged = false
        generation &+= 1
        let currentGeneration = generation
        indexingCancellation?.cancel()
        cancelQueryAndCloseRowMap()
        cancelColumnSummaryRequest()
        cancelCSVMutation()
        cancelUniqueValueRequest()
        pendingFilterQuery?.cancel()
        pendingFilterQuery = nil
        presentedPopover?.close()
        presentedPopover = nil
        presentedPopoverAnchor = nil
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
            let index = try CSVRowIndex(
                snapshot: captured,
                configuration: CSVRowIndex.Configuration(delimiter: delimiter.rawValue)
            )
            snapshot = captured
            rowIndex = index
            latestProgress = index.progress
            if !activeFilters.isEmpty || activeSort != nil {
                isTableOperationInFlight = true
                showQueryLoadingOverlay(
                    title: projectionVerb,
                    detail: "Building the row index before applying this view…",
                    fraction: index.progress.fractionCompleted
                )
                setOperationBusy(text: "Preparing \(projectionVerb.lowercased())…", fraction: 0)
            } else {
                setBusy(true, text: "Indexing rows…")
            }
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
        isResidentPresentationPurged = false
        generation &+= 1
        indexingCancellation?.cancel()
        indexingCancellation = nil
        cancelQueryAndCloseRowMap()
        cancelColumnSummaryRequest()
        cancelCSVMutation()
        exportCancellation?.cancel()
        exportCancellation = nil
        isTableOperationInFlight = false
        cancelUniqueValueRequest()
        pendingFilterQuery?.cancel()
        pendingFilterQuery = nil
        presentedPopover?.close()
        presentedPopover = nil
        presentedPopoverAnchor = nil
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

    /// Releases parsed presentation rows and visible cell strings without
    /// touching the source snapshot, sparse row index, disk-backed projection
    /// map, filters, sort, or selection. Since CSV edits commit before AppKit
    /// ends field editing, an active field is conservatively left resident.
    var hasPurgedRebuildableResidentMemory: Bool { isResidentPresentationPurged }

    @discardableResult
    func purgeRebuildableResidentMemory() -> Bool {
        guard !isResidentPresentationPurged else { return false }
        guard !isEditingRegistered, presentedPopover == nil else { return false }

        isResidentPresentationPurged = true
        pageDecodeGeneration &+= 1
        pendingPages.removeAll(keepingCapacity: false)
        cachedRecords.removeAll(keepingCapacity: false)
        cacheOrder.removeAll(keepingCapacity: false)
        firstParsedRecord = nil
        reloadTablePreservingSelection()
        return true
    }

    /// Visible pages are decoded lazily after reactivation. This is idempotent
    /// and preserves the exact disk-backed filter/sort projection.
    func reactivateAfterResidentPurge() {
        guard isResidentPresentationPurged else { return }
        isResidentPresentationPurged = false
        reloadTablePreservingSelection()
        if firstRowIsHeader { _ = recordForDisplay(0) }
    }

    var canExportCurrentView: Bool {
        let session = editorDelegate as? LighTxtDocumentSession
        return snapshot != nil
            && rowIndex != nil
            && !isResidentPresentationPurged
            && !isTableOperationInFlight
            && exportCancellation == nil
            && session?.isSourceTextValidated != false
    }

    var isExporting: Bool { exportCancellation != nil }

    func refreshDocumentAccessState() {
        reloadVisibleEditableCells()
    }

    func exportCurrentView() {
        guard canExportCurrentView else {
            NSSound.beep()
            return
        }
        guard commitPendingEdit() else { return }

        let selectedRows = tableView.selectedRowIndexes
        let accessory = TabularExportAccessoryView(
            selectedRowCount: selectedRows.count,
            hasHeaders: firstRowIsHeader
        )
        let panel = NSSavePanel()
        panel.title = "Export Table"
        panel.prompt = "Export"
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = "Export.csv"
        panel.accessoryView = accessory
        accessory.onFormatChange = { [weak panel] format in
            guard let panel else { return }
            let base = URL(fileURLWithPath: panel.nameFieldStringValue)
                .deletingPathExtension().lastPathComponent
            panel.nameFieldStringValue = "\(base).\(format.preferredPathExtension)"
        }

        let completion: (NSApplication.ModalResponse) -> Void = { [weak self, weak panel] response in
            guard response == .OK, let self, let url = panel?.url else { return }
            self.beginExport(to: url, request: accessory.request)
        }
        if let window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(panel.runModal())
        }
    }

    func cancelExport() {
        guard let exportCancellation else { return }
        exportCancellation.cancel()
        setOperationBusy(text: "Cancelling export…", fraction: nil)
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

    func setDelimiter(_ delimiter: DelimitedTextDelimiter, reload: Bool = true) {
        guard self.delimiter != delimiter else {
            synchronizeDelimiterPopup()
            return
        }
        self.delimiter = delimiter
        synchronizeDelimiterPopup()
        if reload { reloadDocument() }
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
        for delimiter in DelimitedTextDelimiter.allCases {
            delimiterPopup.addItem(withTitle: delimiter.displayName)
            delimiterPopup.lastItem?.representedObject = Int(delimiter.rawValue)
        }
        delimiterPopup.target = self
        delimiterPopup.action = #selector(delimiterSettingChanged(_:))
        delimiterPopup.controlSize = .regular
        delimiterPopup.setAccessibilityLabel("Table delimiter")
        delimiterPopup.setAccessibilityHelp("Choose comma, tab, semicolon, or pipe-separated fields")
        synchronizeDelimiterPopup()
        headerCheckbox.target = self
        headerCheckbox.action = #selector(headerSettingChanged(_:))
        headerCheckbox.controlSize = .regular
        headerCheckbox.font = .systemFont(ofSize: 13)
        headerCheckbox.setAccessibilityHelp("Keep the first CSV row fixed as column headings")

        clearFiltersButton.toolTip = "Remove every CSV column filter"
        clearFiltersButton.setAccessibilityLabel("Clear all CSV filters")

        filterStripScrollView.documentView = filterChipContainer
        filterStripScrollView.drawsBackground = false
        filterStripScrollView.borderType = .noBorder
        filterStripScrollView.hasHorizontalScroller = false
        filterStripScrollView.hasVerticalScroller = false
        filterStripScrollView.autohidesScrollers = true
        filterStripScrollView.horizontalScrollElasticity = .allowed
        filterStripScrollView.setAccessibilityLabel("Active CSV filters")
        filterChipContainer.frame = NSRect(x: 0, y: 0, width: 1, height: 30)

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
        headerView.onCommitContainsFilter = { [weak self] column, value in
            self?.commitInlineContainsFilter(column: column, value: value)
        }
        headerView.onShowFilterValues = { [weak self] column in
            self?.showColumnFilter(column: column)
        }
        headerView.filterTextProvider = { [weak self] column in
            self?.activeFilters[column]?.value ?? ""
        }
        headerView.filterEditingEnabledProvider = { [weak self] in
            guard let self else { return false }
            return self.latestProgress?.isComplete == true && self.mutationCancellation == nil
        }
        tableView.headerView = headerView
        tableView.bodyMenuProvider = { [weak self] tableColumn, row in
            self?.rowMenu(forTableColumn: tableColumn, row: row)
        }
        tableView.setAccessibilityLabel("CSV table")

        let rowNumber = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("row-number"))
        rowNumber.title = "#"
        let rowHeader = LighTxtCSVHeaderCell(textCell: "#")
        rowHeader.showsFilterControls = false
        rowNumber.headerCell = rowHeader
        rowNumber.width = 62
        rowNumber.minWidth = 48
        rowNumber.maxWidth = 100
        rowNumber.resizingMask = .userResizingMask
        tableView.addTableColumn(rowNumber)

        scrollView.documentView = tableView
        // Assigning an NSTableView as the document view causes NSScrollView
        // to tile its header clip. Set the custom height after that ownership
        // transfer, then retile so both header rows are actually visible.
        headerView.frame.size.height = LighTxtCSVHeaderView.preferredHeight
        scrollView.tile()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        LighTxtComfortScroller.install(
            in: scrollView,
            vertical: true,
            horizontal: true
        )
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
    }

    private func enforceTwoRowHeaderHeight() {
        guard let header = tableView.headerView else { return }
        let target = LighTxtCSVHeaderView.preferredHeight
        let clipHeight = (header.superview as? NSClipView)?.bounds.height ?? 0
        guard abs(header.frame.height - target) > 0.5 || abs(clipHeight - target) > 0.5 else {
            return
        }
#if LIGHTXT_STANDALONE_CSV_QA
        qaHeaderRetileCountStorage += 1
#endif
        header.frame.size.height = target
        scrollView.tile()
    }

    private func configureLayout() {
        [controls, scrollView, queryLoadingOverlay].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        queryLoadingOverlay.isHidden = true
        [delimiterPopup, headerCheckbox, filterStripScrollView, statusLabel, progressIndicator].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            controls.addSubview($0)
        }

        let stripWidth = filterStripScrollView.widthAnchor.constraint(equalToConstant: 0)
        stripWidth.priority = .defaultHigh
        filterStripWidthConstraint = stripWidth
        filterStripScrollView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let progressWidth = progressIndicator.widthAnchor.constraint(equalToConstant: 150)
        progressWidth.priority = .defaultHigh

        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor),
            controls.topAnchor.constraint(equalTo: topAnchor),
            controls.heightAnchor.constraint(equalToConstant: 48),

            delimiterPopup.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 16),
            delimiterPopup.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            delimiterPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 96),
            headerCheckbox.leadingAnchor.constraint(equalTo: delimiterPopup.trailingAnchor, constant: 12),
            headerCheckbox.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            filterStripScrollView.leadingAnchor.constraint(equalTo: headerCheckbox.trailingAnchor, constant: 12),
            filterStripScrollView.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            filterStripScrollView.heightAnchor.constraint(equalToConstant: 32),
            stripWidth,
            statusLabel.leadingAnchor.constraint(equalTo: filterStripScrollView.trailingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: progressIndicator.leadingAnchor, constant: -14),
            progressIndicator.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -18),
            progressIndicator.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            progressIndicator.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
            progressWidth,

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: controls.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            queryLoadingOverlay.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            queryLoadingOverlay.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            queryLoadingOverlay.topAnchor.constraint(equalTo: scrollView.topAnchor),
            queryLoadingOverlay.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
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
                        delimiter: index.delimiter,
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
                    self?.handleIndexingFailure(error)
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
                    self?.handleIndexingFailure(error)
                }
            }
        }
    }

    private func handleIndexingFailure(_ error: Error) {
        indexingCancellation = nil
        cancelQueryAndCloseRowMap()
        report(error)
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
            if !activeFilters.isEmpty || activeSort != nil {
                showQueryLoadingOverlay(
                    title: projectionVerb,
                    detail: "Finishing the row index  ·  \(rows.formatted()) rows ready",
                    fraction: progress.fractionCompleted
                )
            }
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
            headerCell.filterText = activeFilters[column]?.value ?? ""
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
            guard let tableColumn = tableColumn(forDataColumn: column) else { continue }
            tableColumn.title = columnTitle(column, header: header)
            if let headerCell = tableColumn.headerCell as? LighTxtCSVHeaderCell {
                headerCell.isFiltered = activeFilters[column] != nil
                headerCell.filterText = activeFilters[column]?.value ?? ""
            }
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
        for column in tableView.tableColumns where column.identifier.rawValue != "row-number" {
            tableView.removeTableColumn(column)
        }
    }

    /// Dataset operations always use the immutable source-column identifier,
    /// never the user's current visual order. This keeps filters and mutation
    /// menus attached to the same bytes after drag-reordering columns.
    private func dataColumn(forTableColumnIndex tableColumnIndex: Int) -> Int? {
        guard let tableColumn = tableView.tableColumns[safe: tableColumnIndex] else { return nil }
        return dataColumn(for: tableColumn)
    }

    private func dataColumn(for tableColumn: NSTableColumn) -> Int? {
        let raw = tableColumn.identifier.rawValue
        guard raw.hasPrefix("csv-column-"),
              let column = Int(raw.dropFirst("csv-column-".count)),
              column >= 0,
              column < columnCount else { return nil }
        return column
    }

    private func tableColumn(forDataColumn column: Int) -> NSTableColumn? {
        tableView.tableColumns.first {
            $0.identifier.rawValue == "csv-column-\(column)"
        }
    }

    private func tableColumnIndex(forDataColumn column: Int) -> Int? {
        guard let tableColumn = tableColumn(forDataColumn: column) else { return nil }
        let index = tableView.column(withIdentifier: tableColumn.identifier)
        return index >= 0 ? index : nil
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
            let documentIsReadOnly = (editorDelegate as? LighTxtDocumentSession)?.isReadOnly == true
            cell.isEditable = !documentIsReadOnly && !isTableOperationInFlight
            cell.originalFieldCount = parsed.fields.count
            if let field = parsed.fields[safe: column] {
                cell.stringValue = field.value
                cell.originalValue = field.value
                cell.byteRange = field.byteRange
                cell.isEditable = !documentIsReadOnly
                    && !field.wasTruncated
                    && !isTableOperationInFlight
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
        guard let column = dataColumn(forTableColumnIndex: tableView.clickedColumn) else { return }
        focusedDataColumn = column
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
        guard !isResidentPresentationPurged else { return nil }
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

    private func reloadTablePreservingSelection() {
        let selection = tableView.selectedRowIndexes
        tableView.reloadData()
        let rowCount = numberOfRows(in: tableView)
        var validSelection = IndexSet()
        for row in selection where row >= 0 && row < rowCount {
            validSelection.insert(row)
        }
        tableView.selectRowIndexes(validSelection, byExtendingSelection: false)
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
        guard !isResidentPresentationPurged else { return }
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
                            delimiter: rowIndex.delimiter,
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
        for column in tableView.tableColumns.indices
        where dataColumn(forTableColumnIndex: column) != nil
            && tableView.rect(ofColumn: column).intersects(tableView.visibleRect) {
                columns.insert(column)
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
            let replacement = CSVRecordParser.encodedField(
                field.stringValue,
                delimiter: rowIndex.delimiter
            )
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
                var appended = Data(
                    repeating: rowIndex.delimiter,
                    count: missingSeparators
                )
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

    @objc private func delimiterSettingChanged(_ sender: NSPopUpButton) {
        guard !isTableOperationInFlight,
              commitPendingEdit(),
              let raw = sender.selectedItem?.representedObject as? Int,
              let selected = DelimitedTextDelimiter(rawValue: UInt8(clamping: raw)) else {
            synchronizeDelimiterPopup()
            NSSound.beep()
            return
        }
        (editorDelegate as? LighTxtDocumentSession)?.setDelimitedTextDelimiter(selected)
        setDelimiter(selected)
    }

    private func synchronizeDelimiterPopup() {
        if let item = delimiterPopup.itemArray.first(where: {
            ($0.representedObject as? Int) == Int(delimiter.rawValue)
        }) {
            delimiterPopup.select(item)
        }
    }

    private func columnMenu(forTableColumn tableColumn: Int) -> NSMenu? {
        guard let column = dataColumn(forTableColumnIndex: tableColumn) else { return nil }
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
        before.isEnabled = canStartDatasetMutation
        menu.addItem(before)
        let after = menuItem("Add Column After", symbol: "arrow.right.to.line.compact", action: #selector(addColumnAfter(_:)))
        after.representedObject = column
        after.isEnabled = canStartDatasetMutation
            && column + 1 < Self.maximumPresentedColumns
        menu.addItem(after)
        let delete = menuItem("Delete Column…", symbol: "trash", action: #selector(deleteCurrentColumn(_:)))
        delete.representedObject = column
        delete.isEnabled = canStartDatasetMutation
        menu.addItem(delete)
        return menu
    }

    private func rowMenu(forTableColumn tableColumn: Int, row: Int) -> NSMenu? {
        let isExistingRow = row >= 0 && row < tableView.numberOfRows
        if !isExistingRow {
            tableView.deselectAll(nil)
            let menu = NSMenu(title: "CSV Table")
            let addRow = menuItem(
                "Add Row",
                symbol: "plus.rectangle.on.rectangle",
                action: #selector(addRowBelow(_:))
            )
            addRow.isEnabled = canStartDatasetMutation
            menu.addItem(addRow)
            if columnCount == 0 {
                let addColumn = menuItem(
                    "Add Column…",
                    symbol: "rectangle.split.1x2",
                    action: #selector(addFirstColumn(_:))
                )
                addColumn.isEnabled = canStartDatasetMutation
                menu.addItem(addColumn)
            }
            return menu
        }
        if !tableView.selectedRowIndexes.contains(row) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        if let column = dataColumn(forTableColumnIndex: tableColumn) {
            focusedDataColumn = column
        }
        let selectedRows = selectedVisibleRows()
        let menu = NSMenu(title: "CSV Row")
        let above = menuItem(
            "Add Row Above",
            symbol: "arrow.up.to.line.compact",
            action: #selector(addRowAbove(_:))
        )
        above.isEnabled = canStartDatasetMutation
        menu.addItem(above)
        let below = menuItem(
            "Add Row Below",
            symbol: "arrow.down.to.line.compact",
            action: #selector(addRowBelow(_:))
        )
        below.isEnabled = canStartDatasetMutation
        menu.addItem(below)
        menu.addItem(.separator())
        let deleteTitle = selectedRows.count > 1
            ? "Delete \(selectedRows.count.formatted()) Rows"
            : "Delete Row"
        let deleteRows = menuItem(
            deleteTitle,
            symbol: "trash",
            action: #selector(deleteSelectedRows(_:))
        )
        deleteRows.isEnabled = canStartDatasetMutation && !selectedRows.isEmpty
        menu.addItem(deleteRows)
        return menu
    }

    private func menuItem(_ title: String, symbol: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    private var currentColumnTitle: String {
        guard columnCount > 0 else { return "" }
        let column = min(max(0, focusedDataColumn), columnCount - 1)
        return tableColumn(forDataColumn: column)?.title ?? spreadsheetColumnName(column)
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
        guard column >= 0,
              column < columnCount,
              let tableColumn = tableColumn(forDataColumn: column) else { return }
        focusedDataColumn = column
        let descriptor = NSSortDescriptor(
            key: tableColumn.identifier.rawValue,
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

    private var canStartDatasetMutation: Bool {
        canStartDatasetOperation
            && (editorDelegate as? LighTxtDocumentSession)?.isReadOnly != true
    }

    @discardableResult
    private func guardDatasetOperationAvailable() -> Bool {
        guard canStartDatasetOperation else {
            NSSound.beep()
            return false
        }
        return true
    }

    @discardableResult
    private func guardDatasetMutationAvailable() -> Bool {
        guard canStartDatasetMutation else {
            NSSound.beep()
            return false
        }
        return true
    }

    private func restoreSortDescriptorChrome() {
        isSettingSortDescriptors = true
        if let activeSort,
           activeSort.column >= 0,
           activeSort.column < columnCount,
           let tableColumn = tableColumn(forDataColumn: activeSort.column) {
            tableView.sortDescriptors = [NSSortDescriptor(
                key: tableColumn.identifier.rawValue,
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
        guard guardDatasetMutationAvailable() else { return }
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
        guard guardDatasetMutationAvailable() else { return }
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
        guard guardDatasetMutationAvailable() else { return }
        requestAddColumn(at: representedColumn(sender))
    }

    @objc private func addFirstColumn(_ sender: Any?) {
        guard guardDatasetMutationAvailable() else { return }
        requestAddColumn(at: 0)
    }

    @objc private func addColumnAfter(_ sender: Any?) {
        guard guardDatasetMutationAvailable() else { return }
        requestAddColumn(at: representedColumn(sender) + 1)
    }

    @objc private func deleteSelectedRows(_ sender: Any?) {
        guard guardDatasetMutationAvailable() else { return }
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
        guard guardDatasetMutationAvailable() else { return }
        guard columnCount > 0 else { return }
        let column = representedColumn(sender)
        let title = tableColumn(forDataColumn: column)?.title ?? spreadsheetColumnName(column)
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
        showColumnFilter(column: representedColumn(sender))
    }

    private func showColumnFilter(column: Int) {
        showColumnFilter(column: column, anchorView: nil)
    }

    private func showColumnFilter(column: Int, anchorView: NSView?) {
        guard latestProgress?.isComplete == true,
              mutationCancellation == nil,
              column >= 0,
              column < columnCount,
              let title = tableColumn(forDataColumn: column)?.title else {
            NSSound.beep()
            return
        }
        focusedDataColumn = column
        let controller = CSVFilterPopoverViewController(
            columnTitle: title,
            filter: activeFilters[column]
        )
        controller.onCommit = { [weak self] filter in
            guard let self else { return }
            self.commitFilterDraft(filter, for: column)
        }
        controller.onClear = { [weak self] in
            guard let self else { return }
            self.clearFilter(column: column, closePopover: false)
        }
        presentPopover(controller, forDataColumn: column, anchorView: anchorView)
        requestUniqueValues(column: column, controller: controller)
    }

    @objc private func clearColumnFilter(_ sender: Any?) {
        clearFilter(column: representedColumn(sender), closePopover: false)
    }

    @objc private func clearAllFilters(_ sender: Any?) {
        guard !activeFilters.isEmpty else { return }
        guard !isEditingRegistered || commitPendingEdit() else { return }
        activeFilters.removeAll(keepingCapacity: true)
        updateFilterChrome()
        scheduleFilterQuery()
    }

    private func updateFilterChrome() {
        for column in 0..<columnCount {
            if let headerCell = tableColumn(forDataColumn: column)?.headerCell as? LighTxtCSVHeaderCell {
                headerCell.isFiltered = activeFilters[column] != nil
                headerCell.filterText = activeFilters[column]?.value ?? ""
            }
        }
        rebuildFilterStrip()
        (tableView.headerView as? LighTxtCSVHeaderView)?.refreshFilterDisplay()
        tableView.headerView?.needsDisplay = true
    }

    private func commitInlineContainsFilter(column: Int, value: String) {
        let current = activeFilters[column] ?? CSVFilterDraft(
            predicate: .contains,
            value: "",
            isCaseSensitive: false
        )
        commitFilterDraft(CSVFilterDraft(
            predicate: .contains,
            value: value,
            isCaseSensitive: false,
            selectedValues: current.selectedValues
        ), for: column)
    }

    private func commitFilterDraft(_ draft: CSVFilterDraft, for column: Int) {
        guard column >= 0, column < columnCount else { return }
        guard mutationCancellation == nil else {
            NSSound.beep()
            return
        }
        // A failed table-cell validation must not change the filter state or
        // launch a query against bytes that were not durably committed.
        guard !isEditingRegistered || commitPendingEdit() else { return }
        let previous = activeFilters[column]
        if draft.isEmpty {
            activeFilters.removeValue(forKey: column)
        } else {
            activeFilters[column] = draft
        }
        guard previous != activeFilters[column] else { return }
        updateFilterChrome()
        scheduleFilterQuery()
    }

    private func clearFilter(column: Int, closePopover: Bool) {
        guard !isEditingRegistered || commitPendingEdit() else { return }
        guard activeFilters.removeValue(forKey: column) != nil else { return }
        if closePopover {
            cancelUniqueValueRequest()
            cancelColumnSummaryRequest()
            presentedPopover?.close()
            presentedPopover = nil
            presentedPopoverAnchor = nil
        }
        updateFilterChrome()
        scheduleFilterQuery()
    }

    /// Typing edits only local draft state. Commits from Return, focus loss,
    /// or checkbox selection coalesce so rapid selections do not repeatedly
    /// scan a multi-gigabyte file.
    private func scheduleFilterQuery() {
        // Invalidate the currently running generation now, not after the UI
        // debounce, so its stale map can never publish beneath newer chips.
        queryGeneration &+= 1
        queryCancellation?.cancel()
        queryCancellation = nil
        pendingFilterQuery?.cancel()
        isTableOperationInFlight = true
        showQueryLoadingOverlay(
            title: activeFilters.isEmpty && activeSort == nil ? "Restoring all rows" : projectionVerb,
            detail: "Preparing a fresh table view…",
            fraction: nil
        )
        setOperationBusy(
            text: activeFilters.isEmpty && activeSort == nil
                ? "Restoring all rows…"
                : "\(projectionVerb)…",
            fraction: nil
        )
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingFilterQuery = nil
            self.requestApplyQuery()
        }
        pendingFilterQuery = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(180), execute: work)
    }

    private func rebuildFilterStrip() {
        filterChipContainer.subviews.forEach { $0.removeFromSuperview() }
        guard !activeFilters.isEmpty else {
            filterChipContainer.frame = NSRect(x: 0, y: 0, width: 1, height: 30)
            filterStripWidthConstraint?.constant = 0
            filterStripScrollView.isHidden = true
            return
        }

        var x: CGFloat = 0
        for column in activeFilters.keys.sorted() {
            guard let draft = activeFilters[column] else { continue }
            let title = tableColumn(forDataColumn: column)?.title ?? spreadsheetColumnName(column)
            let chip = CSVFilterChipView(
                sourceColumn: column,
                title: title,
                summary: draft.shortSummary,
                fullDescription: draft.accessibilityDescription(columnTitle: title)
            )
            chip.onOpen = { [weak self, weak chip] in
                self?.showColumnFilter(column: column, anchorView: chip)
            }
            chip.onClear = { [weak self] in self?.clearFilter(column: column, closePopover: true) }
            chip.frame.origin = NSPoint(x: x, y: 1)
            filterChipContainer.addSubview(chip)
            x += chip.frame.width + 6
        }
        clearFiltersButton.title = "Clear filters"
        clearFiltersButton.sizeToFit()
        clearFiltersButton.frame = NSRect(
            x: x,
            y: 1,
            width: max(94, clearFiltersButton.frame.width + 10),
            height: 28
        )
        filterChipContainer.addSubview(clearFiltersButton)
        x = clearFiltersButton.frame.maxX
        filterChipContainer.frame = NSRect(x: 0, y: 0, width: max(1, x), height: 30)
        filterStripWidthConstraint?.constant = min(430, x)
        filterStripScrollView.isHidden = false
    }

    private func requestUniqueValues(
        column: Int,
        controller: CSVFilterPopoverViewController
    ) {
        cancelUniqueValueRequest()
        guard let snapshot, let rowIndex else { return }
        let firstRecord: Int64 = firstRowIsHeader ? 1 : 0
        let baseFilters = coreFilters(excluding: column)
        let progressRelay = CSVUniqueValuesProgressRelay(controller: controller)
        controller.showUniqueValuesLoading()
        uniqueValuesTask = Task { [weak self, weak controller] in
            do {
                let result = try await CSVUniqueValueProvider.values(
                    snapshot: snapshot,
                    index: rowIndex,
                    column: column,
                    firstRecord: firstRecord,
                    baseFilters: baseFilters,
                    configuration: .init(
                        pageRecordCount: 4_096,
                        maximumUniqueValueCount: 500,
                        maximumValueBytes: 64 << 10
                    ),
                    progress: { @Sendable progress in progressRelay.report(progress) }
                )
                guard !Task.isCancelled,
                      let self,
                      let controller,
                      self.presentedPopover?.contentViewController === controller else { return }
                controller.showUniqueValues(result)
                self.uniqueValuesTask = nil
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      let self,
                      let controller,
                      self.presentedPopover?.contentViewController === controller else { return }
                controller.showUniqueValues(error: error)
                self.uniqueValuesTask = nil
            }
        }
    }

    private func cancelUniqueValueRequest() {
        uniqueValuesTask?.cancel()
        uniqueValuesTask = nil
    }

    @objc private func showColumnSummary(_ sender: Any?) {
        guard guardDatasetOperationAvailable() else { return }
        guard columnCount > 0 else { return }
        let column = representedColumn(sender)
        let title = tableColumn(forDataColumn: column)?.title ?? spreadsheetColumnName(column)
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

    private func presentPopover(
        _ controller: NSViewController,
        forDataColumn column: Int,
        anchorView: NSView? = nil
    ) {
        cancelUniqueValueRequest()
        cancelColumnSummaryRequest()
        presentedPopover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = controller
        presentedPopover = popover
        if let chip = anchorView as? CSVFilterChipView {
            // A committed draft rebuilds the chip strip. Anchor to its stable
            // container (using the clicked chip's current rect) so removing
            // and recreating that chip cannot detach or close this popover.
            let anchorRect = filterChipContainer.convert(chip.bounds, from: chip)
            presentedPopoverAnchor = .filterChip(column: column)
            popover.show(relativeTo: anchorRect, of: filterChipContainer, preferredEdge: .maxY)
            return
        }
        guard let header = tableView.headerView,
              let tableColumn = tableColumnIndex(forDataColumn: column) else {
            presentedPopover = nil
            presentedPopoverAnchor = nil
            cancelUniqueValueRequest()
            cancelColumnSummaryRequest()
            return
        }
        presentedPopoverAnchor = .tableHeader(column: column)
        popover.show(
            relativeTo: header.headerRect(ofColumn: tableColumn),
            of: header,
            preferredEdge: .maxY
        )
    }

    private func dismissPopover(containing controller: NSViewController?) {
        guard let controller, presentedPopover?.contentViewController === controller else { return }
        cancelUniqueValueRequest()
        cancelColumnSummaryRequest()
        presentedPopover?.close()
        presentedPopover = nil
        presentedPopoverAnchor = nil
    }

    func popoverDidClose(_ notification: Notification) {
        if notification.object as? NSPopover === presentedPopover {
            presentedPopover = nil
            presentedPopoverAnchor = nil
            cancelColumnSummaryRequest()
            cancelUniqueValueRequest()
        }
    }

    // MARK: - Query and mutation adapters

    /// Core integration lives behind these methods so the native AppKit state
    /// machine stays independent from the bounded, file-backed algorithms.
    private func requestSort(column: Int?, ascending: Bool) {
        guard !isEditingRegistered || commitPendingEdit() else { return }
        activeSort = column.map { ($0, ascending) }
        requestApplyQuery()
    }

    private func requestApplyQuery() {
        // Filter controls have their own committed/draft lifecycle. Ending all
        // window editing here would steal focus from a popover or inline
        // search field shortly after the user typed the first characters.
        guard !isEditingRegistered || commitPendingEdit() else {
            restorePublishedProjectionAfterQueryRefusal()
            return
        }
#if LIGHTXT_STANDALONE_CSV_QA
        qaQueryLaunchCountStorage += 1
#endif
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
            publishedFilters = activeFilters
            publishedSort = activeSort
            tableView.deselectAll(nil)
            tableView.reloadData()
            hideQueryLoadingOverlay()
            restoreTableStatus()
            return
        }
        guard latestProgress?.isComplete == true else {
            let rows = latestProgress?.knownRecordCount ?? 0
            showQueryLoadingOverlay(
                title: projectionVerb,
                detail: "Finishing the row index  ·  \(rows.formatted()) rows ready",
                fraction: latestProgress?.fractionCompleted
            )
            setOperationBusy(
                text: "Preparing \(projectionVerb.lowercased())…  ·  \(rows.formatted()) rows indexed",
                fraction: latestProgress?.fractionCompleted
            )
            return
        }
        guard let snapshot, let rowIndex else {
            hideQueryLoadingOverlay()
            return
        }

        let filters = coreFilters()
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
        showQueryLoadingOverlay(
            title: projectionVerb,
            detail: "Scanning rows and building the new result…",
            fraction: 0
        )
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
                    self.publishedFilters = self.activeFilters
                    self.publishedSort = self.activeSort
                    self.tableView.deselectAll(nil)
                    self.tableView.reloadData()
                    self.hideQueryLoadingOverlay()
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

    private func restorePublishedProjectionAfterQueryRefusal() {
        activeFilters = publishedFilters
        activeSort = publishedSort
        isSettingSortDescriptors = true
        if let publishedSort,
           let tableColumn = tableColumn(forDataColumn: publishedSort.column) {
            tableView.sortDescriptors = [
                NSSortDescriptor(
                    key: tableColumn.identifier.rawValue,
                    ascending: publishedSort.ascending
                ),
            ]
        } else {
            tableView.sortDescriptors = []
        }
        isSettingSortDescriptors = false
        isTableOperationInFlight = false
        updateFilterChrome()
        hideQueryLoadingOverlay()
        restoreTableStatus()
    }

    private func coreFilters(excluding excludedColumn: Int? = nil) -> [CSVColumnFilter] {
        activeFilters.keys.sorted().compactMap { column -> CSVColumnFilter? in
            guard column != excludedColumn,
                  let draft = activeFilters[column],
                  !draft.isEmpty else { return nil }
            return CSVColumnFilter(
                column: column,
                containsText: draft.value,
                selectedValues: draft.selectedValues,
                containsCaseSensitive: draft.isCaseSensitive,
                selectedValuesCaseSensitive: true
            )
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
        showQueryLoadingOverlay(
            title: projectionVerb,
            detail: "\(progress.matchedRecordCount.formatted()) matches  ·  \(progress.scannedRecordCount.formatted()) rows checked",
            fraction: fraction ?? progress.indexedFractionCompleted
        )
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
        hideQueryLoadingOverlay()
    }

    private func requestAddRow(atSourceRecord record: Int64) {
        guard guardDatasetMutationAvailable(),
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
                index: rowIndex,
                delimiter: rowIndex.delimiter
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
        guard guardDatasetMutationAvailable(),
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
        guard guardDatasetMutationAvailable() else { return }
        guard guardVisibleColumnInsertion(at: column) else { return }
        let isEmptyDocument = snapshot?.byteCount == 0
        guard firstRowIsHeader || isEmptyDocument else {
            applyColumnMutation(.insert(CSVColumnInsertion(column: column)), label: "Adding column")
            return
        }
#if LIGHTXT_STANDALONE_CSV_QA
        // The runtime harness still dispatches the real context-menu action;
        // this supplies the value a user would enter into the naming sheet so
        // headless AppKit services do not make the test depend on alert UI.
        if let name = qaNextColumnName {
            qaNextColumnName = nil
            applyNamedColumn(name, at: column, toEmptyDocument: isEmptyDocument)
            return
        }
#endif
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
            self.applyNamedColumn(name, at: column, toEmptyDocument: isEmptyDocument)
        }
        if let window {
            alert.beginSheetModal(for: window, completionHandler: apply)
        } else {
            apply(alert.runModal())
        }
    }

    private func applyNamedColumn(
        _ name: String,
        at column: Int,
        toEmptyDocument isEmptyDocument: Bool
    ) {
        if isEmptyDocument {
            firstRowIsHeader = true
            headerDetectionCompleted = true
            headerCheckbox.state = .on
            requestBootstrapColumn(named: name)
        } else {
            applyColumnMutation(
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

    private func requestDeleteColumn(_ column: Int) {
        guard guardDatasetMutationAvailable() else { return }
        applyColumnMutation(.delete(column: column), label: "Deleting column")
    }

    private func requestBootstrapColumn(named name: String) {
        guard guardDatasetMutationAvailable(),
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
            var bytes = CSVRecordParser.encodedField(
                name,
                delimiter: self.delimiter.rawValue
            )
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
        (tableView.headerView as? LighTxtCSVHeaderView)?.refreshFilterDisplay()
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
                    (self.tableView.headerView as? LighTxtCSVHeaderView)?.refreshFilterDisplay()
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
        (tableView.headerView as? LighTxtCSVHeaderView)?.refreshFilterDisplay()
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
        guard guardDatasetMutationAvailable(),
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
        cancelUniqueValueRequest()
        cancelColumnSummaryRequest()
        presentedPopover?.close()
        presentedPopover = nil
        presentedPopoverAnchor = nil
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
        (tableView.headerView as? LighTxtCSVHeaderView)?.refreshFilterDisplay()
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
                (self.tableView.headerView as? LighTxtCSVHeaderView)?.refreshFilterDisplay()
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
        (tableView.headerView as? LighTxtCSVHeaderView)?.refreshFilterDisplay()
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
        guard column >= 0,
              column < columnCount,
              let tableColumn = tableColumn(forDataColumn: column) else { return }
        let oldDescriptors = tableView.sortDescriptors
        let nextDescriptor: NSSortDescriptor
        if activeSort?.column == column, activeSort?.ascending == true {
            nextDescriptor = NSSortDescriptor(
                key: tableColumn.identifier.rawValue,
                ascending: false
            )
        } else {
            nextDescriptor = NSSortDescriptor(
                key: tableColumn.identifier.rawValue,
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

    func qaBeginInlineContainsFilter(column: Int) {
        (tableView.headerView as? LighTxtCSVHeaderView)?.qaBeginEditing(dataColumn: column)
    }

    func qaTypeInlineContainsFilter(_ value: String) {
        (tableView.headerView as? LighTxtCSVHeaderView)?.qaType(value)
    }

    func qaCommitInlineContainsFilter() {
        (tableView.headerView as? LighTxtCSVHeaderView)?.qaCommit()
    }

    func qaCancelInlineContainsFilter() {
        (tableView.headerView as? LighTxtCSVHeaderView)?.qaCancel()
    }

    var qaInlineFilterHasFocus: Bool {
        (tableView.headerView as? LighTxtCSVHeaderView)?.qaHasFocus == true
    }

    func qaShowFilterPopover(column: Int) { showColumnFilter(column: column) }

    func qaTypePopoverContains(_ value: String) {
        (presentedPopover?.contentViewController as? CSVFilterPopoverViewController)?.qaType(value)
    }

    func qaCommitPopoverContains() {
        (presentedPopover?.contentViewController as? CSVFilterPopoverViewController)?.qaCommit()
    }

    func qaEndPopoverContainsEditingByFocusLoss() {
        (presentedPopover?.contentViewController as? CSVFilterPopoverViewController)?
            .qaEndEditingByFocusLoss()
    }

    var qaPopoverFilterHasFocus: Bool {
        (presentedPopover?.contentViewController as? CSVFilterPopoverViewController)?.qaHasFocus == true
    }

    var qaPopoverUniqueValues: [String] {
        (presentedPopover?.contentViewController as? CSVFilterPopoverViewController)?.qaUniqueValues ?? []
    }

    func qaTogglePopoverValue(_ value: String) {
        (presentedPopover?.contentViewController as? CSVFilterPopoverViewController)?.qaToggle(value)
    }

    func qaCommittedFilter(column: Int) -> (contains: String, selected: Set<String>)? {
        activeFilters[column].map { ($0.value, $0.selectedValues) }
    }

    var qaFilterChipCount: Int {
        filterChipContainer.subviews.compactMap { $0 as? CSVFilterChipView }.count
    }

    func qaOpenFilterChip(column: Int) {
        filterChipContainer.subviews
            .compactMap { $0 as? CSVFilterChipView }
            .first { $0.sourceColumn == column }?
            .qaOpen()
    }

    func qaClearFilterChip(column: Int) {
        filterChipContainer.subviews
            .compactMap { $0 as? CSVFilterChipView }
            .first { $0.sourceColumn == column }?
            .qaClear()
    }

    func qaMoveDataColumn(_ column: Int, toVisualIndex destination: Int) {
        guard let source = tableColumnIndex(forDataColumn: column),
              destination >= 0,
              destination < tableView.tableColumns.count else { return }
        tableView.moveColumn(source, toColumn: destination)
    }

    func qaScrollDataColumnToVisible(_ column: Int) {
        guard let index = tableColumnIndex(forDataColumn: column) else { return }
        tableView.scrollColumnToVisible(index)
        let target = tableView.rect(ofColumn: index)
        let clipView = scrollView.contentView
        if !clipView.bounds.contains(target) {
            let x = target.minX < clipView.bounds.minX
                ? target.minX
                : target.maxX - clipView.bounds.width
            clipView.scroll(to: NSPoint(x: max(0, x), y: clipView.bounds.minY))
            scrollView.reflectScrolledClipView(clipView)
        }
        // An offscreen titled QA window does not receive WindowServer-driven
        // header synchronization. Scroll the real header clip to the same
        // document coordinate so its visible-only controls exercise the same
        // geometry as an onscreen horizontal scroll.
        if let headerClip = tableView.headerView?.superview as? NSClipView {
            headerClip.scroll(to: NSPoint(x: clipView.bounds.minX, y: headerClip.bounds.minY))
        }
    }

    func qaResizeDataColumn(_ column: Int, width: CGFloat) {
        guard let tableColumn = tableColumn(forDataColumn: column) else { return }
        tableColumn.width = width
        tableView.headerView?.needsLayout = true
        tableView.headerView?.needsDisplay = true
    }

    var qaHorizontalOffset: CGFloat { tableView.visibleRect.minX }

    var qaAccessibleFilterButtonColumns: Set<Int> {
        guard let header = tableView.headerView as? LighTxtCSVHeaderView else { return [] }
        header.qaSynchronizeFilterButtons()
        return header.qaFilterButtonColumns
    }

    func qaHeaderGeometry(column: Int) -> (
        header: NSRect,
        title: NSRect,
        filter: NSRect,
        input: NSRect,
        funnel: NSRect,
        clipBounds: NSRect,
        titleInClip: NSRect,
        filterInClip: NSRect,
        drawnTitleInClip: NSRect,
        actualInputInClip: NSRect,
        actualTextInClip: NSRect,
        actualFunnelInClip: NSRect,
        interiorFrame: NSRect,
        resolvedLayoutFrame: NSRect
    )? {
        guard let header = tableView.headerView as? LighTxtCSVHeaderView,
              let clipView = header.superview as? NSClipView,
              let visualIndex = tableColumnIndex(forDataColumn: column),
              let tableColumn = tableView.tableColumns[safe: visualIndex],
              let cell = tableColumn.headerCell as? LighTxtCSVHeaderCell else { return nil }
        header.qaSynchronizeFilterButtons()
        header.needsDisplay = true
        header.display()
        let visibleHeader = header.visibleRect
        if !visibleHeader.isEmpty,
           let bitmap = header.bitmapImageRepForCachingDisplay(in: visibleHeader) {
            // Hidden/offscreen QA windows do not always receive a WindowServer
            // display pass after scrolling. Caching the actual visible header
            // exercises drawInterior and records its real presentation rect.
            header.cacheDisplay(in: visibleHeader, to: bitmap)
        }
        let headerRect = header.headerRect(ofColumn: visualIndex)
        if abs(cell.qaLastResolvedLayoutFrame.minX - headerRect.minX) > 0.5
            || abs(cell.qaLastResolvedLayoutFrame.width - headerRect.width) > 0.5 {
            // Offscreen hosted windows can suppress AppKit's cell display pass
            // even after their real header clip scrolls. Refresh only the QA
            // presentation record through the same full-row geometry.
            cell.qaRefreshPresentationGeometry(in: headerRect, controlView: header)
        }
        guard let actual = header.qaFilterPresentationRects(column: column) else { return nil }
        let titleRect = cell.titleRect(in: headerRect, controlView: header)
        let filterRect = cell.filterControlRect(in: headerRect, controlView: header)
        return (
            headerRect,
            titleRect,
            filterRect,
            cell.filterInputRect(in: headerRect, controlView: header),
            cell.funnelRect(in: headerRect, controlView: header),
            clipView.bounds,
            clipView.convert(titleRect, from: header),
            clipView.convert(filterRect, from: header),
            clipView.convert(cell.qaLastDrawnTitleRect, from: header),
            clipView.convert(actual.input, from: header),
            clipView.convert(actual.text, from: header),
            clipView.convert(actual.funnel, from: header),
            cell.qaLastInteriorFrame,
            cell.qaLastResolvedLayoutFrame
        )
    }

    func qaRowContextMenuTitles(row: Int) -> [String] {
        rowMenu(forTableColumn: tableColumnIndex(forDataColumn: 0) ?? 0, row: row)?
            .items.filter { !$0.isSeparatorItem }.map(\.title) ?? []
    }

    var qaEmptySpaceContextMenuTitles: [String] {
        rowMenu(forTableColumn: -1, row: -1)?
            .items.filter { !$0.isSeparatorItem }.map(\.title) ?? []
    }

    @discardableResult
    func qaPerformEmptySpaceContextMenuItem(
        named title: String,
        columnName: String? = nil
    ) -> Bool {
        qaNextColumnName = columnName
        guard let item = rowMenu(forTableColumn: -1, row: -1)?
            .items.first(where: { !$0.isSeparatorItem && $0.title == title }),
              item.isEnabled,
              let action = item.action else {
            qaNextColumnName = nil
            return false
        }
        let sent = NSApp.sendAction(action, to: item.target, from: item)
        if !sent { qaNextColumnName = nil }
        return sent
    }

    var qaHasPresentedPopover: Bool { presentedPopover != nil }
    var qaPopoverAnchoredToFilterChip: Bool {
        if case .filterChip = presentedPopoverAnchor { return true }
        return false
    }

    var qaStructuralMutationInFlight: Bool { mutationCancellation != nil }
    var qaQueryLaunchCount: Int { qaQueryLaunchCountStorage }
    var qaHeaderRetileCount: Int { qaHeaderRetileCountStorage }
    var qaIsQueryLoadingOverlayVisible: Bool {
        isQueryLoadingOverlayVisible && !queryLoadingOverlay.isHidden
    }
    var qaQueryOverlayConsumesHitTest: Bool {
        queryLoadingOverlay.hitTest(
            NSPoint(x: queryLoadingOverlay.bounds.midX, y: queryLoadingOverlay.bounds.midY)
        ) != nil
    }
    var qaPresentedTableAlpha: CGFloat { scrollView.alphaValue }
    var qaPresentedTableIsEnabled: Bool { tableView.isEnabled }
    var qaPopoverContentView: NSView? { presentedPopover?.contentViewController?.view }

    func qaPreparePopoverCaptureBackground() {
        (presentedPopover?.contentViewController as? CSVFilterPopoverViewController)?
            .qaPrepareCaptureBackground()
    }

    var qaFilterAffordanceContrast: CGFloat {
        guard let header = tableView.headerView as? LighTxtCSVHeaderView else { return 0 }
        header.qaSynchronizeFilterButtons()
        return header.qaMinimumFilterAffordanceContrast
    }

    func qaShowColumnSummary(column: Int) {
        let item = NSMenuItem()
        item.representedObject = column
        showColumnSummary(item)
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
    var qaColumnTitles: [String] {
        (0..<columnCount).compactMap { tableColumn(forDataColumn: $0)?.title }
    }

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
        publishedSort = nil
        publishedFilters.removeAll(keepingCapacity: true)
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
        headerCheckbox.isEnabled = latestProgress?.isComplete == true && !isTableOperationInFlight
        delimiterPopup.isEnabled = !isTableOperationInFlight
        onStatusChange?(text, busy)
    }

    private func setOperationBusy(text: String, fraction: Double?) {
        isTableOperationInFlight = true
        statusLabel.stringValue = text
        statusLabel.setAccessibilityValue(text)
        progressIndicator.doubleValue = min(1, max(0, fraction ?? 0))
        progressIndicator.isHidden = false
        headerCheckbox.isEnabled = false
        delimiterPopup.isEnabled = false
        onStatusChange?(text, true)
        reloadVisibleEditableCells()
    }

    /// A query is transactional from the user's point of view: the rows
    /// underneath remain the last complete result until the next row map is
    /// ready. Fade and cover those stale rows so they can never be mistaken
    /// for the filter currently shown in the header.
    private func showQueryLoadingOverlay(
        title: String,
        detail: String,
        fraction: Double?
    ) {
        queryLoadingOverlay.update(title: title, detail: detail, progress: fraction)
        queryLoadingOverlay.blocksInteraction = true
        tableView.isEnabled = false
        scrollView.setAccessibilityHidden(true)
        queryLoadingOverlay.startAnimating()

        guard !isQueryLoadingOverlayVisible else { return }
        isQueryLoadingOverlayVisible = true
        queryLoadingOverlay.isHidden = false
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            scrollView.alphaValue = 0.30
            queryLoadingOverlay.alphaValue = 1
            return
        }
        queryLoadingOverlay.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            scrollView.animator().alphaValue = 0.30
            queryLoadingOverlay.animator().alphaValue = 1
        }
    }

    private func hideQueryLoadingOverlay() {
        queryLoadingOverlay.blocksInteraction = false
        tableView.isEnabled = true
        scrollView.setAccessibilityHidden(false)
        queryLoadingOverlay.stopAnimating()
        guard isQueryLoadingOverlayVisible || !queryLoadingOverlay.isHidden else {
            scrollView.alphaValue = 1
            return
        }
        isQueryLoadingOverlayVisible = false
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if reduceMotion {
            scrollView.alphaValue = 1
            queryLoadingOverlay.alphaValue = 0
            queryLoadingOverlay.isHidden = true
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            scrollView.animator().alphaValue = 1
            queryLoadingOverlay.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isQueryLoadingOverlayVisible else { return }
                self.queryLoadingOverlay.isHidden = true
            }
        }
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
        let dataColumns = IndexSet(
            tableView.tableColumns.indices.filter { dataColumn(forTableColumnIndex: $0) != nil }
        )
        tableView.reloadData(
            forRowIndexes: IndexSet(
                integersIn: visible.location..<(visible.location + visible.length)
            ),
            columnIndexes: dataColumns
        )
    }

    private func beginExport(to url: URL, request: TabularExportRequest) {
        guard let snapshot, let rowIndex, !isTableOperationInFlight else {
            NSSound.beep()
            return
        }
        let expectedDestination: FileFingerprint?
        do {
            // Freeze the destination at save-panel acceptance. Capturing this
            // later on the worker could silently bless a file changed during
            // the handoff from the sheet to the export queue.
            let accessStarted = url.startAccessingSecurityScopedResource()
            defer { if accessStarted { url.stopAccessingSecurityScopedResource() } }
            expectedDestination = try TabularExportSink.expectedDestination(at: url)
        } catch {
            report(error)
            return
        }

        // Export scope is row-based in the shared accessory. Always preserve
        // the complete presented schema, matching Parquet table export.
        let columns = Array(0..<columnCount)
        let columnNames = columns.map { column in
            tableColumn(forDataColumn: column)?.title ?? spreadsheetColumnName(column)
        }
        let selectedDisplayedRows = request.scope == .selectedRows
            ? tableView.selectedRowIndexes
            : nil
        guard request.scope != .selectedRows || selectedDisplayedRows?.isEmpty == false else {
            NSSound.beep()
            return
        }

        let displayedMap = displayedRowMap
        let firstRecord: Int64 = firstRowIsHeader ? 1 : 0
        let totalRows: Int64? = selectedDisplayedRows.map { Int64($0.count) }
            ?? displayedMap?.rowCount
            ?? latestProgress?.totalRecordCount.map { max(0, $0 - firstRecord) }
        let headers = request.includesHeaders ? columnNames : nil
        let format = request.format
        let cancellation = CancellationToken()
        exportCancellation = cancellation
        isTableOperationInFlight = true
        setOperationBusy(text: "Exporting table…", fraction: 0)

        Self.exportQueue.async { [weak self] in
            let accessStarted = url.startAccessingSecurityScopedResource()
            defer {
                if accessStarted { url.stopAccessingSecurityScopedResource() }
            }
            let result: Result<Int64, Error>
            do {
                let sink = try TabularExportSink(
                    targetURL: url,
                    format: format,
                    headers: headers,
                    expectedDestination: expectedDestination
                )
                var completed: Int64 = 0
                var lastProgress = ContinuousClock.now

                func reportProgress(force: Bool = false) {
                    let now = ContinuousClock.now
                    guard force || now - lastProgress >= .milliseconds(120) else { return }
                    lastProgress = now
                    let update = TabularExportProgress(rowsWritten: completed, totalRows: totalRows)
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.exportCancellation === cancellation else { return }
                        if let fraction = update.fractionCompleted {
                            let percent = Int(fraction * 100)
                            self.setOperationBusy(
                                text: "Exporting \(percent)%  ·  \(completed.formatted()) rows",
                                fraction: fraction
                            )
                        } else {
                            self.setOperationBusy(
                                text: "Exporting…  ·  \(completed.formatted()) rows",
                                fraction: nil
                            )
                        }
                    }
                }

                func append(location: CSVRowIndex.RecordLocation) throws {
                    if cancellation.isCancelled { throw CancellationError() }
                    let selected = try CSVRecordParser.selectedFields(
                        snapshot: snapshot,
                        location: location,
                        columns: Set(columns),
                        delimiter: rowIndex.delimiter,
                        maximumValueBytesPerField: 4 << 20,
                        maximumRetainedValueBytes: 16 << 20,
                        cancellation: { cancellation.isCancelled }
                    )
                    for column in columns where selected.fields[column]?.wasTruncated == true {
                        throw NSError(
                            domain: "app.lightxt.table-export",
                            code: 1,
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "Row \(location.record + 1), column \(column + 1) is larger than the 4 MB exact export limit. No partial file was written."
                            ]
                        )
                    }
                    try sink.append(row: columns.map { selected.fields[$0]?.value })
                    completed += 1
                    reportProgress()
                }

                do {
                    if let selectedDisplayedRows {
                        // Iterate the existing compact IndexSet and translate
                        // filtered/sorted rows in bounded pages. Do not build a
                        // second O(selection) source-record array.
                        for contiguous in selectedDisplayedRows.rangeView {
                            var displayed = Int64(contiguous.lowerBound)
                            let upper = Int64(contiguous.upperBound)
                            while displayed < upper {
                                if cancellation.isCancelled { throw CancellationError() }
                                let pageUpper = min(upper, displayed + 4_096)
                                if let displayedMap {
                                    let records = try displayedMap.records(in: displayed..<pageUpper)
                                    for record in records {
                                        guard let location = try rowIndex.recordLocation(
                                            forRecord: record,
                                            cancellation: { cancellation.isCancelled }
                                        ) else { continue }
                                        try append(location: location)
                                    }
                                } else {
                                    var row = displayed
                                    while row < pageUpper {
                                        guard let location = try rowIndex.recordLocation(
                                            forRecord: row + firstRecord,
                                            cancellation: { cancellation.isCancelled }
                                        ) else {
                                            row += 1
                                            continue
                                        }
                                        try append(location: location)
                                        row += 1
                                    }
                                }
                                displayed = pageUpper
                            }
                        }
                    } else if let displayedMap {
                        var offset: Int64 = 0
                        while offset < displayedMap.rowCount {
                            if cancellation.isCancelled { throw CancellationError() }
                            let records = try displayedMap.records(
                                in: offset..<min(displayedMap.rowCount, offset + 4_096)
                            )
                            guard !records.isEmpty else { break }
                            for record in records {
                                guard let location = try rowIndex.recordLocation(
                                    forRecord: record,
                                    cancellation: { cancellation.isCancelled }
                                ) else { continue }
                                try append(location: location)
                            }
                            offset += Int64(records.count)
                        }
                    } else {
                        var record = firstRecord
                        while true {
                            if cancellation.isCancelled { throw CancellationError() }
                            let locations = try rowIndex.recordLocations(
                                startingAt: record,
                                limit: 1_024,
                                cancellation: { cancellation.isCancelled }
                            )
                            guard !locations.isEmpty else { break }
                            for location in locations { try append(location: location) }
                            record = locations[locations.count - 1].record + 1
                        }
                    }
                    if cancellation.isCancelled { throw CancellationError() }
                    try sink.finish()
                    reportProgress(force: true)
                    result = .success(completed)
                } catch {
                    sink.cancel()
                    throw error
                }
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async { [weak self] in
                guard let self, self.exportCancellation === cancellation else { return }
                self.exportCancellation = nil
                self.isTableOperationInFlight = false
                switch result {
                case .success(let rows):
                    self.setBusy(false, text: "Exported \(rows.formatted()) rows")
                case .failure(let error) where error is CancellationError:
                    self.restoreTableStatus()
                    self.onStatusChange?("Export cancelled", false)
                case .failure(let error as CSVRowIndex.IndexError) where error == .cancelled:
                    self.restoreTableStatus()
                    self.onStatusChange?("Export cancelled", false)
                case .failure(let error):
                    self.report(error)
                }
                self.reloadVisibleEditableCells()
            }
        }
    }

    private func report(_ error: Error) {
        setBusy(false, text: error.localizedDescription)
        editorDelegate?.editorDidFail(error)
    }

    private func reportOnce(_ error: Error) {
        guard lastReportedError != error.localizedDescription else { return }
        lastReportedError = error.localizedDescription
        if isQueryLoadingOverlayVisible {
            editorDelegate?.editorDidFail(error)
            return
        }
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
        if let tableColumn = tableColumnIndex(forDataColumn: pendingScrollTarget.column) {
            tableView.scrollColumnToVisible(tableColumn)
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
private final class CSVQueryLoadingOverlayView: NSView {
    var blocksInteraction = false

    private let card = NSVisualEffectView()
    private let indicator = CSVQueryLoadingIndicatorView()
    private let titleLabel = NSTextField(labelWithString: "Filtering")
    private let detailLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Updating table results")

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

        let preferredWidth = card.widthAnchor.constraint(equalToConstant: 430)
        preferredWidth.priority = .defaultHigh
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
            card.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -24),
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
            preferredWidth,
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

    func update(title: String, detail: String, progress: Double?) {
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
private final class CSVQueryLoadingIndicatorView: NSView {
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
        scannerLayer.add(scan, forKey: "csv.queryScan")

        for (order, index) in highlightedCells.sorted().enumerated() {
            let pulse = CAKeyframeAnimation(keyPath: "opacity")
            pulse.values = [0.42, 1, 0.42]
            pulse.keyTimes = [0, 0.48, 1]
            pulse.duration = 1.25
            pulse.beginTime = CACurrentMediaTime() + Double(order) * 0.14
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            cellLayers[index].add(pulse, forKey: "csv.matchPulse")
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

@MainActor
private final class CSVEditableTextField: NSTextField {
    var displayedRow: Int64 = 0
    var record: Int64 = 0
    var column = 0
    var byteRange: Range<Int64>?
    var originalValue = ""
    var originalFieldCount = 0
}
#endif

struct CSVFilterDraft: Equatable {
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
    var selectedValues: Set<String>

    init(
        predicate: Predicate,
        value: String,
        isCaseSensitive: Bool,
        selectedValues: Set<String> = []
    ) {
        self.predicate = predicate
        self.value = value
        self.isCaseSensitive = isCaseSensitive
        self.selectedValues = selectedValues
    }

    var isEmpty: Bool { value.isEmpty && selectedValues.isEmpty }

    var shortSummary: String {
        let typed = value.isEmpty ? nil : value
        let selected: String? = {
            guard !selectedValues.isEmpty else { return nil }
            let first = selectedValues.sorted(by: CSVFilterDraft.localizedValueOrder).first ?? ""
            let label = first.isEmpty ? "Empty" : first
            return selectedValues.count == 1 ? label : "\(label) +\(selectedValues.count - 1)"
        }()
        return [typed, selected].compactMap { $0 }.joined(separator: " · ")
    }

    func accessibilityDescription(columnTitle: String) -> String {
        var pieces: [String] = ["Filter \(columnTitle)"]
        if !value.isEmpty { pieces.append("contains \(value)") }
        if !selectedValues.isEmpty {
            pieces.append("\(selectedValues.count) selected value\(selectedValues.count == 1 ? "" : "s")")
        }
        return pieces.joined(separator: ", ")
    }

    static func localizedValueOrder(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}

@MainActor
final class CSVFilterPopoverViewController: NSViewController,
    NSSearchFieldDelegate,
    NSTableViewDataSource,
    NSTableViewDelegate
{
    var onCommit: ((CSVFilterDraft) -> Void)?
    var onClear: (() -> Void)?

    private let columnTitle: String
    private let valueDisplayProvider: (String) -> String
    private var committedFilter: CSVFilterDraft
    private let valueField = NSSearchField()
    private let valuesStatus = NSTextField(labelWithString: "Loading values…")
    private let valuesTable = NSTableView()
    private let valuesScroll = NSScrollView()
    private lazy var clearButton = NSButton(title: "Clear", target: self, action: #selector(clear(_:)))
    private var allUniqueValues: [String] = []
    private var visibleUniqueValues: [String] = []
    private var remoteUniqueValueSearch: ((String) -> Void)?
    private var remoteUniqueValuePageRequest: (() -> Void)?
    private var pendingRemoteSearch: DispatchWorkItem?
    private var valuesBoundsObserver: NSObjectProtocol?
    private var remoteUniqueValueCount: Int64?
    private var remoteUniqueValuesHaveMore = false
    private var isRequestingRemoteValues = false
    private var remoteMatchingUniqueValues: [String] = []

    init(
        columnTitle: String,
        filter: CSVFilterDraft?,
        valueDisplayProvider: @escaping (String) -> String = { $0 }
    ) {
        self.columnTitle = columnTitle
        self.valueDisplayProvider = valueDisplayProvider
        self.committedFilter = filter ?? CSVFilterDraft(
            predicate: .contains,
            value: "",
            isCaseSensitive: false
        )
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 350, height: 390)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        pendingRemoteSearch?.cancel()
        if let valuesBoundsObserver {
            NotificationCenter.default.removeObserver(valuesBoundsObserver)
        }
    }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        view = root

        let title = NSTextField(labelWithString: columnTitle)
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.toolTip = columnTitle
        title.setAccessibilityLabel("Filter column \(columnTitle)")

        valueField.placeholderString = "Contains"
        valueField.delegate = self
        valueField.target = self
        valueField.action = #selector(commitText(_:))
        valueField.sendsSearchStringImmediately = false
        valueField.sendsWholeSearchString = true
        valueField.stringValue = committedFilter.value
        valueField.setAccessibilityLabel("Contains text for \(columnTitle)")
        valueField.setAccessibilityHelp("Type freely, then press Return or click elsewhere to apply")

        valuesStatus.font = .systemFont(ofSize: 11)
        valuesStatus.textColor = .secondaryLabelColor
        valuesStatus.lineBreakMode = .byTruncatingTail
        valuesStatus.maximumNumberOfLines = 1

        valuesTable.headerView = nil
        valuesTable.delegate = self
        valuesTable.dataSource = self
        valuesTable.rowHeight = 27
        valuesTable.intercellSpacing = NSSize(width: 0, height: 1)
        valuesTable.selectionHighlightStyle = .none
        valuesTable.setAccessibilityLabel("Unique values for \(columnTitle)")
        let valueColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("filter-value"))
        valueColumn.resizingMask = .autoresizingMask
        valueColumn.width = 316
        valuesTable.addTableColumn(valueColumn)
        valuesScroll.documentView = valuesTable
        valuesScroll.hasVerticalScroller = true
        valuesScroll.autohidesScrollers = true
        valuesScroll.borderType = .bezelBorder
        valuesScroll.contentView.postsBoundsChangedNotifications = true
        valuesBoundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: valuesScroll.contentView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestMoreRemoteValuesIfNeeded() }
        }

        clearButton.bezelStyle = .rounded
        clearButton.isEnabled = !committedFilter.isEmpty
        clearButton.setAccessibilityLabel("Clear filter for \(columnTitle)")

        let hint = NSTextField(labelWithString: "Check one or more exact values")
        hint.font = .systemFont(ofSize: 11, weight: .medium)
        hint.textColor = .secondaryLabelColor
        let heading = NSStackView(views: [hint, NSView(), clearButton])
        heading.orientation = .horizontal
        heading.alignment = .centerY
        heading.spacing = 8

        let content = NSStackView(views: [title, valueField, heading, valuesStatus, valuesScroll])
        content.translatesAutoresizingMaskIntoConstraints = false
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        root.addSubview(content)

        [valueField, heading, valuesStatus, valuesScroll].forEach {
            $0.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        valuesScroll.heightAnchor.constraint(equalToConstant: 246).isActive = true
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: preferredContentSize.width),
            root.heightAnchor.constraint(equalToConstant: preferredContentSize.height),
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(valueField)
    }

    func showUniqueValuesLoading() {
        valuesTable.isEnabled = false
        valuesStatus.stringValue = "Loading unique values…"
        valuesStatus.setAccessibilityValue(valuesStatus.stringValue)
    }

    /// Enables a bounded, server-backed value browser. CSV continues to use
    /// its existing in-memory picker; Parquet supplies searched/paged DuckDB
    /// results so the 500 visible rows are a page size rather than a logical
    /// limit on which exact values can be selected.
    func configureRemoteUniqueValues(
        onSearch: @escaping (String) -> Void,
        onRequestNextPage: @escaping () -> Void
    ) {
        remoteUniqueValueSearch = onSearch
        remoteUniqueValuePageRequest = onRequestNextPage
    }

    var uniqueValueSearchText: String {
        loadViewIfNeeded()
        return valueField.stringValue
    }

    func showRemoteUniqueValuesLoading(replacing: Bool) {
        isRequestingRemoteValues = true
        valuesTable.isEnabled = false
        valuesStatus.toolTip = nil
        if replacing {
            remoteUniqueValueCount = nil
            remoteUniqueValuesHaveMore = false
            remoteMatchingUniqueValues.removeAll(keepingCapacity: true)
        }
        valuesStatus.stringValue = replacing
            ? "Searching unique values…"
            : "Loading more unique values…"
        valuesStatus.setAccessibilityValue(valuesStatus.stringValue)
    }

    func showRemoteUniqueValues(
        _ values: [String],
        totalValueCount: Int64,
        hasMore: Bool,
        replacing: Bool,
        omittedOversizedValueCount: Int64 = 0
    ) {
        isRequestingRemoteValues = false
        valuesTable.isEnabled = true
        valuesStatus.toolTip = nil
        remoteUniqueValueCount = max(0, totalValueCount)
        remoteUniqueValuesHaveMore = hasMore
        remoteMatchingUniqueValues = Self.stablyAppendingUniqueValues(
            replacing ? [] : remoteMatchingUniqueValues,
            values
        )
        // Preserve DuckDB's stable frequency/value page order. Checked values
        // outside the active search follow the matches so they remain
        // available for deselection without inflating the matching count.
        let retainedSelections = committedFilter.selectedValues
            .subtracting(remoteMatchingUniqueValues)
            .sorted(by: CSVFilterDraft.localizedValueOrder)
        allUniqueValues = remoteMatchingUniqueValues + retainedSelections
        let shown = remoteMatchingUniqueValues.count
        let pageStatus = hasMore
            ? "Showing \(shown.formatted()) of \(totalValueCount.formatted()) values"
            : "\(totalValueCount.formatted()) matching value\(totalValueCount == 1 ? "" : "s")"
        let selectionStatus = retainedSelections.isEmpty
            ? ""
            : " · \(retainedSelections.count.formatted()) selected outside search"
        valuesStatus.stringValue = omittedOversizedValueCount > 0
            ? "\(pageStatus) · \(omittedOversizedValueCount.formatted()) oversized rows omitted"
                + selectionStatus
            : pageStatus + selectionStatus
        valuesStatus.setAccessibilityValue(valuesStatus.stringValue)
        updateVisibleUniqueValues()
        requestMoreRemoteValuesIfNeeded()
    }

    func showUniqueValues(progress: CSVUniqueValuesProgress) {
        let total = progress.totalRecordCount.map { " of \($0.formatted())" } ?? ""
        valuesStatus.stringValue = "Scanned \(progress.scannedRecordCount.formatted())\(total) rows · \(progress.uniqueValueCount.formatted()) values…"
        valuesStatus.setAccessibilityValue(valuesStatus.stringValue)
    }

    func showUniqueValues(_ result: CSVUniqueValuesResult) {
        isRequestingRemoteValues = false
        valuesTable.isEnabled = true
        // Keep checked values visible even when a bounded scan reached its
        // cap before rediscovering one of them.
        allUniqueValues = Array(Set(result.values).union(committedFilter.selectedValues))
            .sorted(by: CSVFilterDraft.localizedValueOrder)
        valuesStatus.stringValue = result.isTruncated
            ? "Showing \(allUniqueValues.count.formatted()) values; more available"
            : "\(allUniqueValues.count.formatted()) unique values"
        valuesStatus.setAccessibilityValue(valuesStatus.stringValue)
        updateVisibleUniqueValues()
    }

    func showUniqueValues(error: Error) {
        isRequestingRemoteValues = false
        valuesTable.isEnabled = true
        valuesStatus.stringValue = "Couldn’t load values"
        valuesStatus.toolTip = error.localizedDescription
        valuesStatus.setAccessibilityValue(error.localizedDescription)
        allUniqueValues = committedFilter.selectedValues.sorted(by: CSVFilterDraft.localizedValueOrder)
        updateVisibleUniqueValues()
    }

    func controlTextDidChange(_ notification: Notification) {
        // Live typing narrows only the local picker. It never mutates the CSV
        // query, reloads the table, or dismisses this popover.
        updateVisibleUniqueValues()
        scheduleRemoteUniqueValueSearch()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        let movement = (notification.userInfo?["NSTextMovement"] as? NSNumber)?.intValue
        if movement == NSCancelTextMovement {
            valueField.stringValue = committedFilter.value
            updateVisibleUniqueValues()
            return
        }
        commitTypedValue()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visibleUniqueValues.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let value = visibleUniqueValues[safe: row] else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("filter-value-checkbox")
        let button = (tableView.makeView(withIdentifier: identifier, owner: self) as? NSButton)
            ?? NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleValue(_:)))
        button.identifier = identifier
        button.target = self
        button.action = #selector(toggleValue(_:))
        button.tag = row
        let displayedValue = valueDisplayProvider(value)
        button.title = displayedValue.isEmpty ? "(Empty)" : displayedValue
        button.toolTip = displayedValue
        button.state = committedFilter.selectedValues.contains(value) ? .on : .off
        button.lineBreakMode = .byTruncatingMiddle
        button.setAccessibilityLabel(displayedValue.isEmpty ? "Empty value" : displayedValue)
        return button
    }

    @objc private func commitText(_ sender: Any?) { commitTypedValue() }

    private func commitTypedValue() {
        let next = CSVFilterDraft(
            predicate: .contains,
            value: valueField.stringValue,
            isCaseSensitive: false,
            selectedValues: committedFilter.selectedValues
        )
        guard next != committedFilter else { return }
        committedFilter = next
        clearButton.isEnabled = !next.isEmpty
        onCommit?(next)
    }

    @objc private func toggleValue(_ sender: NSButton) {
        guard let value = visibleUniqueValues[safe: sender.tag] else { return }
        if sender.state == .on {
            committedFilter.selectedValues.insert(value)
        } else {
            committedFilter.selectedValues.remove(value)
        }
        clearButton.isEnabled = !committedFilter.isEmpty
        onCommit?(committedFilter)
    }

    @objc private func clear(_ sender: Any?) {
        committedFilter = CSVFilterDraft(
            predicate: .contains,
            value: "",
            isCaseSensitive: false
        )
        valueField.stringValue = ""
        clearButton.isEnabled = false
        updateVisibleUniqueValues()
        onClear?()
        view.window?.makeFirstResponder(valueField)
    }

    private func updateVisibleUniqueValues() {
        let needle = valueField.stringValue
        visibleUniqueValues = needle.isEmpty
            ? allUniqueValues
            : allUniqueValues.filter {
                committedFilter.selectedValues.contains($0)
                    || valueDisplayProvider($0).localizedCaseInsensitiveContains(needle)
            }
        valuesTable.reloadData()
    }

    private static func stablyAppendingUniqueValues(
        _ existing: [String],
        _ additions: [String]
    ) -> [String] {
        var seen = Set(existing)
        var result = existing
        result.reserveCapacity(existing.count + additions.count)
        for value in additions where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }

    private func scheduleRemoteUniqueValueSearch() {
        guard let remoteUniqueValueSearch else { return }
        pendingRemoteSearch?.cancel()
        let searchText = valueField.stringValue
        let work = DispatchWorkItem { remoteUniqueValueSearch(searchText) }
        pendingRemoteSearch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    private func requestMoreRemoteValuesIfNeeded() {
        guard remoteUniqueValuesHaveMore,
              !isRequestingRemoteValues,
              let remoteUniqueValuePageRequest else { return }
        let visibleBottom = valuesScroll.contentView.bounds.maxY
        let contentBottom = valuesTable.bounds.maxY
        let preloadDistance = max(54, valuesTable.rowHeight * 8)
        guard contentBottom - visibleBottom <= preloadDistance else { return }
        isRequestingRemoteValues = true
        remoteUniqueValuePageRequest()
    }


#if LIGHTXT_STANDALONE_CSV_QA
    func qaType(_ value: String) {
        valueField.stringValue = value
        valueField.currentEditor()?.string = value
        updateVisibleUniqueValues()
    }

    func qaCommit() { commitTypedValue() }
    func qaEndEditingByFocusLoss() {
        // Move focus to another real control inside the still-open popover so
        // AppKit delivers controlTextDidEndEditing without transient-popover
        // dismissal obscuring the commit path.
        view.window?.makeFirstResponder(valuesTable)
    }
    var qaHasFocus: Bool { valueField.currentEditor() != nil }
    var qaUniqueValues: [String] { allUniqueValues }
    var qaUniqueValuesStatus: String { valuesStatus.stringValue }
    var qaUniqueValuesToolTip: String? { valuesStatus.toolTip }
    var qaRemoteUniqueValueCount: Int64? { remoteUniqueValueCount }

    func qaPrepareCaptureBackground() {
        view.wantsLayer = true
        view.layer?.backgroundColor = LighTxtTheme.resolved(
            NSColor.windowBackgroundColor,
            for: view.effectiveAppearance
        ).cgColor
    }

    func qaToggle(_ value: String) {
        if committedFilter.selectedValues.contains(value) {
            committedFilter.selectedValues.remove(value)
        } else {
            committedFilter.selectedValues.insert(value)
        }
        clearButton.isEnabled = !committedFilter.isEmpty
        valuesTable.reloadData()
        onCommit?(committedFilter)
    }
#endif
}

@MainActor
private final class CSVUniqueValuesProgressRelay: @unchecked Sendable {
    private weak var controller: CSVFilterPopoverViewController?

    init(controller: CSVFilterPopoverViewController) {
        self.controller = controller
    }

    nonisolated func report(_ progress: CSVUniqueValuesProgress) {
        Task { @MainActor [weak self] in
            guard let self, let controller else { return }
            controller.showUniqueValues(progress: progress)
        }
    }
}

struct CSVColumnSummaryPresentation {
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
final class CSVColumnSummaryPopoverViewController: NSViewController {
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
final class LighTxtCSVHeaderCell: NSTableHeaderCell {
    var isFiltered = false
    var showsFilterControls = true
    var filterText = ""
#if LIGHTXT_STANDALONE_CSV_QA
    private(set) var qaLastDrawnTitleRect = NSRect.zero
    private(set) var qaLastInteriorFrame = NSRect.zero
    private(set) var qaLastResolvedLayoutFrame = NSRect.zero
#endif

    private func rowRects(
        in cellFrame: NSRect,
        controlView: NSView
    ) -> (title: NSRect, filter: NSRect) {
        let verticalInset = min(1, cellFrame.height / 8)
        let gap = min(3, max(1, cellFrame.height / 18))
        let usableHeight = max(0, cellFrame.height - verticalInset * 2 - gap)
        let filterHeight = min(24, floor(usableHeight / 2))
        let titleHeight = max(0, usableHeight - filterHeight)
        if controlView.isFlipped {
            let title = NSRect(
                x: cellFrame.minX,
                y: cellFrame.minY + verticalInset,
                width: cellFrame.width,
                height: titleHeight
            )
            return (
                title,
                NSRect(
                    x: cellFrame.minX,
                    y: title.maxY + gap,
                    width: cellFrame.width,
                    height: filterHeight
                )
            )
        }
        let filter = NSRect(
            x: cellFrame.minX,
            y: cellFrame.minY + verticalInset,
            width: cellFrame.width,
            height: filterHeight
        )
        return (
            NSRect(
                x: cellFrame.minX,
                y: filter.maxY + gap,
                width: cellFrame.width,
                height: titleHeight
            ),
            filter
        )
    }

    func titleRect(in cellFrame: NSRect, controlView: NSView) -> NSRect {
        rowRects(in: cellFrame, controlView: controlView).title.insetBy(dx: 5, dy: 0)
    }

    func filterBandRect(in cellFrame: NSRect, controlView: NSView) -> NSRect {
        rowRects(in: cellFrame, controlView: controlView).filter
    }

    func filterControlRect(in cellFrame: NSRect, controlView: NSView) -> NSRect {
        guard showsFilterControls else { return .zero }
        return filterBandRect(in: cellFrame, controlView: controlView).insetBy(dx: 3, dy: 0)
    }

    func funnelRect(in cellFrame: NSRect, controlView: NSView) -> NSRect {
        let row = filterControlRect(in: cellFrame, controlView: controlView)
        // Keep a dedicated resize gutter at the trailing edge so the filter
        // affordance never steals native column-resize drags.
        return NSRect(x: row.maxX - 29, y: row.minY, width: 24, height: row.height)
    }

    func filterInputRect(in cellFrame: NSRect, controlView: NSView) -> NSRect {
        let row = filterControlRect(in: cellFrame, controlView: controlView)
        return NSRect(x: row.minX, y: row.minY, width: max(0, row.width - 25), height: row.height)
    }

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        // NSTableHeaderCell passes drawInterior a one-line text interior (for
        // example, y=19/h=15 inside our 54pt header), not the full column
        // header rectangle. Base both rows on the full header height so the
        // title cannot be centered into the filter controls.
        let layoutFrame: NSRect
        if let headerView = controlView as? NSTableHeaderView,
           let tableView = headerView.tableView,
           let columnIndex = tableView.tableColumns.firstIndex(where: {
               $0.headerCell === self
           }) {
            layoutFrame = headerView.headerRect(ofColumn: columnIndex)
        } else {
            layoutFrame = NSRect(
                x: cellFrame.minX,
                y: controlView.bounds.minY,
                width: cellFrame.width,
                height: controlView.bounds.height
            )
        }
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
        let indicatorWidth: CGFloat = isFiltered ? 15 : 0
        var titleFrame = titleRect(in: layoutFrame, controlView: controlView)
        titleFrame.size.width = max(0, titleFrame.width - indicatorWidth)
        let titleHeight = attributedTitle.size().height
        let verticallyCentered = NSRect(
            x: titleFrame.minX,
            y: titleFrame.midY - titleHeight / 2,
            width: titleFrame.width,
            height: titleHeight
        )
#if LIGHTXT_STANDALONE_CSV_QA
        qaLastInteriorFrame = cellFrame
        qaLastResolvedLayoutFrame = layoutFrame
        qaLastDrawnTitleRect = verticallyCentered
#endif
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
               systemSymbolName: "line.3.horizontal.decrease.circle.fill",
               accessibilityDescription: "Filtered"
           )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)) {
            indicator.isTemplate = true
            let frame = NSRect(
                x: titleFrame.maxX + 2,
                y: titleFrame.midY - 6,
                width: 12,
                height: 12
            )
            NSColor.controlAccentColor.set()
            indicator.draw(in: frame)
        }

        // Visible, accessible overlay controls own the complete filter-row
        // surface. Avoid stacking a second separator or active fill beneath
        // them; the header view masks the unrelated native bezel rule.
    }

#if LIGHTXT_STANDALONE_CSV_QA
    func qaRefreshPresentationGeometry(in layoutFrame: NSRect, controlView: NSView) {
        var titleFrame = titleRect(in: layoutFrame, controlView: controlView)
        titleFrame.size.width = max(0, titleFrame.width - (isFiltered ? 15 : 0))
        let titleHeight = NSAttributedString(
            string: stringValue,
            attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]
        ).size().height
        qaLastInteriorFrame = NSRect(
            x: layoutFrame.minX,
            y: floor(layoutFrame.midY - titleHeight / 2),
            width: layoutFrame.width,
            height: titleHeight
        )
        qaLastResolvedLayoutFrame = layoutFrame
        qaLastDrawnTitleRect = NSRect(
            x: titleFrame.minX,
            y: titleFrame.midY - titleHeight / 2,
            width: titleFrame.width,
            height: titleHeight
        )
    }
#endif
}

/// A lightweight, visible-only proxy for the inline contains editor. Keeping
/// these controls virtualized to the visible columns preserves the 512-column
/// bound while making the filter row discoverable and keyboard accessible.
@MainActor
private final class LighTxtCSVContainsButton: NSButton {
    private let textLabel = NSTextField(labelWithString: "")
    var filterText = "" {
        didSet {
            needsDisplay = true
            needsLayout = true
        }
    }
    var isFilterActive = false { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        focusRingType = .default
        textLabel.font = .systemFont(ofSize: 11)
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.maximumNumberOfLines = 1
        textLabel.setAccessibilityElement(false)
        addSubview(textLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let appearance = effectiveAppearance
        let fieldRect = bounds.insetBy(dx: 0.5, dy: 1.5)
        let path = NSBezierPath(roundedRect: fieldRect, xRadius: 5, yRadius: 5)
        let fill = isFilterActive
            ? LighTxtTheme.resolved(LighTxtTheme.accent, for: appearance).withAlphaComponent(0.13)
            : LighTxtTheme.resolved(NSColor.controlBackgroundColor, for: appearance).withAlphaComponent(0.34)
        fill.setFill()
        path.fill()
        LighTxtTheme.resolved(LighTxtTheme.separator, for: appearance)
            .withAlphaComponent(isEnabled ? 0.72 : 0.38)
            .setStroke()
        path.lineWidth = 0.75
        path.stroke()

        let color = LighTxtTheme.resolved(
            filterText.isEmpty ? LighTxtTheme.secondaryText : LighTxtTheme.primaryText,
            for: appearance
        ).withAlphaComponent(isEnabled ? 1 : 0.48)
        color.setStroke()
        let center = NSPoint(x: fieldRect.minX + 11, y: fieldRect.midY)
        let glass = NSBezierPath(ovalIn: NSRect(
            x: center.x - 3.7,
            y: center.y - 3.7,
            width: 7.4,
            height: 7.4
        ))
        glass.lineWidth = 1.25
        glass.stroke()
        let direction: CGFloat = isFlipped ? 1 : -1
        let handle = NSBezierPath()
        handle.move(to: NSPoint(x: center.x + 2.8, y: center.y + 2.8 * direction))
        handle.line(to: NSPoint(x: center.x + 5.8, y: center.y + 5.8 * direction))
        handle.lineWidth = 1.25
        handle.lineCapStyle = .round
        handle.stroke()

        let textColor = filterText.isEmpty
            ? LighTxtTheme.resolved(LighTxtTheme.secondaryText, for: appearance)
            : LighTxtTheme.resolved(LighTxtTheme.primaryText, for: appearance)
        textLabel.textColor = textColor.withAlphaComponent(isEnabled ? 1 : 0.48)
    }

    override func layout() {
        super.layout()
        textLabel.stringValue = filterText.isEmpty
            ? (bounds.width >= 78 ? "Contains" : "")
            : filterText
        textLabel.sizeToFit()
        let height = min(bounds.height, textLabel.frame.height)
        textLabel.frame = NSRect(
            x: 22,
            y: floor((bounds.height - height) / 2),
            width: max(0, bounds.width - 26),
            height: height
        )
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, bounds.contains(point) else { return nil }
        return self
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

#if LIGHTXT_STANDALONE_CSV_QA
    var qaTextRect: NSRect { convert(textLabel.bounds, from: textLabel) }
#endif
}

/// The standard header opts into vibrancy. That is attractive over window
/// materials, but our opaque editor surface has no material backdrop and dark
/// vibrancy can suppress custom header titles almost completely. A non-vibrant
/// header keeps native resizing/dragging while drawing predictable contrast.
@MainActor
final class LighTxtCSVHeaderView: NSTableHeaderView, NSSearchFieldDelegate {
    static let preferredHeight: CGFloat = 54

    var menuProvider: ((Int) -> NSMenu?)?
    var onCommitContainsFilter: ((Int, String) -> Void)?
    var onShowFilterValues: ((Int) -> Void)?
    var filterTextProvider: ((Int) -> String)?
    var filterEditingEnabledProvider: (() -> Bool)?

    private var editingColumn: Int?
    private var originalText = ""
    private var containsButtons: [Int: LighTxtCSVContainsButton] = [:]
    private var filterButtons: [Int: NSButton] = [:]
    private var boundsObserver: NSObjectProtocol?
    private lazy var inlineField: NSSearchField = {
        let field = NSSearchField()
        field.placeholderString = "Contains"
        field.controlSize = .small
        field.delegate = self
        field.target = self
        field.action = #selector(commitInlineField(_:))
        field.sendsSearchStringImmediately = false
        field.sendsWholeSearchString = true
        field.setAccessibilityHelp("Press Return or click elsewhere to apply; press Escape to cancel")
        return field
    }()

    override var allowsVibrancy: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let tableView,
              let cell = tableView.tableColumns.compactMap({
                  $0.headerCell as? LighTxtCSVHeaderCell
              }).first else { return }

        // NSTableHeaderCell's stock bezel draws an internal horizontal rule
        // for its native one-line header. In our 54pt, two-row header that
        // rule lands through the middle of Contains fields. Mask only the
        // filter band in header coordinates, then restore the useful bottom
        // seam and vertical column dividers. Overlay controls draw afterward.
        let referenceFrame = NSRect(
            x: bounds.minX,
            y: bounds.minY,
            width: max(1, bounds.width),
            height: bounds.height
        )
        let band = cell.filterBandRect(in: referenceFrame, controlView: self)
        let mask = NSRect(
            x: dirtyRect.minX,
            y: band.minY,
            width: dirtyRect.width,
            height: band.height
        ).intersection(bounds)
        guard !mask.isEmpty else { return }

        LighTxtTheme.resolved(
            LighTxtTheme.editorBackground,
            for: effectiveAppearance
        ).setFill()
        mask.fill()

        let separator = LighTxtTheme.resolved(
            LighTxtTheme.separator,
            for: effectiveAppearance
        )
        separator.setStroke()
        for index in tableView.tableColumns.indices {
            let column = headerRect(ofColumn: index)
            let x = column.maxX - 0.5
            guard x >= dirtyRect.minX - 1, x <= dirtyRect.maxX + 1 else { continue }
            NSBezierPath.strokeLine(
                from: NSPoint(x: x, y: band.minY),
                to: NSPoint(x: x, y: band.maxY)
            )
        }
        let bottomY = isFlipped ? bounds.maxY - 0.5 : bounds.minY + 0.5
        NSBezierPath.strokeLine(
            from: NSPoint(x: dirtyRect.minX, y: bottomY),
            to: NSPoint(x: dirtyRect.maxX, y: bottomY)
        )

        // The stock indicator can descend into the filter band and therefore
        // be partially covered by the mask. Redraw it in the dedicated title
        // row, retaining AppKit's native ascending/descending artwork.
        if let descriptor = tableView.sortDescriptors.first,
           let key = descriptor.key,
           let sortedIndex = tableView.tableColumns.firstIndex(where: {
               $0.sortDescriptorPrototype?.key == key
           }),
           let sortedCell = tableView.tableColumns[sortedIndex].headerCell
                as? LighTxtCSVHeaderCell {
            let columnFrame = headerRect(ofColumn: sortedIndex)
            let titleFrame = sortedCell.titleRect(in: columnFrame, controlView: self)
            sortedCell.drawSortIndicator(
                withFrame: titleFrame,
                in: self,
                ascending: descriptor.ascending,
                priority: 0
            )
        }
    }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
        boundsObserver = nil
        guard let clipView = superview as? NSClipView else { return }
        clipView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.synchronizeVisibleFilterButtons()
                self?.repositionInlineField()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let tableView else { return super.mouseDown(with: event) }
        let point = convert(event.locationInWindow, from: nil)
        let tableColumnIndex = tableView.column(at: point)
        guard tableColumnIndex >= 0,
              let tableColumn = tableView.tableColumns[safe: tableColumnIndex],
              let column = Self.dataColumn(from: tableColumn),
              let cell = tableColumn.headerCell as? LighTxtCSVHeaderCell else {
            return super.mouseDown(with: event)
        }
        let frame = headerRect(ofColumn: tableColumnIndex)
        guard filterEditingEnabledProvider?() != false else {
            NSSound.beep()
            return
        }
        if cell.funnelRect(in: frame, controlView: self).contains(point) {
            window?.makeFirstResponder(nil)
            onShowFilterValues?(column)
            return
        }
        if cell.filterInputRect(in: frame, controlView: self).contains(point) {
            beginEditing(column: column, tableColumnIndex: tableColumnIndex, cell: cell)
            return
        }
        super.mouseDown(with: event)
    }

    override func layout() {
        super.layout()
        synchronizeVisibleFilterButtons()
        repositionInlineField()
    }

    func refreshFilterDisplay() {
        if filterEditingEnabledProvider?() == false, editingColumn != nil {
            inlineField.stringValue = originalText
            finishInlineField(commit: false)
        }
        if editingColumn == nil { inlineField.removeFromSuperview() }
        synchronizeVisibleFilterButtons()
        needsDisplay = true
    }

    private func beginEditing(
        column: Int,
        tableColumnIndex: Int,
        cell: LighTxtCSVHeaderCell
    ) {
        if editingColumn != column { finishInlineField(commit: true) }
        editingColumn = column
        originalText = filterTextProvider?(column) ?? ""
        inlineField.stringValue = originalText
        let title = tableView?.tableColumns[safe: tableColumnIndex]?.title ?? "column"
        inlineField.setAccessibilityLabel("Contains text for \(title)")
        if inlineField.superview !== self { addSubview(inlineField) }
        containsButtons[column]?.isHidden = true
        inlineField.frame = cell.filterInputRect(
            in: headerRect(ofColumn: tableColumnIndex),
            controlView: self
        ).insetBy(dx: 1, dy: 0)
        window?.makeFirstResponder(inlineField)
    }

    private func repositionInlineField() {
        guard let editingColumn,
              let tableView,
              let index = tableView.tableColumns.firstIndex(where: {
                  Self.dataColumn(from: $0) == editingColumn
              }),
              let cell = tableView.tableColumns[index].headerCell as? LighTxtCSVHeaderCell else {
            return
        }
        inlineField.frame = cell.filterInputRect(
            in: headerRect(ofColumn: index),
            controlView: self
        ).insetBy(dx: 1, dy: 0)
    }

    @objc private func commitInlineField(_ sender: Any?) {
        finishInlineField(commit: true)
        window?.makeFirstResponder(nil)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        let movement = (notification.userInfo?["NSTextMovement"] as? NSNumber)?.intValue
        finishInlineField(commit: movement != NSCancelTextMovement)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        inlineField.stringValue = originalText
        finishInlineField(commit: false)
        window?.makeFirstResponder(nil)
        return true
    }

    private func finishInlineField(commit: Bool) {
        guard let column = editingColumn else { return }
        let value = inlineField.stringValue
        editingColumn = nil
        inlineField.removeFromSuperview()
        synchronizeVisibleFilterButtons()
        needsDisplay = true
        if commit, value != originalText { onCommitContainsFilter?(column, value) }
    }

    private func synchronizeVisibleFilterButtons() {
        guard let tableView else { return }
        let viewport = visibleRect.width > 0 && visibleRect.height > 0
            ? visibleRect
            : NSRect(x: bounds.minX, y: bounds.minY, width: max(1_000, bounds.width), height: max(54, bounds.height))
        let visible = viewport.insetBy(dx: -30, dy: 0)
        var retained = Set<Int>()
        for (index, tableColumn) in tableView.tableColumns.enumerated() {
            guard let column = Self.dataColumn(from: tableColumn),
                  let cell = tableColumn.headerCell as? LighTxtCSVHeaderCell else { continue }
            let columnFrame = headerRect(ofColumn: index)
            guard columnFrame.intersects(visible) else { continue }
            retained.insert(column)
            let containsButton: LighTxtCSVContainsButton
            if let existing = containsButtons[column] {
                containsButton = existing
            } else {
                containsButton = LighTxtCSVContainsButton()
                containsButton.target = self
                containsButton.action = #selector(beginContainsFromButton(_:))
                containsButtons[column] = containsButton
                addSubview(containsButton)
            }
            containsButton.tag = column
            containsButton.frame = cell.filterInputRect(
                in: columnFrame,
                controlView: self
            ).insetBy(dx: 1, dy: 0)
            containsButton.filterText = filterTextProvider?(column) ?? ""
            containsButton.isFilterActive = cell.isFiltered
            containsButton.toolTip = "Contains filter for \(tableColumn.title)"
            containsButton.setAccessibilityLabel("Contains filter for \(tableColumn.title)")
            containsButton.setAccessibilityHelp("Type text, then press Return or click elsewhere to apply")
            containsButton.isEnabled = filterEditingEnabledProvider?() != false
            containsButton.isHidden = editingColumn == column

            let button: NSButton
            if let existing = filterButtons[column] {
                button = existing
            } else {
                button = NSButton()
                button.image = NSImage(
                    systemSymbolName: "line.3.horizontal.decrease",
                    accessibilityDescription: nil
                )?.withSymbolConfiguration(NSImage.SymbolConfiguration(
                    pointSize: 11,
                    weight: .medium
                ))
                button.imagePosition = .imageOnly
                button.isBordered = false
                button.focusRingType = .default
                button.target = self
                button.action = #selector(showValuesFromButton(_:))
                filterButtons[column] = button
                addSubview(button)
            }
            button.tag = column
            button.frame = cell.funnelRect(in: columnFrame, controlView: self)
            button.toolTip = "Choose values for \(tableColumn.title)"
            button.setAccessibilityLabel("Filter values for \(tableColumn.title)")
            button.setAccessibilityHelp("Opens unique values and a contains field")
            button.contentTintColor = LighTxtTheme.resolved(
                cell.isFiltered ? LighTxtTheme.accent : LighTxtTheme.secondaryText,
                for: effectiveAppearance
            )
            button.isEnabled = filterEditingEnabledProvider?() != false
        }
        let removed = filterButtons.keys.filter { !retained.contains($0) }
        for column in removed {
            filterButtons.removeValue(forKey: column)?.removeFromSuperview()
            containsButtons.removeValue(forKey: column)?.removeFromSuperview()
        }
    }

    @objc private func beginContainsFromButton(_ sender: NSButton) {
        guard filterEditingEnabledProvider?() != false,
              let tableView,
              let index = tableView.tableColumns.firstIndex(where: {
                  Self.dataColumn(from: $0) == sender.tag
              }),
              let cell = tableView.tableColumns[index].headerCell as? LighTxtCSVHeaderCell else {
            NSSound.beep()
            return
        }
        beginEditing(column: sender.tag, tableColumnIndex: index, cell: cell)
    }

    @objc private func showValuesFromButton(_ sender: NSButton) {
        guard filterEditingEnabledProvider?() != false else {
            NSSound.beep()
            return
        }
        window?.makeFirstResponder(nil)
        onShowFilterValues?(sender.tag)
    }

    private static func dataColumn(from tableColumn: NSTableColumn) -> Int? {
        let raw = tableColumn.identifier.rawValue
        guard raw.hasPrefix("csv-column-") else { return nil }
        return Int(raw.dropFirst("csv-column-".count))
    }

#if LIGHTXT_STANDALONE_CSV_QA
    func qaBeginEditing(dataColumn column: Int) {
        guard filterEditingEnabledProvider?() != false,
              let tableView,
              let index = tableView.tableColumns.firstIndex(where: {
                  Self.dataColumn(from: $0) == column
              }),
              let cell = tableView.tableColumns[index].headerCell as? LighTxtCSVHeaderCell else { return }
        beginEditing(column: column, tableColumnIndex: index, cell: cell)
    }

    func qaType(_ value: String) {
        inlineField.stringValue = value
        inlineField.currentEditor()?.string = value
    }

    func qaCommit() { commitInlineField(nil) }
    func qaCancel() {
        inlineField.stringValue = originalText
        finishInlineField(commit: false)
        window?.makeFirstResponder(nil)
    }
    var qaHasFocus: Bool { editingColumn != nil && inlineField.currentEditor() != nil }
    var qaFilterButtonColumns: Set<Int> { Set(filterButtons.keys) }
    func qaSynchronizeFilterButtons() { synchronizeVisibleFilterButtons() }

    func qaFilterPresentationRects(column: Int) -> (
        input: NSRect,
        text: NSRect,
        funnel: NSRect
    )? {
        guard let input = containsButtons[column],
              let funnel = filterButtons[column] else { return nil }
        input.layoutSubtreeIfNeeded()
        return (
            input.frame,
            convert(input.qaTextRect, from: input),
            funnel.frame
        )
    }

    var qaMinimumFilterAffordanceContrast: CGFloat {
        let background = LighTxtTheme.resolved(
            LighTxtTheme.editorBackground,
            for: effectiveAppearance
        )
        let search = LighTxtTheme.resolved(
            LighTxtTheme.secondaryText,
            for: effectiveAppearance
        )
        let colors = [search] + filterButtons.values.compactMap(\.contentTintColor)
        return colors.map { Self.contrastRatio($0, background) }.min() ?? 0
    }

    private static func contrastRatio(_ lhs: NSColor, _ rhs: NSColor) -> CGFloat {
        func luminance(_ color: NSColor) -> CGFloat {
            guard let rgb = color.usingColorSpace(.deviceRGB) else { return 0 }
            func linear(_ component: CGFloat) -> CGFloat {
                component <= 0.04045
                    ? component / 12.92
                    : pow((component + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(rgb.redComponent)
                + 0.7152 * linear(rgb.greenComponent)
                + 0.0722 * linear(rgb.blueComponent)
        }
        let light = max(luminance(lhs), luminance(rhs))
        let dark = min(luminance(lhs), luminance(rhs))
        return (light + 0.05) / (dark + 0.05)
    }
#endif

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let tableView else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        return menuProvider?(tableView.column(at: point))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        synchronizeVisibleFilterButtons()
        needsDisplay = true
    }
}

@MainActor
final class LighTxtCSVTableView: NSTableView {
    var bodyMenuProvider: ((Int, Int) -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let column = self.column(at: point)
        return bodyMenuProvider?(column, row) ?? super.menu(for: event)
    }
}

@MainActor
final class CSVFilterChipView: NSView {
    var onOpen: (() -> Void)?
    var onClear: (() -> Void)?
    let sourceColumn: Int

    private let openButton = NSButton()
    private let clearButton = NSButton()

    init(sourceColumn: Int, title: String, summary: String, fullDescription: String) {
        self.sourceColumn = sourceColumn
        let displaySummary = summary.isEmpty ? "Filtered" : summary
        let display = "\(title)  \(displaySummary)"
        let measured = (display as NSString).size(withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        ]).width
        super.init(frame: NSRect(x: 0, y: 0, width: min(210, max(105, measured + 48)), height: 28))
        wantsLayer = true
        layer?.cornerRadius = 7

        openButton.title = display
        openButton.font = .systemFont(ofSize: 12, weight: .medium)
        openButton.isBordered = false
        openButton.alignment = .left
        openButton.lineBreakMode = .byTruncatingTail
        openButton.target = self
        openButton.action = #selector(open(_:))
        openButton.toolTip = fullDescription
        openButton.setAccessibilityLabel(fullDescription)

        clearButton.image = NSImage(
            systemSymbolName: "xmark.circle.fill",
            accessibilityDescription: "Remove filter"
        )
        clearButton.imagePosition = .imageOnly
        clearButton.isBordered = false
        clearButton.target = self
        clearButton.action = #selector(clear(_:))
        clearButton.toolTip = "Remove this filter"
        clearButton.setAccessibilityLabel("Remove filter for \(title)")

        addSubview(openButton)
        addSubview(clearButton)
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        clearButton.frame = NSRect(x: bounds.maxX - 28, y: 0, width: 28, height: bounds.height)
        openButton.frame = NSRect(x: 8, y: 0, width: max(0, bounds.width - 36), height: bounds.height)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func applyAppearance() {
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.32).cgColor
        layer?.borderWidth = 1
        openButton.contentTintColor = .labelColor
        clearButton.contentTintColor = .controlAccentColor
    }

    @objc private func open(_ sender: Any?) { onOpen?() }
    @objc private func clear(_ sender: Any?) { onClear?() }

#if LIGHTXT_STANDALONE_CSV_QA
    func qaOpen() { onOpen?() }
    func qaClear() { onClear?() }
#endif
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
