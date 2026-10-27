import Darwin
import Foundation

/// Errors from the explicit, opt-in CSV resident-query path. DuckDB's original
/// diagnostic is retained in load/query failures so the UI can present a useful
/// failure instead of leaving the table in an indeterminate loading state.
public nonisolated enum CSVInMemoryQueryError: Error, LocalizedError, Equatable {
    case runtimeUnavailable(String)
    case incompatibleRuntime(expected: String, actual: String)
    case invalidConfiguration(String)
    case invalidColumn(Int)
    case invalidPage(offset: Int64, limit: Int)
    case invalidFilter(String)
    case sourceChanged
    case loadFailed(String)
    case queryFailed(String)
    case cancelled
    case closed

    public var errorDescription: String? {
        switch self {
        case let .runtimeUnavailable(reason):
            return "The built-in CSV query engine could not be loaded. \(reason)"
        case let .incompatibleRuntime(expected, actual):
            return "The built-in CSV query engine is version \(actual); LighTxt requires \(expected)."
        case let .invalidConfiguration(reason):
            return "The CSV cannot be loaded into memory. \(reason)"
        case let .invalidColumn(column):
            return "CSV column \(column + 1) is outside the available schema."
        case let .invalidPage(offset, limit):
            return "The CSV page request is invalid (offset \(offset), limit \(limit))."
        case let .invalidFilter(reason):
            return "The CSV filter is invalid. \(reason)"
        case .sourceChanged:
            return "The CSV changed on disk while it was being loaded. Reload it and try again."
        case let .loadFailed(reason):
            return "The CSV could not be loaded into memory. \(reason)"
        case let .queryFailed(reason):
            return "The in-memory CSV query failed. \(reason)"
        case .cancelled:
            return "The CSV operation was cancelled."
        case .closed:
            return "This in-memory CSV table is no longer open."
        }
    }
}

/// The exact CSV dialect and presentation schema selected in the file-backed
/// viewer. Column names are display metadata; fixed private aliases are used in
/// SQL, so duplicate, empty, or quoted headers remain safe.
public nonisolated struct CSVInMemoryConfiguration: Sendable, Equatable {
    public let columnNames: [String]
    public let delimiter: UInt8
    public let firstRowIsHeader: Bool

    public init(
        columnNames: [String],
        delimiter: UInt8 = DelimitedTextDelimiter.comma.rawValue,
        firstRowIsHeader: Bool = false
    ) {
        self.columnNames = columnNames
        self.delimiter = delimiter
        self.firstRowIsHeader = firstRowIsHeader
    }

    public init(
        columnNames: [String],
        delimiter: DelimitedTextDelimiter,
        firstRowIsHeader: Bool = false
    ) {
        self.init(
            columnNames: columnNames,
            delimiter: delimiter.rawValue,
            firstRowIsHeader: firstRowIsHeader
        )
    }
}

/// An explicitly resident CSV table. Loading materializes every CSV value as a
/// VARCHAR in DuckDB's in-memory database. Subsequent paging, filtering, sorts,
/// facets, and summaries therefore do not rescan the source file.
///
/// The service intentionally does not set DuckDB's `threads`, `memory_limit`,
/// `max_memory`, temporary-storage, or buffer settings. DuckDB chooses its own
/// thread count and memory policy. Limits here bound only data returned to the
/// UI and never constrain query execution resources.
public actor CSVInMemoryQueryService: TabularQueryService {
    public struct Limits: Sendable, Equatable {
        public let maximumPresentedColumns: Int
        public let maximumPageRows: Int
        public let maximumCellCharacters: Int
        public let maximumPageCharacters: Int
        public let maximumUniqueValues: Int
        public let maximumSelectedValuesPerColumn: Int
        public let maximumFilterValueCharacters: Int

        public init(
            maximumPresentedColumns: Int = 512,
            maximumPageRows: Int = 128,
            maximumCellCharacters: Int = 65_536,
            maximumPageCharacters: Int = 16_777_216,
            maximumUniqueValues: Int = 500,
            maximumSelectedValuesPerColumn: Int = 5_000,
            maximumFilterValueCharacters: Int = 1_048_576
        ) {
            self.maximumPresentedColumns = min(1_024, max(1, maximumPresentedColumns))
            self.maximumPageRows = min(512, max(1, maximumPageRows))
            self.maximumCellCharacters = min(1_048_576, max(64, maximumCellCharacters))
            self.maximumPageCharacters = max(
                self.maximumPresentedColumns * self.maximumPageRows,
                min(64 << 20, maximumPageCharacters)
            )
            self.maximumUniqueValues = min(5_000, max(1, maximumUniqueValues))
            self.maximumSelectedValuesPerColumn = min(
                5_000,
                max(1, maximumSelectedValuesPerColumn)
            )
            self.maximumFilterValueCharacters = min(
                1_048_576,
                max(64, maximumFilterValueCharacters)
            )
        }

        public static let `default` = Limits()
    }

    /// Only safety/extension controls are supplied when opening DuckDB. This is
    /// internal so regression tests can prevent a resource cap from returning.
    static let databaseOptions: [(String, String)] = [
        ("autoload_known_extensions", "false"),
        ("autoinstall_known_extensions", "false"),
        ("allow_community_extensions", "false"),
        ("allow_unsigned_extensions", "false"),
        ("enable_external_access", "true"),
    ]

    public nonisolated let sourceFileState: ExternalFileState

    private let configuration: CSVInMemoryConfiguration
    private let limits: Limits
    private let pinnedSource: PinnedCSVInMemorySource
    private let securityScope: SecurityScopedAccess
    private let runtime: DuckDBDynamicAPI
    private let connectionStorage: DuckDBConnectionStorage
    private let interruptHandle: ParquetInterruptHandle
    private let queryExecutor = CSVInMemorySerialExecutor()
    private var metadataStorage: ParquetMetadata?
    private var openingTask: Task<ParquetMetadata, Error>?
    private var countCache: [ParquetTableQuery: Int64] = [:]
    #if LIGHTXT_PACKAGE_TESTING
    private var testingExecutedSQL: [String] = []
    #endif
    private var isClosed = false

    public init(
        url: URL,
        configuration: CSVInMemoryConfiguration,
        limits: Limits = .default,
        libraryURL: URL? = nil
    ) throws {
        try Self.validate(configuration: configuration)
        let standardized = url.standardizedFileURL
        let securityScope = SecurityScopedAccess(url: standardized)
        var openedSource: PinnedCSVInMemorySource?
        do {
            let pinnedSource = try PinnedCSVInMemorySource(url: standardized)
            openedSource = pinnedSource
            let runtime: DuckDBDynamicAPI
            do {
                runtime = try DuckDBDynamicAPI(libraryURL: libraryURL)
            } catch {
                throw Self.mapRuntimeError(error, loading: true)
            }
            self.configuration = configuration
            self.limits = limits
            self.pinnedSource = pinnedSource
            self.sourceFileState = pinnedSource.externalFileState
            self.securityScope = securityScope
            self.runtime = runtime
            self.connectionStorage = DuckDBConnectionStorage(runtime: runtime)
            self.interruptHandle = ParquetInterruptHandle(runtime: runtime)
        } catch {
            openedSource?.close()
            securityScope.stop()
            throw error
        }
    }

    deinit {
        pinnedSource.close()
        securityScope.stop()
    }

    /// Loads the source exactly once. Concurrent callers share the same load;
    /// cancelling any active owner interrupts DuckDB rather than allowing a
    /// partially materialized table to be published.
    public func open() async throws -> ParquetMetadata {
        if let metadataStorage { return metadataStorage }
        try ensureOpen()
        if let openingTask {
            return try await awaitOpeningTask(openingTask)
        }
        let task = Task { try await self.performOpen() }
        openingTask = task
        do {
            let metadata = try await awaitOpeningTask(task)
            openingTask = nil
            return metadata
        } catch {
            openingTask = nil
            if metadataStorage == nil { finishAfterFailedOpen() }
            throw Self.mapRuntimeError(error, loading: true)
        }
    }

    public func page(
        offset: Int64,
        limit: Int,
        query: ParquetTableQuery = ParquetTableQuery()
    ) async throws -> ParquetPage {
        let metadata = try await open()
        guard offset >= 0, limit > 0, limit <= limits.maximumPageRows else {
            throw CSVInMemoryQueryError.invalidPage(offset: offset, limit: limit)
        }
        try validate(query: query, columns: metadata.columns)

        let countKey = ParquetTableQuery(filters: query.filters)
        let total: Int64
        if let cachedTotal = countCache[countKey] {
            total = cachedTotal
        } else {
            total = try await countRows(query: countKey)
            storeCount(total, for: countKey)
        }
        if offset >= total {
            return ParquetPage(
                offset: offset,
                totalRowCount: total,
                sourceRowOrdinals: [],
                rows: []
            )
        }

        let columns = metadata.columns
        let boundedLimit = min(limit, limits.maximumPageRows)
        let cellBudgetDivisor = max(1, boundedLimit * max(1, columns.count))
        let cellCharacterLimit = min(
            limits.maximumCellCharacters,
            max(0, (limits.maximumPageCharacters / cellBudgetDivisor) - 1)
        )
        let values = columns.map {
            displayProjection(column: $0, characterLimit: cellCharacterLimit)
        }.joined(separator: ", ")
        let rowIdentifier = Self.rowIdentifier
        let projection = "\(rowIdentifier)::BIGINT AS \(Self.quoteIdentifier("__lightxt_result_row")), \(values)"
        var bindings: [DuckDBBinding] = []
        let whereClause = buildWhereClause(
            query.filters,
            columns: columns,
            bindings: &bindings
        )
        let orderClause = buildOrderClause(query.sort, columns: columns)
        let sql: String
        if query.filters.isEmpty && query.sort == nil {
            bindings.append(.int64(offset))
            bindings.append(.int64(Int64(boundedLimit)))
            sql = """
                SELECT \(projection)
                \(Self.sourceClause)
                WHERE \(rowIdentifier) >= ?
                ORDER BY \(rowIdentifier) ASC
                LIMIT ?
                """
        } else {
            bindings.append(.int64(Int64(boundedLimit)))
            bindings.append(.int64(offset))
            sql = """
                SELECT \(projection)
                \(Self.sourceClause)
                \(whereClause)
                \(orderClause)
                LIMIT ? OFFSET ?
                """
        }
        let result = try await execute(sql: sql, bindings: bindings)
        var rows: [[ParquetCell]] = []
        var ordinals: [Int64] = []
        rows.reserveCapacity(result.rowCount)
        ordinals.reserveCapacity(result.rowCount)
        for row in 0..<result.rowCount {
            guard let ordinal = result.int64(column: 0, row: row) else {
                throw CSVInMemoryQueryError.queryFailed("A resident row had no stable source position.")
            }
            ordinals.append(ordinal)
            var cells: [ParquetCell] = []
            cells.reserveCapacity(columns.count)
            for column in columns.indices {
                let valueColumn = 1 + column * 2
                let truncationColumn = valueColumn + 1
                let value = result.hexDecodedString(column: valueColumn, row: row)
                let truncated = (result.int64(column: truncationColumn, row: row) ?? 0) != 0
                cells.append(ParquetCell(
                    value: truncated ? (value ?? "") + "…" : value,
                    isTruncated: truncated
                ))
            }
            rows.append(cells)
        }
        return ParquetPage(
            offset: offset,
            totalRowCount: total,
            sourceRowOrdinals: ordinals,
            rows: rows
        )
    }

    public func uniqueValues(
        forColumn columnIndex: Int,
        query: ParquetTableQuery = ParquetTableQuery(),
        searchText: String = "",
        searchIsCaseSensitive: Bool = false,
        offset: Int64 = 0,
        limit requestedLimit: Int? = nil
    ) async throws -> ParquetUniqueValues {
        let metadata = try await open()
        guard metadata.columns.indices.contains(columnIndex) else {
            throw CSVInMemoryQueryError.invalidColumn(columnIndex)
        }
        let limit = requestedLimit ?? limits.maximumUniqueValues
        guard offset >= 0, limit > 0, limit <= limits.maximumUniqueValues else {
            throw CSVInMemoryQueryError.invalidPage(offset: offset, limit: limit)
        }
        guard searchText.utf8.count <= limits.maximumFilterValueCharacters else {
            throw CSVInMemoryQueryError.invalidFilter("Unique-value search text is too large.")
        }
        let remainingFilters = query.filters.filter { $0.column != columnIndex }
        try validate(query: .init(filters: remainingFilters), columns: metadata.columns)
        return try await queryUniqueValues(
            forColumn: columnIndex,
            filters: remainingFilters,
            columns: metadata.columns,
            searchText: searchText,
            searchIsCaseSensitive: searchIsCaseSensitive,
            offset: offset,
            limit: limit
        )
    }

    public func structuredCellDetail(
        sourceRowOrdinal: Int64,
        column columnIndex: Int
    ) async throws -> ParquetStructuredCellDetail {
        let metadata = try await open()
        guard sourceRowOrdinal >= 0 else {
            throw CSVInMemoryQueryError.queryFailed("The resident CSV row is invalid.")
        }
        guard metadata.columns.indices.contains(columnIndex) else {
            throw CSVInMemoryQueryError.invalidColumn(columnIndex)
        }
        throw CSVInMemoryQueryError.queryFailed(
            "CSV values are plain text and do not have a structured detail view."
        )
    }

    public func cellDetail(
        sourceRowOrdinal: Int64,
        column columnIndex: Int
    ) async throws -> TabularCellDetail {
        let metadata = try await open()
        guard sourceRowOrdinal >= 0 else {
            throw CSVInMemoryQueryError.queryFailed("The resident CSV row is invalid.")
        }
        guard metadata.columns.indices.contains(columnIndex) else {
            throw CSVInMemoryQueryError.invalidColumn(columnIndex)
        }
        let value = "TRY_CAST(\(internalIdentifier(for: columnIndex)) AS VARCHAR)"
        let limit = ParquetQueryService.Limits.maximumStructuredDetailCharacters
        let result = try await execute(
            sql: """
                SELECT hex(encode(left(\(value), \(limit)))) AS cell_value,
                       CASE WHEN length(\(value)) > \(limit) THEN 1::BIGINT ELSE 0::BIGINT END
                \(Self.sourceClause)
                WHERE \(Self.rowIdentifier) = ?
                LIMIT 1
                """,
            bindings: [.int64(sourceRowOrdinal)]
        )
        guard result.rowCount == 1 else {
            throw CSVInMemoryQueryError.queryFailed("The resident CSV row is no longer available.")
        }
        return TabularCellDetail(
            value: result.hexDecodedString(column: 0, row: 0),
            isTruncated: (result.int64(column: 1, row: 0) ?? 0) != 0
        )
    }

    public func columnSummary(
        forColumn columnIndex: Int,
        query: ParquetTableQuery = ParquetTableQuery()
    ) async throws -> ParquetColumnSummary {
        let metadata = try await open()
        guard metadata.columns.indices.contains(columnIndex) else {
            throw CSVInMemoryQueryError.invalidColumn(columnIndex)
        }
        try validate(query: query, columns: metadata.columns)
        let column = metadata.columns[columnIndex]
        let identifier = internalIdentifier(for: columnIndex)
        let text = "TRY_CAST(\(identifier) AS VARCHAR)"
        var bindings: [DuckDBBinding] = []
        let whereClause = buildWhereClause(
            query.filters,
            columns: metadata.columns,
            bindings: &bindings
        )
        let sql = """
            SELECT COUNT(*)::BIGINT AS row_count,
                   COUNT(*) FILTER (WHERE \(identifier) IS NULL)::BIGINT AS null_count,
                   COALESCE(approx_count_distinct(\(text)), 0)::BIGINT AS distinct_count,
                   hex(encode(left(MIN(\(text)), \(limits.maximumCellCharacters)))) AS minimum,
                   hex(encode(left(MAX(\(text)), \(limits.maximumCellCharacters)))) AS maximum
            \(Self.sourceClause)
            \(whereClause)
            """
        let result = try await execute(sql: sql, bindings: bindings)
        let unique = try await queryUniqueValues(
            forColumn: columnIndex,
            filters: query.filters,
            columns: metadata.columns,
            limit: min(5, limits.maximumUniqueValues)
        )
        return ParquetColumnSummary(
            column: column,
            rowCount: result.int64(column: 0, row: 0) ?? 0,
            nullCount: result.int64(column: 1, row: 0) ?? 0,
            approximateDistinctCount: result.int64(column: 2, row: 0) ?? 0,
            minimum: result.hexDecodedString(column: 3, row: 0),
            maximum: result.hexDecodedString(column: 4, row: 0),
            frequentValues: unique.values.prefix(5).map {
                ParquetFrequentValue(value: $0.value, count: $0.count)
            }
        )
    }

    public func invalidateQueryCaches() {
        countCache.removeAll(keepingCapacity: true)
        if let metadataStorage {
            countCache[ParquetTableQuery()] = metadataStorage.rowCount
        }
    }

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        openingTask?.cancel()
        openingTask = nil
        interruptHandle.interrupt()
        await queryExecutor.runWithoutThrowing { [connectionStorage, interruptHandle] in
            interruptHandle.setConnection(nil)
            connectionStorage.close()
        }
        metadataStorage = nil
        countCache.removeAll(keepingCapacity: false)
        pinnedSource.close()
        securityScope.stop()
    }

    public nonisolated func cancelCurrentQuery() {
        interruptHandle.interrupt()
    }

    #if DEBUG || LIGHTXT_PACKAGE_TESTING
    struct TestingResourceSettings: Sendable, Equatable {
        let threads: Int64
        let memoryLimit: String
    }

    func testingResourceSettings() async throws -> TestingResourceSettings {
        _ = try await open()
        let result = try await execute(
            sql: "SELECT current_setting('threads')::BIGINT, current_setting('memory_limit')::VARCHAR",
            bindings: []
        )
        guard let threads = result.int64(column: 0, row: 0),
              let memoryLimit = result.string(column: 1, row: 0) else {
            throw CSVInMemoryQueryError.queryFailed("DuckDB did not report its resource defaults.")
        }
        return TestingResourceSettings(threads: threads, memoryLimit: memoryLimit)
    }

    func testingCancellationOwnershipIsAtomic() -> Bool {
        interruptHandle.testingQueuedCancellationNeverBegins()
            && interruptHandle.testingLateCancellationPreservesNewOwner()
    }

    func testingSourceQueryPath() -> String {
        pinnedSource.queryPath
    }
    #endif

    #if LIGHTXT_PACKAGE_TESTING
    func testingRecentExecutedSQL() -> [String] {
        testingExecutedSQL
    }
    #endif

    private func performOpen() async throws -> ParquetMetadata {
        try ensureOpen()
        try initializeDatabase()
        do {
            _ = try await execute(
                sql: "SET allowed_paths = \(Self.duckDBListLiteral([pinnedSource.queryPath]))",
                bindings: [],
                validatesSource: true
            )
            _ = try await execute(
                sql: Self.createResidentTableSQL(configuration: configuration),
                bindings: [.text(pinnedSource.queryPath)],
                validatesSource: true
            )
            _ = try await execute(
                sql: "SET enable_external_access = false",
                bindings: []
            )
            _ = try await execute(
                sql: "SET lock_configuration = true",
                bindings: []
            )
        } catch let error as CSVInMemoryQueryError {
            switch error {
            case .cancelled, .closed, .sourceChanged:
                throw error
            case let .queryFailed(reason), let .loadFailed(reason):
                throw CSVInMemoryQueryError.loadFailed(reason)
            default:
                throw error
            }
        }
        // The resident table is now self-contained. Release the source handle
        // and its security scope; later queries cannot observe path changes.
        pinnedSource.close()
        securityScope.stop()

        let rowCount = try await countRows(query: ParquetTableQuery())
        let visibleNames = Array(configuration.columnNames.prefix(limits.maximumPresentedColumns))
        let columns = visibleNames.enumerated().map { index, name in
            ParquetColumn(index: index, name: name, typeName: "VARCHAR", isNullable: false)
        }
        let metadata = ParquetMetadata(
            columns: columns,
            totalColumnCount: configuration.columnNames.count,
            rowCount: rowCount,
            fileSize: sourceFileState.byteCount,
            engineVersion: runtime.version
        )
        metadataStorage = metadata
        countCache[ParquetTableQuery()] = rowCount
        return metadata
    }

    private func awaitOpeningTask(_ task: Task<ParquetMetadata, Error>) async throws -> ParquetMetadata {
        try await withTaskCancellationHandler {
            let value = try await task.value
            if Task.isCancelled { throw CSVInMemoryQueryError.cancelled }
            return value
        } onCancel: {
            self.cancelCurrentQuery()
        }
    }

    private func queryUniqueValues(
        forColumn columnIndex: Int,
        filters: [ParquetColumnFilter],
        columns: [ParquetColumn],
        searchText: String = "",
        searchIsCaseSensitive: Bool = false,
        offset: Int64 = 0,
        limit: Int
    ) async throws -> ParquetUniqueValues {
        let identifier = internalIdentifier(for: columnIndex)
        let text = "TRY_CAST(\(identifier) AS VARCHAR)"
        var bindings: [DuckDBBinding] = []
        let whereClause = buildWhereClause(filters, columns: columns, bindings: &bindings)
        let searchPredicate: String
        if searchText.isEmpty {
            searchPredicate = "TRUE"
        } else if searchIsCaseSensitive {
            searchPredicate = "contains(value_text, ?)"
            bindings.append(.text(searchText))
        } else {
            searchPredicate = "contains(lower(value_text), lower(?))"
            bindings.append(.text(searchText))
        }
        bindings.append(.int64(Int64(limit)))
        bindings.append(.int64(offset))
        let maximumBytes = limits.maximumFilterValueCharacters
        let sql = """
            WITH projected AS (
                SELECT \(identifier) IS NULL AS value_is_null,
                       \(text) AS value_text
                \(Self.sourceClause)
                \(whereClause)
            ), classified AS (
                SELECT value_text,
                       CASE WHEN value_is_null THEN 0::BIGINT
                            WHEN octet_length(encode(value_text)) > \(maximumBytes) THEN 2::BIGINT
                            WHEN \(searchPredicate) THEN 1::BIGINT
                            ELSE 3::BIGINT END AS value_kind
                FROM projected
            ), grouped AS (
                SELECT value_kind,
                       CASE WHEN value_kind = 1 THEN value_text ELSE NULL END AS value_text,
                       COUNT(*)::BIGINT AS frequency
                FROM classified
                GROUP BY 1, 2
            ), stats AS (
                SELECT COALESCE(SUM(CASE WHEN value_kind IN (0, 1) THEN 1 ELSE 0 END), 0)::BIGINT
                           AS total_value_count,
                       COALESCE(SUM(CASE WHEN value_kind = 2 THEN frequency ELSE 0 END), 0)::BIGINT
                           AS oversized_row_count
                FROM grouped
            ), paged AS (
                SELECT CASE WHEN value_kind = 0 THEN NULL ELSE hex(encode(value_text)) END AS value,
                       frequency
                FROM grouped
                WHERE value_kind IN (0, 1)
                ORDER BY frequency DESC, value ASC NULLS FIRST
                LIMIT ? OFFSET ?
            )
            SELECT 0::BIGINT AS result_kind, paged.value, paged.frequency,
                   stats.total_value_count, stats.oversized_row_count
            FROM paged CROSS JOIN stats
            UNION ALL
            SELECT 1::BIGINT, NULL::VARCHAR, 0::BIGINT,
                   stats.total_value_count, stats.oversized_row_count
            FROM stats
            ORDER BY result_kind ASC, frequency DESC, value ASC NULLS FIRST
            """
        let result = try await execute(sql: sql, bindings: bindings)
        var values: [ParquetUniqueValue] = []
        var total: Int64 = 0
        var oversized: Int64 = 0
        for row in 0..<result.rowCount {
            total = result.int64(column: 3, row: row) ?? total
            oversized = result.int64(column: 4, row: row) ?? oversized
            guard result.int64(column: 0, row: row) == 0 else { continue }
            let value: ParquetFilterValue = result.isNull(column: 1, row: row)
                ? .null
                : .text(result.hexDecodedString(column: 1, row: row) ?? "")
            values.append(ParquetUniqueValue(
                value: value,
                count: result.int64(column: 2, row: row) ?? 0
            ))
        }
        let hasMore = offset + Int64(values.count) < total
        return ParquetUniqueValues(
            values: values,
            offset: offset,
            totalValueCount: total,
            isTruncated: hasMore,
            omittedOversizedValueCount: oversized
        )
    }

    private func countRows(query: ParquetTableQuery) async throws -> Int64 {
        let columns = metadataStorage?.columns ?? configuration.columnNames
            .prefix(limits.maximumPresentedColumns)
            .enumerated()
            .map { ParquetColumn(index: $0.offset, name: $0.element, typeName: "VARCHAR", isNullable: false) }
        try validate(query: query, columns: columns)
        var bindings: [DuckDBBinding] = []
        let whereClause = buildWhereClause(query.filters, columns: columns, bindings: &bindings)
        let result = try await execute(
            sql: "SELECT COUNT(*)::BIGINT \(Self.sourceClause) \(whereClause)",
            bindings: bindings
        )
        return result.int64(column: 0, row: 0) ?? 0
    }

    private func storeCount(_ count: Int64, for query: ParquetTableQuery) {
        if countCache.count >= 8, countCache[query] == nil {
            countCache.removeAll(keepingCapacity: true)
            if let metadataStorage {
                countCache[ParquetTableQuery()] = metadataStorage.rowCount
            }
        }
        countCache[query] = count
    }

    private func validate(query: ParquetTableQuery, columns: [ParquetColumn]) throws {
        guard query.filters.count <= columns.count else {
            throw CSVInMemoryQueryError.invalidFilter("Too many column filters were supplied.")
        }
        guard Set(query.filters.map(\.column)).count == query.filters.count else {
            throw CSVInMemoryQueryError.invalidFilter("Each column can have only one filter.")
        }
        var aggregateBytes = 0
        var aggregateSelectedValues = 0
        for filter in query.filters {
            guard columns.indices.contains(filter.column) else {
                throw CSVInMemoryQueryError.invalidColumn(filter.column)
            }
            guard filter.containsText.utf8.count <= limits.maximumFilterValueCharacters else {
                throw CSVInMemoryQueryError.invalidFilter("Contains text is too large.")
            }
            guard filter.selectedValues.count <= limits.maximumSelectedValuesPerColumn else {
                throw CSVInMemoryQueryError.invalidFilter("Too many values are selected in one column.")
            }
            aggregateSelectedValues += filter.selectedValues.count
            aggregateBytes += filter.containsText.utf8.count
            for value in filter.selectedValues {
                if case let .text(text) = value {
                    guard text.utf8.count <= limits.maximumFilterValueCharacters else {
                        throw CSVInMemoryQueryError.invalidFilter("A selected value is too large.")
                    }
                    aggregateBytes += text.utf8.count
                }
                guard aggregateBytes <= ParquetQueryService.Limits.maximumAggregateFilterBytes else {
                    throw CSVInMemoryQueryError.invalidFilter("Combined filter text is too large.")
                }
            }
        }
        guard aggregateSelectedValues <= ParquetQueryService.Limits.maximumAggregateSelectedValues else {
            throw CSVInMemoryQueryError.invalidFilter("Too many values are selected across all columns.")
        }
        if let sort = query.sort, !columns.indices.contains(sort.column) {
            throw CSVInMemoryQueryError.invalidColumn(sort.column)
        }
    }

    private func buildWhereClause(
        _ filters: [ParquetColumnFilter],
        columns: [ParquetColumn],
        bindings: inout [DuckDBBinding]
    ) -> String {
        var predicates: [String] = []
        for filter in filters where columns.indices.contains(filter.column) && !filter.isEmpty {
            let identifier = internalIdentifier(for: filter.column)
            let text = "TRY_CAST(\(identifier) AS VARCHAR)"
            if !filter.containsText.isEmpty {
                predicates.append(filter.containsCaseSensitive
                    ? "contains(COALESCE(\(text), ''), ?)"
                    : "contains(lower(COALESCE(\(text), '')), lower(?))")
                bindings.append(.text(filter.containsText))
            }
            if !filter.selectedValues.isEmpty {
                var alternatives: [String] = []
                if filter.selectedValues.contains(.null) {
                    alternatives.append("\(identifier) IS NULL")
                }
                for value in filter.selectedValues.compactMap({ value -> String? in
                    guard case let .text(text) = value else { return nil }
                    return text
                }).sorted() {
                    alternatives.append("\(text) = ?")
                    bindings.append(.text(value))
                }
                if !alternatives.isEmpty {
                    predicates.append("(" + alternatives.joined(separator: " OR ") + ")")
                }
            }
        }
        return predicates.isEmpty ? "" : "WHERE " + predicates.joined(separator: " AND ")
    }

    private func buildOrderClause(
        _ sort: ParquetSortDescriptor?,
        columns: [ParquetColumn]
    ) -> String {
        guard let sort, columns.indices.contains(sort.column) else {
            return "ORDER BY \(Self.rowIdentifier) ASC"
        }
        let direction = sort.order == .ascending ? "ASC" : "DESC"
        return "ORDER BY \(internalIdentifier(for: sort.column)) \(direction) NULLS LAST, \(Self.rowIdentifier) ASC"
    }

    private func displayProjection(column: ParquetColumn, characterLimit: Int) -> String {
        let identifier = internalIdentifier(for: column.index)
        let text = "TRY_CAST(\(identifier) AS VARCHAR)"
        return """
            CASE WHEN \(identifier) IS NULL THEN NULL
                 WHEN length(\(text)) > \(characterLimit)
                 THEN hex(encode(left(\(text), \(characterLimit))))
                 ELSE hex(encode(\(text))) END AS \(Self.quoteIdentifier("__lightxt_value_\(column.index)")),
            CASE WHEN \(identifier) IS NOT NULL AND length(\(text)) > \(characterLimit)
                 THEN 1::BIGINT ELSE 0::BIGINT END AS \(Self.quoteIdentifier("__lightxt_truncated_\(column.index)"))
            """
    }

    private func initializeDatabase() throws {
        guard connectionStorage.connection == nil else { return }
        do {
            let handles = try runtime.openInMemory(options: Self.databaseOptions)
            connectionStorage.install(database: handles.database, connection: handles.connection)
            interruptHandle.setConnection(handles.connection)
        } catch {
            throw Self.mapRuntimeError(error, loading: true)
        }
    }

    private func execute(
        sql: String,
        bindings: [DuckDBBinding],
        validatesSource: Bool = false
    ) async throws -> DuckDBResult {
        try ensureOpen()
        guard connectionStorage.connection != nil else { throw CSVInMemoryQueryError.closed }
        #if LIGHTXT_PACKAGE_TESTING
        testingExecutedSQL.append(sql)
        if testingExecutedSQL.count > 8 {
            testingExecutedSQL.removeFirst(testingExecutedSQL.count - 8)
        }
        #endif
        let runtime = runtime
        let executor = queryExecutor
        let connectionStorage = connectionStorage
        let interruptHandle = interruptHandle
        let pinnedSource = pinnedSource
        let requestID = interruptHandle.registerRequest()
        do {
            return try await withTaskCancellationHandler {
                let value = try await executor.run {
                    guard interruptHandle.beginRequest(requestID) else {
                        throw CSVInMemoryQueryError.cancelled
                    }
                    defer { interruptHandle.finishRequest(requestID) }
                    guard let connection = connectionStorage.connection else {
                        throw CSVInMemoryQueryError.closed
                    }
                    if validatesSource, !pinnedSource.matchesOriginalRevision() {
                        throw CSVInMemoryQueryError.sourceChanged
                    }
                    let result = try runtime.execute(
                        connection: connection,
                        sql: sql,
                        bindings: bindings
                    )
                    if validatesSource, !pinnedSource.matchesOriginalRevision() {
                        throw CSVInMemoryQueryError.sourceChanged
                    }
                    return result
                }
                if Task.isCancelled { throw CSVInMemoryQueryError.cancelled }
                return value
            } onCancel: {
                interruptHandle.cancelRequest(requestID)
            }
        } catch {
            throw Self.mapRuntimeError(error, loading: false)
        }
    }

    private func ensureOpen() throws {
        if Task.isCancelled { throw CSVInMemoryQueryError.cancelled }
        if isClosed { throw CSVInMemoryQueryError.closed }
    }

    private func finishAfterFailedOpen() {
        isClosed = true
        interruptHandle.setConnection(nil)
        connectionStorage.close()
        pinnedSource.close()
        securityScope.stop()
    }

    private func internalIdentifier(for column: Int) -> String {
        Self.quoteIdentifier(Self.internalColumnAlias(column))
    }

    private static func validate(configuration: CSVInMemoryConfiguration) throws {
        guard !configuration.columnNames.isEmpty else {
            throw CSVInMemoryQueryError.invalidConfiguration("No columns were detected.")
        }
        guard configuration.columnNames.count <= ParquetQueryService.Limits.maximumPhysicalColumns else {
            throw CSVInMemoryQueryError.invalidConfiguration(
                "More than \(ParquetQueryService.Limits.maximumPhysicalColumns.formatted()) columns were detected."
            )
        }
        guard DelimitedTextDelimiter.allCases.map(\.rawValue).contains(configuration.delimiter) else {
            throw CSVInMemoryQueryError.invalidConfiguration("The selected delimiter is not supported.")
        }
        var aggregateBytes = 0
        for name in configuration.columnNames {
            guard name.utf8.count <= ParquetQueryService.Limits.maximumSchemaFieldUTF8Bytes else {
                throw CSVInMemoryQueryError.invalidConfiguration("A column name is too large.")
            }
            let (newTotal, overflow) = aggregateBytes.addingReportingOverflow(name.utf8.count)
            guard !overflow,
                  newTotal <= ParquetQueryService.Limits.maximumAggregateSchemaUTF8Bytes else {
                throw CSVInMemoryQueryError.invalidConfiguration("The combined column names are too large.")
            }
            aggregateBytes = newTotal
        }
    }

    private static func createResidentTableSQL(
        configuration: CSVInMemoryConfiguration
    ) -> String {
        let internalNames = configuration.columnNames.indices.map(internalColumnAlias)
        let schema = internalNames.map {
            "\(duckDBStringLiteral($0)): 'VARCHAR'"
        }.joined(separator: ", ")
        let forcedNonNull = duckDBListLiteral(internalNames)
        let delimiter = String(decoding: [configuration.delimiter], as: UTF8.self)
        let header = configuration.firstRowIsHeader ? "true" : "false"
        return """
            CREATE TABLE \(residentTableIdentifier) AS
            SELECT * FROM read_csv(
                $1,
                auto_detect = false,
                header = \(header),
                columns = {\(schema)},
                delim = \(duckDBStringLiteral(delimiter)),
                quote = '"',
                escape = '"',
                strict_mode = true,
                ignore_errors = false,
                null_padding = false,
                force_not_null = \(forcedNonNull),
                parallel = true
            )
            """
    }

    private static func mapRuntimeError(_ error: Error, loading: Bool) -> CSVInMemoryQueryError {
        if let error = error as? CSVInMemoryQueryError { return error }
        if error is CancellationError { return .cancelled }
        guard let error = error as? ParquetQueryError else {
            return loading ? .loadFailed(error.localizedDescription) : .queryFailed(error.localizedDescription)
        }
        switch error {
        case let .runtimeUnavailable(reason): return .runtimeUnavailable(reason)
        case let .incompatibleRuntime(expected, actual):
            return .incompatibleRuntime(expected: expected, actual: actual)
        case .cancelled: return .cancelled
        case .closed: return .closed
        case .sourceChanged: return .sourceChanged
        case let .queryFailed(reason), let .malformedFile(reason), let .invalidFilter(reason):
            return loading ? .loadFailed(reason) : .queryFailed(reason)
        case let .invalidColumn(column): return .invalidColumn(column)
        case let .invalidPage(offset, limit): return .invalidPage(offset: offset, limit: limit)
        }
    }

    private static func internalColumnAlias(_ index: Int) -> String {
        "__lightxt_csv_memory_column_\(index)"
    }

    private static func quoteIdentifier(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func duckDBListLiteral(_ values: [String]) -> String {
        "[" + values.map(duckDBStringLiteral).joined(separator: ",") + "]"
    }

    private static func duckDBStringLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    private static let residentTableIdentifier = quoteIdentifier("__lightxt_csv_memory")
    private static let rowIdentifier = "rowid"
    private static let sourceClause = "FROM \(residentTableIdentifier)"
}

/// Retains the exact source inode until materialization completes while giving
/// DuckDB the ordinary filesystem path required for parallel CSV ingestion.
/// Descriptor and pathname revisions are checked around the load so an atomic
/// replacement cannot publish a mixed resident table.
private nonisolated final class PinnedCSVInMemorySource: @unchecked Sendable {
    private struct Revision: Equatable {
        let device: UInt64
        let inode: UInt64
        let fileSize: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
    }

    let queryPath: String
    let externalFileState: ExternalFileState
    private let descriptor: Int32
    private let revision: Revision
    private let lock = NSLock()
    private var isClosed = false

    init(url: URL) throws {
        let queryPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        let descriptor = Darwin.open(queryPath, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw CSVInMemoryQueryError.invalidConfiguration(Self.systemError("The file could not be opened"))
        }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else {
            let reason = Self.systemError("The file metadata could not be read")
            Darwin.close(descriptor)
            throw CSVInMemoryQueryError.invalidConfiguration(reason)
        }
        let revision = Revision(
            device: UInt64(bitPattern: Int64(information.st_dev)),
            inode: UInt64(information.st_ino),
            fileSize: Int64(information.st_size),
            modifiedSeconds: Int64(information.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(information.st_mtimespec.tv_nsec)
        )
        self.descriptor = descriptor
        self.queryPath = queryPath
        self.revision = revision
        self.externalFileState = ExternalFileState(
            identity: ExternalFileIdentity(device: revision.device, inode: revision.inode),
            byteCount: revision.fileSize,
            modificationTime: ExternalFileModificationTime(
                seconds: revision.modifiedSeconds,
                nanoseconds: revision.modifiedNanoseconds
            )
        )
    }

    deinit { close() }

    func close() {
        let shouldClose = lock.withLock { () -> Bool in
            guard !isClosed else { return false }
            isClosed = true
            return true
        }
        if shouldClose { Darwin.close(descriptor) }
    }

    func matchesOriginalRevision() -> Bool {
        let descriptor: Int32? = lock.withLock { isClosed ? nil : self.descriptor }
        guard let descriptor else { return false }
        var descriptorInformation = stat()
        guard Darwin.fstat(descriptor, &descriptorInformation) == 0,
              revision == Self.revision(from: descriptorInformation) else { return false }
        var pathInformation = stat()
        guard Darwin.lstat(queryPath, &pathInformation) == 0 else { return false }
        return revision == Self.revision(from: pathInformation)
    }

    private static func systemError(_ prefix: String) -> String {
        "\(prefix). \(String(cString: strerror(errno)))"
    }

    private static func revision(from information: stat) -> Revision {
        Revision(
            device: UInt64(bitPattern: Int64(information.st_dev)),
            inode: UInt64(information.st_ino),
            fileSize: Int64(information.st_size),
            modifiedSeconds: Int64(information.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(information.st_mtimespec.tv_nsec)
        )
    }
}

private nonisolated final class CSVInMemorySerialExecutor: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "app.lightxt.csv-memory.duckdb-query",
        qos: .userInitiated
    )

    func run<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try operation() })
            }
        }
    }

    func runWithoutThrowing(_ operation: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { continuation in
            queue.async {
                operation()
                continuation.resume()
            }
        }
    }
}
