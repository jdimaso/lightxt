import XCTest
@testable import LighTxt

final class CSVAnalysisTests: XCTestCase {
    private func scanner(_ data: [[String?]]) -> CSVAnalysisScan {
        { columns, rows, visit in
            for i in rows ?? IndexSet(integersIn: data.indices) {
                try Task.checkCancellation()
                try visit(columns.map { data[i][$0] })
            }
        }
    }

    func testMixedSelectionAndExactSpilledMedian() async throws {
        let input = scanner([["ignored", "12", nil], ["no", " 2 ", "4"], ["text", "NaN", "6"],
                             ["none", "", "inf"]])
        for limit in [0, 2, 100] {
            let s = try await CSVCellStatistics.calculate(columns: [2, 1], rows: IndexSet(integersIn: 0..<4), scan: input, medianMemoryLimit: limit)
            XCTAssertEqual(s.cells, 8)
            XCTAssertEqual(s.filled, 6)
            XCTAssertEqual(s.numeric, 4)
            XCTAssertEqual(s.sum, 24)
            XCTAssertEqual(s.average, 6)
            XCTAssertEqual(s.median, 5)
            XCTAssertEqual(s.minimum, 2)
            XCTAssertEqual(s.maximum, 12)
        }
        let blank = try await CSVCellStatistics.calculate(columns: [0], rows: IndexSet(integersIn: 0..<4), scan: input)
        XCTAssertNil(blank.sum)
        XCTAssertNil(blank.median)
        let odd = try await CSVCellStatistics.calculate(columns: [0], rows: IndexSet(integersIn: 0..<3), scan: scanner([["7"], ["-2"], ["1"]]), medianMemoryLimit: 1)
        XCTAssertEqual(odd.median, 1)
    }

    func testPivotGroupMeasuresAndDisplayConstraints() async throws {
        let scan = scanner([["east", "A", "7"], ["east", "B", "bad"], ["east", "A", "5"], ["west", "A", ""]])
        let metrics = [PivotMetric(operation: .rows, field: 0), .init(operation: .sum, field: 2),
                       .init(operation: .average, field: 2), .init(operation: .count, field: 2)]
        let p = try await CSVPivotResult.calculate(dimensions: [0, 1], metrics: metrics, scan: scan)
        XCTAssertEqual(p.recordCount, 4)
        XCTAssertEqual(p.rows.map(\.dimensions), [["east", "A"], ["east", "B"], ["west", "A"]])
        XCTAssertEqual(p.rows.map(\.values), [[2, 12, 6, 2], [1, nil, nil, 1], [1, nil, nil, 0]])
        let total = try await CSVPivotResult.calculate(dimensions: [], metrics: [metrics[0]], scan: scan)
        XCTAssertEqual(total.rows.map(\.values), [[4]])
        let fast = try await CSVPivotResult.calculate(dimensions: [], metrics: [metrics[0]],
            scan: { _, _, _ in throw CSVAnalysisError("Unexpected scan") }, knownRowCount: 1_000_000)
        XCTAssertEqual(fast.rows.map(\.values), [[1_000_000]])
        XCTAssertEqual(PivotDisplay.available(dimensions: 0, metrics: 1), [.table])
        XCTAssertEqual(PivotDisplay.available(dimensions: 1, metrics: 2), [.table, .bar, .line, .scatter])
        XCTAssertEqual(PivotDisplay.available(dimensions: 2, metrics: 2), [.table, .scatter])
        XCTAssertEqual(PivotDisplay.available(dimensions: 2, metrics: 3), [.table])
    }

    func testSequentialSelectionStopsAtLastDisplayedRow() async throws {
        let engine = FileBackedPieceTable(empty: .init())
        try engine.insert(utf8: "id\n" + (0..<800).map(String.init).joined(separator: "\n"), at: 0)
        let snapshot = try engine.snapshot()
        let index = try CSVRowIndex(snapshot: snapshot)
        _ = try index.scanToEnd()
        let scan: CSVAnalysisScan = { columns, rows, visit in
            try CSVAnalysisReader.read(snapshot: snapshot, index: index, firstRecord: 1, filters: [],
                                       rowMap: nil, rows: rows, columns: columns, visit: visit)
        }
        let s = try await CSVCellStatistics.calculate(columns: [0], rows: IndexSet(integersIn: 231..<543), scan: scan)
        XCTAssertEqual(s.numeric, 312)
        XCTAssertEqual(s.minimum, 231)
        XCTAssertEqual(s.maximum, 542)
        XCTAssertEqual(s.median, 386.5)
    }

    func testHeaderFilterSortAndEditedSnapshot() async throws {
        let engine = FileBackedPieceTable(empty: .init())
        try engine.insert(utf8: "region,amount,note\r\neast,8,\r\nwest,50,\r\neast,4,\"a\nb\"\r\neast,16,c\r\n", at: 0)
        let snapshot = try engine.snapshot()
        let index = try CSVRowIndex(snapshot: snapshot)
        _ = try index.scanToEnd()
        let filters = [CSVColumnFilter(column: 0, predicate: .contains("east", caseSensitive: false))]
        let map = try CSVRowQueryEngine.execute(snapshot: snapshot, index: index, query: .init(
            firstRecord: 1, filters: filters, sortDescriptors: [.init(column: 1, order: .descending, valueKind: .automatic)]))
        defer { map.close() }
        let scan: CSVAnalysisScan = { columns, rows, visit in
            try CSVAnalysisReader.read(snapshot: snapshot, index: index, firstRecord: 1, filters: filters,
                                       rowMap: map, rows: rows, columns: columns, visit: visit)
        }
        let selection = try await CSVCellStatistics.calculate(columns: [1], rows: IndexSet(integersIn: 0..<2), scan: scan)
        XCTAssertEqual(selection.sum, 24)
        XCTAssertEqual(selection.median, 12)
        var separateRows = IndexSet(integer: 0)
        separateRows.insert(2)
        let disjoint = try await CSVCellStatistics.calculate(columns: [1], rows: separateRows, scan: scan)
        XCTAssertEqual(disjoint.cells, 2)
        XCTAssertEqual(disjoint.sum, 20)
        XCTAssertEqual(disjoint.median, 10)
        let all = try await CSVCellStatistics.calculate(columns: [1], rows: IndexSet(integersIn: 0..<3), scan: scan)
        XCTAssertEqual(all.sum, 28)
        let pivot = try await CSVPivotResult.calculate(dimensions: [0], metrics: [.init(operation: .sum, field: 1)], scan: scan)
        XCTAssertEqual(pivot.recordCount, 3)
        XCTAssertEqual(pivot.rows.first?.values, [28])
        let rowCount = try await CSVPivotResult.calculate(dimensions: [], metrics: [.init(operation: .rows, field: 0)], scan: scan)
        XCTAssertEqual(rowCount.rows.first?.values, [3])
    }
}
