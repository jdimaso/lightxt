import Foundation
import Testing
@testable import LighTxt

@Suite("Tabular export")
struct TabularExportTests {
    @Test("CSV, TSV, and pipe rows are escaped incrementally")
    func delimitedFormats() throws {
        for (format, expected) in [
            (TabularExportFormat.csv, "a,b\n\"x,y\",\"quote\"\"here\"\n"),
            (.tsv, "a\tb\nx,y\t\"quote\"\"here\"\n"),
            (.pipe, "a|b\nx,y|\"quote\"\"here\"\n"),
        ] {
            let url = temporaryURL(extension: format.preferredPathExtension)
            defer { try? FileManager.default.removeItem(at: url) }
            let sink = try TabularExportSink(
                targetURL: url,
                format: format,
                headers: ["a", "b"],
                expectedDestination: nil
            )
            try sink.append(row: ["x,y", "quote\"here"])
            try sink.finish()
            #expect(try String(contentsOf: url, encoding: .utf8) == expected)
        }
    }

    @Test("JSON Lines preserves null and escapes keys and values")
    func jsonLines() throws {
        let url = temporaryURL(extension: "jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let sink = try TabularExportSink(
            targetURL: url,
            format: .jsonLines,
            headers: ["na\"me", "value"],
            expectedDestination: nil
        )
        try sink.append(row: ["line\nvalue", nil])
        try sink.finish()
        let object = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        #expect(object["na\"me"] as? String == "line\nvalue")
        #expect(object["value"] is NSNull)
    }

    @Test("Cancel never publishes a partial destination")
    func cancellationIsAtomic() throws {
        let url = temporaryURL(extension: "csv")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("original".utf8).write(to: url)
        let expected = try TabularExportSink.expectedDestination(at: url)
        let sink = try TabularExportSink(
            targetURL: url,
            format: .csv,
            headers: nil,
            expectedDestination: expected
        )
        try sink.append(row: ["partial"])
        sink.cancel()
        #expect(try String(contentsOf: url, encoding: .utf8) == "original")
    }

    private func temporaryURL(extension pathExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("LighTxt-export-test-\(UUID().uuidString)")
            .appendingPathExtension(pathExtension)
    }
}
