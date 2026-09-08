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

        print(
            "Document search controller QA passed: bounded search stops after the first 100 "
                + "matches and exhaustive search reports the exact 250-match total"
        )
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
