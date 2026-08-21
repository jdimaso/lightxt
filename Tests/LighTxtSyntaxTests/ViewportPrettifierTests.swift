import Foundation
import XCTest
@testable import LighTxt

final class ViewportPrettifierTests: XCTestCase {
    func testJSONPreservesDuplicateKeyOrderAndTokenSpellingWhileOmittingBOM() throws {
        let source = Data([0xEF, 0xBB, 0xBF])
            + Data(#"{"z":1e+09,"z":"\u00e9","a":-0.0,"escaped":"a\/b"}"#.utf8)
        let result = try ViewportPrettifier.prettify(
            source,
            as: .json,
            viewportRange: 0..<Int64(source.count),
            documentByteCount: Int64(source.count)
        )

        XCTAssertTrue(result.didPrettify)
        XCTAssertTrue(result.omittedUTF8BOM)
        XCTAssertFalse(result.text.hasPrefix("\u{FEFF}"))
        XCTAssertTrue(result.text.contains("1e+09"))
        XCTAssertTrue(result.text.contains(#""\u00e9""#))
        XCTAssertTrue(result.text.contains("-0.0"))
        XCTAssertTrue(result.text.contains(#""a\/b""#))
        let first = try XCTUnwrap(result.text.range(of: #""z""#))
        let second = try XCTUnwrap(result.text.range(of: #""z""#, range: first.upperBound..<result.text.endIndex))
        let a = try XCTUnwrap(result.text.range(of: #""a""#))
        XCTAssertLessThan(first.lowerBound, second.lowerBound)
        XCTAssertLessThan(second.lowerBound, a.lowerBound)
    }

    func testJSONInvalidUTF8AndInvalidWholeDocumentFailClosed() throws {
        let invalidUTF8 = Data([0x7B, 0x22, 0x78, 0x22, 0x3A, 0xFF, 0x7D])
        let utf8Result = try format(invalidUTF8, as: .json)
        XCTAssertFalse(utf8Result.didPrettify)
        XCTAssertTrue(utf8Result.status.contains("not valid UTF-8"))

        let invalidJSON = Data(#"{"x":1 2}"#.utf8)
        let syntaxResult = try format(invalidJSON, as: .json)
        XCTAssertFalse(syntaxResult.didPrettify)
        XCTAssertTrue(syntaxResult.status.contains("not valid JSON"))
    }

    func testJSONPartialFragmentUsesOnlyProvenBoundedContext() throws {
        let leading = Data(#"{"wide":[{"a":1},"#.utf8)
        let viewport = Data(#"{"b":2}]}"#.utf8)
        let result = try ViewportPrettifier.prettify(
            viewport,
            as: .json,
            viewportRange: Int64(leading.count)..<Int64(leading.count + viewport.count),
            documentByteCount: Int64(leading.count + viewport.count),
            leadingContext: leading,
            leadingContextStartByteOffset: 0
        )
        XCTAssertTrue(result.didPrettify)
        XCTAssertTrue(result.status.contains("bounded preceding context"))
        XCTAssertTrue(result.text.contains("\n  \"b\": 2"))

        let unproven = try ViewportPrettifier.prettify(
            Data("}".utf8),
            as: .json,
            viewportRange: 5_000..<5_001,
            documentByteCount: 8_000
        )
        XCTAssertFalse(unproven.didPrettify)
    }

    func testJSONPartialStringPrefixIsCopiedExactlyThenFormattingResumes() throws {
        let leading = Data(#"{"text":"long "#.utf8)
        let viewport = Data(#"continued\" value","next":{"x":1}}"#.utf8)
        let result = try ViewportPrettifier.prettify(
            viewport,
            as: .json,
            viewportRange: Int64(leading.count)..<Int64(leading.count + viewport.count),
            documentByteCount: Int64(leading.count + viewport.count),
            leadingContext: leading,
            leadingContextStartByteOffset: 0
        )
        XCTAssertTrue(result.didPrettify)
        XCTAssertTrue(result.preservedLeadingPartialLine)
        XCTAssertTrue(result.text.hasPrefix(#"continued\" value""#))
        XCTAssertTrue(result.text.contains("\"next\": "))
    }

    func testJSONAmbiguousScalarWhitespaceIsNeverCollapsed() throws {
        let leading = Data(#"{"x":"#.utf8)
        let viewport = Data("1 2}".utf8)
        let result = try ViewportPrettifier.prettify(
            viewport,
            as: .json,
            viewportRange: Int64(leading.count)..<Int64(leading.count + viewport.count),
            documentByteCount: Int64(leading.count + viewport.count),
            leadingContext: leading,
            leadingContextStartByteOffset: 0
        )
        XCTAssertFalse(result.didPrettify)
        XCTAssertEqual(result.text, "1 2}")
        XCTAssertTrue(result.status.contains("adjacent JSON scalar tokens"))
    }

    func testJSONExactlyMaximumInputAndOutputExpansionCap() throws {
        let fixedBytes = Data(#"{"x":""}"#.utf8).count
        let exact = Data((#"{"x":""# + String(repeating: "a", count: ViewportPrettifier.maximumInputBytes - fixedBytes) + #""}"#).utf8)
        XCTAssertEqual(exact.count, ViewportPrettifier.maximumInputBytes)
        XCTAssertTrue(try format(exact, as: .json).didPrettify)

        let over = Data(repeating: 0x20, count: ViewportPrettifier.maximumInputBytes + 1)
        XCTAssertFalse(try format(over, as: .json).didPrettify)

        let expanding = Data(("[" + Array(repeating: "0", count: 20_000).joined(separator: ",") + "]").utf8)
        let capped = try ViewportPrettifier.prettify(
            expanding,
            as: .json,
            viewportRange: 0..<Int64(expanding.count),
            documentByteCount: Int64(expanding.count),
            maximumOutputBytes: expanding.count
        )
        XCTAssertFalse(capped.didPrettify)
        XCTAssertTrue(capped.status.contains("output"))
    }

    func testCancellationStopsBeforeFormatting() {
        let token = CancellationToken()
        token.cancel()
        XCTAssertThrowsError(
            try ViewportPrettifier.prettify(
                Data(#"{"x":1}"#.utf8),
                as: .json,
                viewportRange: 0..<7,
                documentByteCount: 7,
                cancellation: token
            )
        ) { XCTAssertTrue($0 is CancellationError) }
    }

    func testYAMLSafeBlockStructurePreservesPayloadCommentsMarkersAndCRLF() throws {
        let source = Data("---\r\nroot:\r\n    title: \"a # b: c\" # note\r\n    rows:\r\n        - name: alpha\r\n          enabled: true\r\n\r\n...\r\n".utf8)
        let result = try format(source, as: .yaml)
        XCTAssertTrue(result.didPrettify)
        XCTAssertTrue(result.text.contains("title: \"a # b: c\" # note"))
        XCTAssertTrue(result.text.contains("- name: alpha"))
        XCTAssertTrue(result.text.split(separator: "\n").contains("      enabled: true"))
        XCTAssertFalse(result.text.contains("\r"))
        XCTAssertTrue(result.text.contains("---\n"))
        XCTAssertTrue(result.text.contains("\n...\n"))
    }

    func testYAMLAdvancedOrAmbiguousFeaturesFailClosedWithExactSource() throws {
        let unsafeSources = [
            "root: &anchor value\ncopy: *anchor\n",
            "tagged: !Thing value\n",
            "flow: [one, two]\n",
            "literal: |2-\n  text\n",
            "folded: >+\n  text\n",
            "root:\n\tchild: value\n",
            "root:\n    child: value\n  mismatched: value\n",
            "items:\n  - scalar\n    illegal: child\n",
            "key: \"\\q\"\n",
            ": value\n",
        ]
        for source in unsafeSources {
            let result = try format(Data(source.utf8), as: .yaml)
            XCTAssertFalse(result.didPrettify, source)
            XCTAssertEqual(result.text, source)
        }
    }

    func testYAMLBOMMultiDocumentAndBlankLinesAreSourceFaithful() throws {
        let body = "---\nfirst:\n    value: one\n\n...\n---\nsecond:\n  value: two\n...\n"
        let source = Data([0xEF, 0xBB, 0xBF]) + Data(body.utf8)
        let result = try format(source, as: .yaml)
        XCTAssertTrue(result.didPrettify)
        XCTAssertTrue(result.omittedUTF8BOM)
        XCTAssertFalse(result.text.hasPrefix("\u{FEFF}"))
        XCTAssertTrue(result.text.contains("\n\n...\n---\n"))
        XCTAssertTrue(result.text.split(separator: "\n").contains("  value: one"))
        XCTAssertTrue(result.text.split(separator: "\n").contains("  value: two"))
        XCTAssertFalse(result.text.split(separator: "\n").contains("    value: one"))
    }

    private func format(
        _ data: Data,
        as type: SyntaxFileType
    ) throws -> ViewportPrettifier.Result {
        try ViewportPrettifier.prettify(
            data,
            as: type,
            viewportRange: 0..<Int64(data.count),
            documentByteCount: Int64(data.count)
        )
    }
}
