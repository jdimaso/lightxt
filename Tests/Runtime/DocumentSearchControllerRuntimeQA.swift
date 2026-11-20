#if LIGHTXT_STANDALONE_DOCUMENT_SEARCH_QA
import AppKit
import Foundation

@main
@MainActor
struct DocumentSearchControllerRuntimeQA {
    static func main() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LighTxt-document-search-QA-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("many-matches.csv")
        let record = "needle\n"
        let matchCount = 250
        try Data(String(repeating: record, count: matchCount).utf8).write(to: url)
        let table = try FileBackedPieceTable(opening: url)
        defer { table.close() }
        let controller = DocumentSearchController { table }

        let bounded = try findAll(
            controller: controller,
            retainedLimit: 100,
            scanMatchLimit: 100
        )
        try expect(bounded.totalMatches == 100, "bounded search did not stop at 100 matches")
        try expect(bounded.retainedMatches.count == 100, "bounded search did not retain its first 100 matches")
        try expect(bounded.retainedLimitReached, "bounded search did not report its intentionally partial result")
        try expect(!bounded.isComplete, "bounded search incorrectly reported a complete-file count")
        try expect(
            bounded.retainedMatches.map(\.byteRange) == expectedRanges(count: 100),
            "bounded search did not return the first 100 matches in file order"
        )

        let exhaustive = try findAll(
            controller: controller,
            retainedLimit: 100,
            scanMatchLimit: nil
        )
        try expect(exhaustive.totalMatches == matchCount, "exhaustive search did not report the exact total")
        try expect(exhaustive.retainedMatches.count == 100, "exhaustive search ignored its retained-result limit")
        try expect(exhaustive.retainedLimitReached, "exhaustive search did not report truncated retained results")
        try expect(exhaustive.isComplete, "exhaustive search did not report completion")
        try expect(
            exhaustive.retainedMatches.map(\.byteRange) == expectedRanges(count: 100),
            "exhaustive search did not retain the first matches in file order"
        )

        try checkNavigation()
        print(
            "Document search controller QA passed: bounded search stops after the first 100 "
                + "matches and exhaustive search reports the exact 250-match total"
        )
    }

    private static func checkNavigation() throws {
        let table = FileBackedPieceTable(empty: .init())
        defer { table.close() }
        let controller = DocumentSearchController { table }
        func find(
            _ query: String,
            from start: Int64,
            backwards: Bool = false,
            regex: Bool = true,
            continuing: Bool = false,
            options: SearchOptions = .init()
        ) throws -> Range<Int64>? {
            var outcome: Result<SearchMatch?, Error>?
            controller.findOne(
                query: query,
                regularExpression: regex,
                from: start,
                backwards: backwards,
                skippingEmptyMatchAtOrigin: continuing,
                options: options
            ) { outcome = $0 }
            try wait(until: { outcome != nil }, failure: "find-one completion was not delivered")
            return try outcome?.get()?.byteRange
        }

        try table.insert(utf8: "needle", at: 0)
        for regex in [false, true] {
            let wrapped = try find("needle", from: 3, regex: regex)
            try expect(wrapped == 0..<6, "wrapped search missed a match spanning the caret")
        }

        try table.replace(byteRange: 0..<6, with: Data("😀a".utf8))
        let empty = "(?=.|$)"
        for (from, backwards, expected): (Int64, Bool, Int64) in [
            (0, false, 4), (4, false, 5), (5, false, 0),
            (0, true, 5), (5, true, 4), (4, true, 0)
        ] {
            let match = try find(empty, from: from, backwards: backwards, continuing: true)
            try expect(match == expected..<expected, "zero-width search failed from byte \(from)")
        }

        let source = String(repeating: "€", count: 1_400_000) + "XY"
        try table.replace(byteRange: 0..<5, with: Data(source.utf8))
        let options = SearchOptions(
            regexChunkByteCount: 128 << 10,
            regexContextByteCount: 0,
            maximumRegexWindowByteCount: 256 << 10,
            maximumExactRegexDocumentByteCount: 0
        )
        let last = try find("Y", from: table.byteCount, backwards: true, options: options)
        try expect(last == (table.byteCount - 1)..<table.byteCount, "reverse regex split a UTF-8 scalar")
    }

    private static func findAll(
        controller: DocumentSearchController,
        retainedLimit: Int,
        scanMatchLimit: Int?
    ) throws -> SearchSummary {
        var outcome: Result<SearchSummary, Error>?
        controller.findAll(
            query: "needle",
            regularExpression: false,
            retainedLimit: retainedLimit,
            scanMatchLimit: scanMatchLimit
        ) { outcome = $0 }

        try wait(
            until: { outcome != nil },
            failure: "find-all completion was not delivered"
        )
        switch outcome {
        case let .success(summary):
            return summary
        case let .failure(error):
            throw error
        case nil:
            throw QAError.failed("find-all completion disappeared")
        }
    }

    private static func expectedRanges(count: Int) -> [Range<Int64>] {
        (0..<count).map { index in
            let start = Int64(index * 7)
            return start..<(start + 6)
        }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ failure: String) throws {
        guard condition() else { throw QAError.failed(failure) }
    }

    private static func wait(
        until condition: () -> Bool,
        timeout: TimeInterval = 5,
        failure: String
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        guard condition() else { throw QAError.failed(failure) }
    }

    private enum QAError: Error, LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message): message
            }
        }
    }
}
#endif
