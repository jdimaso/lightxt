import XCTest
@testable import LighTxt

final class CSVNumericValueTests: XCTestCase {
    func testCurrencyAndStrictThousandsGrouping() {
        for (text, expected): (String, Double) in [
            ("$0.00", 0), ("$7,558.33", 7_558.33), ("$116,898.19", 116_898.19),
            ("-$1,234.56", -1_234.56), ("$-1,234.56", -1_234.56), ("($1,234.56)", -1_234.56),
            ("  ( $ 1,234.50 ) ", -1_234.5), ("$  +.50", 0.5), ("1,234,567.89", 1_234_567.89),
            ("+1.25e2", 125), ("  -2.5  ", -2.5), ("$1,000.50e-1", 100.05)
        ] {
            XCTAssertEqual(CSVNumericValue.parse(text), expected, text)
        }
        for text in ["3/31/2026", "Pending", "4.5%", "$", "$$", "x$100", "100$", "$--3", "-(5)",
                     "($-5)", "(+5)", "(5", "1234,567", "1,23", "1,,234", ",234",
                     "$ 1 2", "$42 due", "3,50 €", "NaN", "infinity", "$1e9999", "1.2.3"] {
            XCTAssertNil(CSVNumericValue.parse(text), text)
        }
    }

    func testScreenshotDollarsFeedStatisticsAndPivotMetrics() async throws {
        let row = ["7/10/2026", "7/11/2026", "7/15/2026", "$468.62", "$205.02", "$673.64"]
        let scan: CSVAnalysisScan = { columns, _, visit in try visit(columns.map { row[$0] }) }
        let selected = try await CSVCellStatistics.calculate(columns: [0, 1, 2, 3, 4], rows: [0], scan: scan)
        XCTAssertEqual(selected.cells, 5)
        XCTAssertEqual(selected.numeric, 2)
        XCTAssertEqual(try XCTUnwrap(selected.sum), 673.64, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(selected.average), 336.82, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(selected.median), 336.82, accuracy: 1e-9)
        let p = try await CSVPivotResult.calculate(dimensions: [0], metrics: [
            .init(operation: .sum, field: 3), .init(operation: .average, field: 4), .init(operation: .max, field: 5)
        ], scan: scan)
        XCTAssertEqual(p.rows.first?.values, [468.62, 205.02, 673.64])
    }

    func testContributionHeaderSortFilterAndProfileUseCurrencyWithoutChangingCSV() throws {
        let source = """
        Pay Date,Processed,Traded,Employee Contribution,Employer Contribution,Total
        7/10/2026,7/11/2026,7/15/2026,$468.62,$205.02,$673.64
        3/31/2026,3/31/2026,3/31/2026,$0.00,$0.00,$0.00
        10/30/2026,10/31/2026,11/4/2026,"$7,132.08","$3,002.04","$10,134.12"
        Totals,,,"$116,898.19","$44,796.85","$161,695.04"
        Adjusted,,,($12.00),$0,($12.00)
        """
        let sample = SampledDocumentDetector.detect(sample: Data(source.utf8), fileName: "contributions.csv")
        XCTAssertEqual(sample.tableDialect?.firstRowLikelyHeader, true)
        let engine = FileBackedPieceTable(empty: .init())
        try engine.insert(utf8: source, at: 0)
        let snapshot = try engine.snapshot()
        let index = try CSVRowIndex(snapshot: snapshot)
        _ = try index.scanToEnd()
        let first = try XCTUnwrap(index.recordLocation(forRecord: 0))
        let second = try XCTUnwrap(index.recordLocation(forRecord: 1))
        XCTAssertTrue(CSVHeaderDetector.isLikelyHeader(
            first: try CSVRecordParser.parse(snapshot: snapshot, location: first),
            second: try CSVRecordParser.parse(snapshot: snapshot, location: second)))
        let sorted = try CSVRowQueryEngine.execute(snapshot: snapshot, index: index, query: .init(
            firstRecord: 1, sortDescriptors: [.init(column: 5, order: .ascending, valueKind: .automatic)]))
        defer { sorted.close() }
        XCTAssertEqual(try sorted.records(in: 0..<5), [5, 2, 1, 3, 4])
        let filtered = try CSVRowQueryEngine.execute(snapshot: snapshot, index: index, query: .init(
            firstRecord: 1, filters: [.init(column: 5, predicate: .numeric(.greaterThan, 1_000))]))
        defer { filtered.close() }
        XCTAssertEqual(try filtered.records(in: 0..<2), [3, 4])
        let profile = try CSVColumnProfiler.profile(snapshot: snapshot, index: index, column: 5, firstRecord: 1)
        XCTAssertEqual(profile.minimumNumericValue, -12)
        XCTAssertEqual(profile.maximumNumericValue, 161_695.04)
        XCTAssertEqual(profile.textValueCount, 0)
        XCTAssertEqual(try snapshot.utf8String(in: 0..<snapshot.byteCount), source)
    }
}
