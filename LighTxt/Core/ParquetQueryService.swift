import Darwin
import Foundation

/// Errors emitted by the bounded, read-only Parquet query path.
public nonisolated enum ParquetQueryError: Error, LocalizedError, Equatable {
    case runtimeUnavailable(String)
    case incompatibleRuntime(expected: String, actual: String)
    case malformedFile(String)
    case invalidColumn(Int)
    case invalidPage(offset: Int64, limit: Int)
    case invalidFilter(String)
    case queryFailed(String)
    case cancelled
    case closed

    public var errorDescription: String? {
        switch self {
        case let .runtimeUnavailable(reason):
            return "The built-in Parquet reader could not be loaded. \(reason)"
        case let .incompatibleRuntime(expected, actual):
            return "The built-in Parquet reader is version \(actual); LighTxt requires \(expected)."
        case let .malformedFile(reason):
            return "This is not a readable Parquet file. \(reason)"
        case let .invalidColumn(column):
            return "Parquet column \(column + 1) is outside the available schema."
        case let .invalidPage(offset, limit):
            return "The Parquet page request is invalid (offset \(offset), limit \(limit))."
        case let .invalidFilter(reason):
            return "The Parquet filter is too large. \(reason)"
        case let .queryFailed(reason):
            return "The Parquet query failed. \(reason)"
        case .cancelled:
            return "The Parquet query was cancelled."
        case .closed:
            return "This Parquet document is no longer open."
        }
    }
}

public nonisolated struct ParquetColumn: Sendable, Equatable, Hashable {
    public let index: Int
    public let name: String
    public let typeName: String
    public let isNullable: Bool

    public init(index: Int, name: String, typeName: String, isNullable: Bool) {
        self.index = index
        self.name = name
        self.typeName = typeName
        self.isNullable = isNullable
    }

    /// DuckDB reports nested Parquet logical types as STRUCT/MAP/UNION names
    /// or with LIST/ARRAY square-bracket suffixes. Keep this schema-derived so
    /// scalar strings that merely happen to contain JSON-like text never gain
    /// structured expansion behavior.
    public var isStructured: Bool {
        let normalized = typeName.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return normalized.hasPrefix("STRUCT(")
            || normalized.hasPrefix("MAP(")
            || normalized.hasPrefix("LIST(")
            || normalized.hasPrefix("UNION(")
            || normalized.hasSuffix("]")
    }
}

public nonisolated struct ParquetMetadata: Sendable, Equatable {
    public let columns: [ParquetColumn]
    public let totalColumnCount: Int
    public let rowCount: Int64
    public let fileSize: Int64
    public let engineVersion: String

    public init(
        columns: [ParquetColumn],
        totalColumnCount: Int,
        rowCount: Int64,
        fileSize: Int64,
        engineVersion: String
    ) {
        self.columns = columns
        self.totalColumnCount = totalColumnCount
        self.rowCount = rowCount
        self.fileSize = fileSize
        self.engineVersion = engineVersion
    }
}

public nonisolated enum ParquetFilterValue: Sendable, Equatable, Hashable {
    case null
    case text(String)

    public var displayText: String {
        switch self {
        case .null: return "NULL"
        case let .text(value): return value.isEmpty ? "Empty string" : "\u{201C}\(value)\u{201D}"
        }
    }
}

public nonisolated struct ParquetColumnFilter: Sendable, Equatable, Hashable {
    public let column: Int
    public let containsText: String
    public let containsCaseSensitive: Bool
    public let selectedValues: Set<ParquetFilterValue>

    public init(
        column: Int,
        containsText: String = "",
        containsCaseSensitive: Bool = false,
        selectedValues: Set<ParquetFilterValue> = []
    ) {
        self.column = column
        self.containsText = containsText
        self.containsCaseSensitive = containsCaseSensitive
        self.selectedValues = selectedValues
    }

    public var isEmpty: Bool { containsText.isEmpty && selectedValues.isEmpty }
}

public nonisolated enum ParquetSortOrder: Sendable, Equatable, Hashable {
    case ascending
    case descending
}

public nonisolated struct ParquetSortDescriptor: Sendable, Equatable, Hashable {
    public let column: Int
    public let order: ParquetSortOrder

    public init(column: Int, order: ParquetSortOrder) {
        self.column = column
        self.order = order
    }
}

public nonisolated struct ParquetTableQuery: Sendable, Equatable, Hashable {
    public let filters: [ParquetColumnFilter]
    public let sort: ParquetSortDescriptor?

    public init(filters: [ParquetColumnFilter] = [], sort: ParquetSortDescriptor? = nil) {
        self.filters = filters.filter { !$0.isEmpty }.sorted { $0.column < $1.column }
        self.sort = sort
    }
}

public nonisolated struct ParquetCell: Sendable, Equatable {
    public let value: String?
    public let isTruncated: Bool

    public init(value: String?, isTruncated: Bool) {
        self.value = value
        self.isTruncated = isTruncated
    }

    public var displayText: String { value ?? "NULL" }
}

public nonisolated struct ParquetPage: Sendable, Equatable {
    public let offset: Int64
    public let totalRowCount: Int64
    /// Stable physical row ordinals from the selected Parquet source. UI
    /// detail requests key by these ordinals rather than filtered/sorted row
    /// offsets, so paging cannot display a detail value on the wrong record.
    public let sourceRowOrdinals: [Int64]
    public let rows: [[ParquetCell]]

    public init(
        offset: Int64,
        totalRowCount: Int64,
        sourceRowOrdinals: [Int64] = [],
        rows: [[ParquetCell]]
    ) {
        self.offset = offset
        self.totalRowCount = totalRowCount
        self.sourceRowOrdinals = sourceRowOrdinals
        self.rows = rows
    }
}

public nonisolated struct ParquetStructuredCellDetail: Sendable, Equatable {
    public let sourceRowOrdinal: Int64
    public let column: Int
    public let json: String?
    public let isTruncated: Bool

    public init(
        sourceRowOrdinal: Int64,
        column: Int,
        json: String?,
        isTruncated: Bool
    ) {
        self.sourceRowOrdinal = sourceRowOrdinal
        self.column = column
        self.json = json
        self.isTruncated = isTruncated
    }
}

public nonisolated struct ParquetUniqueValue: Sendable, Equatable {
    public let value: ParquetFilterValue
    public let count: Int64

    public init(value: ParquetFilterValue, count: Int64) {
        self.value = value
        self.count = count
    }
}

public nonisolated struct ParquetUniqueValues: Sendable, Equatable {
    public let values: [ParquetUniqueValue]
    public let isTruncated: Bool
    public let omittedOversizedValueCount: Int64

    public init(
        values: [ParquetUniqueValue],
        isTruncated: Bool,
        omittedOversizedValueCount: Int64
    ) {
        self.values = values
        self.isTruncated = isTruncated
        self.omittedOversizedValueCount = omittedOversizedValueCount
    }
}

public nonisolated struct ParquetFrequentValue: Sendable, Equatable {
    public let value: ParquetFilterValue
    public let count: Int64

    public init(value: ParquetFilterValue, count: Int64) {
        self.value = value
        self.count = count
    }
}

public nonisolated struct ParquetColumnSummary: Sendable, Equatable {
    public let column: ParquetColumn
    public let rowCount: Int64
    public let nullCount: Int64
    public let approximateDistinctCount: Int64
    public let minimum: String?
    public let maximum: String?
    public let frequentValues: [ParquetFrequentValue]

    public init(
        column: ParquetColumn,
        rowCount: Int64,
        nullCount: Int64,
        approximateDistinctCount: Int64,
        minimum: String?,
        maximum: String?,
        frequentValues: [ParquetFrequentValue]
    ) {
        self.column = column
        self.rowCount = rowCount
        self.nullCount = nullCount
        self.approximateDistinctCount = approximateDistinctCount
        self.minimum = minimum
        self.maximum = maximum
        self.frequentValues = frequentValues
    }
}

/// One serial DuckDB connection per open Parquet document. Queries never copy
/// the source into a database: DuckDB scans the selected file directly with
/// projection/filter pushdown and every returned result is hard-capped.
public actor ParquetQueryService {
    public struct Limits: Sendable, Equatable {
        public static let maximumPhysicalColumns = 4_096
        public static let maximumSchemaFieldUTF8Bytes = 65_536
        public static let maximumAggregateSchemaUTF8Bytes = 4 << 20
        public static let maximumAggregateFilterBytes = 4 << 20
        public static let maximumAggregateSelectedValues = 5_000
        public static let maximumAggregateFacetUTF8Bytes = 32 << 20
        /// A detail is fetched only after explicit expansion. Sixteen UI
        /// expansions therefore retain at most 1 MiB of source JSON before
        /// bounded pretty-formatting overhead.
        public static let maximumStructuredDetailCharacters = 65_536
        public let maximumPresentedColumns: Int
        public let maximumPageRows: Int
        public let maximumCellCharacters: Int
        public let maximumPageCharacters: Int
        public let maximumUniqueValues: Int
        public let maximumSelectedValuesPerColumn: Int
        public let maximumFilterValueCharacters: Int
        public let memoryLimit: String
        public let maximumTemporaryStorage: String
        public let workerThreads: Int

        public init(
            maximumPresentedColumns: Int = 256,
            maximumPageRows: Int = 128,
            maximumCellCharacters: Int = 4_096,
            maximumPageCharacters: Int = 4_194_304,
            maximumUniqueValues: Int = 500,
            maximumSelectedValuesPerColumn: Int = 500,
            maximumFilterValueCharacters: Int = 16_384,
            workerThreads: Int = min(4, max(1, ProcessInfo.processInfo.activeProcessorCount))
        ) {
            self.maximumPresentedColumns = min(1_024, max(1, maximumPresentedColumns))
            self.maximumPageRows = min(512, max(1, maximumPageRows))
            self.maximumCellCharacters = min(65_536, max(64, maximumCellCharacters))
            self.maximumPageCharacters = max(
                self.maximumPresentedColumns * self.maximumPageRows,
                min(16_777_216, maximumPageCharacters)
            )
            self.maximumSelectedValuesPerColumn = min(
                5_000,
                max(1, maximumSelectedValuesPerColumn)
            )
            self.maximumFilterValueCharacters = min(
                1_048_576,
                max(64, maximumFilterValueCharacters)
            )
            // A facet result is retained as one array. Couple its row and
            // value-size limits so custom limits cannot request gigabytes of
            // strings. Four UTF-8 bytes per scalar is the conservative bound.
            let maximumFacetValuesForValueSize = max(
                1,
                Limits.maximumAggregateFacetUTF8Bytes
                    / (self.maximumFilterValueCharacters * 4)
            )
            self.maximumUniqueValues = min(
                5_000,
                max(1, maximumUniqueValues),
                maximumFacetValuesForValueSize
            )
            self.memoryLimit = "512MB"
            self.maximumTemporaryStorage = "1GB"
            self.workerThreads = min(4, max(1, workerThreads))
        }

        public static let `default` = Limits()
    }

    public static let requiredDuckDBVersion = "v1.4.5"

    private let sourceURL: URL
    private let limits: Limits
    private let runtime: DuckDBDynamicAPI
    private let interruptHandle: ParquetInterruptHandle
    private let connectionStorage: DuckDBConnectionStorage
    private let securityScope: SecurityScopedAccess
    private let queryExecutor = DuckDBSerialExecutor()
    private let temporaryDirectory: URL
    private var allColumnsStorage: [ParquetColumn] = []
    private var metadataStorage: ParquetMetadata?
    private var countCache: [ParquetTableQuery: Int64] = [:]
    private var isClosed = false

    public init(
        url: URL,
        limits: Limits = .default,
        libraryURL: URL? = nil
    ) throws {
        let standardized = url.standardizedFileURL
        self.sourceURL = standardized
        self.limits = limits
        let securityScope = SecurityScopedAccess(url: standardized)
        self.securityScope = securityScope
        do {
            let runtime = try DuckDBDynamicAPI(libraryURL: libraryURL)
            self.runtime = runtime
            self.interruptHandle = ParquetInterruptHandle(runtime: runtime)
            self.connectionStorage = DuckDBConnectionStorage(runtime: runtime)
            self.temporaryDirectory = try Self.makeTemporaryDirectory()
        } catch {
            securityScope.stop()
            throw error
        }
    }

    deinit {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    public func open() async throws -> ParquetMetadata {
        if let metadataStorage { return metadataStorage }
        try ensureOpen()
        try Self.validateParquetEnvelope(at: sourceURL)
        try initializeDatabase()

        let schema = try await describeColumns()
        guard !schema.isEmpty else {
            throw ParquetQueryError.malformedFile("The file contains no readable columns.")
        }
        guard schema.count <= Limits.maximumPhysicalColumns else {
            throw ParquetQueryError.malformedFile(
                "Its schema has more than \(Limits.maximumPhysicalColumns.formatted()) columns."
            )
        }
        allColumnsStorage = schema
        let visibleColumns = Array(schema.prefix(limits.maximumPresentedColumns))
        let rowCount = try await countRows(query: ParquetTableQuery())
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        let metadata = ParquetMetadata(
            columns: visibleColumns,
            totalColumnCount: schema.count,
            rowCount: rowCount,
            fileSize: fileSize,
            engineVersion: runtime.version
        )
        metadataStorage = metadata
        countCache[ParquetTableQuery()] = rowCount
        return metadata
    }

    public func page(
        offset: Int64,
        limit: Int,
        query: ParquetTableQuery = ParquetTableQuery()
    ) async throws -> ParquetPage {
        let metadata = try await open()
        guard offset >= 0, limit > 0, limit <= limits.maximumPageRows else {
            throw ParquetQueryError.invalidPage(offset: offset, limit: limit)
        }
        try validate(query: query, columns: metadata.columns)
        let total: Int64
        if let cached = countCache[query] {
            total = cached
        } else {
            let count = try await countRows(query: query)
            if countCache.count >= 8 { countCache.removeAll(keepingCapacity: true) }
            countCache[query] = count
            total = count
        }
        guard offset < total else {
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
        let valueProjection = columns.map { column in
            displayProjection(column: column, characterLimit: cellCharacterLimit)
        }.joined(separator: ", ")
        let rowIdentifier = Self.quoteIdentifier(Self.rowOrdinalAlias)
        let projection = "\(rowIdentifier)::BIGINT AS \(Self.quoteIdentifier("__lightxt_result_row")), \(valueProjection)"
        var bindings: [DuckDBBinding] = [.text(sourceURL.path)]
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
                \(sourceClause())
                WHERE \(rowIdentifier) >= ?
                ORDER BY \(rowIdentifier) ASC
                LIMIT ?
                """
        } else {
            bindings.append(.int64(Int64(boundedLimit)))
            bindings.append(.int64(offset))
            sql = """
                SELECT \(projection)
                \(sourceClause())
                \(whereClause)
                \(orderClause)
                LIMIT ? OFFSET ?
                """
        }
        let result = try await execute(sql: sql, bindings: bindings)
        var rows: [[ParquetCell]] = []
        var sourceRowOrdinals: [Int64] = []
        rows.reserveCapacity(result.rowCount)
        sourceRowOrdinals.reserveCapacity(result.rowCount)
        for row in 0..<result.rowCount {
            guard let sourceRowOrdinal = result.int64(column: 0, row: row) else {
                throw ParquetQueryError.queryFailed("A Parquet row had no stable source position.")
            }
            sourceRowOrdinals.append(sourceRowOrdinal)
            var values: [ParquetCell] = []
            values.reserveCapacity(columns.count)
            for column in 0..<columns.count {
                let valueColumn = 1 + column * 2
                let truncationColumn = valueColumn + 1
                guard let value = result.hexDecodedString(column: valueColumn, row: row) else {
                    values.append(ParquetCell(value: nil, isTruncated: false))
                    continue
                }
                let truncated = (result.int64(column: truncationColumn, row: row) ?? 0) != 0
                values.append(ParquetCell(
                    value: truncated ? value + "…" : value,
                    isTruncated: truncated
                ))
            }
            rows.append(values)
        }
        return ParquetPage(
            offset: offset,
            totalRowCount: total,
            sourceRowOrdinals: sourceRowOrdinals,
            rows: rows
        )
    }

    /// Fetches one bounded, canonical JSON representation for an explicitly
    /// expanded nested cell. This never widens a page projection or retains a
    /// full Parquet row, and the stable source ordinal prevents filtered/sorted
    /// offsets from being confused across page requests.
    public func structuredCellDetail(
        sourceRowOrdinal: Int64,
        column columnIndex: Int
    ) async throws -> ParquetStructuredCellDetail {
        let metadata = try await open()
        guard sourceRowOrdinal >= 0 else {
            throw ParquetQueryError.queryFailed("The Parquet source row is invalid.")
        }
        guard metadata.columns.indices.contains(columnIndex) else {
            throw ParquetQueryError.invalidColumn(columnIndex)
        }
        let column = metadata.columns[columnIndex]
        guard column.isStructured else {
            throw ParquetQueryError.queryFailed("The selected Parquet value is not structured.")
        }
        let identifier = internalIdentifier(for: columnIndex)
        let rowIdentifier = Self.quoteIdentifier(Self.rowOrdinalAlias)
        let characterLimit = Limits.maximumStructuredDetailCharacters
        let json = "TRY_CAST(to_json(\(identifier)) AS VARCHAR)"
        let sql = """
            SELECT CASE WHEN \(identifier) IS NULL THEN NULL
                        WHEN length(\(json)) > \(characterLimit)
                        THEN hex(encode(left(\(json), \(characterLimit))))
                        ELSE hex(encode(\(json)))
                   END AS structured_json,
                   CASE WHEN \(identifier) IS NOT NULL AND length(\(json)) > \(characterLimit)
                        THEN 1::BIGINT ELSE 0::BIGINT
                   END AS is_truncated
            \(sourceClause())
            WHERE \(rowIdentifier) = ?
            LIMIT 1
            """
        let result = try await execute(
            sql: sql,
            bindings: [.text(sourceURL.path), .int64(sourceRowOrdinal)]
        )
        guard result.rowCount == 1 else {
            throw ParquetQueryError.queryFailed("The Parquet source row is no longer available.")
        }
        return ParquetStructuredCellDetail(
            sourceRowOrdinal: sourceRowOrdinal,
            column: columnIndex,
            json: result.hexDecodedString(column: 0, row: 0),
            isTruncated: (result.int64(column: 1, row: 0) ?? 0) != 0
        )
    }

    public func uniqueValues(
        forColumn columnIndex: Int,
        query: ParquetTableQuery = ParquetTableQuery()
    ) async throws -> ParquetUniqueValues {
        let metadata = try await open()
        guard metadata.columns.indices.contains(columnIndex) else {
            throw ParquetQueryError.invalidColumn(columnIndex)
        }
        // Match the CSV facet model: a column's value choices are calculated
        // under every other active filter, never narrowed by their own current
        // checkbox/contains state.
        let remainingFilters = query.filters.filter { $0.column != columnIndex }
        try validate(query: ParquetTableQuery(filters: remainingFilters), columns: metadata.columns)
        return try await queryUniqueValues(
            forColumn: columnIndex,
            filters: remainingFilters,
            columns: metadata.columns
        )
    }

    private func queryUniqueValues(
        forColumn columnIndex: Int,
        filters: [ParquetColumnFilter],
        columns: [ParquetColumn]
    ) async throws -> ParquetUniqueValues {
        let identifier = internalIdentifier(for: columnIndex)
        let text = "TRY_CAST(\(identifier) AS VARCHAR)"
        var bindings: [DuckDBBinding] = [.text(sourceURL.path)]
        let whereClause = buildWhereClause(
            filters,
            columns: columns,
            bindings: &bindings,
            additionalPredicate: "(\(identifier) IS NULL OR length(\(text)) <= \(limits.maximumFilterValueCharacters))"
        )
        bindings.append(.int64(Int64(limits.maximumUniqueValues + 1)))
        let sql = """
            SELECT CASE WHEN \(identifier) IS NULL THEN NULL ELSE hex(encode(\(text))) END AS value,
                   COUNT(*)::BIGINT AS frequency
            \(sourceClause())
            \(whereClause)
            GROUP BY 1
            ORDER BY frequency DESC, value ASC NULLS FIRST
            LIMIT ?
            """
        let result = try await execute(sql: sql, bindings: bindings)
        let isTruncated = result.rowCount > limits.maximumUniqueValues
        let retainedCount = min(result.rowCount, limits.maximumUniqueValues)
        var values: [ParquetUniqueValue] = []
        values.reserveCapacity(retainedCount)
        for row in 0..<retainedCount {
            let value: ParquetFilterValue = result.isNull(column: 0, row: row)
                ? .null
                : .text(result.hexDecodedString(column: 0, row: row) ?? "")
            values.append(ParquetUniqueValue(
                value: value,
                count: result.int64(column: 1, row: row) ?? 0
            ))
        }

        var oversizedBindings: [DuckDBBinding] = [.text(sourceURL.path)]
        let oversizedWhere = buildWhereClause(
            filters,
            columns: columns,
            bindings: &oversizedBindings,
            additionalPredicate: "(\(identifier) IS NOT NULL AND length(\(text)) > \(limits.maximumFilterValueCharacters))"
        )
        let oversizedSQL = "SELECT COUNT(*)::BIGINT \(sourceClause()) \(oversizedWhere)"
        let oversized = try await execute(
            sql: oversizedSQL,
            bindings: oversizedBindings
        ).int64(column: 0, row: 0) ?? 0
        return ParquetUniqueValues(
            values: values,
            isTruncated: isTruncated,
            omittedOversizedValueCount: oversized
        )
    }

    public func columnSummary(
        forColumn columnIndex: Int,
        query: ParquetTableQuery = ParquetTableQuery()
    ) async throws -> ParquetColumnSummary {
        let metadata = try await open()
        guard metadata.columns.indices.contains(columnIndex) else {
            throw ParquetQueryError.invalidColumn(columnIndex)
        }
        try validate(query: query, columns: metadata.columns)
        let column = metadata.columns[columnIndex]
        let identifier = internalIdentifier(for: columnIndex)
        let text = "TRY_CAST(\(identifier) AS VARCHAR)"
        let extrema: String
        if Self.supportsOrderedExtrema(typeName: column.typeName) {
            extrema = """
                hex(encode(left(TRY_CAST(MIN(\(identifier)) AS VARCHAR), \(limits.maximumCellCharacters)))) AS minimum,
                hex(encode(left(TRY_CAST(MAX(\(identifier)) AS VARCHAR), \(limits.maximumCellCharacters)))) AS maximum
                """
        } else {
            extrema = "NULL::VARCHAR AS minimum, NULL::VARCHAR AS maximum"
        }
        var bindings: [DuckDBBinding] = [.text(sourceURL.path)]
        let whereClause = buildWhereClause(
            query.filters,
            columns: metadata.columns,
            bindings: &bindings
        )
        let sql = """
            SELECT COUNT(*)::BIGINT AS row_count,
                   COUNT(*) FILTER (WHERE \(identifier) IS NULL)::BIGINT AS null_count,
                   COALESCE(approx_count_distinct(\(text)), 0)::BIGINT AS distinct_count,
                   \(extrema)
            \(sourceClause())
            \(whereClause)
            """
        let result = try await execute(sql: sql, bindings: bindings)
        let unique = try await queryUniqueValues(
            forColumn: columnIndex,
            filters: query.filters,
            columns: metadata.columns
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

    public func close() async {
        guard !isClosed else { return }
        isClosed = true
        interruptHandle.interrupt()
        await queryExecutor.runWithoutThrowing { [connectionStorage, interruptHandle] in
            // Detach under the interrupt lock before freeing the C handle, so
            // a late nonisolated cancellation can never observe a stale
            // DuckDB connection pointer during actor-continuation handoff.
            interruptHandle.setConnection(nil)
            connectionStorage.close()
        }
        metadataStorage = nil
        allColumnsStorage.removeAll(keepingCapacity: false)
        countCache.removeAll(keepingCapacity: false)
        securityScope.stop()
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    public nonisolated func cancelCurrentQuery() {
        interruptHandle.interrupt()
    }

    #if DEBUG
    /// Test-only probe for the per-document external-access allowlist.
    func testingCanReadParquet(at url: URL) async -> Bool {
        do {
            _ = try await execute(
                sql: "SELECT COUNT(*)::BIGINT FROM read_parquet(?)",
                bindings: [.text(url.standardizedFileURL.path)]
            )
            return true
        } catch {
            return false
        }
    }

    func testingCanExecuteSecurityProbe(_ sql: String) async -> Bool {
        do {
            _ = try await execute(sql: sql, bindings: [])
            return true
        } catch {
            return false
        }
    }

    func testingCanWriteTemporaryProbe() async -> Bool {
        let url = temporaryDirectory.appendingPathComponent("allowed-probe.parquet")
        defer { try? FileManager.default.removeItem(at: url) }
        let sql = "COPY (SELECT 1 AS value) TO \(Self.duckDBStringLiteral(url.path)) (FORMAT PARQUET)"
        return await testingCanExecuteSecurityProbe(sql)
    }

    func testingCancellationOwnershipIsAtomic() -> Bool {
        interruptHandle.testingQueuedCancellationNeverBegins()
            && interruptHandle.testingLateCancellationPreservesNewOwner()
    }
    #endif

    private func initializeDatabase() throws {
        guard connectionStorage.connection == nil else { return }
        let options: [(String, String)] = [
            ("threads", String(limits.workerThreads)),
            ("memory_limit", limits.memoryLimit),
            ("temp_directory", temporaryDirectory.path),
            ("max_temp_directory_size", limits.maximumTemporaryStorage),
            ("autoload_known_extensions", "false"),
            ("autoinstall_known_extensions", "false"),
            ("allow_community_extensions", "false"),
            ("allow_unsigned_extensions", "false"),
            ("enable_external_file_cache", "false"),
            ("enable_external_access", "true"),
            ("preserve_insertion_order", "true"),
        ]
        let handles = try runtime.openInMemory(options: options)
        do {
            // LIST-valued settings are not accepted by duckdb_set_config's
            // scalar C interface. Bootstrap them through trusted, fully escaped
            // statements, then close external access and lock configuration
            // before any selected-file query is prepared.
            _ = try runtime.execute(
                connection: handles.connection,
                sql: "SET allowed_paths = \(Self.duckDBListLiteral([sourceURL.path]))",
                bindings: []
            )
            _ = try runtime.execute(
                connection: handles.connection,
                sql: "SET allowed_directories = \(Self.duckDBListLiteral([temporaryDirectory.path]))",
                bindings: []
            )
            _ = try runtime.execute(
                connection: handles.connection,
                sql: "SET enable_external_access = false",
                bindings: []
            )
            _ = try runtime.execute(
                connection: handles.connection,
                sql: "SET lock_configuration = true",
                bindings: []
            )
        } catch {
            runtime.disconnect(handles.connection)
            runtime.close(handles.database)
            throw error
        }
        connectionStorage.install(database: handles.database, connection: handles.connection)
        interruptHandle.setConnection(handles.connection)
    }

    private func describeColumns() async throws -> [ParquetColumn] {
        // Validate only scalar lengths first. Returning unbounded schema
        // strings from DESCRIBE would otherwise let hostile metadata allocate
        // arbitrarily large DuckDB/Swift result buffers before validation.
        let lengthsSQL = """
            SELECT octet_length(encode(column_name))::BIGINT,
                   octet_length(encode(column_type))::BIGINT
            FROM (DESCRIBE SELECT * FROM read_parquet(?))
            LIMIT \(Limits.maximumPhysicalColumns + 1)
            """
        let lengths = try await execute(
            sql: lengthsSQL,
            bindings: [.text(sourceURL.path)]
        )
        guard lengths.rowCount <= Limits.maximumPhysicalColumns else {
            throw ParquetQueryError.malformedFile(
                "Its schema has more than \(Limits.maximumPhysicalColumns.formatted()) columns."
            )
        }
        var aggregateSchemaBytes = 0
        for row in 0..<lengths.rowCount {
            let nameBytes = Int(clamping: lengths.int64(column: 0, row: row) ?? 0)
            let typeBytes = Int(clamping: lengths.int64(column: 1, row: row) ?? 0)
            guard nameBytes <= Limits.maximumSchemaFieldUTF8Bytes,
                  typeBytes <= Limits.maximumSchemaFieldUTF8Bytes else {
                throw ParquetQueryError.malformedFile(
                    "A schema name or type exceeds the supported metadata size."
                )
            }
            let (rowBytes, rowOverflow) = nameBytes.addingReportingOverflow(typeBytes)
            let (newAggregate, aggregateOverflow) = aggregateSchemaBytes.addingReportingOverflow(rowBytes)
            guard !rowOverflow, !aggregateOverflow,
                  newAggregate <= Limits.maximumAggregateSchemaUTF8Bytes else {
                throw ParquetQueryError.malformedFile(
                    "Its schema metadata exceeds the supported size."
                )
            }
            aggregateSchemaBytes = newAggregate
        }

        // Repeat the bounds inside the value-producing statement. If the file
        // is replaced between the two snapshots, no newly oversized schema
        // string can cross the C result boundary before the row-count check.
        let sql = """
            WITH described AS (
                SELECT *,
                       octet_length(encode(column_name))::BIGINT AS name_bytes,
                       octet_length(encode(column_type))::BIGINT AS type_bytes
                FROM (DESCRIBE SELECT * FROM read_parquet(?))
            ), bounded AS (
                SELECT *,
                       SUM(name_bytes + type_bytes) OVER () AS total_schema_bytes
                FROM described
            )
            SELECT hex(encode(column_name)),
                   hex(encode(column_type)),
                   hex(encode(\"null\"))
            FROM bounded
            WHERE name_bytes <= \(Limits.maximumSchemaFieldUTF8Bytes)
              AND type_bytes <= \(Limits.maximumSchemaFieldUTF8Bytes)
              AND total_schema_bytes <= \(Limits.maximumAggregateSchemaUTF8Bytes)
            LIMIT \(Limits.maximumPhysicalColumns + 1)
            """
        let result = try await execute(
            sql: sql,
            bindings: [.text(sourceURL.path)]
        )
        guard result.rowCount == lengths.rowCount else {
            throw ParquetQueryError.malformedFile(
                "Its schema changed while it was being opened."
            )
        }
        var columns: [ParquetColumn] = []
        columns.reserveCapacity(result.rowCount)
        for row in 0..<result.rowCount {
            guard let name = result.hexDecodedString(column: 0, row: row),
                  let typeName = result.hexDecodedString(column: 1, row: row) else { continue }
            let nullableText = result.hexDecodedString(column: 2, row: row) ?? "YES"
            columns.append(ParquetColumn(
                index: columns.count,
                name: name,
                typeName: typeName,
                isNullable: nullableText.caseInsensitiveCompare("NO") != .orderedSame
            ))
        }
        return columns
    }

    private func countRows(query: ParquetTableQuery) async throws -> Int64 {
        let columns = metadataStorage?.columns ?? Array(allColumnsStorage.prefix(limits.maximumPresentedColumns))
        try validate(query: query, columns: columns)
        var bindings: [DuckDBBinding] = [.text(sourceURL.path)]
        let whereClause = buildWhereClause(query.filters, columns: columns, bindings: &bindings)
        let sql = "SELECT COUNT(*)::BIGINT \(sourceClause()) \(whereClause)"
        let result = try await execute(
            sql: sql,
            bindings: bindings
        )
        return result.int64(column: 0, row: 0) ?? 0
    }

    private func validate(query: ParquetTableQuery, columns: [ParquetColumn]) throws {
        guard query.filters.count <= columns.count else {
            throw ParquetQueryError.invalidFilter("Too many column filters were supplied.")
        }
        guard Set(query.filters.map(\.column)).count == query.filters.count else {
            throw ParquetQueryError.invalidFilter("Each column can have only one filter.")
        }
        var aggregateBytes = 0
        var aggregateSelectedValues = 0
        for filter in query.filters {
            guard columns.indices.contains(filter.column) else {
                throw ParquetQueryError.invalidColumn(filter.column)
            }
            guard filter.containsText.utf8.count <= limits.maximumFilterValueCharacters else {
                throw ParquetQueryError.invalidFilter("Contains text exceeds the supported length.")
            }
            guard filter.selectedValues.count <= limits.maximumSelectedValuesPerColumn else {
                throw ParquetQueryError.invalidFilter("Too many values are selected in one column.")
            }
            aggregateSelectedValues += filter.selectedValues.count
            aggregateBytes += filter.containsText.utf8.count
            guard aggregateBytes <= Limits.maximumAggregateFilterBytes else {
                throw ParquetQueryError.invalidFilter("Combined filter text exceeds the supported size.")
            }
            for value in filter.selectedValues {
                if case let .text(text) = value,
                   text.utf8.count > limits.maximumFilterValueCharacters {
                    throw ParquetQueryError.invalidFilter("A selected value exceeds the supported length.")
                }
                if case let .text(text) = value { aggregateBytes += text.utf8.count }
                guard aggregateBytes <= Limits.maximumAggregateFilterBytes else {
                    throw ParquetQueryError.invalidFilter("Combined filter text exceeds the supported size.")
                }
            }
        }
        guard aggregateSelectedValues <= Limits.maximumAggregateSelectedValues else {
            throw ParquetQueryError.invalidFilter("Too many values are selected across all columns.")
        }
        if let sort = query.sort, !columns.indices.contains(sort.column) {
            throw ParquetQueryError.invalidColumn(sort.column)
        }
    }

    private func buildWhereClause(
        _ filters: [ParquetColumnFilter],
        columns: [ParquetColumn],
        bindings: inout [DuckDBBinding],
        additionalPredicate: String? = nil
    ) -> String {
        var predicates: [String] = []
        for filter in filters where columns.indices.contains(filter.column) && !filter.isEmpty {
            let identifier = internalIdentifier(for: filter.column)
            let text = "TRY_CAST(\(identifier) AS VARCHAR)"
            if !filter.containsText.isEmpty {
                if filter.containsCaseSensitive {
                    predicates.append("contains(COALESCE(\(text), ''), ?)")
                } else {
                    predicates.append("contains(lower(COALESCE(\(text), '')), lower(?))")
                }
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
        if let additionalPredicate { predicates.append(additionalPredicate) }
        return predicates.isEmpty ? "" : "WHERE " + predicates.joined(separator: " AND ")
    }

    private func buildOrderClause(
        _ sort: ParquetSortDescriptor?,
        columns: [ParquetColumn]
    ) -> String {
        let rowIdentifier = Self.quoteIdentifier(Self.rowOrdinalAlias)
        guard let sort, columns.indices.contains(sort.column) else {
            return "ORDER BY \(rowIdentifier) ASC"
        }
        let identifier = internalIdentifier(for: sort.column)
        let direction = sort.order == .ascending ? "ASC" : "DESC"
        return "ORDER BY \(identifier) \(direction) NULLS LAST, \(rowIdentifier) ASC"
    }

    private func displayProjection(column: ParquetColumn, characterLimit: Int) -> String {
        let identifier = internalIdentifier(for: column.index)
        let outputName = Self.quoteIdentifier(column.name)
        let text = "TRY_CAST(\(identifier) AS VARCHAR)"
        return """
            CASE WHEN \(identifier) IS NULL THEN NULL
                 WHEN length(\(text)) > \(characterLimit)
                 THEN hex(encode(left(\(text), \(characterLimit))))
                 ELSE hex(encode(\(text)))
            END AS \(outputName),
            CASE WHEN \(identifier) IS NOT NULL AND length(\(text)) > \(characterLimit)
                 THEN 1::BIGINT ELSE 0::BIGINT
            END AS \(Self.quoteIdentifier("__lightxt_truncated_\(column.index)"))
            """
    }

    private func sourceClause() -> String {
        let aliases = allColumnsStorage.indices.map(Self.internalColumnAlias)
            + [Self.rowOrdinalAlias]
        let aliasedColumns = aliases.map(Self.quoteIdentifier).joined(separator: ", ")
        if allColumnsStorage.contains(where: {
            $0.name.caseInsensitiveCompare("file_row_number") == .orderedSame
        }) {
            // DuckDB rejects file_row_number=true when the physical schema has
            // that name. Parquet scans preserve file order, so capture it in a
            // window before filters and aliases are applied.
            return "FROM (SELECT *, row_number() OVER () - 1 AS __lightxt_source_row FROM read_parquet(?)) " +
                "AS parquet_source(\(aliasedColumns))"
        }
        return "FROM read_parquet(?, file_row_number = true) AS parquet_source(\(aliasedColumns))"
    }

    private func internalIdentifier(for columnIndex: Int) -> String {
        Self.quoteIdentifier(Self.internalColumnAlias(columnIndex))
    }

    private func requiredConnection() throws -> OpaquePointer {
        try ensureOpen()
        guard let connection = connectionStorage.connection else { throw ParquetQueryError.closed }
        return connection
    }

    private func ensureOpen() throws {
        if Task.isCancelled { throw ParquetQueryError.cancelled }
        if isClosed { throw ParquetQueryError.closed }
    }

    private func execute(sql: String, bindings: [DuckDBBinding]) async throws -> DuckDBResult {
        try ensureOpen()
        _ = try requiredConnection()
        let runtime = runtime
        let executor = queryExecutor
        let connectionStorage = connectionStorage
        let interruptHandle = interruptHandle
        let requestID = interruptHandle.registerRequest()
        return try await withTaskCancellationHandler {
            let value = try await executor.run {
                guard interruptHandle.beginRequest(requestID) else {
                    throw ParquetQueryError.cancelled
                }
                defer { interruptHandle.finishRequest(requestID) }
                guard let connection = connectionStorage.connection else {
                    throw ParquetQueryError.closed
                }
                return try runtime.execute(connection: connection, sql: sql, bindings: bindings)
            }
            if Task.isCancelled { throw ParquetQueryError.cancelled }
            return value
        } onCancel: {
            interruptHandle.cancelRequest(requestID)
        }
    }

    private static func validateParquetEnvelope(at url: URL) throws {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ParquetQueryError.malformedFile(error.localizedDescription)
        }
        defer { try? handle.close() }
        do {
            let length = try handle.seekToEnd()
            guard length >= 12 else {
                throw ParquetQueryError.malformedFile("The file is too short to contain a Parquet footer.")
            }
            try handle.seek(toOffset: 0)
            let first = try handle.read(upToCount: 4) ?? Data()
            try handle.seek(toOffset: length - 4)
            let last = try handle.read(upToCount: 4) ?? Data()
            let magic = Data("PAR1".utf8)
            guard first == magic, last == magic else {
                throw ParquetQueryError.malformedFile("Its PAR1 header or footer marker is missing.")
            }
        } catch let error as ParquetQueryError {
            throw error
        } catch {
            throw ParquetQueryError.malformedFile(error.localizedDescription)
        }
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let fileManager = FileManager.default
        let cacheRoot = try? fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let roots = [cacheRoot, fileManager.temporaryDirectory].compactMap { $0 }
        var lastError: Error?
        for root in roots {
            let directory = root
                .appendingPathComponent("LighTxt", isDirectory: true)
                .appendingPathComponent("ParquetTemp", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                return directory
            } catch {
                lastError = error
            }
        }
        throw lastError ?? ParquetQueryError.queryFailed("A private temporary directory could not be created.")
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

    private static func internalColumnAlias(_ index: Int) -> String {
        "__lightxt_parquet_column_\(index)"
    }

    private static func supportsOrderedExtrema(typeName: String) -> Bool {
        let upper = typeName.uppercased()
        let unsupportedPrefixes = ["BLOB", "LIST", "MAP", "STRUCT", "UNION"]
        return !unsupportedPrefixes.contains { upper.hasPrefix($0) }
            && !upper.contains("[]")
    }

    private static let rowOrdinalAlias = "__lightxt_parquet_file_row"

}

private nonisolated enum DuckDBBinding: Sendable {
    case text(String)
    case int64(Int64)
}

private nonisolated final class SecurityScopedAccess: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var isActive: Bool

    init(url: URL) {
        self.url = url
        self.isActive = url.startAccessingSecurityScopedResource()
    }

    deinit { stop() }

    func stop() {
        let shouldStop = lock.withLock { () -> Bool in
            guard isActive else { return false }
            isActive = false
            return true
        }
        if shouldStop { url.stopAccessingSecurityScopedResource() }
    }
}

private nonisolated final class DuckDBSerialExecutor: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.lightxt.parquet.duckdb-query",
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

private nonisolated final class DuckDBConnectionStorage: @unchecked Sendable {
    private let lock = NSLock()
    private let runtime: DuckDBDynamicAPI
    private var databaseStorage: OpaquePointer?
    private var connectionStorage: OpaquePointer?

    init(runtime: DuckDBDynamicAPI) {
        self.runtime = runtime
    }

    deinit { close() }

    var connection: OpaquePointer? {
        lock.withLock { connectionStorage }
    }

    func install(database: OpaquePointer, connection: OpaquePointer) {
        lock.withLock {
            precondition(databaseStorage == nil && connectionStorage == nil)
            databaseStorage = database
            connectionStorage = connection
        }
    }

    func close() {
        lock.withLock {
            if let connectionStorage { runtime.disconnect(connectionStorage) }
            if let databaseStorage { runtime.close(databaseStorage) }
            connectionStorage = nil
            databaseStorage = nil
        }
    }
}

private nonisolated final class ParquetInterruptHandle: @unchecked Sendable {
    private enum RequestState { case queued, active, cancelled }

    private let lock = NSLock()
    private let runtime: DuckDBDynamicAPI
    private var connection: OpaquePointer?
    private var requestStates: [UUID: RequestState] = [:]
    private var activeRequestID: UUID?
    #if DEBUG
    private var testingInterruptCount = 0
    #endif

    init(runtime: DuckDBDynamicAPI) {
        self.runtime = runtime
    }

    func setConnection(_ connection: OpaquePointer?) {
        lock.withLock { self.connection = connection }
    }

    func registerRequest() -> UUID {
        lock.withLock {
            let id = UUID()
            requestStates[id] = .queued
            return id
        }
    }

    func beginRequest(_ id: UUID) -> Bool {
        lock.withLock {
            switch requestStates[id] {
            case .queued:
                precondition(activeRequestID == nil, "DuckDB requests must execute serially")
                requestStates[id] = .active
                activeRequestID = id
                return true
            case .cancelled:
                requestStates[id] = nil
                return false
            case .active, .none:
                return false
            }
        }
    }

    func finishRequest(_ id: UUID) {
        lock.withLock {
            if activeRequestID == id { activeRequestID = nil }
            requestStates[id] = nil
        }
    }

    func cancelRequest(_ id: UUID) {
        lock.withLock {
            switch requestStates[id] {
            case .queued:
                requestStates[id] = .cancelled
            case .active:
                requestStates[id] = .cancelled
                if activeRequestID == id, let connection {
                    #if DEBUG
                    testingInterruptCount += 1
                    #endif
                    runtime.interrupt(connection)
                }
            case .cancelled, .none:
                break
            }
        }
    }

    func interrupt() {
        lock.withLock {
            if let activeRequestID {
                requestStates[activeRequestID] = .cancelled
            }
            if let connection {
                #if DEBUG
                testingInterruptCount += 1
                #endif
                runtime.interrupt(connection)
            }
        }
    }

    #if DEBUG
    /// Deterministically exercises the old late-cancellation race: request A
    /// finishes, request B becomes active, then A's cancellation arrives.
    /// Atomic ownership must ensure A cannot interrupt B.
    func testingLateCancellationPreservesNewOwner() -> Bool {
        let first = registerRequest()
        guard beginRequest(first) else { return false }
        finishRequest(first)
        let second = registerRequest()
        guard beginRequest(second) else { return false }
        let interruptsBefore = lock.withLock { testingInterruptCount }
        cancelRequest(first)
        let preserved = lock.withLock {
            activeRequestID == second && testingInterruptCount == interruptsBefore
        }
        finishRequest(second)
        return preserved
    }

    func testingQueuedCancellationNeverBegins() -> Bool {
        let request = registerRequest()
        cancelRequest(request)
        return !beginRequest(request)
    }
    #endif
}

/// Minimal dynamically loaded DuckDB C surface. LighTxt intentionally avoids
/// linking the much older eager Swift wrapper and does not expose SQL to UI.
private nonisolated final class DuckDBDynamicAPI: @unchecked Sendable {
    private typealias State = Int32
    private typealias CreateConfig = @convention(c) (UnsafeMutablePointer<OpaquePointer?>?) -> State
    private typealias SetConfig = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> State
    private typealias DestroyConfig = @convention(c) (UnsafeMutablePointer<OpaquePointer?>?) -> Void
    private typealias OpenExt = @convention(c) (
        UnsafePointer<CChar>?, UnsafeMutablePointer<OpaquePointer?>?, OpaquePointer?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
    ) -> State
    private typealias Close = @convention(c) (UnsafeMutablePointer<OpaquePointer?>?) -> Void
    private typealias Connect = @convention(c) (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> State
    private typealias Disconnect = @convention(c) (UnsafeMutablePointer<OpaquePointer?>?) -> Void
    private typealias Interrupt = @convention(c) (OpaquePointer?) -> Void
    private typealias Prepare = @convention(c) (
        OpaquePointer?, UnsafePointer<CChar>?, UnsafeMutablePointer<OpaquePointer?>?
    ) -> State
    private typealias PrepareError = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?
    private typealias DestroyPrepare = @convention(c) (UnsafeMutablePointer<OpaquePointer?>?) -> Void
    private typealias BindVarcharLength = @convention(c) (
        OpaquePointer?, UInt64, UnsafePointer<CChar>?, UInt64
    ) -> State
    private typealias BindInt64 = @convention(c) (OpaquePointer?, UInt64, Int64) -> State
    private typealias ExecutePrepared = @convention(c) (OpaquePointer?, UnsafeMutableRawPointer?) -> State
    private typealias DestroyResult = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias ResultError = @convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?
    private typealias ColumnCount = @convention(c) (UnsafeMutableRawPointer?) -> UInt64
    private typealias RowCount = @convention(c) (UnsafeMutableRawPointer?) -> UInt64
    private typealias ValueIsNull = @convention(c) (UnsafeMutableRawPointer?, UInt64, UInt64) -> Bool
    private typealias ValueVarchar = @convention(c) (
        UnsafeMutableRawPointer?, UInt64, UInt64
    ) -> UnsafeMutablePointer<CChar>?
    private typealias ValueInt64 = @convention(c) (UnsafeMutableRawPointer?, UInt64, UInt64) -> Int64
    private typealias Free = @convention(c) (UnsafeMutableRawPointer?) -> Void
    private typealias LibraryVersion = @convention(c) () -> UnsafePointer<CChar>?

    private let libraryHandle: UnsafeMutableRawPointer
    private let createConfig: CreateConfig
    private let setConfig: SetConfig
    private let destroyConfig: DestroyConfig
    private let openExt: OpenExt
    private let closeDatabase: Close
    private let connectDatabase: Connect
    private let disconnectDatabase: Disconnect
    private let interruptConnection: Interrupt
    private let prepareQuery: Prepare
    private let prepareError: PrepareError
    private let destroyPrepared: DestroyPrepare
    private let bindVarcharLength: BindVarcharLength
    private let bindInt64: BindInt64
    private let executePrepared: ExecutePrepared
    private let destroyResult: DestroyResult
    private let resultError: ResultError
    private let columnCount: ColumnCount
    private let rowCount: RowCount
    private let valueIsNull: ValueIsNull
    private let valueVarchar: ValueVarchar
    private let valueInt64: ValueInt64
    private let freeValue: Free
    let version: String

    init(libraryURL explicitURL: URL?) throws {
        let libraryURL = try Self.resolveLibraryURL(explicitURL)
        guard let handle = dlopen(libraryURL.path, RTLD_NOW | RTLD_LOCAL) else {
            let reason = dlerror().map { String(cString: $0) } ?? "Unknown dynamic-loader error."
            throw ParquetQueryError.runtimeUnavailable(reason)
        }
        self.libraryHandle = handle
        do {
            self.createConfig = try Self.symbol("duckdb_create_config", in: handle)
            self.setConfig = try Self.symbol("duckdb_set_config", in: handle)
            self.destroyConfig = try Self.symbol("duckdb_destroy_config", in: handle)
            self.openExt = try Self.symbol("duckdb_open_ext", in: handle)
            self.closeDatabase = try Self.symbol("duckdb_close", in: handle)
            self.connectDatabase = try Self.symbol("duckdb_connect", in: handle)
            self.disconnectDatabase = try Self.symbol("duckdb_disconnect", in: handle)
            self.interruptConnection = try Self.symbol("duckdb_interrupt", in: handle)
            self.prepareQuery = try Self.symbol("duckdb_prepare", in: handle)
            self.prepareError = try Self.symbol("duckdb_prepare_error", in: handle)
            self.destroyPrepared = try Self.symbol("duckdb_destroy_prepare", in: handle)
            self.bindVarcharLength = try Self.symbol("duckdb_bind_varchar_length", in: handle)
            self.bindInt64 = try Self.symbol("duckdb_bind_int64", in: handle)
            self.executePrepared = try Self.symbol("duckdb_execute_prepared", in: handle)
            self.destroyResult = try Self.symbol("duckdb_destroy_result", in: handle)
            self.resultError = try Self.symbol("duckdb_result_error", in: handle)
            self.columnCount = try Self.symbol("duckdb_column_count", in: handle)
            self.rowCount = try Self.symbol("duckdb_row_count", in: handle)
            self.valueIsNull = try Self.symbol("duckdb_value_is_null", in: handle)
            self.valueVarchar = try Self.symbol("duckdb_value_varchar", in: handle)
            self.valueInt64 = try Self.symbol("duckdb_value_int64", in: handle)
            self.freeValue = try Self.symbol("duckdb_free", in: handle)
            let versionFunction: LibraryVersion = try Self.symbol("duckdb_library_version", in: handle)
            self.version = versionFunction().map { String(cString: $0) } ?? "unknown"
        } catch {
            dlclose(handle)
            throw error
        }
        guard version == ParquetQueryService.requiredDuckDBVersion else {
            dlclose(handle)
            throw ParquetQueryError.incompatibleRuntime(
                expected: ParquetQueryService.requiredDuckDBVersion,
                actual: version
            )
        }
    }

    deinit { dlclose(libraryHandle) }

    func openInMemory(options: [(String, String)]) throws -> (database: OpaquePointer, connection: OpaquePointer) {
        var config: OpaquePointer?
        guard createConfig(&config) == 0, config != nil else {
            throw ParquetQueryError.queryFailed("DuckDB could not create a secure configuration.")
        }
        defer { destroyConfig(&config) }
        for (name, value) in options {
            let state = name.withCString { namePointer in
                value.withCString { valuePointer in
                    setConfig(config, namePointer, valuePointer)
                }
            }
            guard state == 0 else {
                throw ParquetQueryError.queryFailed("DuckDB rejected the \(name) safety setting.")
            }
        }

        var database: OpaquePointer?
        var openError: UnsafeMutablePointer<CChar>?
        let state = openExt(nil, &database, config, &openError)
        defer { if let openError { freeValue(openError) } }
        guard state == 0, let database else {
            let reason = openError.map { String(cString: $0) } ?? "The in-memory database could not be opened."
            throw ParquetQueryError.queryFailed(reason)
        }
        var connection: OpaquePointer?
        guard connectDatabase(database, &connection) == 0, let connection else {
            var mutableDatabase: OpaquePointer? = database
            closeDatabase(&mutableDatabase)
            throw ParquetQueryError.queryFailed("DuckDB could not create a read-only Parquet connection.")
        }
        return (database, connection)
    }

    func close(_ database: OpaquePointer) {
        var handle: OpaquePointer? = database
        closeDatabase(&handle)
    }

    func disconnect(_ connection: OpaquePointer) {
        var handle: OpaquePointer? = connection
        disconnectDatabase(&handle)
    }

    func interrupt(_ connection: OpaquePointer) {
        interruptConnection(connection)
    }

    func execute(
        connection: OpaquePointer,
        sql: String,
        bindings: [DuckDBBinding]
    ) throws -> DuckDBResult {
        if Task.isCancelled { throw ParquetQueryError.cancelled }
        var statement: OpaquePointer?
        let prepareState = sql.withCString { prepareQuery(connection, $0, &statement) }
        guard prepareState == 0, let statement else {
            let reason = prepareError(statement).map { String(cString: $0) } ?? "The query could not be prepared."
            var failedStatement: OpaquePointer? = statement
            destroyPrepared(&failedStatement)
            throw ParquetQueryError.queryFailed(reason)
        }
        defer {
            var mutable: OpaquePointer? = statement
            destroyPrepared(&mutable)
        }
        for (offset, binding) in bindings.enumerated() {
            let index = UInt64(offset + 1)
            let state: State
            switch binding {
            case let .text(value):
                state = value.withCString {
                    bindVarcharLength(statement, index, $0, UInt64(value.utf8.count))
                }
            case let .int64(value):
                state = bindInt64(statement, index, value)
            }
            guard state == 0 else {
                throw ParquetQueryError.queryFailed("A safe Parquet query parameter could not be bound.")
            }
        }

        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: DuckDBResult.storageByteCount,
            alignment: MemoryLayout<UInt64>.alignment
        )
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: DuckDBResult.storageByteCount)
        let executeState = executePrepared(statement, storage)
        guard executeState == 0 else {
            let reason = resultError(storage).map { String(cString: $0) } ?? "DuckDB returned an unknown error."
            destroyResult(storage)
            storage.deallocate()
            if Task.isCancelled || reason.localizedCaseInsensitiveContains("interrupt") {
                throw ParquetQueryError.cancelled
            }
            throw ParquetQueryError.queryFailed(reason)
        }
        return DuckDBResult(
            storage: storage,
            columnCount: Int(columnCount(storage)),
            rowCount: Int(rowCount(storage)),
            isNull: valueIsNull,
            varchar: valueVarchar,
            int64: valueInt64,
            freeValue: freeValue,
            destroy: destroyResult
        )
    }

    private static func resolveLibraryURL(_ explicitURL: URL?) throws -> URL {
        let candidates: [URL?] = [
            explicitURL,
            ProcessInfo.processInfo.environment["LIGHTXT_DUCKDB_LIBRARY_PATH"].map {
                URL(fileURLWithPath: $0)
            },
            Bundle.main.privateFrameworksURL?.appendingPathComponent("libduckdb.dylib"),
        ]
        if let url = candidates.compactMap({ $0 }).first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) {
            return url
        }
        throw ParquetQueryError.runtimeUnavailable("libduckdb.dylib is missing from the app bundle.")
    }

    private static func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer) throws -> T {
        let pointer = try rawSymbol(name, in: handle)
        return unsafeBitCast(pointer, to: T.self)
    }

    private static func rawSymbol(
        _ name: String,
        in handle: UnsafeMutableRawPointer
    ) throws -> UnsafeMutableRawPointer {
        guard let pointer = dlsym(handle, name) else {
            throw ParquetQueryError.runtimeUnavailable("The DuckDB symbol \(name) is unavailable.")
        }
        return pointer
    }
}

private nonisolated final class DuckDBResult: @unchecked Sendable {
    /// DuckDB 1.4.5's public `duckdb_result` contains three `idx_t` values and
    /// three pointers on every supported 64-bit macOS architecture.
    static let storageByteCount = 6 * MemoryLayout<UInt64>.size

    fileprivate typealias IsNull = @convention(c) (UnsafeMutableRawPointer?, UInt64, UInt64) -> Bool
    fileprivate typealias Varchar = @convention(c) (
        UnsafeMutableRawPointer?, UInt64, UInt64
    ) -> UnsafeMutablePointer<CChar>?
    fileprivate typealias Int64Value = @convention(c) (UnsafeMutableRawPointer?, UInt64, UInt64) -> Int64
    fileprivate typealias Free = @convention(c) (UnsafeMutableRawPointer?) -> Void
    fileprivate typealias Destroy = @convention(c) (UnsafeMutableRawPointer?) -> Void

    private let storage: UnsafeMutableRawPointer
    let columnCount: Int
    let rowCount: Int
    private let nullFunction: IsNull
    private let varcharFunction: Varchar
    private let int64Function: Int64Value
    private let freeFunction: Free
    private let destroyFunction: Destroy

    init(
        storage: UnsafeMutableRawPointer,
        columnCount: Int,
        rowCount: Int,
        isNull: @escaping IsNull,
        varchar: @escaping Varchar,
        int64: @escaping Int64Value,
        freeValue: @escaping Free,
        destroy: @escaping Destroy
    ) {
        self.storage = storage
        self.columnCount = columnCount
        self.rowCount = rowCount
        self.nullFunction = isNull
        self.varcharFunction = varchar
        self.int64Function = int64
        self.freeFunction = freeValue
        self.destroyFunction = destroy
    }

    deinit {
        destroyFunction(storage)
        storage.deallocate()
    }

    func isNull(column: Int, row: Int) -> Bool {
        guard column >= 0, column < columnCount, row >= 0, row < rowCount else { return true }
        return nullFunction(storage, UInt64(column), UInt64(row))
    }

    func string(column: Int, row: Int) -> String? {
        guard !isNull(column: column, row: row),
              let pointer = varcharFunction(storage, UInt64(column), UInt64(row)) else { return nil }
        defer { freeFunction(pointer) }
        return String(cString: pointer)
    }

    func hexDecodedString(column: Int, row: Int) -> String? {
        guard let hex = string(column: column, row: row) else { return nil }
        guard hex.utf8.count.isMultiple(of: 2) else { return nil }
        var data = Data(capacity: hex.utf8.count / 2)
        var highNibble: UInt8?
        for byte in hex.utf8 {
            let nibble: UInt8
            switch byte {
            case 48...57: nibble = byte - 48
            case 65...70: nibble = byte - 55
            case 97...102: nibble = byte - 87
            default: return nil
            }
            if let high = highNibble {
                data.append((high << 4) | nibble)
                highNibble = nil
            } else {
                highNibble = nibble
            }
        }
        return String(decoding: data, as: UTF8.self)
    }

    func int64(column: Int, row: Int) -> Int64? {
        guard !isNull(column: column, row: row) else { return nil }
        return int64Function(storage, UInt64(column), UInt64(row))
    }
}
