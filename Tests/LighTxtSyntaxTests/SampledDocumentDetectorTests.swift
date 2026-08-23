import Foundation
import XCTest
@testable import LighTxt

final class SampledDocumentDetectorTests: XCTestCase {
    func testDetectsSupportedTextFormatsConservatively() {
        assertFormat(
            "{\"items\":[1,2],\"ok\":true}",
            is: .json,
            confidence: .high
        )
        assertFormat(
            "# Release Notes\n\n- Fast\n- Bounded\n\n[Details](https://example.test)",
            is: .markdown,
            confidence: .high
        )
        assertFormat(
            "SELECT id, created_at FROM events WHERE active = true;",
            is: .sql,
            confidence: .high
        )
        assertFormat(
            "<?xml version=\"1.0\"?><events><event id=\"1\"/></events>",
            is: .xml,
            confidence: .high
        )
        assertFormat(
            "service: api\nenvironment: production\nreplicas: 3\n",
            is: .yaml,
            confidence: .medium
        )

        let prose = SampledDocumentDetector.detect(
            sample: Data("Notes for tomorrow.\nNothing structured is implied here.\n".utf8)
        )
        XCTAssertEqual(prose.format, .plainText)
        XCTAssertEqual(prose.formatConfidence, .low)
        XCTAssertNil(prose.tableDialect)
    }

    func testDetectsCommaTabSemicolonAndPipeDialects() {
        let cases: [(String, DelimitedTextDelimiter, String)] = [
            ("name,age\nAda,36\nLin,29\nGrace,85\n", .comma, "csv"),
            ("name\tage\nAda\t36\nLin\t29\nGrace\t85\nEdsger\t72\n", .tab, "tsv"),
            ("name;age\nAda;36\nLin;29\nGrace;85\n", .semicolon, "csv"),
            ("name|age\nAda|36\nLin|29\nGrace|85\n", .pipe, "psv"),
        ]

        for (source, delimiter, preferredExtension) in cases {
            let result = SampledDocumentDetector.detect(sample: Data(source.utf8))
            XCTAssertEqual(result.format, .delimitedText(delimiter), source)
            XCTAssertEqual(result.syntaxFileType, .csv, source)
            XCTAssertEqual(result.tableDialect?.delimiter, delimiter, source)
            XCTAssertEqual(result.tableDialect?.columnCount, 2, source)
            XCTAssertEqual(result.tableDialect?.firstRowLikelyHeader, true, source)
            XCTAssertEqual(result.tableDialect?.lineEnding, .lineFeed, source)
            XCTAssertEqual(result.preferredPathExtension, preferredExtension, source)
            XCTAssertGreaterThanOrEqual(result.formatConfidence, .medium, source)
        }
    }

    func testKnownDelimitedExtensionsBeatYAMLLikeFieldPunctuation() {
        let cases: [(String, DelimitedTextDelimiter, Character)] = [
            ("network.csv", .comma, ","),
            ("network.tsv", .tab, "\t"),
            ("network.psv", .pipe, "|"),
        ]

        for (fileName, delimiter, separator) in cases {
            let rows = [
                ["name", "description", "network"],
                ["one", "service: special", "Clinic & Rehabilitation"],
                ["two", "service: advanced", "Research & Development"],
                ["three", "service: routine", "Hospital & Medical Center"],
            ]
            let source = rows
                .map { $0.joined(separator: String(separator)) }
                .joined(separator: "\n") + "\n"
            let result = SampledDocumentDetector.detect(
                sample: Data(source.utf8),
                fileName: fileName
            )

            XCTAssertEqual(result.format, .delimitedText(delimiter), fileName)
            XCTAssertEqual(result.tableDialect?.delimiter, delimiter, fileName)
            XCTAssertEqual(result.tableDialect?.columnCount, 3, fileName)
            XCTAssertGreaterThanOrEqual(result.formatConfidence, .medium, fileName)
        }
    }

    func testTSVAndPSVExtensionsKeepTheirDialectWhenFieldPunctuationCompetes() {
        let commaRichTSV = [
            "id\tLast, First, Credential",
            "1\tSmith, Ada, MD",
            "2\tJones, Grace, PhD",
            "3\tDoe, Lin, RN",
        ].joined(separator: "\n") + "\n"
        let sampled = SampledDocumentDetector.detect(
            sample: Data(commaRichTSV.utf8),
            fileName: "people.tsv"
        )

        // Pure content scoring sees three consistent comma fields versus two
        // tab fields. Ordinary-open resolution must still honor the explicit
        // TSV filename; CSV itself remains content-driven for semicolon files.
        XCTAssertEqual(sampled.tableDialect?.delimiter, .comma)
        XCTAssertEqual(
            sampled.resolvedDelimitedTextDelimiter(forPathExtension: "tsv"),
            .tab
        )
        XCTAssertEqual(
            sampled.resolvedDelimitedTextDelimiter(forPathExtension: "PSV"),
            .pipe
        )
        XCTAssertEqual(
            sampled.resolvedDelimitedTextDelimiter(forPathExtension: "csv"),
            .comma
        )
    }

    func testAmpersandsAloneAreNotYAMLButStructuredYAMLStillIs() {
        let table = (0..<18)
            .map { "Provider \($0),Clinic & Rehabilitation,Research & Development" }
            .joined(separator: "\n") + "\n"
        let tableResult = SampledDocumentDetector.detect(sample: Data(table.utf8))
        XCTAssertEqual(tableResult.format, .delimitedText(.comma))

        let yaml = "defaults: &defaults\n  enabled: true\ncopy: *defaults\n"
        let yamlResult = SampledDocumentDetector.detect(
            sample: Data(yaml.utf8),
            fileName: "misnamed.txt"
        )
        XCTAssertEqual(yamlResult.format, .yaml)

        let strongJSON = SampledDocumentDetector.detect(
            sample: Data("{\"still\":\"json\"}".utf8),
            fileName: "misnamed.csv"
        )
        XCTAssertEqual(strongJSON.format, .json)
    }

    func testDelimitedScannerHonorsQuotedSeparatorsAndNewlines() {
        let source = "name,notes\r\nAda,\"hello,\r\nworld\"\r\nLin,calm\r\n"
        let result = SampledDocumentDetector.detect(sample: Data(source.utf8))

        XCTAssertEqual(result.format, .delimitedText(.comma))
        XCTAssertEqual(result.tableDialect?.columnCount, 2)
        XCTAssertEqual(result.tableDialect?.sampledRecordCount, 3)
        XCTAssertEqual(result.tableDialect?.lineEnding, .carriageReturnLineFeed)
    }

    func testTwoRowsAndMarkdownTablesAreNotMisclassifiedAsGenericTables() {
        let tooShort = SampledDocumentDetector.detect(
            sample: Data("left|right\none|two\n".utf8)
        )
        XCTAssertEqual(tooShort.format, .plainText)
        XCTAssertNil(tooShort.tableDialect)

        let markdown = SampledDocumentDetector.detect(
            sample: Data("| Name | Age |\n| --- | --- |\n| Ada | 36 |\n".utf8)
        )
        XCTAssertEqual(markdown.format, .markdown)
        XCTAssertNil(markdown.tableDialect)
    }

    func testNeverInspectsBeyond64KiBPrefix() {
        var source = Data(repeating: 0x61, count: SampledDocumentDetector.maximumSampleByteCount)
        source.append(Data("\n{\"deceptiveTail\":true}".utf8))

        let result = SampledDocumentDetector.detect(sample: source)
        XCTAssertEqual(result.sampledByteCount, SampledDocumentDetector.maximumSampleByteCount)
        XCTAssertEqual(result.format, .plainText)
    }

    func testUTF8SampleBoundaryMaySplitOneValidScalar() {
        let json = Data("{\"ok\":true}".utf8)
        let scalar = Array("😀".utf8)

        for retainedByteCount in 1...3 {
            var sample = json
            sample.append(Data(
                repeating: 0x20,
                count: SampledDocumentDetector.maximumSampleByteCount
                    - json.count
                    - retainedByteCount
            ))
            sample.append(contentsOf: scalar.prefix(retainedByteCount))

            let result = SampledDocumentDetector.detect(sample: sample)
            XCTAssertEqual(
                result.textEncoding.encoding,
                .utf8,
                "retained bytes: \(retainedByteCount)"
            )
            XCTAssertEqual(result.textEncoding.evidence, .validUTF8)
            XCTAssertEqual(result.format, .json)
            XCTAssertEqual(
                result.sampledByteCount,
                SampledDocumentDetector.maximumSampleByteCount
            )
        }
    }

    func testMalformedUTF8TerminalBytesAreNotTrimmedAsSampleBoundary() {
        let malformedSuffixes: [[UInt8]] = [
            [0xFF],             // Illegal lead.
            [0x80],             // Stray continuation.
            [0xE0, 0x80],       // Overlong scalar prefix.
            [0xED, 0xA0],       // UTF-16 surrogate prefix.
            [0xF4, 0x90],       // Greater than U+10FFFF.
            [0xF0, 0x9F, 0x41], // Non-continuation inside a scalar.
        ]

        for suffix in malformedSuffixes {
            var sample = Data(
                repeating: 0x61,
                count: SampledDocumentDetector.maximumSampleByteCount - suffix.count
            )
            sample.append(contentsOf: suffix)

            let result = SampledDocumentDetector.detect(sample: sample)
            XCTAssertNil(result.textEncoding.encoding, "suffix: \(suffix)")
            XCTAssertEqual(result.textEncoding.evidence, .unavailable)
            XCTAssertEqual(result.format, .plainText)
        }
    }

    func testDetectsEverySupportedUnicodeBOMAndClassifiesDecodedContent() throws {
        let source = "name,age\nAda,36\nLin,29\n"
        let cases: [(DocumentTextEncoding, [UInt8])] = [
            (.utf8, [0xEF, 0xBB, 0xBF]),
            (.utf16LittleEndian, [0xFF, 0xFE]),
            (.utf16BigEndian, [0xFE, 0xFF]),
            (.utf32LittleEndian, [0xFF, 0xFE, 0x00, 0x00]),
            (.utf32BigEndian, [0x00, 0x00, 0xFE, 0xFF]),
        ]

        for (encoding, bom) in cases {
            var bytes = Data(bom)
            bytes.append(try XCTUnwrap(source.data(using: encoding.foundationEncoding)))
            let result = SampledDocumentDetector.detect(sample: bytes)
            XCTAssertEqual(result.textEncoding.encoding, encoding)
            XCTAssertEqual(result.textEncoding.byteOrderMarkByteCount, bom.count)
            XCTAssertEqual(result.textEncoding.evidence, .byteOrderMark)
            XCTAssertEqual(result.textEncoding.confidence, .high)
            XCTAssertEqual(result.format, .delimitedText(.comma))
        }
    }

    func testInfersUnmarkedUTF16AndUTF32FromConservativeZeroPatterns() throws {
        let source = "name,age\nAda,36\nLin,29\nGrace,85\n"
        for encoding in [
            DocumentTextEncoding.utf16LittleEndian,
            .utf16BigEndian,
            .utf32LittleEndian,
            .utf32BigEndian,
        ] {
            let bytes = try XCTUnwrap(source.data(using: encoding.foundationEncoding))
            let result = SampledDocumentDetector.detect(sample: bytes)
            XCTAssertEqual(result.textEncoding.encoding, encoding)
            XCTAssertEqual(result.textEncoding.evidence, .bytePattern)
            XCTAssertEqual(result.textEncoding.confidence, .medium)
            XCTAssertEqual(result.format, .delimitedText(.comma))
        }
    }

    func testUnknownEncodingRemainsExplicitlyUnresolved() {
        let result = SampledDocumentDetector.detect(
            sample: Data([0x80, 0x81, 0x82, 0x83, 0x84])
        )
        XCTAssertNil(result.textEncoding.encoding)
        XCTAssertEqual(result.textEncoding.evidence, .unavailable)
        XCTAssertEqual(result.format, .plainText)
        XCTAssertEqual(result.suggestedOpenOptions.encoding, .automatic)
    }

    func testExplicitEncodingDoesNotBorrowConflictingAutomaticBOMInference() throws {
        var utf16 = Data([0xFF, 0xFE])
        utf16.append(try XCTUnwrap(
            "{\"looksLikeJSONOnlyWhenDecodedAsUTF16\":true}"
                .data(using: .utf16LittleEndian)
        ))

        let automatic = SampledDocumentDetector.detect(sample: utf16)
        XCTAssertEqual(automatic.textEncoding.encoding, .utf16LittleEndian)
        XCTAssertEqual(automatic.format, .json)

        let forcedUTF8 = SampledDocumentDetector.detect(
            sample: utf16,
            fileName: "payload.txt",
            assuming: .utf8
        )
        XCTAssertEqual(forcedUTF8.textEncoding.encoding, .utf8)
        XCTAssertEqual(forcedUTF8.textEncoding.evidence, .explicitSelection)
        XCTAssertEqual(forcedUTF8.textEncoding.byteOrderMarkByteCount, 0)
        XCTAssertEqual(forcedUTF8.format, .plainText)
        XCTAssertEqual(forcedUTF8.formatConfidence, .low)
    }

    func testOpenAsModelProvidesSafeUntitledAndFormatExtensions() {
        XCTAssertEqual(DocumentOpenAsFormat.defaultUntitledPathExtension, "txt")
        XCTAssertEqual(DocumentOpenOptions.defaultUntitled.preferredPathExtension, "txt")
        XCTAssertEqual(DocumentOpenOptions.defaultUntitled.format, .plainText)
        XCTAssertEqual(DocumentOpenOptions.defaultUntitled.encoding, .explicit(.utf8))
        XCTAssertEqual(DocumentOpenAsFormat.automatic.preferredPathExtension, "txt")
        XCTAssertEqual(DocumentOpenAsFormat.delimitedText(.tab).preferredPathExtension, "tsv")
        XCTAssertEqual(DocumentOpenAsFormat.delimitedText(.pipe).preferredPathExtension, "psv")

        let emptyTSV = SampledDocumentDetector.detect(sample: Data(), fileName: "untitled.tsv")
        XCTAssertEqual(emptyTSV.format, .delimitedText(.tab))
        XCTAssertEqual(emptyTSV.preferredPathExtension, "tsv")
        XCTAssertEqual(emptyTSV.formatConfidence, .low)

        let emptyPSV = SampledDocumentDetector.detect(sample: Data(), fileName: "untitled.PSV")
        XCTAssertEqual(emptyPSV.format, .delimitedText(.pipe))
        XCTAssertEqual(emptyPSV.preferredPathExtension, "psv")
        XCTAssertEqual(emptyPSV.formatConfidence, .low)
    }

    func testAutomaticOpenKeepsEveryKnownExtensionAuthoritative() {
        let adversarialSample = SampledDocumentDetection(
            format: .yaml,
            formatConfidence: .high,
            textEncoding: TextEncodingDetection(
                encoding: .utf8,
                byteOrderMarkByteCount: 0,
                confidence: .high,
                evidence: .validUTF8
            ),
            tableDialect: nil,
            sampledByteCount: 64
        )
        let cases: [(String, SyntaxFileType)] = [
            ("txt", .plainText),
            ("json", .json),
            ("md", .markdown),
            ("sql", .sql),
            ("xml", .xml),
            ("csv", .csv),
            ("tsv", .csv),
            ("psv", .csv),
            ("yaml", .yaml),
            ("parquet", .parquet),
        ]
        for (pathExtension, expected) in cases {
            XCTAssertEqual(
                adversarialSample.resolvedSyntaxFileType(
                    forPathExtension: pathExtension,
                    parquetMagicDetected: true
                ),
                expected,
                pathExtension
            )
        }
        XCTAssertEqual(
            adversarialSample.resolvedSyntaxFileType(forPathExtension: "unknown"),
            .yaml
        )
        XCTAssertEqual(
            adversarialSample.resolvedSyntaxFileType(
                forPathExtension: "unknown",
                parquetMagicDetected: true
            ),
            .parquet
        )
    }

    private func assertFormat(
        _ source: String,
        is expected: DocumentOpenAsFormat,
        confidence: SampleDetectionConfidence,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let result = SampledDocumentDetector.detect(sample: Data(source.utf8))
        XCTAssertEqual(result.format, expected, file: file, line: line)
        XCTAssertEqual(result.formatConfidence, confidence, file: file, line: line)
        XCTAssertNil(result.tableDialect, file: file, line: line)
    }
}
