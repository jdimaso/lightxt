import XCTest
@testable import LighTxt

final class BulkReplaceTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LighTxtBulkTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testLiteralReplaceAllCreatesOneMappedPieceAndDoesNotSave() throws {
        let (table, source) = try makeTable("one fish two fish red fish")
        let result = try table.replaceAll(
            matching: .literal("fish"),
            with: Data("cat".utf8)
        )

        XCTAssertEqual(result.replacementCount, 3)
        XCTAssertEqual(try text(table), "one cat two cat red cat")
        XCTAssertEqual(table.pieceCount, 1)
        XCTAssertTrue(table.hasUnsavedChanges)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "one fish two fish red fish")
    }

    func testRegexCaptureTemplateStreamsCaptureExpansion() throws {
        let (table, _) = try makeTable("Smith, John\nDoe, Jane")
        let result = try table.replaceAll(
            matching: .regularExpression("([A-Za-z]{1,64}), ([A-Za-z]{1,64})"),
            withUTF8Template: "$2 $1 $$"
        )

        XCTAssertEqual(result.replacementCount, 2)
        XCTAssertEqual(try text(table), "John Smith $\nJane Doe $")
        XCTAssertEqual(result.resultByteCount, table.byteCount)
    }

    func testExactRegexReplaceSupportsWordBoundariesAndUnboundedWhitespace() throws {
        let (table, _) = try makeTable("food bar\nfoo.  bar\nfoo bar")
        let result = try table.replaceAll(
            matching: .regularExpression("\\bfoo\\b[\\s.]*\\bbar\\b"),
            with: Data("MATCH".utf8)
        )

        XCTAssertEqual(result.replacementCount, 2)
        XCTAssertEqual(try text(table), "food bar\nMATCH\nMATCH")
    }

    func testZeroWidthRegexAdvancesSafely() throws {
        let (table, _) = try makeTable("aaa")
        let result = try table.replaceAll(
            matching: .regularExpression("a{0}"),
            with: Data("X".utf8)
        )

        XCTAssertEqual(result.replacementCount, 4)
        XCTAssertEqual(try text(table), "XaXaXaX")
    }

    func testCancellationDiscardsPartialRewriteAndLeavesOriginalRoot() throws {
        let original = "a a a a"
        let (table, source) = try makeTable(original)
        let token = CancellationToken()
        var providerCalls = 0

        XCTAssertThrowsError(
            try table.replaceAll(
                matching: .literal("a"),
                cancellation: token
            ) { _, _ in
                providerCalls += 1
                token.cancel()
                return Data("replacement".utf8)
            }
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }

        XCTAssertEqual(providerCalls, 1)
        XCTAssertEqual(try text(table), original)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), original)
        XCTAssertFalse(table.hasUnsavedChanges)
        XCTAssertFalse(table.canUndo)
    }

    func testBulkRewriteIsExactlyOneUndoRedoStep() throws {
        let (table, _) = try makeTable("x x x")
        try table.replaceAll(matching: .literal("x"), with: Data("long".utf8))
        XCTAssertEqual(try text(table), "long long long")

        XCTAssertTrue(table.undo())
        XCTAssertEqual(try text(table), "x x x")
        XCTAssertFalse(table.hasUnsavedChanges)
        XCTAssertFalse(table.canUndo)

        XCTAssertTrue(table.redo())
        XCTAssertEqual(try text(table), "long long long")
        XCTAssertTrue(table.hasUnsavedChanges)
        XCTAssertFalse(table.redo())
    }

    func testNoMatchesDoesNotCreateUndoState() throws {
        let (table, _) = try makeTable("abc")
        let result = try table.replaceAll(
            matching: .literal("missing"),
            with: Data("value".utf8)
        )
        XCTAssertFalse(result.didChange)
        XCTAssertFalse(table.canUndo)
        XCTAssertFalse(table.hasUnsavedChanges)
        XCTAssertEqual(table.pieceCount, 1)
    }

    func testConcurrentEditWinsAndBulkCommitIsRejected() throws {
        let (table, _) = try makeTable("a a")
        var edited = false
        XCTAssertThrowsError(
            try table.replaceAll(matching: .literal("a")) { _, _ in
                if !edited {
                    edited = true
                    try table.insert(utf8: "!", at: table.byteCount)
                }
                return Data("b".utf8)
            }
        ) { error in
            guard case LighTxtCoreError.documentChangedDuringBulkOperation = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try text(table), "a a!")
    }

    private func makeTable(_ text: String) throws -> (FileBackedPieceTable, URL) {
        let source = temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data(text.utf8).write(to: source)
        return (try FileBackedPieceTable(opening: source), source)
    }

    private func text(_ table: FileBackedPieceTable) throws -> String {
        let snapshot = try table.snapshot()
        return try snapshot.utf8String(in: 0..<snapshot.byteCount)
    }
}
