import AppKit

/// Read-only, bounded Parquet table presentation. The selected file remains on
/// disk; DuckDB returns only the visible 64-row pages and bounded facet/summary
/// results. No text editor or mutable document snapshot is installed.
@MainActor
final class ParquetTableView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSPopoverDelegate {
    var onStatusChange: ((String, Bool) -> Void)?

    private static let pageSize = 64
    private static let maximumCachedPages = 4
    private static let maximumExpandedCells = 16
    private static let maximumStructuredDetailRequests = 2
    private static let collapsedRowHeight: CGFloat = 28
    private static let loadingExpandedRowHeight: CGFloat = 72
    private static let maximumExpandedRowHeight: CGFloat = 360
    private static let maximumPrettyCharacters = 65_536
    private static let maximumPrettyLines = 20
    private static let maximumPrettyIndentDepth = 16
    private static let nullPickerKey = "\u{E000}N"
    private static let textPickerPrefix = "\u{E000}T"

    private let controls = NSView()
    private let filterStrip = NSScrollView()
    private let filterContainer = NSView()
    private let statusLabel = NSTextField(labelWithString: "Open a Parquet file to begin")
    private let progress = NSProgressIndicator()
    private let scrollView = NSScrollView()
    private let tableView = ParquetReadOnlyTableView()

    private var sourceURL: URL?
    private var service: ParquetQueryService?
    private var metadata: ParquetMetadata?
    private var totalRowCount: Int64 = 0
    private var activeFilters: [Int: CSVFilterDraft] = [:]
    private var activeSort: (column: Int, ascending: Bool)?
    private var cachedPages: [Int64: ParquetPage] = [:]
    private var cacheOrder: [Int64] = []
    private struct PageRequest {
        let id: UUID
        let task: Task<Void, Never>
    }

    private struct StructuredCellKey: Hashable {
        let sourceRowOrdinal: Int64
        let column: Int
    }

    private struct StructuredPresentation {
        let text: String
        let lineCount: Int
        let sourceWasTruncated: Bool
        let displayWasTruncated: Bool
    }

    private struct StructuredDetailRequest {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var pageTasks: [Int64: PageRequest] = [:]
    private var expandedCells = Set<StructuredCellKey>()
    private var expandedCellOrder: [StructuredCellKey] = []
    private var structuredDetails: [StructuredCellKey: ParquetStructuredCellDetail] = [:]
    private var structuredPresentations: [StructuredCellKey: StructuredPresentation] = [:]
    private var structuredDetailErrors: [StructuredCellKey: String] = [:]
    private var structuredDetailTasks: [StructuredCellKey: StructuredDetailRequest] = [:]
    private var structuredDetailTaskOrder: [StructuredCellKey] = []
    private var openTask: Task<Void, Never>?
    private var uniqueValuesTask: Task<Void, Never>?
    private var summaryTask: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var presentedPopover: NSPopover?
    private weak var presentedFilterController: CSVFilterPopoverViewController?
    private var presentedFilterColumn: Int?
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
        openTask?.cancel()
        uniqueValuesTask?.cancel()
        summaryTask?.cancel()
        pageTasks.values.forEach { $0.task.cancel() }
        structuredDetailTasks.values.forEach { $0.task.cancel() }
        service?.cancelCurrentQuery()
    }

    override func layout() {
        super.layout()
        enforceTwoRowHeaderHeight()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
        tableView.reloadData()
    }

    func load(url: URL) {
        deactivate(showPausedStatus: false)
        generation &+= 1
        let currentGeneration = generation
        sourceURL = url.standardizedFileURL
        setBusy(true, text: "Reading Parquet schema…")
        do {
            let service = try ParquetQueryService(url: url)
            self.service = service
            openTask = Task { [weak self] in
                do {
                    let metadata = try await service.open()
                    guard !Task.isCancelled, let self, self.generation == currentGeneration else {
                        await service.close()
                        return
                    }
                    self.metadata = metadata
                    self.totalRowCount = metadata.rowCount
                    self.configureColumns(metadata.columns)
                    self.updateFilterStrip()
                    self.tableView.reloadData()
                    self.materializeHeaderFilterControls()
                    self.updateStatus()
                    self.requestPage(containing: 0)
                } catch {
                    guard let self, self.generation == currentGeneration else { return }
                    self.report(error)
                }
            }
        } catch {
            report(error)
        }
    }

    func deactivate() { deactivate(showPausedStatus: true) }

    func focusTable() {
        window?.makeFirstResponder(tableView)
    }

    private func deactivate(showPausedStatus: Bool) {
        generation &+= 1
        openTask?.cancel()
        uniqueValuesTask?.cancel()
        summaryTask?.cancel()
        openTask = nil
        uniqueValuesTask = nil
        summaryTask = nil
        cancelPageTasks()
        clearStructuredExpansionState(reload: false)
        presentedPopover?.close()
        presentedPopover = nil
        let closingService = service
        closingService?.cancelCurrentQuery()
        service = nil
        if let closingService { Task { await closingService.close() } }
        sourceURL = nil
        metadata = nil
        totalRowCount = 0
        activeFilters.removeAll(keepingCapacity: false)
        activeSort = nil
        cachedPages.removeAll(keepingCapacity: false)
        cacheOrder.removeAll(keepingCapacity: false)
        removeDataColumns()
        isSettingSortDescriptors = true
        tableView.sortDescriptors = []
        isSettingSortDescriptors = false
        tableView.reloadData()
        updateFilterStrip()
        if showPausedStatus { setBusy(false, text: "Parquet table paused") }
    }

    private func configureControls() {
        controls.wantsLayer = true
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.setAccessibilityLabel("Parquet query progress")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        filterStrip.documentView = filterContainer
        filterStrip.drawsBackground = false
        filterStrip.borderType = .noBorder
        filterStrip.hasHorizontalScroller = false
        filterStrip.hasVerticalScroller = false
        filterStrip.autohidesScrollers = true
        filterStrip.horizontalScrollElasticity = .allowed
        filterStrip.setAccessibilityLabel("Active Parquet filters")
    }

    private func configureTable() {
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.allowsColumnReordering = true
        tableView.allowsColumnResizing = true
        tableView.columnAutoresizingStyle = .noColumnAutoresizing
        tableView.rowHeight = Self.collapsedRowHeight
        tableView.intercellSpacing = NSSize(width: 1, height: 1)
        tableView.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]

        let headerView = LighTxtCSVHeaderView()
        headerView.menuProvider = { [weak self] index in self?.columnMenu(tableColumnIndex: index) }
        headerView.onCommitContainsFilter = { [weak self] column, value in
            self?.commitContains(value, column: column)
        }
        headerView.onShowFilterValues = { [weak self] column in self?.showFilter(column: column) }
        headerView.filterTextProvider = { [weak self] column in self?.activeFilters[column]?.value ?? "" }
        headerView.filterEditingEnabledProvider = { [weak self] in self?.metadata != nil }
        tableView.headerView = headerView
        tableView.bodyMenuProvider = { [weak self] column, row in self?.bodyMenu(column: column, row: row) }
        tableView.activateProvider = { [weak self] column, row in
            self?.toggleStructuredCell(visualColumn: column, row: row) ?? false
        }
        tableView.target = self
        tableView.doubleAction = #selector(activateStructuredCell(_:))
        tableView.setAccessibilityLabel("Read-only Parquet table")

        let rowNumber = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("parquet-row-number"))
        rowNumber.title = "#"
        let rowHeader = LighTxtCSVHeaderCell(textCell: "#")
        rowHeader.showsFilterControls = false
        rowNumber.headerCell = rowHeader
        rowNumber.width = 68
        rowNumber.minWidth = 52
        rowNumber.maxWidth = 110
        rowNumber.resizingMask = .userResizingMask
        tableView.addTableColumn(rowNumber)

        scrollView.documentView = tableView
        headerView.frame.size.height = LighTxtCSVHeaderView.preferredHeight
        scrollView.tile()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
    }

    private func configureLayout() {
        [controls, filterStrip, filterContainer, statusLabel, progress, scrollView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(controls)
        controls.addSubview(filterStrip)
        controls.addSubview(statusLabel)
        controls.addSubview(progress)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor),
            controls.topAnchor.constraint(equalTo: topAnchor),
            controls.heightAnchor.constraint(equalToConstant: 44),
            filterStrip.leadingAnchor.constraint(equalTo: controls.leadingAnchor, constant: 10),
            filterStrip.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            filterStrip.heightAnchor.constraint(equalToConstant: 32),
            filterStrip.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: filterStrip.trailingAnchor, constant: 12),
            statusLabel.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            progress.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 8),
            progress.trailingAnchor.constraint(equalTo: controls.trailingAnchor, constant: -12),
            progress.centerYAnchor.constraint(equalTo: controls.centerYAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: controls.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        let width = filterStrip.widthAnchor.constraint(equalToConstant: 0)
        width.priority = .defaultHigh
        width.isActive = true
    }

    private func applyAppearance() {
        let appearance = effectiveAppearance
        let background = LighTxtTheme.resolved(LighTxtTheme.editorBackground, for: appearance)
        controls.layer?.backgroundColor = LighTxtTheme.resolved(
            LighTxtTheme.gutterBackground,
            for: appearance
        ).cgColor
        statusLabel.textColor = LighTxtTheme.resolved(LighTxtTheme.secondaryText, for: appearance)
        scrollView.drawsBackground = true
        scrollView.backgroundColor = background
        tableView.backgroundColor = background
        tableView.gridColor = LighTxtTheme.resolved(LighTxtTheme.separator, for: appearance)
        tableView.headerView?.needsDisplay = true
    }

    private func enforceTwoRowHeaderHeight() {
        guard let header = tableView.headerView else { return }
        let target = LighTxtCSVHeaderView.preferredHeight
        let clip = header.superview as? NSClipView
        if abs(header.frame.height - target) > 0.5 || abs((clip?.bounds.height ?? 0) - target) > 0.5 {
            header.frame.size.height = target
            clip?.frame.size.height = target
            scrollView.tile()
        }
    }

    /// Parquet installs its schema asynchronously, after the initially empty
    /// header has already completed a layout pass. Explicitly rematerialize the
    /// visible overlay controls at that boundary so discoverability never
    /// depends on a click in their expected hit regions.
    private func materializeHeaderFilterControls() {
        scrollView.tile()
        enforceTwoRowHeaderHeight()
        guard let header = tableView.headerView as? LighTxtCSVHeaderView else { return }
        header.needsLayout = true
        header.layoutSubtreeIfNeeded()
        header.refreshFilterDisplay()
        header.needsDisplay = true
    }

    private func configureColumns(_ columns: [ParquetColumn]) {
        removeDataColumns()
        for column in columns {
            let tableColumn = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier("csv-column-\(column.index)")
            )
            tableColumn.title = column.name
            let header = LighTxtCSVHeaderCell(textCell: column.name)
            header.isFiltered = activeFilters[column.index] != nil
            header.filterText = activeFilters[column.index]?.value ?? ""
            tableColumn.headerCell = header
            tableColumn.sortDescriptorPrototype = NSSortDescriptor(
                key: tableColumn.identifier.rawValue,
                ascending: true
            )
            let contentMinimum: CGFloat = column.isStructured ? 240 : 120
            tableColumn.width = min(320, max(contentMinimum, CGFloat(column.name.count * 8 + 44)))
            tableColumn.minWidth = 72
            tableColumn.maxWidth = 800
            tableColumn.resizingMask = .userResizingMask
            tableView.addTableColumn(tableColumn)
        }
        materializeHeaderFilterControls()
    }

    private func removeDataColumns() {
        for column in tableView.tableColumns where column.identifier.rawValue.hasPrefix("csv-column-") {
            tableView.removeTableColumn(column)
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { Int(clamping: totalRowCount) }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard let ordinal = cachedSourceRowOrdinal(row: row) else {
            return Self.collapsedRowHeight
        }
        let keys = expandedCells.filter { $0.sourceRowOrdinal == ordinal }
        guard !keys.isEmpty else { return Self.collapsedRowHeight }
        let lineCount = keys.compactMap { structuredPresentations[$0]?.lineCount }.max() ?? 3
        return min(
            Self.maximumExpandedRowHeight,
            max(Self.loadingExpandedRowHeight, CGFloat(lineCount) * 16 + 14)
        )
    }

    func tableViewColumnDidMove(_ notification: Notification) {
        materializeHeaderFilterControls()
    }

    func tableViewColumnDidResize(_ notification: Notification) {
        materializeHeaderFilterControls()
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let tableColumn else { return nil }
        if tableColumn.identifier.rawValue == "parquet-row-number" {
            let field = reusableLabel(identifier: "parquet-row")
            field.stringValue = Int64(row + 1).formatted()
            field.alignment = .right
            field.textColor = .secondaryLabelColor
            return field
        }
        guard let column = dataColumn(tableColumn) else { return nil }
        if let columns = metadata?.columns,
           columns.indices.contains(column),
           columns[column].isStructured {
            let cellView = reusableStructuredCell()
            guard let cell = cachedCell(row: row, column: column) else {
                cellView.configureLoading(columnTitle: tableColumn.title)
                requestPage(containing: Int64(row))
                return cellView
            }
            let key = cachedSourceRowOrdinal(row: row).map {
                StructuredCellKey(sourceRowOrdinal: $0, column: column)
            }
            let isExpanded = key.map(expandedCells.contains) ?? false
            cellView.configure(
                compactText: cell.value,
                compactWasTruncated: cell.isTruncated,
                expanded: isExpanded,
                expandedText: key.flatMap { structuredPresentations[$0]?.text },
                expandedSourceWasTruncated: key.flatMap {
                    structuredPresentations[$0]?.sourceWasTruncated
                } ?? false,
                expandedDisplayWasTruncated: key.flatMap {
                    structuredPresentations[$0]?.displayWasTruncated
                } ?? false,
                detailError: key.flatMap { structuredDetailErrors[$0] },
                isLoadingDetail: key.map {
                    isExpanded
                        && structuredPresentations[$0] == nil
                        && structuredDetailErrors[$0] == nil
                } ?? false,
                row: row,
                columnTitle: tableColumn.title,
                onToggle: { [weak self] in
                    _ = self?.toggleStructuredCell(dataColumn: column, row: row)
                }
            )
            return cellView
        }
        let field = reusableLabel(identifier: "parquet-value")
        field.alignment = .left
        field.textColor = .labelColor
        field.stringValue = ""
        field.placeholderString = "Loading…"
        field.toolTip = nil
        if let cell = cachedCell(row: row, column: column) {
            field.placeholderString = nil
            if let value = cell.value {
                field.stringValue = value
                field.toolTip = cell.isTruncated ? "Value shortened for the bounded table preview" : value
            } else {
                field.stringValue = "NULL"
                field.textColor = .tertiaryLabelColor
                field.font = .monospacedSystemFont(ofSize: 12, weight: .regular).italic()
                field.toolTip = "Parquet NULL"
            }
        } else {
            requestPage(containing: Int64(row))
        }
        return field
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !isSettingSortDescriptors else { return }
        guard let descriptor = tableView.sortDescriptors.first,
              let key = descriptor.key,
              key.hasPrefix("csv-column-"),
              let column = Int(key.dropFirst("csv-column-".count)) else {
            activeSort = nil
            resetQuery()
            return
        }
        if let old = oldDescriptors.first,
           old.key == key,
           !old.ascending,
           descriptor.ascending {
            activeSort = nil
            isSettingSortDescriptors = true
            tableView.sortDescriptors = []
            isSettingSortDescriptors = false
        } else {
            activeSort = (column, descriptor.ascending)
        }
        resetQuery()
    }

    private func reusableLabel(identifier: String) -> NSTextField {
        let id = NSUserInterfaceItemIdentifier(identifier)
        let field = (tableView.makeView(withIdentifier: id, owner: self) as? NSTextField)
            ?? NSTextField(labelWithString: "")
        field.identifier = id
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.lineBreakMode = .byTruncatingTail
        field.isSelectable = true
        field.isEditable = false
        field.isBordered = false
        field.drawsBackground = false
        return field
    }

    private func reusableStructuredCell() -> ParquetStructuredCellView {
        let identifier = NSUserInterfaceItemIdentifier("parquet-structured-value")
        let view = (tableView.makeView(withIdentifier: identifier, owner: self) as? ParquetStructuredCellView)
            ?? ParquetStructuredCellView()
        view.identifier = identifier
        return view
    }

    private func cachedCell(row: Int, column: Int) -> ParquetCell? {
        let offset = Int64(row / Self.pageSize * Self.pageSize)
        guard let page = cachedPages[offset] else { return nil }
        let local = row - Int(offset)
        guard page.rows.indices.contains(local), page.rows[local].indices.contains(column) else { return nil }
        return page.rows[local][column]
    }

    private func cachedSourceRowOrdinal(row: Int) -> Int64? {
        let offset = Int64(row / Self.pageSize * Self.pageSize)
        guard let page = cachedPages[offset] else { return nil }
        let local = row - Int(offset)
        guard page.sourceRowOrdinals.indices.contains(local) else { return nil }
        return page.sourceRowOrdinals[local]
    }

    private func requestPage(containing row: Int64) {
        guard row >= 0, let service else { return }
        let offset = row / Int64(Self.pageSize) * Int64(Self.pageSize)
        guard cachedPages[offset] == nil, pageTasks[offset] == nil else { return }
        if pageTasks.count >= 2,
           let farthest = pageTasks.keys.max(by: {
               abs($0 - offset) < abs($1 - offset)
           }) {
            pageTasks.removeValue(forKey: farthest)?.task.cancel()
        }
        let currentGeneration = generation
        let query = serviceQuery()
        let requestID = UUID()
        let task = Task { [weak self] in
            do {
                let page = try await service.page(offset: offset, limit: Self.pageSize, query: query)
                guard !Task.isCancelled, let self, self.generation == currentGeneration else { return }
                guard self.finishPageRequest(offset: offset, id: requestID) else { return }
                let rowCountChanged = self.totalRowCount != page.totalRowCount
                self.totalRowCount = page.totalRowCount
                self.cache(page)
                if rowCountChanged { self.tableView.noteNumberOfRowsChanged() }
                self.tableView.reloadData(forRowIndexes: IndexSet(integersIn: Int(offset)..<Int(offset) + page.rows.count), columnIndexes: IndexSet(integersIn: 0..<self.tableView.tableColumns.count))
                self.invalidateStructuredRows(for: self.expandedCellOrder)
                self.updateStatus()
            } catch is CancellationError {
                self?.finishPageRequest(offset: offset, id: requestID)
            } catch let error as ParquetQueryError where error == .cancelled {
                self?.finishPageRequest(offset: offset, id: requestID)
            } catch {
                guard let self, self.generation == currentGeneration else { return }
                guard self.finishPageRequest(offset: offset, id: requestID) else { return }
                self.report(error)
            }
        }
        pageTasks[offset] = PageRequest(id: requestID, task: task)
    }

    @discardableResult
    private func finishPageRequest(offset: Int64, id: UUID) -> Bool {
        guard pageTasks[offset]?.id == id else { return false }
        pageTasks.removeValue(forKey: offset)
        return true
    }

    private func cache(_ page: ParquetPage) {
        cachedPages[page.offset] = page
        cacheOrder.removeAll { $0 == page.offset }
        cacheOrder.append(page.offset)
        while cacheOrder.count > Self.maximumCachedPages {
            cachedPages.removeValue(forKey: cacheOrder.removeFirst())
        }
    }

    private func cancelPageTasks() {
        pageTasks.values.forEach { $0.task.cancel() }
        pageTasks.removeAll(keepingCapacity: false)
    }

    private func clearStructuredExpansionState(reload: Bool) {
        structuredDetailTasks.values.forEach { $0.task.cancel() }
        structuredDetailTasks.removeAll(keepingCapacity: false)
        structuredDetailTaskOrder.removeAll(keepingCapacity: false)
        expandedCells.removeAll(keepingCapacity: false)
        expandedCellOrder.removeAll(keepingCapacity: false)
        structuredDetails.removeAll(keepingCapacity: false)
        structuredPresentations.removeAll(keepingCapacity: false)
        structuredDetailErrors.removeAll(keepingCapacity: false)
        if reload { tableView.reloadData() }
    }

    @objc private func activateStructuredCell(_ sender: Any?) {
        let row = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        let column = tableView.clickedColumn >= 0 ? tableView.clickedColumn : tableView.selectedColumn
        _ = toggleStructuredCell(visualColumn: column, row: row)
    }

    @discardableResult
    private func toggleStructuredCell(visualColumn: Int, row: Int) -> Bool {
        guard row >= 0 else { return false }
        if tableView.tableColumns.indices.contains(visualColumn) {
            guard let column = dataColumn(tableView.tableColumns[visualColumn]) else { return false }
            return toggleStructuredCell(dataColumn: column, row: row)
        }
        // Keyboard row navigation does not enable NSTableView column
        // selection. If there is no prior mouse-focused column, Return/Space
        // deterministically activates the first non-NULL structured cell.
        for tableColumn in tableView.tableColumns {
            guard let column = dataColumn(tableColumn),
                  toggleStructuredCell(dataColumn: column, row: row) else { continue }
            return true
        }
        return false
    }

    @discardableResult
    private func toggleStructuredCell(dataColumn column: Int, row: Int) -> Bool {
        guard row >= 0,
              let metadata,
              metadata.columns.indices.contains(column),
              metadata.columns[column].isStructured,
              cachedCell(row: row, column: column)?.value != nil,
              let sourceRowOrdinal = cachedSourceRowOrdinal(row: row) else { return false }
        let key = StructuredCellKey(sourceRowOrdinal: sourceRowOrdinal, column: column)
        var affectedKeys = [key]
        if expandedCells.contains(key) {
            removeStructuredExpansion(key)
        } else {
            if expandedCellOrder.count >= Self.maximumExpandedCells,
               let evicted = expandedCellOrder.first {
                affectedKeys.append(evicted)
                removeStructuredExpansion(evicted)
            }
            expandedCells.insert(key)
            expandedCellOrder.append(key)
        }
        startWaitingStructuredDetails()
        invalidateStructuredRows(for: affectedKeys)
        return true
    }

    private func removeStructuredExpansion(_ key: StructuredCellKey) {
        expandedCells.remove(key)
        expandedCellOrder.removeAll { $0 == key }
        structuredDetailTasks.removeValue(forKey: key)?.task.cancel()
        structuredDetailTaskOrder.removeAll { $0 == key }
        structuredDetails.removeValue(forKey: key)
        structuredPresentations.removeValue(forKey: key)
        structuredDetailErrors.removeValue(forKey: key)
    }

    private func requestStructuredDetail(for key: StructuredCellKey) {
        guard expandedCells.contains(key),
              structuredDetails[key] == nil,
              structuredDetailErrors[key] == nil,
              structuredDetailTasks[key] == nil,
              structuredDetailTasks.count < Self.maximumStructuredDetailRequests,
              let service else { return }
        let requestID = UUID()
        let currentGeneration = generation
        let task = Task { [weak self] in
            do {
                let detail = try await service.structuredCellDetail(
                    sourceRowOrdinal: key.sourceRowOrdinal,
                    column: key.column
                )
                guard !Task.isCancelled,
                      let self,
                      self.generation == currentGeneration,
                      self.expandedCells.contains(key),
                      self.finishStructuredDetailRequest(key: key, id: requestID) else { return }
                self.structuredDetails[key] = detail
                if let json = detail.json {
                    self.structuredPresentations[key] = Self.prettyStructuredJSON(
                        json,
                        sourceWasTruncated: detail.isTruncated
                    )
                } else {
                    self.structuredPresentations[key] = StructuredPresentation(
                        text: "NULL",
                        lineCount: 1,
                        sourceWasTruncated: false,
                        displayWasTruncated: false
                    )
                }
                self.invalidateStructuredRows(for: [key])
                self.startWaitingStructuredDetails()
            } catch is CancellationError {
                guard let self,
                      self.finishStructuredDetailRequest(key: key, id: requestID) else { return }
                self.startWaitingStructuredDetails()
            } catch let error as ParquetQueryError where error == .cancelled {
                guard let self,
                      self.finishStructuredDetailRequest(key: key, id: requestID) else { return }
                self.startWaitingStructuredDetails()
            } catch {
                guard let self,
                      self.generation == currentGeneration,
                      self.expandedCells.contains(key),
                      self.finishStructuredDetailRequest(key: key, id: requestID) else { return }
                self.structuredDetailErrors[key] = error.localizedDescription
                self.invalidateStructuredRows(for: [key])
                self.startWaitingStructuredDetails()
            }
        }
        structuredDetailTasks[key] = StructuredDetailRequest(id: requestID, task: task)
        structuredDetailTaskOrder.append(key)
    }

    /// Keeps DuckDB work bounded without collapsing cells the user asked to
    /// expand. Additional cells remain visibly loading and start in stable
    /// expansion order as one of the two active detail requests completes.
    private func startWaitingStructuredDetails() {
        guard structuredDetailTasks.count < Self.maximumStructuredDetailRequests else { return }
        for key in expandedCellOrder where structuredDetailTasks.count < Self.maximumStructuredDetailRequests {
            guard structuredDetails[key] == nil,
                  structuredPresentations[key] == nil,
                  structuredDetailErrors[key] == nil,
                  structuredDetailTasks[key] == nil else { continue }
            requestStructuredDetail(for: key)
        }
    }

    @discardableResult
    private func finishStructuredDetailRequest(key: StructuredCellKey, id: UUID) -> Bool {
        guard structuredDetailTasks[key]?.id == id else { return false }
        structuredDetailTasks.removeValue(forKey: key)
        structuredDetailTaskOrder.removeAll { $0 == key }
        return true
    }

    private func displayedRow(forSourceOrdinal ordinal: Int64) -> Int? {
        for (offset, page) in cachedPages {
            if let local = page.sourceRowOrdinals.firstIndex(of: ordinal) {
                return Int(offset) + local
            }
        }
        return nil
    }

    private func invalidateStructuredRows(for keys: [StructuredCellKey]) {
        let rows = IndexSet(keys.compactMap { displayedRow(forSourceOrdinal: $0.sourceRowOrdinal) })
        guard !rows.isEmpty else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            tableView.noteHeightOfRows(withIndexesChanged: rows)
        }
        tableView.reloadData(
            forRowIndexes: rows,
            columnIndexes: IndexSet(integersIn: 0..<tableView.tableColumns.count)
        )
    }

    /// Adds whitespace without parsing/re-serializing the JSON value, so very
    /// large integers, key order, escaped Unicode, and embedded punctuation are
    /// preserved exactly. Output, indentation, and visible lines are all hard
    /// capped independently of the already bounded service detail.
    private static func prettyStructuredJSON(
        _ json: String,
        sourceWasTruncated: Bool
    ) -> StructuredPresentation {
        var output = ""
        var outputCharacters = 0
        var lineCount = 1
        var depth = 0
        var inString = false
        var escaped = false
        var pendingOpen = false
        var lineHasContent = false
        var displayWasTruncated = false
        var isAppendingMarker = false
        let markerReserve = 192

        @discardableResult
        func append(_ text: String) -> Bool {
            let characterCount = text.count
            let limit = isAppendingMarker
                ? maximumPrettyCharacters
                : maximumPrettyCharacters - markerReserve
            guard outputCharacters + characterCount <= limit else {
                displayWasTruncated = true
                return false
            }
            output.append(text)
            outputCharacters += characterCount
            return true
        }

        @discardableResult
        func newline() -> Bool {
            guard lineCount < maximumPrettyLines else {
                displayWasTruncated = true
                return false
            }
            lineCount += 1
            let indentation = String(
                repeating: "  ",
                count: min(depth, maximumPrettyIndentDepth)
            )
            let appended = append("\n" + indentation)
            if appended { lineHasContent = false }
            return appended
        }

        formatting: for scalar in json.unicodeScalars {
            if inString {
                guard append(String(scalar)) else { break formatting }
                lineHasContent = true
                if escaped {
                    escaped = false
                } else if scalar.value == 0x5C {
                    escaped = true
                } else if scalar.value == 0x22 {
                    inString = false
                }
                continue
            }

            if scalar.value == 0x20 || scalar.value == 0x09
                || scalar.value == 0x0A || scalar.value == 0x0D {
                continue
            }
            if pendingOpen {
                if scalar.value == 0x7D || scalar.value == 0x5D {
                    pendingOpen = false
                    depth = max(0, depth - 1)
                    guard append(String(scalar)) else { break formatting }
                    lineHasContent = true
                    continue
                }
                guard newline() else { break formatting }
                pendingOpen = false
            }

            switch scalar.value {
            case 0x22: // quote
                inString = true
                guard append(String(scalar)) else { break formatting }
                lineHasContent = true
            case 0x7B, 0x5B: // { [
                guard append(String(scalar)) else { break formatting }
                lineHasContent = true
                depth += 1
                pendingOpen = true
            case 0x7D, 0x5D: // } ]
                depth = max(0, depth - 1)
                if lineHasContent, !newline() { break formatting }
                guard append(String(scalar)) else { break formatting }
                lineHasContent = true
            case 0x2C: // comma
                guard append(","), newline() else { break formatting }
            case 0x3A: // colon
                guard append(": ") else { break formatting }
            default:
                guard append(String(scalar)) else { break formatting }
                lineHasContent = true
            }
        }

        if sourceWasTruncated || displayWasTruncated {
            isAppendingMarker = true
            if lineCount < maximumPrettyLines, lineHasContent {
                output.append("\n")
                outputCharacters += 1
                lineCount += 1
                lineHasContent = false
            } else if lineHasContent {
                output.append(" ")
                outputCharacters += 1
            }
            let reason = sourceWasTruncated
                ? "… Structured value shortened at \(ParquetQueryService.Limits.maximumStructuredDetailCharacters.formatted()) characters"
                : "… Structured display limited to \(maximumPrettyLines) lines"
            if !append(reason) {
                let prefixCount = max(0, maximumPrettyCharacters - reason.count - 2)
                output = String(output.prefix(prefixCount)) + "\n" + reason
                outputCharacters = output.count
            }
            lineHasContent = true
        }

        return StructuredPresentation(
            text: output,
            lineCount: lineCount,
            sourceWasTruncated: sourceWasTruncated,
            displayWasTruncated: displayWasTruncated
        )
    }

    private func resetQuery() {
        generation &+= 1
        cancelPageTasks()
        clearStructuredExpansionState(reload: false)
        uniqueValuesTask?.cancel()
        summaryTask?.cancel()
        cachedPages.removeAll(keepingCapacity: true)
        cacheOrder.removeAll(keepingCapacity: true)
        totalRowCount = 0
        refreshHeaderFilters()
        updateFilterStrip()
        tableView.reloadData()
        setBusy(true, text: "Applying Parquet query…")
        requestPage(containing: 0)
        if let column = presentedFilterColumn,
           let controller = presentedFilterController,
           let popover = presentedPopover,
           let service {
            loadUniqueValues(
                column: column,
                controller: controller,
                popover: popover,
                service: service
            )
        }
    }

    private func serviceQuery() -> ParquetTableQuery {
        let filters = activeFilters.sorted(by: { $0.key < $1.key }).compactMap { column, draft -> ParquetColumnFilter? in
            guard !draft.isEmpty else { return nil }
            return ParquetColumnFilter(
                column: column,
                containsText: draft.value,
                containsCaseSensitive: draft.isCaseSensitive,
                selectedValues: Set(draft.selectedValues.compactMap(Self.decodePickerValue))
            )
        }
        let sort = activeSort.map {
            ParquetSortDescriptor(column: $0.column, order: $0.ascending ? .ascending : .descending)
        }
        return ParquetTableQuery(filters: filters, sort: sort)
    }

    private func commitContains(_ value: String, column: Int) {
        var draft = activeFilters[column] ?? CSVFilterDraft(predicate: .contains, value: "", isCaseSensitive: false)
        draft.value = value
        if draft.isEmpty { activeFilters.removeValue(forKey: column) } else { activeFilters[column] = draft }
        resetQuery()
    }

    private func showFilter(
        column: Int,
        anchor: NSView? = nil,
        anchorRect: NSRect? = nil
    ) {
        guard let metadata, metadata.columns.indices.contains(column), let service else { return }
        replacePresentedPopover()
        let title = metadata.columns[column].name
        let controller = CSVFilterPopoverViewController(
            columnTitle: title,
            filter: activeFilters[column],
            valueDisplayProvider: Self.displayPickerValue
        )
        controller.onCommit = { [weak self] draft in
            guard let self else { return }
            if draft.isEmpty { self.activeFilters.removeValue(forKey: column) }
            else { self.activeFilters[column] = draft }
            self.resetQuery()
        }
        controller.onClear = { [weak self] in
            self?.activeFilters.removeValue(forKey: column)
            self?.resetQuery()
        }
        controller.showUniqueValuesLoading()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.delegate = self
        presentedPopover = popover
        presentedFilterController = controller
        presentedFilterColumn = column
        show(popover: popover, column: column, anchor: anchor, anchorRect: anchorRect)
        loadUniqueValues(
            column: column,
            controller: controller,
            popover: popover,
            service: service
        )
    }

    private func loadUniqueValues(
        column: Int,
        controller: CSVFilterPopoverViewController,
        popover: NSPopover,
        service: ParquetQueryService
    ) {
        uniqueValuesTask?.cancel()
        controller.showUniqueValuesLoading()
        let leadingPageTask = pageTasks[0]?.task
        let query = serviceQuery()
        uniqueValuesTask = Task { [weak self, weak controller] in
            do {
                // resetQuery installs the bounded page first. Let it complete
                // before a potentially long facet aggregation on the same
                // serial DuckDB connection.
                await leadingPageTask?.value
                try Task.checkCancellation()
                let result = try await service.uniqueValues(forColumn: column, query: query)
                guard !Task.isCancelled,
                      let self,
                      let controller,
                      self.presentedPopover === popover,
                      self.presentedFilterController === controller,
                      self.presentedFilterColumn == column else { return }
                let values = result.values.map { Self.encodePickerValue($0.value) }
                let truncation: CSVUniqueValuesTruncationReason? = result.omittedOversizedValueCount > 0
                    ? .valueByteLimit
                    : (result.isTruncated ? .uniqueValueCountLimit : nil)
                controller.showUniqueValues(CSVUniqueValuesResult(
                    column: column,
                    values: values,
                    // DuckDB performs this facet as one pushed-down aggregate;
                    // there is no truthful CSV-style incremental scan count,
                    // especially because the target column's own filter is
                    // intentionally excluded from the facet population.
                    scannedRecordCount: 0,
                    eligibleRecordCount: 0,
                    totalRecordCount: nil,
                    isCompleteDataset: truncation == nil,
                    truncationReason: truncation,
                    maximumUniqueValueCount: ParquetQueryService.Limits.default.maximumUniqueValues,
                    maximumRetainedValueBytes: ParquetQueryService.Limits.maximumAggregateFacetUTF8Bytes
                ))
            } catch is CancellationError {
                return
            } catch let error as ParquetQueryError where error == .cancelled {
                return
            } catch {
                guard let self,
                      let controller,
                      self.presentedPopover === popover,
                      self.presentedFilterController === controller,
                      self.presentedFilterColumn == column else { return }
                controller.showUniqueValues(error: error)
            }
        }
    }

    private func show(
        popover: NSPopover,
        column: Int,
        anchor: NSView?,
        anchorRect: NSRect? = nil
    ) {
        if let anchor {
            popover.show(relativeTo: anchorRect ?? anchor.bounds, of: anchor, preferredEdge: .maxY)
            return
        }
        guard let header = tableView.headerView,
              let tableColumn = tableColumn(dataColumn: column) else { return }
        let index = tableView.column(withIdentifier: tableColumn.identifier)
        guard index >= 0 else { return }
        popover.show(relativeTo: header.headerRect(ofColumn: index), of: header, preferredEdge: .maxY)
    }

    private func showSummary(column: Int, anchor: NSView? = nil) {
        guard let metadata, metadata.columns.indices.contains(column), let service else { return }
        replacePresentedPopover()
        let controller = CSVColumnSummaryPopoverViewController(columnTitle: metadata.columns[column].name)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = controller
        popover.delegate = self
        presentedPopover = popover
        show(popover: popover, column: column, anchor: anchor)
        let query = serviceQuery()
        let currentGeneration = generation
        summaryTask = Task { [weak self, weak controller] in
            do {
                let summary = try await service.columnSummary(forColumn: column, query: query)
                guard !Task.isCancelled, let self, let controller, self.generation == currentGeneration else { return }
                controller.show(CSVColumnSummaryPresentation(
                    type: summary.column.typeName,
                    samplingDescription: "Filtered Parquet dataset",
                    rowLabel: "Rows",
                    rowCount: summary.rowCount,
                    emptyCount: summary.nullCount,
                    distinctValueDescription: "≈ \(summary.approximateDistinctCount.formatted())",
                    minimum: summary.minimum,
                    maximum: summary.maximum,
                    frequentValues: summary.frequentValues.map {
                        .init(value: $0.value.displayText, count: $0.count, isEstimated: false)
                    },
                    isApproximate: true
                ))
            } catch {
                guard let self, let controller, self.generation == currentGeneration else { return }
                controller.show(error: error)
            }
        }
    }

    private func updateFilterStrip() {
        filterContainer.subviews.forEach { $0.removeFromSuperview() }
        var x: CGFloat = 0
        for (column, draft) in activeFilters.sorted(by: { $0.key < $1.key }) {
            guard let columns = metadata?.columns, columns.indices.contains(column) else { continue }
            let title = columns[column].name
            let summary = filterSummary(draft)
            let chip = CSVFilterChipView(
                sourceColumn: column,
                title: title,
                summary: summary,
                fullDescription: "Filter \(title): \(summary)"
            )
            chip.frame.origin = NSPoint(x: x, y: 2)
            chip.onOpen = { [weak self, weak chip] in
                guard let self, let chip else { return }
                // Anchor to the stable scroll view, not the chip itself: a
                // committed checkbox/text change rebuilds filterContainer and
                // would otherwise detach the popover mid-interaction.
                let rect = self.filterStrip.convert(chip.bounds, from: chip)
                self.showFilter(column: column, anchor: self.filterStrip, anchorRect: rect)
            }
            chip.onClear = { [weak self] in
                self?.activeFilters.removeValue(forKey: column)
                self?.resetQuery()
            }
            filterContainer.addSubview(chip)
            x += chip.frame.width + 6
        }
        if !activeFilters.isEmpty {
            let clear = NSButton(title: "Clear filters", target: self, action: #selector(clearFilters(_:)))
            clear.bezelStyle = .inline
            clear.frame = NSRect(x: x, y: 2, width: 90, height: 28)
            filterContainer.addSubview(clear)
            x += 96
        }
        filterContainer.frame = NSRect(x: 0, y: 0, width: max(1, x), height: 32)
        filterStrip.isHidden = activeFilters.isEmpty
        for constraint in filterStrip.constraints where constraint.firstAttribute == .width {
            constraint.constant = min(520, x)
        }
    }

    @objc private func clearFilters(_ sender: Any?) {
        activeFilters.removeAll(keepingCapacity: true)
        resetQuery()
    }

    private func filterSummary(_ draft: CSVFilterDraft) -> String {
        var pieces: [String] = []
        if !draft.value.isEmpty { pieces.append(draft.value) }
        if let first = draft.selectedValues.sorted().first {
            let value = Self.displayPickerValue(first)
            pieces.append(draft.selectedValues.count == 1 ? value : "\(value) +\(draft.selectedValues.count - 1)")
        }
        return pieces.joined(separator: " · ")
    }

    private func refreshHeaderFilters() {
        for tableColumn in tableView.tableColumns {
            guard let column = dataColumn(tableColumn),
                  let header = tableColumn.headerCell as? LighTxtCSVHeaderCell else { continue }
            header.isFiltered = activeFilters[column] != nil
            header.filterText = activeFilters[column]?.value ?? ""
        }
        (tableView.headerView as? LighTxtCSVHeaderView)?.refreshFilterDisplay()
    }

    private func columnMenu(tableColumnIndex: Int) -> NSMenu? {
        guard tableView.tableColumns.indices.contains(tableColumnIndex),
              let column = dataColumn(tableView.tableColumns[tableColumnIndex]) else { return nil }
        let menu = NSMenu()
        menu.addItem(menuItem("Sort Ascending", action: #selector(sortAscending(_:)), column: column))
        menu.addItem(menuItem("Sort Descending", action: #selector(sortDescending(_:)), column: column))
        menu.addItem(menuItem("Clear Sort", action: #selector(clearSort(_:)), column: column))
        menu.addItem(.separator())
        menu.addItem(menuItem("Filter…", action: #selector(openFilterMenu(_:)), column: column))
        menu.addItem(menuItem("Column Summary…", action: #selector(openSummaryMenu(_:)), column: column))
        return menu
    }

    private func menuItem(_ title: String, action: Selector, column: Int) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = column
        return item
    }

    @objc private func sortAscending(_ sender: NSMenuItem) { applySort(sender, ascending: true) }
    @objc private func sortDescending(_ sender: NSMenuItem) { applySort(sender, ascending: false) }
    @objc private func clearSort(_ sender: NSMenuItem) {
        activeSort = nil
        isSettingSortDescriptors = true
        tableView.sortDescriptors = []
        isSettingSortDescriptors = false
        resetQuery()
    }
    @objc private func openFilterMenu(_ sender: NSMenuItem) {
        if let column = sender.representedObject as? Int { showFilter(column: column) }
    }
    @objc private func openSummaryMenu(_ sender: NSMenuItem) {
        if let column = sender.representedObject as? Int { showSummary(column: column) }
    }

    private func applySort(_ sender: NSMenuItem, ascending: Bool) {
        guard let column = sender.representedObject as? Int,
              let tableColumn = tableColumn(dataColumn: column) else { return }
        activeSort = (column, ascending)
        isSettingSortDescriptors = true
        tableView.sortDescriptors = [NSSortDescriptor(key: tableColumn.identifier.rawValue, ascending: ascending)]
        isSettingSortDescriptors = false
        resetQuery()
    }

    private func bodyMenu(column tableColumnIndex: Int, row: Int) -> NSMenu? {
        guard row >= 0, tableView.tableColumns.indices.contains(tableColumnIndex) else { return nil }
        let menu = NSMenu()
        if let column = dataColumn(tableView.tableColumns[tableColumnIndex]),
           let cell = cachedCell(row: row, column: column) {
            if metadata?.columns.indices.contains(column) == true,
               metadata?.columns[column].isStructured == true,
               cell.value != nil,
               let ordinal = cachedSourceRowOrdinal(row: row) {
                let key = StructuredCellKey(sourceRowOrdinal: ordinal, column: column)
                let expand = NSMenuItem(
                    title: expandedCells.contains(key) ? "Collapse Structured Value" : "Expand Structured Value",
                    action: #selector(toggleStructuredCellFromMenu(_:)),
                    keyEquivalent: ""
                )
                expand.target = self
                expand.representedObject = [row, column]
                menu.addItem(expand)
                menu.addItem(.separator())
            }
            let copy = NSMenuItem(title: "Copy Cell", action: #selector(copyCell(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = [row, column]
            menu.addItem(copy)
        }
        let copyRow = NSMenuItem(title: "Copy Row", action: #selector(copyRow(_:)), keyEquivalent: "")
        copyRow.target = self
        copyRow.representedObject = row
        copyRow.isEnabled = cachedPages[Int64(row / Self.pageSize * Self.pageSize)] != nil
        menu.addItem(copyRow)
        return menu
    }

    @objc private func toggleStructuredCellFromMenu(_ sender: NSMenuItem) {
        guard let location = sender.representedObject as? [Int], location.count == 2 else { return }
        _ = toggleStructuredCell(dataColumn: location[1], row: location[0])
    }

    @objc private func copyCell(_ sender: NSMenuItem) {
        guard let location = sender.representedObject as? [Int], location.count == 2,
              let cell = cachedCell(row: location[0], column: location[1]) else { return }
        writePasteboard(cell.value ?? "NULL")
    }

    @objc private func copyRow(_ sender: NSMenuItem) {
        guard let row = sender.representedObject as? Int, let metadata else { return }
        let values = metadata.columns.indices.map { cachedCell(row: row, column: $0)?.value ?? "NULL" }
        writePasteboard(values.joined(separator: "\t"))
    }

    private func writePasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    private func tableColumn(dataColumn: Int) -> NSTableColumn? {
        tableView.tableColumns.first { self.dataColumn($0) == dataColumn }
    }

    private func dataColumn(_ tableColumn: NSTableColumn) -> Int? {
        let raw = tableColumn.identifier.rawValue
        guard raw.hasPrefix("csv-column-") else { return nil }
        return Int(raw.dropFirst("csv-column-".count))
    }

    private static func encodePickerValue(_ value: ParquetFilterValue) -> String {
        switch value {
        case .null: nullPickerKey
        case let .text(text): textPickerPrefix + text
        }
    }

    private static func decodePickerValue(_ key: String) -> ParquetFilterValue? {
        if key == nullPickerKey { return .null }
        guard key.hasPrefix(textPickerPrefix) else { return nil }
        return .text(String(key.dropFirst(textPickerPrefix.count)))
    }

    private static func displayPickerValue(_ key: String) -> String {
        switch decodePickerValue(key) {
        case .null: "NULL"
        case let .text(text): text.isEmpty ? "Empty string" : "\u{201C}\(text)\u{201D}"
        case nil: key
        }
    }

    private func updateStatus() {
        guard let metadata else { return }
        let filtered = !activeFilters.isEmpty
        let sorted = activeSort != nil
        var description = "\(totalRowCount.formatted()) row\(totalRowCount == 1 ? "" : "s")"
        if filtered { description += " filtered" }
        if sorted { description += " · sorted" }
        if metadata.totalColumnCount > metadata.columns.count {
            description += " · first \(metadata.columns.count) of \(metadata.totalColumnCount) columns"
        }
        setBusy(false, text: description)
    }

    private func setBusy(_ busy: Bool, text: String) {
        statusLabel.stringValue = text
        statusLabel.toolTip = text
        statusLabel.textColor = .secondaryLabelColor
        if busy { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
        onStatusChange?(text, busy)
    }

    private func report(_ error: Error) {
        setBusy(false, text: error.localizedDescription)
        statusLabel.textColor = .systemRed
        statusLabel.toolTip = error.localizedDescription
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closing = notification.object as? NSPopover, closing === presentedPopover else { return }
        presentedPopover = nil
        presentedFilterController = nil
        presentedFilterColumn = nil
        uniqueValuesTask?.cancel()
        summaryTask?.cancel()
        uniqueValuesTask = nil
        summaryTask = nil
    }

    private func replacePresentedPopover() {
        uniqueValuesTask?.cancel()
        summaryTask?.cancel()
        uniqueValuesTask = nil
        summaryTask = nil
        let old = presentedPopover
        presentedPopover = nil
        presentedFilterController = nil
        presentedFilterColumn = nil
        old?.delegate = nil
        old?.close()
    }

#if LIGHTXT_STANDALONE_PARQUET_QA
    /// Focused hooks for the standalone AppKit runtime harness. They exercise
    /// the production query/popover/header paths without exposing mutable
    /// table operations in the shipping application.
    var qaIsReady: Bool {
        metadata != nil && cachedPages[0] != nil && pageTasks.isEmpty && openTask?.isCancelled != true
    }
    var qaRowCount: Int { tableView.numberOfRows }
    var qaColumnNames: [String] { metadata?.columns.map(\.name) ?? [] }
    var qaCachedPageCount: Int { cachedPages.count }
    var qaPendingPageCount: Int { pageTasks.count }
    var qaCacheAndRequestLimits: (cache: Int, requests: Int) { (Self.maximumCachedPages, 2) }
    var qaStatus: String { statusLabel.stringValue }
    var qaTableAccessibilityLabel: String? { tableView.accessibilityLabel() }
    var qaExpansionAndDetailLimits: (expansions: Int, requests: Int) {
        (Self.maximumExpandedCells, Self.maximumStructuredDetailRequests)
    }
    var qaExpandedCellCount: Int { expandedCells.count }
    var qaPendingStructuredDetailCount: Int { structuredDetailTasks.count }
    func qaPrettyFormattedJSON(_ json: String, sourceWasTruncated: Bool = false) -> (String, Int) {
        let presentation = Self.prettyStructuredJSON(json, sourceWasTruncated: sourceWasTruncated)
        return (presentation.text, presentation.lineCount)
    }

    func qaValue(row: Int, column: Int) -> String? { cachedCell(row: row, column: column)?.value }
    func qaValueIsTruncated(row: Int, column: Int) -> Bool {
        cachedCell(row: row, column: column)?.isTruncated == true
    }

    func qaApplyContainsFilter(column: Int, value: String) { commitContains(value, column: column) }
    func qaClearFilters() { clearFilters(nil) }
    func qaBeginInlineContainsFilter(column: Int) {
        (tableView.headerView as? LighTxtCSVHeaderView)?.qaBeginEditing(dataColumn: column)
    }
    func qaTypeInlineContainsFilter(_ value: String) {
        (tableView.headerView as? LighTxtCSVHeaderView)?.qaType(value)
    }
    func qaCommitInlineContainsFilter() {
        (tableView.headerView as? LighTxtCSVHeaderView)?.qaCommit()
    }
    var qaInlineFilterHasFocus: Bool {
        (tableView.headerView as? LighTxtCSVHeaderView)?.qaHasFocus == true
    }

    func qaShowFilterPopover(column: Int) { showFilter(column: column) }
    func qaTypePopoverContains(_ value: String) {
        presentedFilterController?.qaType(value)
    }
    func qaCommitPopoverContains() { presentedFilterController?.qaCommit() }
    var qaPopoverFilterHasFocus: Bool { presentedFilterController?.qaHasFocus == true }
    var qaPopoverUniqueValueLabels: [String] {
        (presentedFilterController?.qaUniqueValues ?? []).map(Self.displayPickerValue)
    }
    func qaTogglePopoverValue(label: String) {
        guard let key = presentedFilterController?.qaUniqueValues.first(where: {
            Self.displayPickerValue($0) == label
        }) else { return }
        presentedFilterController?.qaToggle(key)
    }
    var qaHasPresentedPopover: Bool { presentedPopover?.isShown == true }
    var qaFilterChipCount: Int {
        filterContainer.subviews.compactMap { $0 as? CSVFilterChipView }.count
    }
    func qaOpenFilterChip(column: Int) {
        filterContainer.subviews.compactMap { $0 as? CSVFilterChipView }
            .first { $0.sourceColumn == column }?.qaOpen()
    }
    func qaClearFilterChip(column: Int) {
        filterContainer.subviews.compactMap { $0 as? CSVFilterChipView }
            .first { $0.sourceColumn == column }?.qaClear()
    }

    func qaCycleHeaderSort(column: Int) {
        guard let tableColumn = tableColumn(dataColumn: column) else { return }
        if activeSort?.column == column, activeSort?.ascending == true {
            activeSort = (column, false)
        } else if activeSort?.column == column, activeSort?.ascending == false {
            activeSort = nil
        } else { activeSort = (column, true) }
        let next = activeSort.map {
            [NSSortDescriptor(key: tableColumn.identifier.rawValue, ascending: $0.ascending)]
        } ?? []
        isSettingSortDescriptors = true
        tableView.sortDescriptors = next
        isSettingSortDescriptors = false
        resetQuery()
    }

    func qaShowColumnSummary(column: Int) { showSummary(column: column) }
    var qaSummaryText: String {
        guard let root = presentedPopover?.contentViewController?.view else { return "" }
        return qaDescendants(of: root, as: NSTextField.self).map(\.stringValue).joined(separator: " | ")
    }

    func qaCopyCell(row: Int, column: Int) {
        let item = NSMenuItem()
        item.representedObject = [row, column]
        copyCell(item)
    }
    func qaCopyRow(_ row: Int) {
        let item = NSMenuItem()
        item.representedObject = row
        copyRow(item)
    }
    func qaBodyMenuTitles(row: Int, visualColumn: Int) -> [String] {
        bodyMenu(column: visualColumn, row: row)?.items.map(\.title) ?? []
    }
    var qaVisibleDataCellsAreReadOnly: Bool {
        guard tableView.numberOfRows > 0 else { return false }
        return tableView.tableColumns.enumerated().compactMap { index, column -> NSTextField? in
            guard dataColumn(column) != nil else { return nil }
            return self.tableView(tableView, viewFor: column, row: 0) as? NSTextField
        }.allSatisfy { !$0.isEditable }
    }
    var qaMaterializedHeaderFilterControlColumns: Set<Int> {
        guard let header = tableView.headerView as? LighTxtCSVHeaderView,
              let metadata else { return [] }
        let visible = header.visibleRect.isEmpty ? header.bounds : header.visibleRect
        return Set(metadata.columns.compactMap { column in
            guard let presentation = header.qaFilterPresentationRects(column: column.index),
                  presentation.input.width > 8,
                  presentation.funnel.width > 8,
                  presentation.input.intersects(visible),
                  presentation.funnel.intersects(visible) else { return nil }
            return column.index
        })
    }
    func qaToggleStructuredCell(row: Int, column: Int) {
        _ = toggleStructuredCell(dataColumn: column, row: row)
    }
    func qaKeyboardToggleStructuredCell(row: Int) {
        tableView.qaPressKeyboardActivation(row: row)
    }
    func qaStructuredCellIsExpanded(row: Int, column: Int) -> Bool {
        guard let ordinal = cachedSourceRowOrdinal(row: row) else { return false }
        return expandedCells.contains(StructuredCellKey(sourceRowOrdinal: ordinal, column: column))
    }
    func qaStructuredCellText(row: Int, column: Int) -> String? {
        if let ordinal = cachedSourceRowOrdinal(row: row),
           let presentation = structuredPresentations[
               StructuredCellKey(sourceRowOrdinal: ordinal, column: column)
           ] {
            return presentation.text
        }
        guard let tableColumn = tableColumn(dataColumn: column),
              let visualColumn = tableView.tableColumns.firstIndex(of: tableColumn) else { return nil }
        return (tableView.view(
            atColumn: visualColumn,
            row: row,
            makeIfNecessary: true
        ) as? ParquetStructuredCellView)?.qaText
    }
    func qaToggleStructuredDisclosure(row: Int, column: Int) {
        guard let tableColumn = tableColumn(dataColumn: column),
              let visualColumn = tableView.tableColumns.firstIndex(of: tableColumn) else { return }
        (tableView.view(
            atColumn: visualColumn,
            row: row,
            makeIfNecessary: true
        ) as? ParquetStructuredCellView)?.qaToggle()
    }
    func qaStructuredDisclosureAccessibilityLabel(row: Int, column: Int) -> String? {
        guard let tableColumn = tableColumn(dataColumn: column),
              let visualColumn = tableView.tableColumns.firstIndex(of: tableColumn) else { return nil }
        return (tableView.view(
            atColumn: visualColumn,
            row: row,
            makeIfNecessary: true
        ) as? ParquetStructuredCellView)?.qaDisclosureAccessibilityLabel
    }
    func qaStructuredDisclosureIsVisible(row: Int, column: Int) -> Bool {
        guard let tableColumn = tableColumn(dataColumn: column),
              let visualColumn = tableView.tableColumns.firstIndex(of: tableColumn) else { return false }
        return (tableView.view(
            atColumn: visualColumn,
            row: row,
            makeIfNecessary: true
        ) as? ParquetStructuredCellView)?.qaDisclosureIsVisible == true
    }
    func qaStructuredCellIsReadOnly(row: Int, column: Int) -> Bool {
        guard let tableColumn = tableColumn(dataColumn: column),
              let visualColumn = tableView.tableColumns.firstIndex(of: tableColumn) else { return false }
        return (tableView.view(
            atColumn: visualColumn,
            row: row,
            makeIfNecessary: true
        ) as? ParquetStructuredCellView)?.qaValueIsReadOnly == true
    }
    func qaRowHeight(_ row: Int) -> CGFloat { tableView(tableView, heightOfRow: row) }
    var qaStructuredCellReuseResetIsClean: Bool {
        let view = ParquetStructuredCellView()
        view.configure(
            compactText: "{'value': [1, 2]}",
            compactWasTruncated: false,
            expanded: true,
            expandedText: "{\n  \"value\": [\n    1,\n    2\n  ]\n}",
            expandedSourceWasTruncated: false,
            expandedDisplayWasTruncated: false,
            detailError: nil,
            isLoadingDetail: false,
            row: 0,
            columnTitle: "nested",
            onToggle: {}
        )
        guard view.qaIsExpanded, view.qaMaximumNumberOfLines == 0 else { return false }
        view.configure(
            compactText: nil,
            compactWasTruncated: false,
            expanded: false,
            expandedText: nil,
            expandedSourceWasTruncated: false,
            expandedDisplayWasTruncated: false,
            detailError: nil,
            isLoadingDetail: false,
            row: 1,
            columnTitle: "nested",
            onToggle: {}
        )
        return !view.qaIsExpanded
            && !view.qaDisclosureIsVisible
            && view.qaMaximumNumberOfLines == 1
            && view.qaText == "NULL"
            && view.qaValueIsReadOnly
            && view.accessibilityLabel()?.contains("NULL") == true
    }
    func qaPrepareForCapture() {
        let width = max(scrollView.contentSize.width, tableView.tableColumns.reduce(0) { $0 + $1.width })
        let rowContentHeight = (0..<tableView.numberOfRows).reduce(CGFloat.zero) { total, row in
            total + self.tableView(tableView, heightOfRow: row) + tableView.intercellSpacing.height
        }
        let height = max(scrollView.contentSize.height, max(Self.collapsedRowHeight, rowContentHeight))
        tableView.frame = NSRect(origin: .zero, size: NSSize(width: width, height: height))
        tableView.reloadData()
        tableView.layoutSubtreeIfNeeded()
        for row in 0..<min(12, tableView.numberOfRows) {
            _ = tableView.rowView(atRow: row, makeIfNecessary: true)
            for column in tableView.tableColumns.indices {
                _ = tableView.view(atColumn: column, row: row, makeIfNecessary: true)
            }
        }
        tableView.needsDisplay = true
        scrollView.contentView.needsDisplay = true
        scrollView.layoutSubtreeIfNeeded()
    }

    func qaMoveDataColumn(_ column: Int, toVisualIndex destination: Int) {
        guard let source = tableView.tableColumns.firstIndex(where: { dataColumn($0) == column }),
              tableView.tableColumns.indices.contains(destination) else { return }
        tableView.moveColumn(source, toColumn: destination)
    }
    func qaResizeDataColumn(_ column: Int, width: CGFloat) {
        tableColumn(dataColumn: column)?.width = width
    }
    func qaScrollDataColumnToVisible(_ column: Int) {
        guard let index = tableView.tableColumns.firstIndex(where: { dataColumn($0) == column }) else { return }
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
        if let headerClip = tableView.headerView?.superview as? NSClipView {
            headerClip.scroll(to: NSPoint(x: clipView.bounds.minX, y: headerClip.bounds.minY))
        }
    }
    var qaAccessibleFilterButtonColumns: Set<Int> {
        guard let header = tableView.headerView as? LighTxtCSVHeaderView else { return [] }
        header.qaSynchronizeFilterButtons()
        return header.qaFilterButtonColumns
    }
    func qaHeaderRows(column: Int) -> (header: NSRect, title: NSRect, filter: NSRect)? {
        guard let header = tableView.headerView as? LighTxtCSVHeaderView,
              let index = tableView.tableColumns.firstIndex(where: { dataColumn($0) == column }),
              let cell = tableView.tableColumns[index].headerCell as? LighTxtCSVHeaderCell else { return nil }
        header.qaSynchronizeFilterButtons()
        let frame = header.headerRect(ofColumn: index)
        return (
            frame,
            cell.titleRect(in: frame, controlView: header),
            cell.filterControlRect(in: frame, controlView: header)
        )
    }

    private func qaDescendants<T: NSView>(of root: NSView, as type: T.Type) -> [T] {
        var output: [T] = root is T ? [root as! T] : []
        for child in root.subviews { output.append(contentsOf: qaDescendants(of: child, as: type)) }
        return output
    }
#endif
}

@MainActor
private final class ParquetReadOnlyTableView: NSTableView {
    var bodyMenuProvider: ((Int, Int) -> NSMenu?)?
    var activateProvider: ((Int, Int) -> Bool)?
    private var lastFocusedColumn = -1

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let column = self.column(at: point)
        if column >= 0 { lastFocusedColumn = column }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let disallowedModifiers: NSEvent.ModifierFlags = [.command, .control, .option]
        let character = event.charactersIgnoringModifiers ?? ""
        let activates = character == " " || character == "\r" || character == "\n"
        let column = selectedColumn >= 0 ? selectedColumn : lastFocusedColumn
        if activates,
           event.modifierFlags.intersection(disallowedModifiers).isEmpty,
           selectedRow >= 0,
           activateProvider?(column, selectedRow) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return bodyMenuProvider?(column(at: point), row(at: point))
    }

#if LIGHTXT_STANDALONE_PARQUET_QA
    func qaPressKeyboardActivation(row: Int) {
        lastFocusedColumn = -1
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ) else { return }
        keyDown(with: event)
    }
#endif
}

@MainActor
private final class ParquetStructuredCellView: NSTableCellView {
    private let disclosureButton = NSButton()
    private let valueField = NSTextField(labelWithString: "")
    private var onToggle: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        disclosureButton.title = ""
        disclosureButton.imagePosition = .imageOnly
        disclosureButton.isBordered = false
        disclosureButton.focusRingType = .default
        disclosureButton.target = self
        disclosureButton.action = #selector(toggle(_:))
        disclosureButton.translatesAutoresizingMaskIntoConstraints = false

        valueField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        valueField.isEditable = false
        valueField.isSelectable = true
        valueField.isBordered = false
        valueField.drawsBackground = false
        valueField.translatesAutoresizingMaskIntoConstraints = false
        valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(disclosureButton)
        addSubview(valueField)
        textField = valueField
        NSLayoutConstraint.activate([
            disclosureButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
            disclosureButton.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            disclosureButton.widthAnchor.constraint(equalToConstant: 20),
            disclosureButton.heightAnchor.constraint(equalToConstant: 20),
            valueField.leadingAnchor.constraint(equalTo: disclosureButton.trailingAnchor, constant: 1),
            valueField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            valueField.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            valueField.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configureLoading(columnTitle: String) {
        onToggle = nil
        disclosureButton.isHidden = true
        disclosureButton.isEnabled = false
        disclosureButton.image = nil
        disclosureButton.toolTip = nil
        disclosureButton.setAccessibilityLabel("Structured value loading")
        disclosureButton.setAccessibilityHelp(nil)
        valueField.stringValue = ""
        valueField.placeholderString = "Loading…"
        valueField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        valueField.textColor = .secondaryLabelColor
        valueField.maximumNumberOfLines = 1
        valueField.lineBreakMode = .byTruncatingTail
        valueField.toolTip = nil
        setAccessibilityLabel("Loading structured value for \(columnTitle)")
        setAccessibilityHelp(nil)
    }

    func configure(
        compactText: String?,
        compactWasTruncated: Bool,
        expanded: Bool,
        expandedText: String?,
        expandedSourceWasTruncated: Bool,
        expandedDisplayWasTruncated: Bool,
        detailError: String?,
        isLoadingDetail: Bool,
        row: Int,
        columnTitle: String,
        onToggle: @escaping () -> Void
    ) {
        valueField.placeholderString = nil
        valueField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        valueField.textColor = .labelColor
        valueField.lineBreakMode = .byTruncatingTail
        valueField.maximumNumberOfLines = expanded ? 0 : 1

        guard let compactText else {
            self.onToggle = nil
            disclosureButton.isHidden = true
            disclosureButton.isEnabled = false
            disclosureButton.image = nil
            disclosureButton.toolTip = nil
            disclosureButton.setAccessibilityLabel("No structured value in \(columnTitle), row \(row + 1)")
            disclosureButton.setAccessibilityHelp(nil)
            valueField.stringValue = "NULL"
            valueField.font = .monospacedSystemFont(ofSize: 12, weight: .regular).italic()
            valueField.textColor = .tertiaryLabelColor
            valueField.toolTip = "Parquet NULL"
            valueField.setAccessibilityLabel("\(columnTitle), row \(row + 1): NULL")
            setAccessibilityLabel("\(columnTitle), row \(row + 1): NULL")
            setAccessibilityHelp(nil)
            return
        }

        self.onToggle = onToggle
        disclosureButton.isHidden = false
        disclosureButton.isEnabled = true
        disclosureButton.image = NSImage(
            systemSymbolName: expanded ? "chevron.down" : "chevron.right",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        disclosureButton.contentTintColor = .secondaryLabelColor
        let action = expanded ? "Collapse" : "Expand"
        disclosureButton.toolTip = "\(action) structured value"
        disclosureButton.setAccessibilityLabel("\(action) structured value in \(columnTitle), row \(row + 1)")
        disclosureButton.setAccessibilityHelp("Press Space to \(action.lowercased()) the read-only value")

        if expanded {
            if let detailError {
                valueField.stringValue = "Couldn’t expand structured value\n\(detailError)"
                valueField.textColor = .systemRed
            } else if let expandedText {
                valueField.stringValue = expandedText
            } else {
                valueField.stringValue = isLoadingDetail
                    ? "Loading structured value…"
                    : "Structured value unavailable"
                valueField.textColor = .secondaryLabelColor
            }
            var tooltip = expandedText ?? detailError ?? "Loading structured value…"
            if expandedSourceWasTruncated { tooltip += "\nSource detail was shortened." }
            if expandedDisplayWasTruncated { tooltip += "\nVisible formatting was bounded." }
            valueField.toolTip = tooltip
            valueField.setAccessibilityLabel("\(columnTitle), row \(row + 1), structured value expanded")
            setAccessibilityLabel("\(columnTitle), row \(row + 1), structured value expanded")
            setAccessibilityHelp("Read-only structured content. Use the disclosure button, Return, or Space to collapse.")
        } else {
            valueField.stringValue = compactText
            valueField.toolTip = compactWasTruncated
                ? "Value shortened for the bounded table preview; expand for more detail"
                : compactText
            valueField.setAccessibilityLabel("\(columnTitle), row \(row + 1), structured value collapsed")
            setAccessibilityLabel("\(columnTitle), row \(row + 1), structured value collapsed")
            setAccessibilityHelp("Use the disclosure button, double-click, Return, or Space to expand read-only content.")
        }
    }

    @objc private func toggle(_ sender: Any?) { onToggle?() }

#if LIGHTXT_STANDALONE_PARQUET_QA
    var qaIsExpanded: Bool {
        disclosureButton.accessibilityLabel()?.hasPrefix("Collapse") == true
    }
    var qaDisclosureIsVisible: Bool { !disclosureButton.isHidden && disclosureButton.isEnabled }
    var qaText: String { valueField.stringValue }
    var qaValueIsReadOnly: Bool { !valueField.isEditable && valueField.isSelectable }
    var qaMaximumNumberOfLines: Int { valueField.maximumNumberOfLines }
    var qaDisclosureAccessibilityLabel: String? { disclosureButton.accessibilityLabel() }
    func qaToggle() { onToggle?() }
#endif
}

private extension NSFont {
    func italic() -> NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: .italicFontMask)
    }
}
