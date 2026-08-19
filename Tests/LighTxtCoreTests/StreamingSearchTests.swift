import XCTest
@testable import LighTxt

final class StreamingSearchTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LighTxtSearchTests-\(UUID().uuidString)", isDirectory: true)
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

    func testLiteralSearchCrossesPieceBoundaries() throws {
        let table = try makeTable("alphaomega")
        try table.insert(utf8: "-needle-", at: 5)
        let snapshot = try table.snapshot()

        let match = try snapshot.firstMatch(for: .literal("a-needle-o"))
        XCTAssertEqual(match?.byteRange, 4..<14)
    }

    func testOverlappingLiteralMatches() throws {
        let snapshot = try makeTable("aaaa").snapshot()
        var overlapping = SearchOptions()
        overlapping.allowsOverlappingMatches = true
        let all = try snapshot.allMatches(for: .literal("aa"), options: overlapping)
        XCTAssertEqual(all.matches.map(\.byteRange), [0..<2, 1..<3, 2..<4])

        let nonoverlapping = try snapshot.allMatches(for: .literal("aa"))
        XCTAssertEqual(nonoverlapping.matches.map(\.byteRange), [0..<2, 2..<4])
    }

    func testASCIICaseInsensitiveLiteralPreservesByteOffsets() throws {
        let snapshot = try makeTable("One ONE one").snapshot()
        var options = SearchOptions()
        options.caseSensitive = false
        let all = try snapshot.allMatches(for: .literal("one"), options: options)
        XCTAssertEqual(all.matches.map(\.byteRange), [0..<3, 4..<7, 8..<11])
    }

    func testWholeWordLiteralSearchRemainsStreamingAndHonorsRangeContext() throws {
        let snapshot = try makeTable("foo food Foo _foo foo_ foo").snapshot()
        var options = SearchOptions(caseSensitive: false, matchesWholeWords: true)
        options.progressIntervalByteCount = 64 << 10

        let all = try snapshot.allMatches(for: .literal("foo"), options: options)
        XCTAssertEqual(all.matches.map(\.byteRange), [0..<3, 9..<12, 23..<26])

        let rangeBeginningInsideWord = try snapshot.allMatches(
            for: .literal("foo"),
            in: 5..<snapshot.byteCount,
            options: options
        )
        XCTAssertEqual(rangeBeginningInsideWord.matches.map(\.byteRange), [9..<12, 23..<26])
    }

    func testRegexAcrossChunkAndPieceBoundaryWithCaptures() throws {
        let prefix = String(repeating: "a", count: 4_093)
        let table = try makeTable(prefix + " tail")
        try table.insert(utf8: "needle-42", at: 4_093)
        let snapshot = try table.snapshot()
        var options = SearchOptions(
            regexChunkByteCount: 4_096,
            regexContextByteCount: 64
        )
        options.regexUsesAnchorsMatchLines = false

        let match = try snapshot.firstMatch(
            for: .regularExpression("needle-(\\d{1,8})"),
            options: options
        )
        XCTAssertEqual(match?.byteRange, 4_093..<4_102)
        XCTAssertEqual(match?.captureByteRanges[1], 4_100..<4_102)
    }

    func testUnicodeRegexReportsUTF8ByteOffsets() throws {
        let snapshot = try makeTable("a🌿 café 🌿z").snapshot()
        let result = try snapshot.allMatches(for: .regularExpression("🌿"))
        XCTAssertEqual(result.matches.map(\.byteRange), [1..<5, 12..<16])
    }

    func testExactRegexSupportsCommonBoundariesClassesAndUnboundedRepetition() throws {
        let snapshot = try makeTable(
            "food bar\nfoo.    bar is good\nfoo is not a bar\nfoobar is not good\n"
        ).snapshot()

        let result = try snapshot.allMatches(
            for: .regularExpression("\\bfoo\\b[\\s.]*\\bbar\\b")
        )

        XCTAssertEqual(result.matches.map(\.byteRange), [9..<20])
    }

    func testExactRegexAnchorsUseDocumentAndLineContext() throws {
        let snapshot = try makeTable("zero\nfoo one\nfoo two\nend").snapshot()

        let lineMatches = try snapshot.allMatches(
            for: .regularExpression("^foo.+$")
        )
        XCTAssertEqual(lineMatches.matches.map(\.byteRange), [5..<12, 13..<20])

        let partialRange = try snapshot.allMatches(
            for: .regularExpression("^foo"),
            in: 7..<snapshot.byteCount
        )
        XCTAssertEqual(partialRange.matches.map(\.byteRange), [13..<16])
    }

    func testExactRegexCapturesRetainUTF8ByteRanges() throws {
        let snapshot = try makeTable("🌿 café-42 🌿").snapshot()
        let match = try XCTUnwrap(snapshot.firstMatch(
            for: .regularExpression("(café)-(\\d+)")
        ))

        XCTAssertEqual(match.byteRange, 5..<13)
        XCTAssertEqual(match.captureByteRanges[1], 5..<10)
        XCTAssertEqual(match.captureByteRanges[2], 11..<13)

        let replacement = try match.expandingUTF8ReplacementTemplate(
            "$2 / $1 / $$ / $9",
            in: snapshot
        )
        XCTAssertEqual(String(decoding: replacement, as: UTF8.self), "42 / café / $ / ")
    }

    func testContextDependentRegexAboveExactCapFailsBeforeReturningResults() throws {
        let snapshot = try makeTable(String(repeating: "x", count: 4_097) + " foo bar").snapshot()
        let options = SearchOptions(
            regexChunkByteCount: 4_096,
            regexContextByteCount: 0,
            maximumRegexWindowByteCount: 8_192,
            maximumExactRegexDocumentByteCount: 4_096
        )
        var emitted: [SearchMatch] = []

        XCTAssertThrowsError(
            try snapshot.search(
                .regularExpression("\\bfoo\\s+bar\\b"),
                options: options
            ) { match in
                emitted.append(match)
                return true
            }
        ) { error in
            guard case let .regularExpressionRequiresExactSearch(documentBytes, maximumBytes, _)
                = error as? LighTxtCoreError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertGreaterThan(documentBytes, maximumBytes)
            XCTAssertEqual(maximumBytes, 4_096)
        }
        XCTAssertTrue(emitted.isEmpty)
    }

    func testExactRegexStillRejectsProvenExplosiveBacktracking() throws {
        // Keep the subject intentionally tiny: rejection must happen in the
        // static preflight, before Foundation attempts any matching work.
        let snapshot = try makeTable("aa").snapshot()

        for expression in [
            "(a|aa){0,1000}",
            "(a+)+$",
            "(a|aa)+$",
            "(?:a*){1,1000}$",
            "^(a+)+$",
            "\\b(a|aa)+$",
            "(a{2,})+$",
            "(?=a)(a+)+$",
            "(?!b)(a+)+$",
            "(?<=a)(a|aa)+$",
            "(?<!b)(a+)+$",
            "(?>a)(a{2,})+$",
            "(?<letter>a)\\k<letter>(a+)+$",
            "(a)\\1(a|aa)+$",
            "(?i:a)(a+)+$",
            "(?# harmless)(a+)+$",
            "\\Q(?=fake)\\E(a+)+$",
            "(?x)# ignored (text)\n(a+)+$",
            "a+a+$",
            "a*a*a*b",
            ".*.*X",
            "a{1,}a{1,}$",
            "a+\\ba+$",
        ] {
            XCTAssertThrowsError(
                try snapshot.firstMatch(for: .regularExpression(expression)),
                "Expected static rejection for \(expression)"
            ) { error in
                guard case .unsupportedRegularExpression = error as? LighTxtCoreError else {
                    return XCTFail("Unexpected error for \(expression): \(error)")
                }
            }
        }
    }

    func testExactRegexAllowsDisjointAdjacentUnboundedClasses() throws {
        let snapshot = try makeTable("foo 123 bar").snapshot()

        let match = try snapshot.firstMatch(
            for: .regularExpression("\\w+\\s+\\w+")
        )

        XCTAssertEqual(match?.byteRange, 0..<7)
    }

    func testExactRegexDeadlineStopsBeforeReturningPartialResults() throws {
        let snapshot = try makeTable("alpha alpha").snapshot()
        let options = SearchOptions(maximumExactRegexDuration: 0)
        var emitted: [SearchMatch] = []

        XCTAssertThrowsError(
            try snapshot.search(
                .regularExpression("alpha"),
                options: options
            ) { match in
                emitted.append(match)
                return true
            }
        ) { error in
            guard case let .regularExpressionTimedOut(maximumDuration)
                = error as? LighTxtCoreError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(maximumDuration, 0)
        }
        XCTAssertTrue(emitted.isEmpty)
    }

    func testExactRegexFindNextRangesCanWrapWithoutCreatingFalseAnchors() throws {
        let snapshot = try makeTable("foo first\nother\nfoo last").snapshot()
        let pattern = SearchPattern.regularExpression("^foo\\s+\\w+")

        let afterLast = try snapshot.firstMatch(
            for: pattern,
            in: 20..<snapshot.byteCount
        )
        XCTAssertNil(afterLast)

        let wrapped = try snapshot.firstMatch(for: pattern, in: 0..<20)
        XCTAssertEqual(wrapped?.byteRange, 0..<9)
    }

    func testRegexPreservesGlobalNonOverlapCursorAcrossChunks() throws {
        let byteCount = 8_205
        let snapshot = try makeTable(String(repeating: "a", count: byteCount)).snapshot()
        let options = SearchOptions(
            regexChunkByteCount: 4_096,
            regexContextByteCount: 0,
            maximumRegexWindowByteCount: 8_192
        )

        let result = try snapshot.allMatches(
            for: .regularExpression("a{3}"),
            options: options,
            limit: 10_000
        )
        let expected = stride(from: 0, through: byteCount - 3, by: 3).map {
            Int64($0)..<Int64($0 + 3)
        }
        XCTAssertEqual(result.matches.map(\.byteRange), expected)
        XCTAssertTrue(expected.contains(4_095..<4_098))
    }

    func testRegexAutomaticallyProvidesProvenBoundaryContext() throws {
        let snapshot = try makeTable(
            String(repeating: "x", count: 4_093) + "ZZZZZZZZ-tail"
        ).snapshot()
        let options = SearchOptions(
            regexChunkByteCount: 4_096,
            regexContextByteCount: 0,
            maximumRegexWindowByteCount: 8_192
        )

        let match = try snapshot.firstMatch(
            for: .regularExpression("Z{8}"),
            options: options
        )
        XCTAssertEqual(match?.byteRange, 4_093..<4_101)
    }

    func testZeroWidthRegexAdvancesAcrossChunksAndOwnsEOFOnce() throws {
        let byteCount = 4_101
        let snapshot = try makeTable(String(repeating: "b", count: byteCount)).snapshot()
        let options = SearchOptions(
            regexChunkByteCount: 4_096,
            regexContextByteCount: 0,
            maximumRegexWindowByteCount: 8_192
        )

        let result = try snapshot.allMatches(
            for: .regularExpression("a{0}"),
            options: options,
            limit: 10_000
        )
        XCTAssertEqual(result.matches.count, byteCount + 1)
        XCTAssertEqual(result.matches.first?.byteRange, 0..<0)
        XCTAssertEqual(result.matches[4_096].byteRange, 4_096..<4_096)
        XCTAssertEqual(result.matches.last?.byteRange, Int64(byteCount)..<Int64(byteCount))
    }

    func testCaseInsensitiveRegexAccountsForFullUnicodeFoldExpansion() throws {
        let decomposed = "ι\u{0308}\u{0301}"
        let snapshot = try makeTable(decomposed).snapshot()
        var options = SearchOptions()
        options.caseSensitive = false

        let match = try snapshot.firstMatch(
            for: .regularExpression("ΐ"),
            options: options
        )
        XCTAssertEqual(match?.byteRange, 0..<6)
    }

    func testOverlappingRegexSearchIsExplicitlyRejected() throws {
        let snapshot = try makeTable("aaaa").snapshot()
        var options = SearchOptions()
        options.allowsOverlappingMatches = true

        assertUnsupportedRegex("a{2}", snapshot: snapshot, options: options)
    }

    func testUnboundedRegexQuantifiersAreExplicitlyRejected() throws {
        let snapshot = try makeTable("aaaa").snapshot()
        for expression in ["a*", "a+", "a{2,}", "(?:ab)+"] {
            assertUnsupportedRegex(expression, snapshot: snapshot)
        }
    }

    func testContextDependentRegexConstructsAreExplicitlyRejected() throws {
        let snapshot = try makeTable("word ab aa").snapshot()
        let expressions = [
            "^word", "word$", "\\Aword", "word\\Z", "word\\z", "\\Gword",
            "\\bword\\B", "a(?=b)", "a(?!b)", "(?<=a)b", "(?<!a)b",
            "(a)\\1", "\\X", "\\C", "(?i:a)", "(?>a)", "(?<name>a)",
        ]
        for expression in expressions {
            assertUnsupportedRegex(expression, snapshot: snapshot)
        }
    }

    func testBoundedCatastrophicRegexFormsAreExplicitlyRejected() throws {
        let snapshot = try makeTable(String(repeating: "a", count: 1_000)).snapshot()
        for expression in [
            "(a|aa){0,1000}",
            "(a{0,2}){0,1000}",
            "a{0,100000}a{0,100000}b",
            String(repeating: "a?", count: 13),
        ] {
            assertUnsupportedRegex(expression, snapshot: snapshot)
        }
    }

    func testRegexWhoseProofCannotFitWindowIsRejectedBeforeMatching() throws {
        let snapshot = try makeTable(String(repeating: "a", count: 2_000)).snapshot()
        let options = SearchOptions(
            regexChunkByteCount: 4_096,
            regexContextByteCount: 0,
            maximumRegexWindowByteCount: 4_096,
            maximumExactRegexDocumentByteCount: 0
        )

        XCTAssertThrowsError(
            try snapshot.firstMatch(
                for: .regularExpression("a{1024}"),
                options: options
            )
        ) { error in
            guard case let .regularExpressionExceedsWindow(required, maximum)
                = error as? LighTxtCoreError else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertGreaterThan(required, maximum)
            XCTAssertEqual(maximum, 4_096)
        }
    }

    func testRegexSafetyErrorsHaveUserFacingDescriptions() {
        let unsupported = LighTxtCoreError.unsupportedRegularExpression("lookahead")
        let tooLarge = LighTxtCoreError.regularExpressionExceedsWindow(
            requiredByteCount: 8_000,
            maximumByteCount: 4_096
        )
        let underestimated = LighTxtCoreError.regularExpressionMatchExceedsAnalyzedBound(
            matchByteCount: 12,
            analyzedMaximumByteCount: 4
        )
        let timedOut = LighTxtCoreError.regularExpressionTimedOut(maximumDuration: 2)

        XCTAssertFalse(unsupported.localizedDescription.isEmpty)
        XCTAssertTrue(tooLarge.localizedDescription.contains("4096-byte"))
        XCTAssertTrue(underestimated.localizedDescription.contains("Search stopped"))
        XCTAssertTrue(timedOut.localizedDescription.contains("2"))
    }

    func testCancellationAndResultLimit() throws {
        let snapshot = try makeTable(String(repeating: "x", count: 100_000)).snapshot()
        let token = CancellationToken()
        token.cancel()
        let cancelled = try snapshot.allMatches(for: .literal("x"), cancellation: token)
        XCTAssertEqual(cancelled.search.stopReason, .cancelled)

        let limited = try snapshot.allMatches(for: .literal("x"), limit: 7)
        XCTAssertEqual(limited.matches.count, 7)
        XCTAssertEqual(limited.search.stopReason, .resultLimitReached)
    }

    func testInvalidRegexAndInvalidUTF8AreReported() throws {
        let validSnapshot = try makeTable("text").snapshot()
        XCTAssertThrowsError(
            try validSnapshot.firstMatch(for: .regularExpression("["))
        )

        let url = temporaryDirectory.appendingPathComponent("invalid.bin")
        try Data([0xff, 0xfe]).write(to: url)
        let invalidSnapshot = try FileBackedPieceTable(opening: url).snapshot()
        XCTAssertThrowsError(
            try invalidSnapshot.firstMatch(for: .regularExpression("."))
        )
    }

    private func makeTable(_ string: String) throws -> FileBackedPieceTable {
        let url = temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data(string.utf8).write(to: url)
        return try FileBackedPieceTable(opening: url)
    }

    private func assertUnsupportedRegex(
        _ expression: String,
        snapshot: DocumentSnapshot,
        options: SearchOptions = SearchOptions(
            maximumExactRegexDocumentByteCount: 0
        ),
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try snapshot.firstMatch(
                for: .regularExpression(expression),
                options: options
            ),
            file: file,
            line: line
        ) { error in
            switch error as? LighTxtCoreError {
            case .unsupportedRegularExpression,
                 .regularExpressionRequiresExactSearch:
                break
            default:
                XCTFail(
                    "Expected a bounded-search regex error for \(expression), got \(error)",
                    file: file,
                    line: line
                )
            }
        }
    }
}
