import AppKit

/// A virtual NSTableView backed directly by a sparse CSV byte index. AppKit
/// creates views only for visible rows; the index stores a hard-capped set of
/// offsets, and individual cells commit exact byte-range piece-table edits.
@MainActor
final class CSVTableView: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSEditor {
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
            if oldValue !== editorDelegate { reloadDocument() }
        }
    }
    var onStatusChange: ((String, Bool) -> Void)?
    var onEditingRegistrationChange: ((Bool) -> Void)?

    private let controls = NSView()
    private let headerCheckbox = NSButton(checkboxWithTitle: "First row is header", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "Preparing table…")
    private let progressIndicator = NSProgressIndicator()
    private let scrollView = NSScrollView()
    private let tableView = NSTableView()

    private var snapshot: DocumentSnapshot?
    private var rowIndex: CSVRowIndex?
    private var latestProgress: CSVRowIndex.Progress?
    private var indexingCancellation: CancellationToken?
    private var generation: UInt64 = 0
    private var firstRowIsHeader = false
    private var headerDetectionCompleted = false
    private var columnCount = 0
    private var cachedRecords: [Int64: CSVParsedRecord] = [:]
    private var cacheOrder: [Int64] = []
    private var pendingPages: Set<Int64> = []
    private var lastReportedError: String?
    private var pendingScrollTarget: (record: Int64, column: Int)?
    private var suppressNextControllerReload = false
    private var pendingCommitFailed = false
    private weak var activeEditingField: CSVEditableTextField?
    private var isEditingRegistered = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureControls()
        configureTable()
        configureLayout()
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { indexingCancellation?.cancel() }

    func reloadDocument() {
        generation &+= 1
        let currentGeneration = generation
        indexingCancellation?.cancel()
        let cancellation = CancellationToken()
        indexingCancellation = cancellation
        cachedRecords.removeAll(keepingCapacity: true)
        cacheOrder.removeAll(keepingCapacity: true)
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
        rowIndex = nil
        snapshot = nil
        latestProgress = nil
        cachedRecords.removeAll(keepingCapacity: false)
        cacheOrder.removeAll(keepingCapacity: false)
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
        firstRowIsHeader = enabled
        headerCheckbox.state = enabled ? .on : .off
        configureColumnsFromAvailableRecords()
        tableView.reloadData()
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

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.maximumNumberOfLines = 1

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
        tableView.headerView = LighTxtCSVHeaderView()
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
        [headerCheckbox, statusLabel, progressIndicator].forEach {
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
            statusLabel.leadingAnchor.constraint(equalTo: headerCheckbox.trailingAnchor, constant: 18),
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
    }

    private func configureColumnsFromAvailableRecords() {
        let sample = cacheOrder.sorted().prefix(Self.sampledRowsForColumns).compactMap { cachedRecords[$0] }
        configureColumns(sample: sample)
    }

    private func configureColumns<S: Sequence>(sample: S) where S.Element == CSVParsedRecord {
        let records = Array(sample)
        let detectedCount = records.map(\.fields.count).max() ?? 0
        let desired = min(Self.maximumPresentedColumns, detectedCount)
        guard desired != columnCount || tableView.tableColumns.count != desired + 1 else {
            updateColumnTitles(from: records.first)
            return
        }

        removeDataColumns()
        columnCount = desired
        let header = records.first
        for column in 0..<desired {
            let tableColumn = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier("csv-column-\(column)")
            )
            tableColumn.title = columnTitle(column, header: header)
            tableColumn.headerCell = LighTxtCSVHeaderCell(textCell: tableColumn.title)
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
        let record = Int64(row) + (firstRowIsHeader ? 1 : 0)
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
            cell.isEditable = true
            cell.originalFieldCount = parsed.fields.count
            if let field = parsed.fields[safe: column] {
                cell.stringValue = field.value
                cell.originalValue = field.value
                cell.byteRange = field.byteRange
                cell.isEditable = !field.wasTruncated
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

    private func recordForDisplay(_ record: Int64) -> CSVParsedRecord? {
        if let cached = cachedRecords[record] {
            touchCache(record)
            return cached
        }
        guard let snapshot, let rowIndex, let indexingCancellation else { return nil }
        let pageStart = (record / Self.recordPageSize) * Self.recordPageSize
        schedulePageDecode(
            pageStart: pageStart,
            snapshot: snapshot,
            rowIndex: rowIndex,
            generation: generation,
            cancellation: indexingCancellation
        )
        return nil
    }

    private func schedulePageDecode(
        pageStart: Int64,
        snapshot: DocumentSnapshot,
        rowIndex: CSVRowIndex,
        generation: UInt64,
        cancellation: CancellationToken
    ) {
        guard pendingPages.insert(pageStart).inserted else { return }
        let limits = Self.presentationParseLimits
        let pageSize = Int(Self.recordPageSize)
        Self.pageDecodingQueue.async { [weak self] in
            do {
                let locations = try rowIndex.recordLocations(
                    startingAt: pageStart,
                    limit: pageSize,
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
                    self.pendingPages.remove(pageStart)
                    guard self.generation == generation else { return }
                    for (row, parsed) in parsedPage { self.storeCached(parsed, for: row) }
                    self.reloadVisibleRows(inPageStartingAt: pageStart)
                }
            } catch is CancellationError {
                return
            } catch CSVRowIndex.IndexError.cancelled {
                return
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.pendingPages.remove(pageStart)
                    guard self.generation == generation else { return }
                    self.reportOnce(error)
                }
            }
        }
    }

    private func reloadVisibleRows(inPageStartingAt pageStart: Int64) {
        let headerOffset: Int64 = firstRowIsHeader ? 1 : 0
        let firstVisible = max(0, pageStart - headerOffset)
        let lastVisible = min(
            Int64(numberOfRows(in: tableView)),
            pageStart + Self.recordPageSize - headerOffset
        )
        guard firstVisible < lastVisible else { return }
        let rows = IndexSet(integersIn: Int(firstVisible)..<Int(lastVisible))
        let columns = IndexSet(integersIn: 1..<tableView.tableColumns.count)
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
            pendingScrollTarget = (field.record, field.column)
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
            snapshot: snapshot,
            rowIndex: index,
            generation: currentGeneration,
            cancellation: cancellation
        )
        restorePendingScrollIfPossible()
    }

    @objc private func headerSettingChanged(_ sender: NSButton) {
        setFirstRowIsHeader(sender.state == .on)
    }

    private func setBusy(_ busy: Bool, text: String) {
        statusLabel.stringValue = text
        progressIndicator.doubleValue = latestProgress?.fractionCompleted ?? (busy ? 0 : 1)
        progressIndicator.isHidden = !busy
        onStatusChange?(text, busy)
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
        let visibleRow = pendingScrollTarget.record - (firstRowIsHeader ? 1 : 0)
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
    var record: Int64 = 0
    var column = 0
    var byteRange: Range<Int64>?
    var originalValue = ""
    var originalFieldCount = 0
}

/// NSTableHeaderCell's cached attributed title can retain its light-mode
/// foreground after a window changes appearance. Drawing only the title here
/// preserves AppKit's native header surface while guaranteeing readable text
/// in both appearances.
private final class LighTxtCSVHeaderCell: NSTableHeaderCell {
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
        let titleFrame = cellFrame.insetBy(dx: 4, dy: 0)
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
    }
}

/// The standard header opts into vibrancy. That is attractive over window
/// materials, but our opaque editor surface has no material backdrop and dark
/// vibrancy can suppress custom header titles almost completely. A non-vibrant
/// header keeps native resizing/dragging while drawing predictable contrast.
private final class LighTxtCSVHeaderView: NSTableHeaderView {
    override var allowsVibrancy: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
