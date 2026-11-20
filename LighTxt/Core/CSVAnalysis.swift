import Foundation
import SQLite3

/// The producer calls the visitor serially, with values in the requested column order.
/// A nil selection means every filtered row. Selected indexes address the displayed sort order.
typealias CSVAnalysisScan = @Sendable (
    _ columns: [Int], _ rows: IndexSet?,
    _ visit: @escaping @Sendable ([String?]) throws -> Void
) async throws -> Void

nonisolated struct CSVAnalysisField: Hashable, Sendable, Identifiable {
    let id: Int
    let name: String
}

nonisolated struct CSVAnalysisError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private nonisolated struct NumericSummary {
    var count: Int64 = 0
    var sum = 0.0
    private var correction = 0.0
    var mean = 0.0
    var minimum = Double.infinity
    var maximum = -Double.infinity

    mutating func add(_ value: Double) {
        count += 1
        let next = sum + value
        if next.isFinite {
            correction += abs(sum) >= abs(value) ? (sum - next) + value : (value - next) + sum
        }
        sum = next
        let difference = value - mean
        mean = difference.isFinite ? mean + difference / Double(count)
            : mean * (Double(count - 1) / Double(count)) + value / Double(count)
        minimum = min(minimum, value)
        maximum = max(maximum, value)
    }

    var total: Double { sum + correction }
}

/// Small selections stay in memory. SQLite's private, automatically deleted temporary
/// database lets the exact middle order statistics be computed for much larger ranges.
private nonisolated final class SelectionMedian {
    let memoryLimit: Int
    var values: [Double] = []
    var db: OpaquePointer?
    var insert: OpaquePointer?

    init(memoryLimit: Int) { self.memoryLimit = memoryLimit }
    deinit { sqlite3_finalize(insert); sqlite3_close(db) }

    func add(_ value: Double) throws {
        if db == nil && values.count < memoryLimit {
            values.append(value)
            return
        }
        if db == nil {
            guard sqlite3_open("", &db) == SQLITE_OK,
                  sqlite3_exec(db, "PRAGMA temp_store=FILE; CREATE TABLE nums(v REAL); BEGIN", nil, nil, nil) == SQLITE_OK,
                  sqlite3_prepare_v2(db, "INSERT INTO nums VALUES(?)", -1, &insert, nil) == SQLITE_OK
            else { throw failure() }
            sqlite3_progress_handler(db, 4096, { _ in Task.isCancelled ? 1 : 0 }, nil)
            for number in values { try appendToDisk(number) }
            values.removeAll(keepingCapacity: false)
        }
        try appendToDisk(value)
    }

    private func appendToDisk(_ number: Double) throws {
        sqlite3_reset(insert)
        guard sqlite3_bind_double(insert, 1, number) == SQLITE_OK,
              sqlite3_step(insert) == SQLITE_DONE else { throw failure() }
    }

    func middle(count: Int64) throws -> Double? {
        guard count > 0 else { return nil }
        let low = (count - 1) / 2, high = count / 2
        func midpoint(_ a: Double, _ b: Double) -> Double {
            let sum = a + b
            return sum.isFinite ? sum / 2 : a / 2 + b / 2
        }
        guard let db else {
            values.sort()
            return midpoint(values[Int(low)], values[Int(high)])
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK,
              sqlite3_prepare_v2(db, "SELECT v FROM nums ORDER BY v LIMIT ? OFFSET ?", -1, &statement, nil) == SQLITE_OK,
              sqlite3_bind_int64(statement, 1, high - low + 1) == SQLITE_OK,
              sqlite3_bind_int64(statement, 2, low) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        let first = sqlite3_column_double(statement, 0)
        if low == high { return first }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw failure() }
        return midpoint(first, sqlite3_column_double(statement, 0))
    }

    private func failure() -> Error {
        if Task.isCancelled { return CancellationError() }
        return CSVAnalysisError("Could not calculate the median: " + String(cString: sqlite3_errmsg(db)))
    }
}

nonisolated struct CSVCellStatistics: Sendable {
    var cells: Int64 = 0
    var filled: Int64 = 0
    var numeric: Int64 = 0
    var sum: Double?
    var average: Double?
    var median: Double?
    var minimum: Double?
    var maximum: Double?

    @concurrent static func calculate(columns: [Int], rows: IndexSet, scan: CSVAnalysisScan,
                          medianMemoryLimit: Int = 65_536) async throws -> Self {
        // Each scan owns one serial accumulator, including when the producer uses a worker queue.
        final class Accumulator: @unchecked Sendable {
            var result = CSVCellStatistics()
            var numbers = NumericSummary()
            let median: SelectionMedian
            init(_ limit: Int) { median = SelectionMedian(memoryLimit: limit) }
        }
        let state = Accumulator(medianMemoryLimit)
        try await scan(columns, rows) { values in
            try Task.checkCancellation()
            for value in values {
                state.result.cells += 1
                if let value, !value.isEmpty { state.result.filled += 1 }
                if let n = CSVNumericValue.parse(value) { state.numbers.add(n); try state.median.add(n) }
            }
        }
        let numbers = state.numbers
        if numbers.count > 0 {
            state.result.numeric = numbers.count
            state.result.sum = numbers.total
            state.result.average = numbers.total.isFinite ? numbers.total / Double(numbers.count) : numbers.mean
            state.result.minimum = numbers.minimum
            state.result.maximum = numbers.maximum
            state.result.median = try state.median.middle(count: numbers.count)
        }
        return state.result
    }
}

nonisolated enum PivotOperation: String, CaseIterable, Sendable {
    case rows = "Count rows", count = "Count values", sum = "Sum", average = "Average", min = "Minimum", max = "Maximum"
}

nonisolated struct PivotMetric: Hashable, Sendable {
    var operation: PivotOperation
    var field: Int
}

nonisolated enum PivotDisplay: String, CaseIterable, Sendable {
    case table = "Pivot table", bar = "Bar", line = "Line", scatter = "Scatter"

    static func available(dimensions: Int, metrics: Int) -> [Self] {
        guard metrics > 0 else { return [] }
        var options: [Self] = [.table]
        if dimensions == 1 || (dimensions == 2 && metrics == 1) { options += [.bar, .line] }
        if (1...2).contains(dimensions) && metrics == 2 { options.append(.scatter) }
        return options
    }
}

nonisolated struct PivotRow: Sendable, Identifiable {
    let dimensions: [String]
    let values: [Double?]
    var id: [String] { dimensions }
}

nonisolated struct CSVPivotResult: Sendable {
    let recordCount: Int64
    let rows: [PivotRow]

    @concurrent static func calculate(dimensions: [Int], metrics: [PivotMetric], scan: CSVAnalysisScan,
                                      knownRowCount: Int64? = nil) async throws -> Self {
        guard !metrics.isEmpty, metrics.count <= 8, dimensions.count <= 2,
              Set(dimensions).count == dimensions.count else {
            throw CSVAnalysisError("Choose up to two different dimensions and one to eight metrics.")
        }
        try Task.checkCancellation()
        if let count = knownRowCount, count >= 0, dimensions.isEmpty,
           metrics.allSatisfy({ $0.operation == .rows }) {
            return Self(recordCount: count, rows: [PivotRow(dimensions: [], values: metrics.map { _ in Double(count) })])
        }
        let fields = Array(Set(dimensions + metrics.filter { $0.operation != .rows }.map(\.field))).sorted()
        let offsets = Dictionary(uniqueKeysWithValues: fields.enumerated().map { ($1, $0) })
        let dims = dimensions.compactMap { offsets[$0] }
        let metricOffsets = metrics.map { offsets[$0.field] }
        final class Groups: @unchecked Sendable {
            var values: [[String]: [NumericSummary]] = [:]
            var rowCount: Int64 = 0
            var labelBytes = 0
        }
        let groups = Groups()
        let empty = Array(repeating: NumericSummary(), count: metrics.count)
        if dims.isEmpty { groups.values[[]] = empty }
        try await scan(fields, nil) { row in
            try Task.checkCancellation()
            let key = dims.map { row[$0] ?? "" }
            if groups.values[key] == nil {
                groups.labelBytes += key.reduce(0) { $0 + $1.utf8.count }
                guard groups.values.count < 10_000, groups.labelBytes <= 16 << 20 else {
                    throw CSVAnalysisError("This pivot exceeds 10,000 groups or 16 MB of labels. Filter the CSV or choose a dimension with fewer distinct values.")
                }
                groups.values[key] = empty
            }
            groups.rowCount += 1
            for i in metrics.indices {
                let value = metricOffsets[i].flatMap { row[$0] }
                switch metrics[i].operation {
                case .rows: groups.values[key]![i].count += 1
                case .count:
                    if let value, !value.isEmpty { groups.values[key]![i].count += 1 }
                default:
                    if let n = CSVNumericValue.parse(value) { groups.values[key]![i].add(n) }
                }
            }
        }
        let rows = groups.values.map { key, numbers in
            PivotRow(dimensions: key, values: metrics.indices.map { i -> Double? in
                let n = numbers[i]
                switch metrics[i].operation {
                case .rows, .count: return Double(n.count)
                case .sum: return n.count > 0 ? n.total : nil
                case .average: return n.count > 0 ? (n.total.isFinite ? n.total / Double(n.count) : n.mean) : nil
                case .min: return n.count > 0 ? n.minimum : nil
                case .max: return n.count > 0 ? n.maximum : nil
                }
            })
        }.sorted { $0.dimensions.lexicographicallyPrecedes($1.dimensions) { a, b in
            let comparison = a.localizedStandardCompare(b)
            return comparison == .orderedSame ? a < b : comparison == .orderedAscending
        } }
        return Self(recordCount: groups.rowCount, rows: rows)
    }
}
