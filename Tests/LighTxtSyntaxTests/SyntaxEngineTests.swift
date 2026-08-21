import Foundation
import XCTest
@testable import LighTxt

final class SyntaxFileTypeDetectorTests: XCTestCase {
    func testEverySupportedExtensionIsCaseInsensitive() {
        XCTAssertEqual(SyntaxFileTypeDetector.detect(fileName: "notes.TXT"), .plainText)
        XCTAssertEqual(SyntaxFileTypeDetector.detect(fileName: "server.LOG"), .plainText)
        XCTAssertEqual(SyntaxFileTypeDetector.detect(fileName: "deploy.SCRIPT"), .plainText)
        XCTAssertEqual(SyntaxFileTypeDetector.detect(fileName: "data.JSON"), .json)
        XCTAssertEqual(SyntaxFileTypeDetector.detect(fileName: "README.md"), .markdown)
        XCTAssertEqual(SyntaxFileTypeDetector.detect(fileName: "README.MARKDOWN"), .markdown)
        XCTAssertEqual(SyntaxFileTypeDetector.detect(fileName: "query.SQL"), .sql)
        XCTAssertEqual(SyntaxFileTypeDetector.detect(fileName: "feed.Xml"), .xml)
        XCTAssertEqual(SyntaxFileTypeDetector.detect(fileName: "rows.CSV"), .csv)
        XCTAssertEqual(SyntaxFileTypeDetector.detect(fileName: "config.yml"), .yaml)
        XCTAssertEqual(SyntaxFileTypeDetector.detect(fileName: "config.YAML"), .yaml)
        XCTAssertEqual(SyntaxFileTypeDetector.detect(fileName: "records.PARQUET"), .parquet)
        XCTAssertTrue(SyntaxFileType.plainText.pathExtensions.contains("script"))
    }

    func testConservativeContentSniffing() {
        XCTAssertEqual(SyntaxFileTypeDetector.sniff(data("  {\"ok\":true}")), .json)
        XCTAssertEqual(SyntaxFileTypeDetector.sniff(data("<?xml version=\"1.0\"?><r/>")), .xml)
        XCTAssertEqual(SyntaxFileTypeDetector.sniff(data("SELECT * FROM values_table;")), .sql)
        XCTAssertEqual(SyntaxFileTypeDetector.sniff(data("name,age\nAda,36\nLin,29\n")), .csv)
        XCTAssertEqual(SyntaxFileTypeDetector.sniff(Data("PAR1fixture".utf8)), .parquet)
        XCTAssertNil(SyntaxFileTypeDetector.sniff(Data([0xFF, 0xFE, 0x7B, 0x00])))
    }
}

final class ViewportSyntaxHighlighterTests: XCTestCase {
    func testJSONUsesUTF8ByteOffsetsAndSemanticKinds() {
        let base = 5_000_000_000
        let result = ViewportSyntaxHighlighter.highlight(
            data("{\"é\":true}"), as: .json, baseByteOffset: base
        )

        XCTAssertEqual(
            result.spans.first(where: { $0.kind == .key })?.range,
            SyntaxByteRange(start: base + 1, length: 4)
        )
        XCTAssertEqual(
            result.spans.first(where: { $0.kind == .boolean })?.range,
            SyntaxByteRange(start: base + 6, length: 4)
        )
    }

    func testSplitJSONStringCarriesEscapeStateAcrossViewports() {
        let first = ViewportSyntaxHighlighter.highlight(data("\"a\\"), as: .json)
        XCTAssertEqual(
            first.endState.mode,
            .quotedString(delimiter: 0x22, escaped: true)
        )

        let second = ViewportSyntaxHighlighter.highlight(
            data("\"b\""),
            as: .json,
            baseByteOffset: 3,
            initialState: first.endState
        )
        XCTAssertEqual(second.endState.mode, .normal)
        XCTAssertEqual(second.spans.first?.range, SyntaxByteRange(start: 3, length: 3))
    }

    func testSplitSQLBlockCommentCarriesState() {
        let first = ViewportSyntaxHighlighter.highlight(data("/* chunk"), as: .sql)
        guard case .blockComment = first.endState.mode else {
            return XCTFail("Expected a continued block comment")
        }
        let second = ViewportSyntaxHighlighter.highlight(
            data(" end */ SELECT"), as: .sql, baseByteOffset: 8, initialState: first.endState
        )
        XCTAssertEqual(second.endState.mode, .normal)
        XCTAssertTrue(second.spans.contains(where: { $0.kind == .keyword }))
    }

    func testSQLCommentClosingDelimiterMaySplitBetweenBytes() {
        let first = ViewportSyntaxHighlighter.highlight(data("/* comment *"), as: .sql)
        guard case .blockCommentAfterAsterisk = first.endState.mode else {
            return XCTFail("Expected a pending comment terminator")
        }
        let second = ViewportSyntaxHighlighter.highlight(
            data("/ SELECT"), as: .sql, baseByteOffset: 12, initialState: first.endState
        )
        XCTAssertEqual(second.endState.mode, .normal)
        XCTAssertTrue(second.spans.contains(where: { $0.kind == .keyword }))
    }

    func testXMLCommentClosingDelimiterMaySplitBetweenBytes() {
        let first = ViewportSyntaxHighlighter.highlight(data("<!-- calm --"), as: .xml)
        XCTAssertEqual(
            first.endState.mode,
            .xmlCommentContinuation(matchedTerminatorBytes: 2)
        )
        let second = ViewportSyntaxHighlighter.highlight(
            data("> <root/>"), as: .xml, baseByteOffset: 12, initialState: first.endState
        )
        XCTAssertEqual(second.endState.mode, .normal)
        XCTAssertTrue(second.spans.contains(where: { $0.kind == .tag }))
    }

    func testYAMLMultilineQuotedScalarIsOneNonoverlappingSpan() {
        let result = ViewportSyntaxHighlighter.highlight(
            data("message: \"calm\nblue\"\nnext: true"), as: .yaml
        )
        let strings = result.spans.filter { $0.kind == .string }
        XCTAssertEqual(strings.count, 1)
        XCTAssertEqual(strings[0].range.length, 11)
        XCTAssertTrue(result.spans.contains(where: { $0.kind == .boolean }))
    }

    func testMarkdownDoesNotTreatMidLineViewportAsHeading() {
        let state = SyntaxLexicalState(mode: .normal, atLineStart: false)
        let result = ViewportSyntaxHighlighter.highlight(
            data("# fragment\n# heading"), as: .markdown, initialState: state
        )
        let headings = result.spans.filter { $0.kind == .heading }
        XCTAssertEqual(headings.count, 1)
        XCTAssertEqual(headings[0].range.start, 11)
    }

    func testSpanCapStillProducesCorrectContinuationState() {
        let limits = SyntaxLimits(maximumSpans: 0)
        let result = ViewportSyntaxHighlighter.highlight(
            data("{\"unfinished"), as: .json, limits: limits
        )
        XCTAssertTrue(result.spans.isEmpty)
        XCTAssertTrue(result.wasTruncated)
        guard case .quotedString = result.endState.mode else {
            return XCTFail("Scanner stopped before producing continuation state")
        }
    }

    func testAlternateCSVDelimiter() {
        let result = ViewportSyntaxHighlighter.highlight(
            data("one;2;true"),
            as: .csv,
            limits: SyntaxLimits(csvDelimiter: 0x3B)
        )
        XCTAssertEqual(result.spans.filter { $0.kind == .punctuation }.count, 2)
        XCTAssertTrue(result.spans.contains(where: { $0.kind == .number }))
        XCTAssertTrue(result.spans.contains(where: { $0.kind == .boolean }))
    }

    func testSingleMegabyteMinifiedViewportRemainsResultBounded() {
        let token = Array("true,".utf8)
        var input = Data(capacity: 1 << 20)
        while input.count + token.count <= 1 << 20 { input.append(contentsOf: token) }
        let limits = SyntaxLimits(maximumSpans: 17)
        let result = ViewportSyntaxHighlighter.highlight(input, as: .json, limits: limits)
        XCTAssertEqual(result.spans.count, 17)
        XCTAssertTrue(result.wasTruncated)
    }
}

final class SyntaxDiagnosticsTests: XCTestCase {
    func testValidAndInvalidJSON() {
        XCTAssertTrue(
            SyntaxDiagnostics.inspect(
                data("{\"emoji\":\"\\uD83C\\uDF3F\",\"n\":-1.25e2}"), as: .json
            ).isEmpty
        )
        XCTAssertEqual(
            SyntaxDiagnostics.inspect(data("{\"a\":[1,]}"), as: .json).first?.code,
            "json.trailing-comma"
        )
        XCTAssertEqual(
            SyntaxDiagnostics.inspect(data("\"\\uD800x\""), as: .json).first?.code,
            "json.invalid-surrogate-pair"
        )
    }

    func testXMLTagAndAttributeErrors() {
        XCTAssertTrue(
            SyntaxDiagnostics.inspect(
                data("<?xml version=\"1.0\"?><root><item id=\"1\"/></root>"), as: .xml
            ).isEmpty
        )
        XCTAssertEqual(
            SyntaxDiagnostics.inspect(data("<root><item></root>"), as: .xml).first?.code,
            "xml.mismatched-closing-tag"
        )
        XCTAssertEqual(
            SyntaxDiagnostics.inspect(data("<root a=no/>"), as: .xml).first?.code,
            "xml.expected-attribute-quote"
        )
        XCTAssertEqual(
            SyntaxDiagnostics.inspect(data("<root>&;</root>"), as: .xml).first?.code,
            "xml.invalid-entity"
        )
    }

    func testYAMLCSVSQLAndMarkdownDiagnostics() {
        XCTAssertTrue(
            SyntaxDiagnostics.inspect(data("name: value\nitems:\n  - one\n  - two\n"), as: .yaml).isEmpty
        )
        XCTAssertTrue(
            SyntaxDiagnostics.inspect(data("\tbad: indent\n"), as: .yaml)
                .contains(where: { $0.code == "yaml.tab-indentation" })
        )

        XCTAssertTrue(
            SyntaxDiagnostics.inspect(data("a,b\n\"x\ny\",2\n"), as: .csv).isEmpty
        )
        XCTAssertTrue(
            SyntaxDiagnostics.inspect(data("a,b\n1\n"), as: .csv)
                .contains(where: { $0.code == "csv.inconsistent-columns" })
        )

        XCTAssertTrue(
            SyntaxDiagnostics.inspect(data("SELECT (1 + 2); -- ok"), as: .sql).isEmpty
        )
        XCTAssertEqual(
            SyntaxDiagnostics.inspect(data("SELECT 'open"), as: .sql).first?.code,
            "sql.unclosed-quote"
        )
        XCTAssertEqual(
            SyntaxDiagnostics.inspect(data("<!-- open"), as: .markdown).first?.code,
            "markdown.unclosed-html-comment"
        )
    }

    func testDiagnosticCountIsCapped() {
        let limits = SyntaxLimits(maximumDiagnostics: 3)
        let result = SyntaxDiagnostics.inspect(Data(repeating: 0xFF, count: 128), as: .plainText, limits: limits)
        XCTAssertEqual(result.count, 3)
    }
}

final class SyntaxFoldDiscoveryTests: XCTestCase {
    func testJSONFoldRanges() {
        let source = "{\n  \"items\": [\n    {\"id\": 1}\n  ]\n}"
        let result = SyntaxFoldDiscovery.discover(data(source), as: .json)
        XCTAssertEqual(result.ranges.map(\.kind), [.object, .array])
        XCTAssertEqual(result.ranges[0].range, SyntaxByteRange(start: 0, length: data(source).count))
    }

    func testXMLFoldRangeKeepsOpeningTagAsHeader() {
        let source = "<root id=\"1\">\n  <item/>\n</root>"
        let result = SyntaxFoldDiscovery.discover(data(source), as: .xml)
        XCTAssertEqual(result.ranges.count, 1)
        XCTAssertEqual(result.ranges[0].kind, .element)
        XCTAssertEqual(result.ranges[0].headerRange, SyntaxByteRange(start: 0, length: 13))
    }

    func testYAMLMappingsSequencesAndBlockScalarsFold() {
        let source = "root:\n  items:\n    - one\n    - two\n  note: |\n    calm\n    text\n"
        let result = SyntaxFoldDiscovery.discover(data(source), as: .yaml)
        XCTAssertTrue(result.ranges.contains(where: { $0.kind == .mapping }))
        XCTAssertTrue(result.ranges.contains(where: { $0.kind == .sequence }))
        XCTAssertTrue(result.ranges.contains(where: { $0.kind == .scalar }))
    }

    func testFoldLimitIsHardAndReported() {
        let source = "{\n\"a\": {\n\"b\": [\n1\n]\n}\n}"
        let result = SyntaxFoldDiscovery.discover(
            data(source), as: .json, limits: SyntaxLimits(maximumFoldRanges: 1)
        )
        XCTAssertEqual(result.ranges.count, 1)
        XCTAssertTrue(result.wasTruncated)
    }

    func testLargeMinifiedJSONStructuresRemainFoldable() {
        let source = "{\"records\":[{\"identifier\":123456789,\"enabled\":true}]}"
        let result = SyntaxFoldDiscovery.discover(data(source), as: .json)
        XCTAssertTrue(result.ranges.contains(where: { $0.kind == .object && $0.range.start == 0 }))
        XCTAssertTrue(result.ranges.contains(where: { $0.kind == .array }))
    }

    func testFoldCoordinatesSupportOffsetsBeyondFourGiB() {
        let base = 8_500_000_000
        let result = SyntaxFoldDiscovery.discover(
            data("[\n1\n]"), as: .json, baseByteOffset: base
        )
        XCTAssertEqual(result.ranges.first?.range.start, base)
        XCTAssertEqual(result.ranges.first?.range.end, base + 5)
    }
}

private func data(_ string: String) -> Data { Data(string.utf8) }
