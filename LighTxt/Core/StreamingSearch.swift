import Foundation

public nonisolated enum SearchPattern: Sendable, Equatable {
    case literal(Data)
    case regularExpression(String)

    public static func literal(_ string: String) -> SearchPattern {
        .literal(Data(string.utf8))
    }
}

public nonisolated struct SearchOptions: Sendable, Equatable {
    /// Literal searches use byte-exact matching. When false, only ASCII letters
    /// are folded, preserving byte offsets and fully streaming operation.
    public var caseSensitive: Bool
    /// Literal matches must be separated from adjacent ASCII/UTF-8 word bytes.
    /// This remains streaming and does not translate the query into a regex.
    public var matchesWholeWords: Bool
    public var allowsOverlappingMatches: Bool

    public var regexUsesAnchorsMatchLines: Bool
    public var regexDotMatchesNewlines: Bool

    /// Owned bytes per regex window. Literal search does not allocate chunks.
    public var regexChunkByteCount: Int
    /// Preferred right context for each regex chunk. Safe bounded expressions
    /// automatically receive at least their proven maximum match width.
    public var regexContextByteCount: Int
    /// Hard upper bound for each owned regex window. Expressions whose proven
    /// bound cannot fit are rejected before search begins.
    public var maximumRegexWindowByteCount: Int
    /// Documents at or below this size use Foundation's full-document regex
    /// semantics. This supports anchors, boundaries, lookarounds, and
    /// unbounded quantifiers without treating a streaming window edge as file
    /// content, while retaining a hard memory ceiling.
    public var maximumExactRegexDocumentByteCount: Int
    /// Monotonic wall-clock deadline for Foundation's exact regex engine.
    /// Progress/result callbacks stop enumeration when this limit is reached.
    public var maximumExactRegexDuration: TimeInterval
    public var progressIntervalByteCount: Int64

    public init(
        caseSensitive: Bool = true,
        matchesWholeWords: Bool = false,
        allowsOverlappingMatches: Bool = false,
        regexUsesAnchorsMatchLines: Bool = true,
        regexDotMatchesNewlines: Bool = false,
        regexChunkByteCount: Int = 1 << 20,
        regexContextByteCount: Int = 64 << 10,
        maximumRegexWindowByteCount: Int = 16 << 20,
        maximumExactRegexDocumentByteCount: Int = 16 << 20,
        maximumExactRegexDuration: TimeInterval = 2,
        progressIntervalByteCount: Int64 = 4 << 20
    ) {
        self.caseSensitive = caseSensitive
        self.matchesWholeWords = matchesWholeWords
        self.allowsOverlappingMatches = allowsOverlappingMatches
        self.regexUsesAnchorsMatchLines = regexUsesAnchorsMatchLines
        self.regexDotMatchesNewlines = regexDotMatchesNewlines
        self.regexChunkByteCount = max(4 << 10, regexChunkByteCount)
        self.regexContextByteCount = max(0, regexContextByteCount)
        self.maximumRegexWindowByteCount = max(
            self.regexChunkByteCount,
            maximumRegexWindowByteCount
        )
        self.maximumExactRegexDocumentByteCount = max(
            0,
            maximumExactRegexDocumentByteCount
        )
        self.maximumExactRegexDuration = maximumExactRegexDuration.isFinite
            ? min(60, max(0, maximumExactRegexDuration))
            : 2
        self.progressIntervalByteCount = max(64 << 10, progressIntervalByteCount)
    }
}

public nonisolated struct SearchMatch: Sendable, Equatable {
    public let byteRange: Range<Int64>
    /// Capture group 0 followed by explicit capture groups. An unmatched group
    /// is nil. Literal matches contain only their full byte range.
    public let captureByteRanges: [Range<Int64>?]

    public init(
        byteRange: Range<Int64>,
        captureByteRanges: [Range<Int64>?] = []
    ) {
        self.byteRange = byteRange
        self.captureByteRanges = captureByteRanges.isEmpty
            ? [byteRange]
            : captureByteRanges
    }

    /// Expands the `$0`...`$99` and `$$` syntax used by Replace Current.
    /// Replace All has a separate streaming expansion path so large capture
    /// bytes never need to be materialized together.
    public func expandingUTF8ReplacementTemplate(
        _ template: String,
        in snapshot: DocumentSnapshot
    ) throws -> Data {
        let bytes = Array(template.utf8)
        var output = Data()
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            guard bytes[index] == 0x24 else {
                output.append(bytes[index])
                index += 1
                continue
            }
            if index + 1 < bytes.count, bytes[index + 1] == 0x24 {
                output.append(0x24)
                index += 2
                continue
            }
            var cursor = index + 1
            var group = 0
            var digits = 0
            while cursor < bytes.count,
                  digits < 2,
                  (0x30...0x39).contains(bytes[cursor]) {
                group = group * 10 + Int(bytes[cursor] - 0x30)
                digits += 1
                cursor += 1
            }
            guard digits > 0 else {
                output.append(0x24)
                index += 1
                continue
            }
            if group < captureByteRanges.count,
               let range = captureByteRanges[group] {
                output.append(try snapshot.data(in: range))
            }
            index = cursor
        }
        return output
    }
}

public nonisolated struct SearchProgress: Sendable, Equatable {
    public let processedBytes: Int64
    public let totalBytes: Int64
    public let matchesFound: Int

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 1 }
        return min(1, Double(processedBytes) / Double(totalBytes))
    }
}

public nonisolated enum SearchStopReason: Sendable, Equatable {
    case completed
    case cancelled
    case matchHandlerRequestedStop
    case resultLimitReached
}

public nonisolated struct SearchResult: Sendable, Equatable {
    public let matchesFound: Int
    public let processedBytes: Int64
    public let stopReason: SearchStopReason
}

public nonisolated struct CollectedSearchResult: Sendable, Equatable {
    public let matches: [SearchMatch]
    public let search: SearchResult
}

private nonisolated enum SearchInterruption: Error {
    case cancelled
    case stopped
}

/// Foundation does not expose an incremental regex engine. Before a regex is
/// allowed onto the bounded-window path, this parser proves a conservative
/// upper bound for every possible match and rejects constructs whose result
/// depends on bytes outside that match. Foundation still performs the actual
/// syntax validation and matching.
private nonisolated struct BoundedRegexAnalysis {
    let maximumMatchByteCount: Int64

    init(expression: String, caseSensitive: Bool) throws {
        var parser = BoundedRegexParser(
            expression: expression,
            // Unicode full case folding can expand one scalar into several
            // scalars. Twelve bytes covers the Unicode maximum of three UTF-8
            // scalars while preserving a simple per-atom proof.
            maximumScalarByteCount: caseSensitive ? 4 : 12
        )
        let parsed = try parser.parse()
        guard !parsed.containsUnboundedQuantifier else {
            throw LighTxtCoreError.unsupportedRegularExpression(
                "unbounded quantifiers (* and +) require exact full-document regex; use an explicit upper bound for streaming search"
            )
        }
        maximumMatchByteCount = parsed.maximumByteCount
    }
}

/// A syntax-tolerant, full-pattern safety pass for Foundation's exact regex
/// path. This scanner is intentionally independent from the bounded-width
/// proof below: exact-only constructs such as lookarounds, named/atomic groups,
/// backreferences, quoted regions, and inline options are consumed without
/// ending the scan. That prevents an unsupported prefix from hiding explosive
/// nested repetition later in an otherwise valid expression.
private nonisolated enum ExactRegexResponsivenessPreflight {
    static func validate(expression: String) throws {
        var scanner = ExactRegexRiskScanner(expression: expression)
        try scanner.scan()
    }
}

private nonisolated struct ExactRegexRiskNode {
    var containsAlternation = false
    var containsQuantifier = false
    var backtrackingChoiceCount: Int64 = 1
    var isDefinitelyZeroWidth = false
    var consumptionDomain = ExactRegexConsumptionDomain.unknown
    var leadingUnboundedDomain: ExactRegexConsumptionDomain?
    var trailingUnboundedDomain: ExactRegexConsumptionDomain?
}

private nonisolated enum ExactRegexConsumptionDomain: Equatable {
    case literal(UInt32)
    case escapedLiteral(UInt32)
    case digit
    case whitespace
    case word
    case any
    case characterClass
    case unknown

    func mayOverlap(with other: Self) -> Bool {
        switch (self, other) {
        case let (.literal(lhs), .literal(rhs)),
             let (.escapedLiteral(lhs), .escapedLiteral(rhs)):
            return lhs == rhs
        case let (.literal(value), .digit),
             let (.digit, .literal(value)):
            return (0x30...0x39).contains(value)
        case let (.literal(value), .whitespace),
             let (.whitespace, .literal(value)):
            return Self.isASCIIWhitespace(value)
        case let (.literal(value), .word),
             let (.word, .literal(value)):
            return Self.isASCIIWord(value) || value > 0x7f
        case (.digit, .whitespace), (.whitespace, .digit),
             (.word, .whitespace), (.whitespace, .word):
            return false
        case (.digit, .word), (.word, .digit),
             (.digit, .digit), (.whitespace, .whitespace), (.word, .word):
            return true
        case (.any, _), (_, .any),
             (.characterClass, _), (_, .characterClass),
             (.unknown, _), (_, .unknown):
            return true
        default:
            // Differently spelled escaped literals and literal-vs-escaped
            // pairs are not proven disjoint (for example `\n` and a newline).
            return true
        }
    }

    private static func isASCIIWhitespace(_ value: UInt32) -> Bool {
        value == 0x20 || (0x09...0x0d).contains(value)
    }

    private static func isASCIIWord(_ value: UInt32) -> Bool {
        (0x30...0x39).contains(value)
            || (0x41...0x5a).contains(value)
            || value == 0x5f
            || (0x61...0x7a).contains(value)
    }
}

private nonisolated struct ExactRegexRiskQuantifier {
    let lowerBound: Int64
    /// `nil` represents `*`, `+`, or an open-ended `{n,}` quantifier.
    let upperBound: Int64?

    var isUnbounded: Bool { upperBound == nil }
    var isVariable: Bool { upperBound == nil || lowerBound != upperBound }
}

/// This is not a second regex compiler. Foundation has already validated the
/// expression before this scanner runs. Its only job is to reach EOF while
/// respecting constructs that may contain metacharacters, and conservatively
/// reject repetition shapes with an unbounded or excessive backtracking tree.
private nonisolated struct ExactRegexRiskScanner {
    private static let maximumBacktrackingDecisions = 12
    private static let maximumBacktrackingChoiceCount: Int64 = 1_000_000

    private let scalars: [Unicode.Scalar]
    private var index = 0
    private var backtrackingDecisions = 0

    init(expression: String) {
        scalars = Array(expression.unicodeScalars)
    }

    mutating func scan() throws {
        var extendedMode = false
        _ = try parseAlternation(
            stopAtClosingParenthesis: false,
            extendedMode: &extendedMode
        )

        // Foundation compilation guarantees balanced syntax, but consuming a
        // defensive stray token is preferable to ever treating a partial scan
        // as a successful preflight.
        while index < scalars.count {
            index += 1
            _ = try parseAlternation(
                stopAtClosingParenthesis: false,
                extendedMode: &extendedMode
            )
        }
    }

    private mutating func parseAlternation(
        stopAtClosingParenthesis: Bool,
        extendedMode: inout Bool
    ) throws -> ExactRegexRiskNode {
        var node = try parseSequence(
            stopAtClosingParenthesis: stopAtClosingParenthesis,
            extendedMode: &extendedMode
        )
        while true {
            skipIgnored(inExtendedMode: extendedMode)
            guard currentValue == 0x7c else { break } // |
            index += 1
            try registerBacktrackingDecision()
            let branch = try parseSequence(
                stopAtClosingParenthesis: stopAtClosingParenthesis,
                extendedMode: &extendedMode
            )
            node.containsAlternation = true
            node.containsQuantifier = node.containsQuantifier
                || branch.containsQuantifier
            node.backtrackingChoiceCount = try checkedChoiceAdd(
                node.backtrackingChoiceCount,
                branch.backtrackingChoiceCount
            )
            node.leadingUnboundedDomain = combinedPossibleDomain(
                node.leadingUnboundedDomain,
                branch.leadingUnboundedDomain
            )
            node.trailingUnboundedDomain = combinedPossibleDomain(
                node.trailingUnboundedDomain,
                branch.trailingUnboundedDomain
            )
            node.isDefinitelyZeroWidth = node.isDefinitelyZeroWidth
                && branch.isDefinitelyZeroWidth
            if node.consumptionDomain != branch.consumptionDomain {
                node.consumptionDomain = .unknown
            }
        }
        return node
    }

    private mutating func parseSequence(
        stopAtClosingParenthesis: Bool,
        extendedMode: inout Bool
    ) throws -> ExactRegexRiskNode {
        var node = ExactRegexRiskNode(isDefinitelyZeroWidth: true)
        while index < scalars.count {
            skipIgnored(inExtendedMode: extendedMode)
            guard let value = currentValue else { break }
            if value == 0x7c { break } // |
            if stopAtClosingParenthesis, value == 0x29 { break } // )

            let start = index
            let atom = try parseRepeatedAtom(
                stopAtClosingParenthesis: stopAtClosingParenthesis,
                extendedMode: &extendedMode
            )
            if let previousDomain = node.trailingUnboundedDomain,
               let nextDomain = atom.leadingUnboundedDomain,
               previousDomain.mayOverlap(with: nextDomain) {
                throw responsivenessError(
                    "adjacent unbounded repetitions can consume the same text and cause uninterruptible catastrophic backtracking"
                )
            }

            let nodeWasZeroWidth = node.isDefinitelyZeroWidth
            node.containsAlternation = node.containsAlternation
                || atom.containsAlternation
            node.containsQuantifier = node.containsQuantifier
                || atom.containsQuantifier
            node.backtrackingChoiceCount = try checkedChoiceMultiply(
                node.backtrackingChoiceCount,
                atom.backtrackingChoiceCount
            )
            if nodeWasZeroWidth {
                node.leadingUnboundedDomain = atom.leadingUnboundedDomain
                node.consumptionDomain = atom.consumptionDomain
            }
            if !atom.isDefinitelyZeroWidth {
                node.trailingUnboundedDomain = atom.trailingUnboundedDomain
                if !nodeWasZeroWidth {
                    node.consumptionDomain = .unknown
                }
            }
            node.isDefinitelyZeroWidth = nodeWasZeroWidth
                && atom.isDefinitelyZeroWidth
            if index == start { index += 1 }
        }
        return node
    }

    private mutating func parseRepeatedAtom(
        stopAtClosingParenthesis: Bool,
        extendedMode: inout Bool
    ) throws -> ExactRegexRiskNode {
        var atom = try parseAtom(
            stopAtClosingParenthesis: stopAtClosingParenthesis,
            extendedMode: &extendedMode
        )
        skipIgnored(inExtendedMode: extendedMode)
        guard let quantifier = parseQuantifier() else { return atom }

        skipIgnored(inExtendedMode: extendedMode)
        if currentValue == 0x3f || currentValue == 0x2b { // lazy / possessive
            index += 1
        }

        if quantifier.isUnbounded,
           atom.containsAlternation || atom.containsQuantifier {
            throw responsivenessError(
                "nesting an unbounded quantifier around an alternation or another quantified expression can cause uninterruptible catastrophic backtracking"
            )
        }
        if let upperBound = quantifier.upperBound,
           upperBound > 1,
           atom.containsAlternation || atom.containsQuantifier {
            throw responsivenessError(
                "repeating an alternation or another quantified expression can cause uninterruptible catastrophic backtracking"
            )
        }

        if quantifier.isVariable, !quantifier.isUnbounded {
            try registerBacktrackingDecision()
        }
        if let upperBound = quantifier.upperBound {
            let choiceWidth = boundedAdd(
                max(0, upperBound - quantifier.lowerBound),
                1
            )
            atom.backtrackingChoiceCount = try checkedChoiceMultiply(
                atom.backtrackingChoiceCount,
                choiceWidth
            )
        }

        if quantifier.isUnbounded, !atom.isDefinitelyZeroWidth {
            atom.leadingUnboundedDomain = atom.consumptionDomain
            atom.trailingUnboundedDomain = atom.consumptionDomain
        } else if quantifier.upperBound == 0 {
            atom.isDefinitelyZeroWidth = true
            atom.leadingUnboundedDomain = nil
            atom.trailingUnboundedDomain = nil
        }
        atom.containsQuantifier = true
        return atom
    }

    private mutating func parseAtom(
        stopAtClosingParenthesis: Bool,
        extendedMode: inout Bool
    ) throws -> ExactRegexRiskNode {
        guard let value = currentValue else { return ExactRegexRiskNode() }
        switch value {
        case 0x28: // (
            return try parseGroup(extendedMode: &extendedMode)
        case 0x5b: // [
            consumeCharacterClass()
            return ExactRegexRiskNode(consumptionDomain: .characterClass)
        case 0x5c: // \\
            let escape = consumeEscape()
            return ExactRegexRiskNode(
                isDefinitelyZeroWidth: escape.isZeroWidth,
                consumptionDomain: escape.domain
            )
        case 0x5e, 0x24: // ^ $
            index += 1
            return ExactRegexRiskNode(isDefinitelyZeroWidth: true)
        case 0x2e: // .
            index += 1
            return ExactRegexRiskNode(consumptionDomain: .any)
        case 0x29 where !stopAtClosingParenthesis: // defensive stray ) at top level
            index += 1
            return ExactRegexRiskNode(isDefinitelyZeroWidth: true)
        default:
            index += 1
            return ExactRegexRiskNode(consumptionDomain: .literal(value))
        }
    }

    private mutating func parseGroup(
        extendedMode: inout Bool
    ) throws -> ExactRegexRiskNode {
        index += 1 // (
        guard currentValue == 0x3f else { // ordinary capturing group
            return try parseGroupBody(inheriting: extendedMode)
        }
        index += 1 // ?

        switch currentValue {
        case 0x23: // (?# comment )
            consumeCommentGroup()
            return ExactRegexRiskNode(isDefinitelyZeroWidth: true)
        case 0x3a, 0x3e, 0x7c: // ?: ?> ?|
            index += 1
            return try parseGroupBody(inheriting: extendedMode)
        case 0x3d, 0x21: // ?= ?!
            index += 1
            let contents = try parseGroupBody(inheriting: extendedMode)
            return zeroWidthNode(preservingRiskFrom: contents)
        case 0x3c: // lookbehind or (?<name>...)
            index += 1
            if currentValue == 0x3d || currentValue == 0x21 {
                index += 1
                let contents = try parseGroupBody(inheriting: extendedMode)
                return zeroWidthNode(preservingRiskFrom: contents)
            } else {
                consume(until: 0x3e) // >
            }
            return try parseGroupBody(inheriting: extendedMode)
        case 0x27: // (?'name'...)
            index += 1
            consume(until: 0x27)
            return try parseGroupBody(inheriting: extendedMode)
        default:
            break
        }

        if let optionGroup = parseOptionGroupHeader(inheriting: extendedMode) {
            if optionGroup.hasBody {
                return try parseGroupBody(inheriting: optionGroup.extendedMode)
            }
            extendedMode = optionGroup.extendedMode
            return ExactRegexRiskNode(isDefinitelyZeroWidth: true)
        }

        // Unknown-but-compiled extension: parse its remainder as a group body
        // instead of abandoning the safety scan. Punctuation in the extension
        // header is harmless to this structural scanner.
        return try parseGroupBody(inheriting: extendedMode)
    }

    private mutating func parseGroupBody(
        inheriting extendedMode: Bool
    ) throws -> ExactRegexRiskNode {
        var groupExtendedMode = extendedMode
        let node = try parseAlternation(
            stopAtClosingParenthesis: true,
            extendedMode: &groupExtendedMode
        )
        skipIgnored(inExtendedMode: groupExtendedMode)
        if currentValue == 0x29 { index += 1 }
        return node
    }

    private mutating func parseOptionGroupHeader(
        inheriting extendedMode: Bool
    ) -> (extendedMode: Bool, hasBody: Bool)? {
        let start = index
        var candidateExtendedMode = extendedMode
        var enablesOption = true
        var consumedOption = false

        while let value = currentValue {
            if value == 0x2d { // -
                enablesOption = false
                consumedOption = true
                index += 1
                continue
            }
            if isASCIIOptionLetter(value) {
                if value == 0x78 { candidateExtendedMode = enablesOption } // x
                consumedOption = true
                index += 1
                continue
            }
            if consumedOption, value == 0x3a { // :
                index += 1
                return (candidateExtendedMode, true)
            }
            if consumedOption, value == 0x29 { // )
                index += 1
                return (candidateExtendedMode, false)
            }
            break
        }

        index = start
        return nil
    }

    private mutating func parseQuantifier() -> ExactRegexRiskQuantifier? {
        switch currentValue {
        case 0x2a: // *
            index += 1
            return ExactRegexRiskQuantifier(lowerBound: 0, upperBound: nil)
        case 0x2b: // +
            index += 1
            return ExactRegexRiskQuantifier(lowerBound: 1, upperBound: nil)
        case 0x3f: // ?
            index += 1
            return ExactRegexRiskQuantifier(lowerBound: 0, upperBound: 1)
        case 0x7b: // {
            break
        default:
            return nil
        }

        let start = index
        index += 1
        guard isASCIIDigit(currentValue) else {
            index = start
            return nil
        }
        let lowerBound = parseDecimal()
        if currentValue == 0x7d { // }
            index += 1
            return ExactRegexRiskQuantifier(
                lowerBound: lowerBound,
                upperBound: lowerBound
            )
        }
        guard currentValue == 0x2c else {
            index = start
            return nil
        }
        index += 1
        if currentValue == 0x7d { // {n,}
            index += 1
            return ExactRegexRiskQuantifier(lowerBound: lowerBound, upperBound: nil)
        }
        guard isASCIIDigit(currentValue) else {
            index = start
            return nil
        }
        let upperBound = parseDecimal()
        guard currentValue == 0x7d else {
            index = start
            return nil
        }
        index += 1
        return ExactRegexRiskQuantifier(
            lowerBound: lowerBound,
            upperBound: upperBound
        )
    }

    private mutating func consumeCharacterClass() {
        index += 1 // [
        if currentValue == 0x5e { index += 1 } // leading ^
        if currentValue == 0x5d { index += 1 } // leading literal ]
        while let value = currentValue {
            if value == 0x5c { // \\
                _ = consumeEscape()
                continue
            }
            index += 1
            // Stop at the first unescaped closing bracket. ICU supports nested
            // Unicode-set syntax, but deliberately under-consuming a nested
            // class is safe for this scanner: the remaining tokens are still
            // inspected, whereas over-consuming could hide a risky suffix.
            if value == 0x5d { return } // ]
        }
    }

    private mutating func consumeEscape() -> (
        domain: ExactRegexConsumptionDomain,
        isZeroWidth: Bool
    ) {
        index += 1 // \\
        guard let escaped = currentValue else { return (.unknown, false) }
        index += 1

        switch escaped {
        case 0x41, 0x5a, 0x7a, 0x47, 0x62, 0x42, 0x4b: // A Z z G b B K
            return (.unknown, true)
        case 0x64: // d
            return (.digit, false)
        case 0x73, 0x52: // s, R
            return (.whitespace, false)
        case 0x77: // w
            return (.word, false)
        case 0x44, 0x53, 0x57, 0x58, 0x43: // D S W X C
            return (.any, false)
        case 0x51: // \Q ... \E
            while index < scalars.count {
                if currentValue == 0x5c, scalarValue(at: index + 1) == 0x45 {
                    index += 2
                    return (.unknown, false)
                }
                index += 1
            }
            return (.unknown, false)
        case 0x6b, 0x67: // named backreference / subroutine payload
            if let delimiter = currentValue,
               delimiter == 0x3c || delimiter == 0x27 || delimiter == 0x7b {
                index += 1
                let closing: UInt32 = delimiter == 0x3c
                    ? 0x3e
                    : (delimiter == 0x27 ? 0x27 : 0x7d)
                consume(until: closing)
            }
            return (.unknown, false)
        case 0x70, 0x50, 0x4e, 0x6f, 0x78: // p P N o x
            if currentValue == 0x7b {
                index += 1
                consume(until: 0x7d)
            } else if escaped == 0x78 {
                consume(upTo: 2)
            }
            return (.unknown, false)
        case 0x75: // uXXXX
            consume(upTo: 4)
            return (.escapedLiteral(escaped), false)
        case 0x55: // UXXXXXXXX
            consume(upTo: 8)
            return (.escapedLiteral(escaped), false)
        case 0x63: // cX
            consume(upTo: 1)
            return (.escapedLiteral(escaped), false)
        case 0x30...0x39: // numeric backreference
            while isASCIIDigit(currentValue) { index += 1 }
            return (.unknown, false)
        default:
            return (.escapedLiteral(escaped), false)
        }
    }

    private mutating func consumeCommentGroup() {
        index += 1 // #
        while let value = currentValue {
            index += 1
            if value == 0x29 { return } // )
        }
    }

    private func zeroWidthNode(
        preservingRiskFrom node: ExactRegexRiskNode
    ) -> ExactRegexRiskNode {
        ExactRegexRiskNode(
            containsAlternation: node.containsAlternation,
            containsQuantifier: node.containsQuantifier,
            backtrackingChoiceCount: node.backtrackingChoiceCount,
            isDefinitelyZeroWidth: true,
            consumptionDomain: .unknown,
            leadingUnboundedDomain: nil,
            trailingUnboundedDomain: nil
        )
    }

    private func combinedPossibleDomain(
        _ lhs: ExactRegexConsumptionDomain?,
        _ rhs: ExactRegexConsumptionDomain?
    ) -> ExactRegexConsumptionDomain? {
        switch (lhs, rhs) {
        case (nil, nil):
            return nil
        case let (domain?, nil), let (nil, domain?):
            return domain
        case let (lhs?, rhs?):
            return lhs == rhs ? lhs : .unknown
        }
    }

    private mutating func skipIgnored(inExtendedMode extendedMode: Bool) {
        guard extendedMode else { return }
        while let scalar = currentScalar {
            if scalar.properties.isWhitespace {
                index += 1
                continue
            }
            guard scalar.value == 0x23 else { return } // # line comment
            while let value = currentValue, value != 0x0a, value != 0x0d {
                index += 1
            }
        }
    }

    private mutating func consume(until closingValue: UInt32) {
        while let value = currentValue {
            index += 1
            if value == closingValue { return }
        }
    }

    private mutating func consume(upTo count: Int) {
        index = min(scalars.count, index + count)
    }

    private mutating func parseDecimal() -> Int64 {
        var result: Int64 = 0
        while let value = currentValue, isASCIIDigit(value) {
            let digit = Int64(value - 0x30)
            if result > (Int64.max - digit) / 10 {
                result = Int64.max
            } else if result != Int64.max {
                result = result * 10 + digit
            }
            index += 1
        }
        return result
    }

    private mutating func registerBacktrackingDecision() throws {
        backtrackingDecisions += 1
        guard backtrackingDecisions <= Self.maximumBacktrackingDecisions else {
            throw responsivenessError(
                "the pattern has too many alternatives or variable bounded quantifiers to guarantee responsive matching"
            )
        }
    }

    private func checkedChoiceAdd(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let total = boundedAdd(lhs, rhs)
        try validateChoiceBudget(total)
        return total
    }

    private func checkedChoiceMultiply(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let total = boundedMultiply(lhs, rhs)
        try validateChoiceBudget(total)
        return total
    }

    private func validateChoiceBudget(_ count: Int64) throws {
        guard count <= Self.maximumBacktrackingChoiceCount else {
            throw responsivenessError(
                "the product of alternatives and repetition choices exceeds the responsive matching budget"
            )
        }
    }

    private func responsivenessError(_ reason: String) -> LighTxtCoreError {
        .unsupportedRegularExpression(reason)
    }

    private func boundedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        guard rhs >= 0, lhs <= Int64.max - rhs else { return Int64.max }
        return lhs + rhs
    }

    private func boundedMultiply(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        guard lhs != 0, rhs != 0 else { return 0 }
        guard lhs > 0, rhs > 0, lhs <= Int64.max / rhs else { return Int64.max }
        return lhs * rhs
    }

    private func isASCIIOptionLetter(_ value: UInt32) -> Bool {
        // ICU option group flags are ASCII letters. Accepting the full range
        // keeps the scanner forward-compatible without changing semantics.
        (0x41...0x5a).contains(value) || (0x61...0x7a).contains(value)
    }

    private func isASCIIDigit(_ value: UInt32?) -> Bool {
        guard let value else { return false }
        return (0x30...0x39).contains(value)
    }

    private var currentScalar: Unicode.Scalar? {
        guard index >= 0, index < scalars.count else { return nil }
        return scalars[index]
    }

    private var currentValue: UInt32? { currentScalar?.value }

    private func scalarValue(at position: Int) -> UInt32? {
        guard position >= 0, position < scalars.count else { return nil }
        return scalars[position].value
    }
}

private nonisolated struct BoundedRegexNode {
    var maximumByteCount: Int64
    var containsAlternation: Bool = false
    var containsQuantifier: Bool = false
    var containsUnboundedQuantifier: Bool = false
    var backtrackingChoiceCount: Int64 = 1
}

private nonisolated struct BoundedQuantifier {
    let lowerBound: Int64
    let upperBound: Int64

    var isUnbounded: Bool { upperBound == Int64.max }
}

private nonisolated struct BoundedRegexParser {
    private static let maximumBacktrackingDecisions = 12
    private static let maximumBacktrackingChoiceCount: Int64 = 1_000_000

    private let scalars: [Unicode.Scalar]
    private let maximumScalarByteCount: Int64
    private var index = 0
    private var backtrackingDecisions = 0

    init(
        expression: String,
        maximumScalarByteCount: Int64
    ) {
        scalars = Array(expression.unicodeScalars)
        self.maximumScalarByteCount = maximumScalarByteCount
    }

    mutating func parse() throws -> BoundedRegexNode {
        let maximum = try parseAlternation(depth: 0)
        guard index == scalars.count else {
            throw LighTxtCoreError.unsupportedRegularExpression(
                "the pattern contains a group form that cannot be bounded"
            )
        }
        return maximum
    }

    private mutating func parseAlternation(depth: Int) throws -> BoundedRegexNode {
        var node = try parseSequence(depth: depth)
        while currentValue == 0x7c { // |
            index += 1
            try registerBacktrackingDecision()
            let branch = try parseSequence(depth: depth)
            node.maximumByteCount = max(node.maximumByteCount, branch.maximumByteCount)
            node.containsAlternation = true
            node.containsQuantifier = node.containsQuantifier || branch.containsQuantifier
            node.containsUnboundedQuantifier = node.containsUnboundedQuantifier
                || branch.containsUnboundedQuantifier
            node.backtrackingChoiceCount = try checkedChoiceAdd(
                node.backtrackingChoiceCount,
                branch.backtrackingChoiceCount
            )
        }
        return node
    }

    private mutating func parseSequence(depth: Int) throws -> BoundedRegexNode {
        var node = BoundedRegexNode(maximumByteCount: 0)
        while let value = currentValue, value != 0x7c, value != 0x29 { // | )
            let atom = try parseRepeatedAtom(depth: depth)
            node.maximumByteCount = boundedAdd(
                node.maximumByteCount,
                atom.maximumByteCount
            )
            node.containsAlternation = node.containsAlternation || atom.containsAlternation
            node.containsQuantifier = node.containsQuantifier || atom.containsQuantifier
            node.containsUnboundedQuantifier = node.containsUnboundedQuantifier
                || atom.containsUnboundedQuantifier
            node.backtrackingChoiceCount = try checkedChoiceMultiply(
                node.backtrackingChoiceCount,
                atom.backtrackingChoiceCount
            )
        }
        return node
    }

    private mutating func parseRepeatedAtom(depth: Int) throws -> BoundedRegexNode {
        var atom = try parseAtom(depth: depth)
        guard let value = currentValue else { return atom }

        switch value {
        case 0x2a, 0x2b: // * +
            index += 1
            if atom.containsAlternation || atom.containsQuantifier {
                throw LighTxtCoreError.unsupportedRegularExpression(
                    "nesting an unbounded quantifier around an alternation or another quantified expression can cause uninterruptible catastrophic backtracking"
                )
            }
            consumeQuantifierBehaviorSuffix()
            atom.maximumByteCount = Int64.max
            atom.containsQuantifier = true
            atom.containsUnboundedQuantifier = true
            return atom
        case 0x3f: // ?
            index += 1
            try registerBacktrackingDecision()
            consumeQuantifierBehaviorSuffix()
            atom.containsQuantifier = true
            atom.backtrackingChoiceCount = try checkedChoiceAdd(
                1,
                atom.backtrackingChoiceCount
            )
            return atom
        case 0x7b where nextValueIsASCIIDigit(): // {
            let quantifier = try parseBoundedQuantifier()
            if quantifier.isUnbounded {
                if atom.containsAlternation || atom.containsQuantifier {
                    throw LighTxtCoreError.unsupportedRegularExpression(
                        "nesting an unbounded quantifier around an alternation or another quantified expression can cause uninterruptible catastrophic backtracking"
                    )
                }
                consumeQuantifierBehaviorSuffix()
                atom.maximumByteCount = Int64.max
                atom.containsQuantifier = true
                atom.containsUnboundedQuantifier = true
                return atom
            }
            if quantifier.lowerBound != quantifier.upperBound {
                try registerBacktrackingDecision()
            }
            if quantifier.upperBound > 1,
               atom.containsAlternation || atom.containsQuantifier {
                throw LighTxtCoreError.unsupportedRegularExpression(
                    "repeating an alternation or another quantified expression can cause uninterruptible catastrophic backtracking"
                )
            }
            consumeQuantifierBehaviorSuffix()
            atom.maximumByteCount = boundedMultiply(
                atom.maximumByteCount,
                quantifier.upperBound
            )
            if quantifier.upperBound == 0 {
                atom.backtrackingChoiceCount = 1
            } else if quantifier.upperBound == 1 {
                atom.backtrackingChoiceCount = quantifier.lowerBound == 0
                    ? try checkedChoiceAdd(1, atom.backtrackingChoiceCount)
                    : atom.backtrackingChoiceCount
            } else {
                let width = boundedAdd(
                    quantifier.upperBound - quantifier.lowerBound,
                    1
                )
                atom.backtrackingChoiceCount = try checkedChoiceMultiply(
                    atom.backtrackingChoiceCount,
                    width
                )
            }
            atom.containsQuantifier = atom.containsQuantifier
                || quantifier.lowerBound != 1
                || quantifier.upperBound != 1
            return atom
        default:
            return atom
        }
    }

    private mutating func parseAtom(depth: Int) throws -> BoundedRegexNode {
        guard let value = currentValue else {
            return BoundedRegexNode(maximumByteCount: 0)
        }
        switch value {
        case 0x28: // (
            guard depth < 128 else {
                throw LighTxtCoreError.unsupportedRegularExpression(
                    "group nesting deeper than 128 levels is not supported"
                )
            }
            index += 1
            if currentValue == 0x3f { // ?
                guard scalarValue(at: index + 1) == 0x3a else { // ?: only
                    let reason: String
                    if scalarValue(at: index + 1) == 0x3d
                        || scalarValue(at: index + 1) == 0x21 {
                        reason = "lookahead assertions are not supported"
                    } else if scalarValue(at: index + 1) == 0x3c,
                              scalarValue(at: index + 2) == 0x3d
                                || scalarValue(at: index + 2) == 0x21 {
                        reason = "lookbehind assertions are not supported"
                    } else {
                        reason = "inline options, named/atomic groups, conditionals, and other extended group forms are not supported"
                    }
                    throw LighTxtCoreError.unsupportedRegularExpression(reason)
                }
                index += 2
            }
            let groupMaximum = try parseAlternation(depth: depth + 1)
            // NSRegularExpression has already validated balanced groups.
            if currentValue == 0x29 { index += 1 }
            return groupMaximum

        case 0x5b: // [
            return BoundedRegexNode(maximumByteCount: try parseCharacterClass())

        case 0x5e, 0x24: // ^ $
            throw LighTxtCoreError.unsupportedRegularExpression(
                "anchors (^, $, and escaped anchor forms) depend on artificial window boundaries"
            )

        case 0x5c: // \\
            return BoundedRegexNode(maximumByteCount: try parseEscape())

        default:
            index += 1
            return BoundedRegexNode(maximumByteCount: maximumScalarByteCount)
        }
    }

    private mutating func parseCharacterClass() throws -> Int64 {
        index += 1 // [
        if currentValue == 0x5e { index += 1 } // leading ^
        if currentValue == 0x5d { index += 1 } // leading literal ]

        while let value = currentValue {
            switch value {
            case 0x5d: // ]
                index += 1
                return maximumScalarByteCount
            case 0x5b, 0x7b: // [ {
                throw LighTxtCoreError.unsupportedRegularExpression(
                    "nested or string-valued character sets are not supported"
                )
            case 0x5c: // \\
                index += 1
                guard let escaped = currentValue else { break }
                if escaped == 0x58 || escaped == 0x52 || escaped == 0x51
                    || escaped == 0x71 || escaped == 0x43 {
                    throw LighTxtCoreError.unsupportedRegularExpression(
                        "multi-scalar escapes are not supported inside character classes"
                    )
                }
                index += 1
                if (escaped == 0x70 || escaped == 0x50 || escaped == 0x4e
                    || escaped == 0x6f || escaped == 0x78), currentValue == 0x7b {
                    try consumeBracedEscapePayload()
                } else if escaped == 0x75 {
                    consume(upTo: 4)
                } else if escaped == 0x55 {
                    consume(upTo: 8)
                }
            default:
                index += 1
            }
        }

        // Compilation happens first, so this is defensive rather than a user
        // syntax diagnostic.
        throw LighTxtCoreError.unsupportedRegularExpression(
            "the character class could not be bounded"
        )
    }

    private mutating func parseEscape() throws -> Int64 {
        index += 1 // \\
        guard let escaped = currentValue else { return maximumScalarByteCount }
        index += 1

        if escaped >= 0x30, escaped <= 0x39 {
            throw LighTxtCoreError.unsupportedRegularExpression(
                "numeric backreferences are not supported"
            )
        }

        switch escaped {
        case 0x41, 0x5a, 0x7a, 0x47, 0x62, 0x42, 0x4b: // A Z z G b B K
            throw LighTxtCoreError.unsupportedRegularExpression(
                "anchors, word boundaries, and match-reset escapes are not supported"
            )
        case 0x6b, 0x67: // k g
            throw LighTxtCoreError.unsupportedRegularExpression(
                "named backreferences and subroutine references are not supported"
            )
        case 0x58: // X
            throw LighTxtCoreError.unsupportedRegularExpression(
                "\\X can consume an unbounded grapheme cluster"
            )
        case 0x43: // C
            throw LighTxtCoreError.unsupportedRegularExpression(
                "\\C can split a Unicode scalar and cannot produce safe UTF-8 byte ranges"
            )
        case 0x51: // Q
            throw LighTxtCoreError.unsupportedRegularExpression(
                "\\Q...\\E quoted regions are not supported; escape literal metacharacters individually"
            )
        case 0x52: // R, either one newline scalar or CRLF
            return boundedMultiply(maximumScalarByteCount, 2)
        case 0x70, 0x50, 0x4e, 0x6f, 0x78: // p P N o x
            if currentValue == 0x7b { try consumeBracedEscapePayload() }
            else if escaped == 0x78 { consume(upTo: 2) }
            return maximumScalarByteCount
        case 0x75: // uXXXX
            consume(upTo: 4)
            return maximumScalarByteCount
        case 0x55: // UXXXXXXXX
            consume(upTo: 8)
            return maximumScalarByteCount
        case 0x63: // cX
            consume(upTo: 1)
            return maximumScalarByteCount
        default:
            return maximumScalarByteCount
        }
    }

    private mutating func parseBoundedQuantifier() throws -> BoundedQuantifier {
        index += 1 // {
        let lower = parseDecimal()
        if currentValue == 0x7d { // }
            index += 1
            return BoundedQuantifier(lowerBound: lower, upperBound: lower)
        }

        // A compiled quantifier at this point must contain a comma.
        if currentValue == 0x2c { index += 1 }
        guard isASCIIDigit(currentValue) else {
            throw LighTxtCoreError.unsupportedRegularExpression(
                "open-ended quantifiers such as {n,} are not supported"
            )
        }
        let upper = parseDecimal()
        if currentValue == 0x7d { index += 1 }
        return BoundedQuantifier(lowerBound: lower, upperBound: upper)
    }

    private mutating func parseDecimal() -> Int64 {
        var result: Int64 = 0
        while let value = currentValue, isASCIIDigit(value) {
            let digit = Int64(value - 0x30)
            if result > (Int64.max - digit) / 10 {
                result = Int64.max
            } else if result != Int64.max {
                result = result * 10 + digit
            }
            index += 1
        }
        return result
    }

    private mutating func consumeQuantifierBehaviorSuffix() {
        if currentValue == 0x3f || currentValue == 0x2b { index += 1 } // lazy/possessive
    }

    private mutating func consumeBracedEscapePayload() throws {
        index += 1 // {
        while let value = currentValue, value != 0x7d { index += 1 }
        if currentValue == 0x7d { index += 1 }
    }

    private mutating func consume(upTo count: Int) {
        index = min(scalars.count, index + count)
    }

    private func nextValueIsASCIIDigit() -> Bool {
        isASCIIDigit(scalarValue(at: index + 1))
    }

    private func isASCIIDigit(_ value: UInt32?) -> Bool {
        guard let value else { return false }
        return value >= 0x30 && value <= 0x39
    }

    private var currentValue: UInt32? { scalarValue(at: index) }

    private func scalarValue(at position: Int) -> UInt32? {
        guard position >= 0, position < scalars.count else { return nil }
        return scalars[position].value
    }

    private func boundedAdd(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        guard lhs <= Int64.max - rhs else { return Int64.max }
        return lhs + rhs
    }

    private func boundedMultiply(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        guard lhs != 0, rhs != 0 else { return 0 }
        guard lhs <= Int64.max / rhs else { return Int64.max }
        return lhs * rhs
    }

    private mutating func registerBacktrackingDecision() throws {
        backtrackingDecisions += 1
        guard backtrackingDecisions <= Self.maximumBacktrackingDecisions else {
            throw LighTxtCoreError.unsupportedRegularExpression(
                "the pattern has too many alternations or variable bounded quantifiers to guarantee responsive matching"
            )
        }
    }

    private func checkedChoiceAdd(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let total = boundedAdd(lhs, rhs)
        try validateChoiceBudget(total)
        return total
    }

    private func checkedChoiceMultiply(_ lhs: Int64, _ rhs: Int64) throws -> Int64 {
        let total = boundedMultiply(lhs, rhs)
        try validateChoiceBudget(total)
        return total
    }

    private func validateChoiceBudget(_ count: Int64) throws {
        guard count <= Self.maximumBacktrackingChoiceCount else {
            throw LighTxtCoreError.unsupportedRegularExpression(
                "the product of bounded alternatives and repetition choices exceeds the responsive matching budget"
            )
        }
    }
}

extension DocumentSnapshot {
    /// Streams matches to `matchHandler`. Returning false stops immediately.
    /// Literal search uses O(pattern length) memory and finds matches across any
    /// number of piece boundaries.
    @discardableResult
    public func search(
        _ pattern: SearchPattern,
        in requestedRange: Range<Int64>? = nil,
        options: SearchOptions = .init(),
        cancellation: CancellationToken? = nil,
        progress: ((SearchProgress) -> Void)? = nil,
        matchHandler: (SearchMatch) throws -> Bool
    ) throws -> SearchResult {
        let range = requestedRange ?? 0..<byteCount
        try validateByteRange(range, byteCount: byteCount)

        switch pattern {
        case let .literal(bytes):
            return try searchLiteral(
                bytes,
                in: range,
                options: options,
                cancellation: cancellation,
                progress: progress,
                matchHandler: matchHandler
            )
        case let .regularExpression(expression):
            return try searchRegularExpression(
                expression,
                in: range,
                options: options,
                cancellation: cancellation,
                progress: progress,
                matchHandler: matchHandler
            )
        }
    }

    /// Convenience for Find One.
    public func firstMatch(
        for pattern: SearchPattern,
        in range: Range<Int64>? = nil,
        options: SearchOptions = .init(),
        cancellation: CancellationToken? = nil
    ) throws -> SearchMatch? {
        var first: SearchMatch?
        _ = try search(
            pattern,
            in: range,
            options: options,
            cancellation: cancellation
        ) { match in
            first = match
            return false
        }
        return first
    }

    /// Convenience for Find All with an explicit safety limit.
    public func allMatches(
        for pattern: SearchPattern,
        in range: Range<Int64>? = nil,
        options: SearchOptions = .init(),
        limit: Int = 100_000,
        cancellation: CancellationToken? = nil,
        progress: ((SearchProgress) -> Void)? = nil
    ) throws -> CollectedSearchResult {
        let safeLimit = max(0, limit)
        var matches: [SearchMatch] = []
        matches.reserveCapacity(min(safeLimit, 1_024))
        var hitLimit = safeLimit == 0

        let result: SearchResult
        if hitLimit {
            result = SearchResult(
                matchesFound: 0,
                processedBytes: 0,
                stopReason: .resultLimitReached
            )
        } else {
            let streamed = try search(
                pattern,
                in: range,
                options: options,
                cancellation: cancellation,
                progress: progress
            ) { match in
                matches.append(match)
                hitLimit = matches.count >= safeLimit
                return !hitLimit
            }
            result = SearchResult(
                matchesFound: streamed.matchesFound,
                processedBytes: streamed.processedBytes,
                stopReason: hitLimit ? .resultLimitReached : streamed.stopReason
            )
        }
        return CollectedSearchResult(matches: matches, search: result)
    }

    private func searchLiteral(
        _ patternData: Data,
        in range: Range<Int64>,
        options: SearchOptions,
        cancellation: CancellationToken?,
        progress: ((SearchProgress) -> Void)?,
        matchHandler: (SearchMatch) throws -> Bool
    ) throws -> SearchResult {
        guard !patternData.isEmpty else { throw LighTxtCoreError.emptySearchPattern }

        let fold: (UInt8) -> UInt8 = options.caseSensitive
            ? { $0 }
            : { byte in
                if byte >= 65, byte <= 90 { return byte + 32 }
                return byte
            }
        let pattern = patternData.map(fold)
        var prefix = [Int](repeating: 0, count: pattern.count)
        if pattern.count > 1 {
            var matched = 0
            for index in 1..<pattern.count {
                while matched > 0, pattern[index] != pattern[matched] {
                    matched = prefix[matched - 1]
                }
                if pattern[index] == pattern[matched] { matched += 1 }
                prefix[index] = matched
            }
        }

        let total = range.upperBound - range.lowerBound
        var processed: Int64 = 0
        var matchesFound = 0
        var matchedBytes = 0
        var nextCancellationCheck: Int64 = 0
        var nextProgress = options.progressIntervalByteCount
        var stopReason = SearchStopReason.completed
        var pendingWholeWordMatch: SearchMatch?
        let historySize = pattern.count + 1
        var byteHistory = options.matchesWholeWords
            ? [UInt8](repeating: 0, count: historySize)
            : []
        let byteBeforeRange: UInt8? = options.matchesWholeWords && range.lowerBound > 0
            ? try byte(at: range.lowerBound - 1)
            : nil
        let byteAfterRange: UInt8? = options.matchesWholeWords && range.upperBound < byteCount
            ? try byte(at: range.upperBound)
            : nil

        @inline(__always)
        func isWordByte(_ byte: UInt8?) -> Bool {
            guard let byte else { return false }
            return (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || byte == 95
                // Treat a UTF-8 scalar as a word constituent at the byte layer.
                // This is conservative at non-ASCII punctuation boundaries and
                // guarantees that a match never splits a scalar.
                || byte >= 0x80
        }

        func emitPendingWholeWordMatch(before rightByte: UInt8?) throws {
            guard let match = pendingWholeWordMatch else { return }
            pendingWholeWordMatch = nil
            guard !isWordByte(rightByte) else { return }
            matchesFound += 1
            guard try matchHandler(match) else {
                throw SearchInterruption.stopped
            }
        }

        progress?(SearchProgress(
            processedBytes: 0,
            totalBytes: total,
            matchesFound: 0
        ))

        do {
            try forEachByteSlice(in: range) { rawBytes in
                let bytes = rawBytes.bindMemory(to: UInt8.self)
                for byte in bytes {
                    if processed >= nextCancellationCheck {
                        if cancellation?.isCancelled == true {
                            throw SearchInterruption.cancelled
                        }
                        nextCancellationCheck = processed + (64 << 10)
                    }

                    if options.matchesWholeWords {
                        try emitPendingWholeWordMatch(before: byte)
                        byteHistory[Int(processed % Int64(historySize))] = byte
                    }

                    let candidate = fold(byte)
                    while matchedBytes > 0, candidate != pattern[matchedBytes] {
                        matchedBytes = prefix[matchedBytes - 1]
                    }
                    if candidate == pattern[matchedBytes] { matchedBytes += 1 }
                    processed += 1

                    if matchedBytes == pattern.count {
                        let end = range.lowerBound + processed
                        let match = SearchMatch(
                            byteRange: (end - Int64(pattern.count))..<end
                        )
                        if options.matchesWholeWords {
                            let leftRelativeOffset = processed - Int64(pattern.count) - 1
                            let leftByte: UInt8?
                            if leftRelativeOffset >= 0 {
                                leftByte = byteHistory[
                                    Int(leftRelativeOffset % Int64(historySize))
                                ]
                            } else {
                                leftByte = byteBeforeRange
                            }
                            if !isWordByte(leftByte) {
                                pendingWholeWordMatch = match
                            }
                        } else {
                            matchesFound += 1
                            guard try matchHandler(match) else {
                                throw SearchInterruption.stopped
                            }
                        }
                        matchedBytes = options.allowsOverlappingMatches
                            ? prefix[matchedBytes - 1]
                            : 0
                    }

                    if processed >= nextProgress {
                        progress?(SearchProgress(
                            processedBytes: processed,
                            totalBytes: total,
                            matchesFound: matchesFound
                        ))
                        nextProgress = processed + options.progressIntervalByteCount
                    }
                }
            }
            if options.matchesWholeWords {
                try emitPendingWholeWordMatch(before: byteAfterRange)
            }
        } catch SearchInterruption.cancelled {
            stopReason = .cancelled
        } catch SearchInterruption.stopped {
            stopReason = .matchHandlerRequestedStop
        }

        progress?(SearchProgress(
            processedBytes: processed,
            totalBytes: total,
            matchesFound: matchesFound
        ))
        return SearchResult(
            matchesFound: matchesFound,
            processedBytes: processed,
            stopReason: stopReason
        )
    }

    private func searchRegularExpression(
        _ expression: String,
        in range: Range<Int64>,
        options: SearchOptions,
        cancellation: CancellationToken?,
        progress: ((SearchProgress) -> Void)?,
        matchHandler: (SearchMatch) throws -> Bool
    ) throws -> SearchResult {
        guard !expression.isEmpty else { throw LighTxtCoreError.emptySearchPattern }
        var regexOptions: NSRegularExpression.Options = []
        if !options.caseSensitive { regexOptions.insert(.caseInsensitive) }
        if options.regexUsesAnchorsMatchLines { regexOptions.insert(.anchorsMatchLines) }
        if options.regexDotMatchesNewlines { regexOptions.insert(.dotMatchesLineSeparators) }

        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: expression, options: regexOptions)
        } catch {
            throw LighTxtCoreError.invalidRegularExpression(error.localizedDescription)
        }

        guard !options.allowsOverlappingMatches else {
            throw LighTxtCoreError.unsupportedRegularExpression(
                "overlapping regex enumeration is not supported; overlapping literal search remains available"
            )
        }

        let maximumExactBytes = Int64(options.maximumExactRegexDocumentByteCount)
        if byteCount <= maximumExactBytes {
            // Preserve the native syntax surface, but retain the parser's
            // strongest responsiveness checks for patterns it can prove are
            // vulnerable to explosive backtracking.
            try ExactRegexResponsivenessPreflight.validate(expression: expression)
            return try searchExactRegularExpression(
                regex,
                in: range,
                maximumDuration: options.maximumExactRegexDuration,
                cancellation: cancellation,
                progress: progress,
                matchHandler: matchHandler
            )
        }

        let analysis: BoundedRegexAnalysis
        do {
            analysis = try BoundedRegexAnalysis(
                expression: expression,
                caseSensitive: options.caseSensitive
            )
        } catch let error as LighTxtCoreError {
            if regexErrorIsResponsivenessRisk(error) { throw error }
            if case let .unsupportedRegularExpression(reason) = error {
                throw LighTxtCoreError.regularExpressionRequiresExactSearch(
                    documentByteCount: byteCount,
                    maximumExactByteCount: maximumExactBytes,
                    reason: reason
                )
            }
            throw error
        }
        let maximumWindowBytes = Int64(options.maximumRegexWindowByteCount)
        let requiredRightContext = max(
            Int64(options.regexContextByteCount),
            analysis.maximumMatchByteCount
        )
        // A UTF-8 scalar can occupy four bytes. Keep four bytes for primary
        // ownership and three bytes of slack when moving the right edge to the
        // next scalar boundary.
        let minimumWindowBytes = clampedAdding(requiredRightContext, 7)
        guard minimumWindowBytes <= maximumWindowBytes else {
            throw LighTxtCoreError.regularExpressionExceedsWindow(
                requiredByteCount: minimumWindowBytes,
                maximumByteCount: maximumWindowBytes
            )
        }
        let primaryTargetByteCount = min(
            Int64(options.regexChunkByteCount),
            maximumWindowBytes - requiredRightContext - 3
        )

        let total = range.upperBound - range.lowerBound
        var primaryStart = range.lowerBound
        // This is the regex engine's global non-overlapping search cursor. It
        // may run past a chunk boundary when a match crosses that boundary.
        var searchCursor = range.lowerBound
        var processed: Int64 = 0
        var matchesFound = 0
        var nextProgress = options.progressIntervalByteCount

        progress?(SearchProgress(
            processedBytes: 0,
            totalBytes: total,
            matchesFound: 0
        ))

        while primaryStart < range.upperBound || (range.isEmpty && primaryStart == range.upperBound) {
            if cancellation?.isCancelled == true {
                return SearchResult(
                    matchesFound: matchesFound,
                    processedBytes: processed,
                    stopReason: .cancelled
                )
            }

            let proposedPrimaryEnd = min(
                range.upperBound,
                clampedAdding(primaryStart, primaryTargetByteCount)
            )
            var primaryEnd = try utf8BoundaryAtOrBefore(
                proposedPrimaryEnd,
                limitedBy: primaryStart
            )
            if primaryEnd <= primaryStart, primaryStart < range.upperBound {
                primaryEnd = try utf8BoundaryAtOrAfter(
                    min(range.upperBound, clampedAdding(primaryStart, 1)),
                    limitedBy: range.upperBound
                )
            }

            let windowStart = primaryStart
            let windowEnd = try utf8BoundaryAtOrAfter(
                min(
                    range.upperBound,
                    clampedAdding(primaryEnd, requiredRightContext)
                ),
                limitedBy: range.upperBound
            )
            let actualWindowByteCount = windowEnd - windowStart
            guard actualWindowByteCount <= maximumWindowBytes else {
                throw LighTxtCoreError.regularExpressionExceedsWindow(
                    requiredByteCount: actualWindowByteCount,
                    maximumByteCount: maximumWindowBytes
                )
            }

            let windowRange = windowStart..<windowEnd
            let windowData = try data(in: windowRange)
            guard let text = String(data: windowData, encoding: .utf8) else {
                throw LighTxtCoreError.invalidUTF8(range: windowRange)
            }

            func absoluteByteRange(for nsRange: NSRange) -> Range<Int64>? {
                guard nsRange.location != NSNotFound,
                      let stringRange = Range(nsRange, in: text),
                      let lowerUTF8 = stringRange.lowerBound.samePosition(in: text.utf8),
                      let upperUTF8 = stringRange.upperBound.samePosition(in: text.utf8) else {
                    return nil
                }
                let lower = windowStart + Int64(
                    text.utf8.distance(from: text.utf8.startIndex, to: lowerUTF8)
                )
                let upper = windowStart + Int64(
                    text.utf8.distance(from: text.utf8.startIndex, to: upperUTF8)
                )
                return lower..<upper
            }

            func stringIndex(atByteOffset absoluteOffset: Int64) -> String.Index? {
                let relativeOffset = absoluteOffset - windowStart
                guard relativeOffset >= 0,
                      relativeOffset <= Int64(text.utf8.count),
                      let relative = Int(exactly: relativeOffset) else {
                    return nil
                }
                let utf8Index = text.utf8.index(text.utf8.startIndex, offsetBy: relative)
                return utf8Index.samePosition(in: text)
            }

            let enumerationStart = max(searchCursor, primaryStart)
            let ownsPossibleStart = enumerationStart < primaryEnd
                || (primaryEnd == range.upperBound
                    && enumerationStart == range.upperBound)

            var callbackError: Error?
            var handlerRequestedStop = false
            var enumerationCancelled = false
            if ownsPossibleStart {
                guard enumerationStart <= windowEnd,
                      let startIndex = stringIndex(atByteOffset: enumerationStart) else {
                    throw LighTxtCoreError.invalidUTF8(
                        range: enumerationStart..<min(
                            range.upperBound,
                            clampedAdding(enumerationStart, 1)
                        )
                    )
                }
                let enumerationRange = NSRange(startIndex..<text.endIndex, in: text)
                regex.enumerateMatches(in: text, range: enumerationRange) { result, _, stop in
                    if cancellation?.isCancelled == true {
                        enumerationCancelled = true
                        stop.pointee = true
                        return
                    }
                    guard let result else { return }
                    guard let byteRange = absoluteByteRange(for: result.range) else {
                        callbackError = LighTxtCoreError.unsupportedRegularExpression(
                            "the regex engine produced a match boundary that is not aligned to UTF-8"
                        )
                        stop.pointee = true
                        return
                    }

                    let finalEmptyMatch = byteRange.isEmpty
                        && byteRange.lowerBound == range.upperBound
                        && primaryEnd == range.upperBound
                    guard byteRange.lowerBound < primaryEnd || finalEmptyMatch else {
                        // Context matches belong to a later primary window.
                        stop.pointee = true
                        return
                    }

                    let matchByteCount = byteRange.upperBound - byteRange.lowerBound
                    guard matchByteCount <= analysis.maximumMatchByteCount else {
                        callbackError = LighTxtCoreError
                            .regularExpressionMatchExceedsAnalyzedBound(
                                matchByteCount: matchByteCount,
                                analyzedMaximumByteCount: analysis.maximumMatchByteCount
                            )
                        stop.pointee = true
                        return
                    }

                    var captures: [Range<Int64>?] = []
                    captures.reserveCapacity(result.numberOfRanges)
                    var capturesAreValid = true
                    for captureIndex in 0..<result.numberOfRanges {
                        let captureNSRange = result.range(at: captureIndex)
                        if captureNSRange.location == NSNotFound {
                            captures.append(nil)
                        } else if let capture = absoluteByteRange(for: captureNSRange) {
                            captures.append(capture)
                        } else {
                            capturesAreValid = false
                            break
                        }
                    }
                    guard capturesAreValid else {
                        callbackError = LighTxtCoreError.unsupportedRegularExpression(
                            "the regex engine produced a capture boundary that is not aligned to UTF-8"
                        )
                        stop.pointee = true
                        return
                    }
                    let match = SearchMatch(
                        byteRange: byteRange,
                        captureByteRanges: captures
                    )
                    do {
                        matchesFound += 1
                        searchCursor = max(searchCursor, byteRange.upperBound)
                        if try !matchHandler(match) {
                            handlerRequestedStop = true
                            stop.pointee = true
                        }
                    } catch {
                        callbackError = error
                        stop.pointee = true
                    }
                }
            }

            if let callbackError { throw callbackError }
            let processedThroughWindow = processed + (primaryEnd - primaryStart)
            if enumerationCancelled {
                return SearchResult(
                    matchesFound: matchesFound,
                    processedBytes: processedThroughWindow,
                    stopReason: .cancelled
                )
            }
            if handlerRequestedStop {
                return SearchResult(
                    matchesFound: matchesFound,
                    processedBytes: processedThroughWindow,
                    stopReason: .matchHandlerRequestedStop
                )
            }

            // No future global match can begin before primaryEnd: the window
            // contained enough bytes to decide every such bounded start.
            searchCursor = max(searchCursor, primaryEnd)

            let primaryBytes = primaryEnd - primaryStart
            processed += primaryBytes
            primaryStart = primaryEnd
            if processed >= nextProgress {
                progress?(SearchProgress(
                    processedBytes: processed,
                    totalBytes: total,
                    matchesFound: matchesFound
                ))
                nextProgress = processed + options.progressIntervalByteCount
            }

            if range.isEmpty { break }
        }

        progress?(SearchProgress(
            processedBytes: processed,
            totalBytes: total,
            matchesFound: matchesFound
        ))
        return SearchResult(
            matchesFound: matchesFound,
            processedBytes: processed,
            stopReason: .completed
        )
    }

    /// Native full-document matching for documents below an explicit hard
    /// cap. Keeping the complete subject in one string is the only way to give
    /// Foundation regexes exact semantics for context-dependent constructs
    /// such as `^`, `$`, `\b`, lookarounds, and unbounded repetition. The
    /// bounded streaming path remains mandatory above the cap.
    private func searchExactRegularExpression(
        _ regex: NSRegularExpression,
        in range: Range<Int64>,
        maximumDuration: TimeInterval,
        cancellation: CancellationToken?,
        progress: ((SearchProgress) -> Void)?,
        matchHandler: (SearchMatch) throws -> Bool
    ) throws -> SearchResult {
        if cancellation?.isCancelled == true {
            return SearchResult(
                matchesFound: 0,
                processedBytes: 0,
                stopReason: .cancelled
            )
        }

        let documentData = try data(in: 0..<byteCount)
        guard let text = String(data: documentData, encoding: .utf8) else {
            throw LighTxtCoreError.invalidUTF8(range: 0..<byteCount)
        }

        func stringIndex(atByteOffset offset: Int64) -> String.Index? {
            guard offset >= 0,
                  offset <= byteCount,
                  let relative = Int(exactly: offset),
                  relative <= text.utf8.count else {
                return nil
            }
            let utf8Index = text.utf8.index(text.utf8.startIndex, offsetBy: relative)
            return utf8Index.samePosition(in: text)
        }

        guard let lowerIndex = stringIndex(atByteOffset: range.lowerBound),
              let upperIndex = stringIndex(atByteOffset: range.upperBound) else {
            throw LighTxtCoreError.invalidUTF8(range: range)
        }

        func absoluteByteRange(for nsRange: NSRange) -> Range<Int64>? {
            guard nsRange.location != NSNotFound,
                  let stringRange = Range(nsRange, in: text),
                  let lowerUTF8 = stringRange.lowerBound.samePosition(in: text.utf8),
                  let upperUTF8 = stringRange.upperBound.samePosition(in: text.utf8) else {
                return nil
            }
            let lower = Int64(
                text.utf8.distance(from: text.utf8.startIndex, to: lowerUTF8)
            )
            let upper = Int64(
                text.utf8.distance(from: text.utf8.startIndex, to: upperUTF8)
            )
            return lower..<upper
        }

        let total = range.upperBound - range.lowerBound
        progress?(SearchProgress(
            processedBytes: 0,
            totalBytes: total,
            matchesFound: 0
        ))

        var matchesFound = 0
        var stopReason = SearchStopReason.completed
        var callbackError: Error?
        let enumerationRange = NSRange(lowerIndex..<upperIndex, in: text)
        let deadline = ProcessInfo.processInfo.systemUptime + maximumDuration
        regex.enumerateMatches(
            in: text,
            options: [
                .withTransparentBounds,
                .withoutAnchoringBounds,
                .reportProgress,
                .reportCompletion,
            ],
            range: enumerationRange
        ) { result, flags, stop in
            if cancellation?.isCancelled == true {
                stopReason = .cancelled
                stop.pointee = true
                return
            }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                callbackError = LighTxtCoreError.regularExpressionTimedOut(
                    maximumDuration: maximumDuration
                )
                stop.pointee = true
                return
            }
            if flags.contains(.internalError) {
                callbackError = LighTxtCoreError.unsupportedRegularExpression(
                    "the regex engine stopped with an internal matching error"
                )
                stop.pointee = true
                return
            }
            // Foundation deliberately supplies no result for progress and
            // completion callbacks. They are cancellation/deadline checkpoints,
            // not malformed match boundaries.
            guard let result else { return }
            guard let byteRange = absoluteByteRange(for: result.range) else {
                callbackError = LighTxtCoreError.unsupportedRegularExpression(
                    "the regex engine produced a boundary that is not aligned to UTF-8"
                )
                stop.pointee = true
                return
            }

            var captures: [Range<Int64>?] = []
            captures.reserveCapacity(result.numberOfRanges)
            for captureIndex in 0..<result.numberOfRanges {
                let captureRange = result.range(at: captureIndex)
                if captureRange.location == NSNotFound {
                    captures.append(nil)
                } else if let capture = absoluteByteRange(for: captureRange) {
                    captures.append(capture)
                } else {
                    callbackError = LighTxtCoreError.unsupportedRegularExpression(
                        "the regex engine produced a capture boundary that is not aligned to UTF-8"
                    )
                    stop.pointee = true
                    return
                }
            }

            do {
                matchesFound += 1
                let shouldContinue = try matchHandler(SearchMatch(
                    byteRange: byteRange,
                    captureByteRanges: captures
                ))
                if !shouldContinue {
                    stopReason = .matchHandlerRequestedStop
                    stop.pointee = true
                }
            } catch {
                callbackError = error
                stop.pointee = true
            }
        }

        if let callbackError { throw callbackError }
        let processed = stopReason == .completed ? total : 0
        progress?(SearchProgress(
            processedBytes: processed,
            totalBytes: total,
            matchesFound: matchesFound
        ))
        return SearchResult(
            matchesFound: matchesFound,
            processedBytes: processed,
            stopReason: stopReason
        )
    }

    private func utf8BoundaryAtOrAfter(
        _ proposedOffset: Int64,
        limitedBy upperBound: Int64
    ) throws -> Int64 {
        var offset = min(proposedOffset, upperBound)
        while offset < upperBound {
            let candidate = try byte(at: offset)
            if candidate & 0b1100_0000 != 0b1000_0000 { break }
            offset += 1
        }
        return offset
    }

    private func utf8BoundaryAtOrBefore(
        _ proposedOffset: Int64,
        limitedBy lowerBound: Int64
    ) throws -> Int64 {
        var offset = max(proposedOffset, lowerBound)
        while offset > lowerBound, offset < byteCount {
            let candidate = try byte(at: offset)
            if candidate & 0b1100_0000 != 0b1000_0000 { break }
            offset -= 1
        }
        return offset
    }

    private func clampedAdding(_ lhs: Int64, _ rhs: Int64) -> Int64 {
        if rhs > 0, lhs > Int64.max - rhs { return Int64.max }
        if rhs < 0, lhs < Int64.min - rhs { return Int64.min }
        return lhs + rhs
    }
}

private nonisolated func regexErrorIsResponsivenessRisk(_ error: LighTxtCoreError) -> Bool {
    guard case let .unsupportedRegularExpression(reason) = error else { return false }
    let normalized = reason.lowercased()
    return normalized.contains("catastrophic backtracking")
        || normalized.contains("responsive matching")
}
