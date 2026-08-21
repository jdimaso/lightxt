import Foundation

/// The text formats LighTxt understands natively.
public enum SyntaxFileType: String, CaseIterable, Sendable {
    case plainText = "txt"
    case json
    case markdown = "md"
    case sql
    case xml
    case csv
    case yaml
    case parquet

    public var preferredPathExtension: String { rawValue }

    public var pathExtensions: Set<String> {
        switch self {
        case .plainText: ["txt", "text", "log", "script"]
        case .json: ["json"]
        case .markdown: ["md", "markdown"]
        case .sql: ["sql"]
        case .xml: ["xml"]
        case .csv: ["csv"]
        case .yaml: ["yaml", "yml"]
        case .parquet: ["parquet"]
        }
    }
}

/// A half-open range expressed in UTF-8 bytes, never UTF-16 code units or
/// grapheme clusters. File-backed clients can therefore apply results without
/// materializing the complete document as a `String`.
public struct SyntaxByteRange: Hashable, Sendable {
    public let start: Int
    public let length: Int

    public init(start: Int, length: Int) {
        self.start = max(0, start)
        self.length = max(0, length)
    }

    public init(_ range: Range<Int>) {
        self.init(start: range.lowerBound, length: range.count)
    }

    public var end: Int {
        let (result, overflow) = start.addingReportingOverflow(length)
        return overflow ? Int.max : result
    }

    public var range: Range<Int> { start..<end }
    public var isEmpty: Bool { length == 0 }
}

public enum SyntaxSemanticKind: String, CaseIterable, Sendable {
    case string
    case number
    case keyword
    case boolean
    case null
    case comment
    case key
    case punctuation
    case `operator`
    case tag
    case attributeName
    case attributeValue
    case entity
    case heading
    case emphasis
    case link
    case code
    case codeFence
    case listMarker
    case quoteMarker
    case directive
    case anchor
    case alias
    case error
}

public struct SyntaxSpan: Hashable, Sendable {
    /// Absolute byte coordinates in the file. The viewport's base offset has
    /// already been applied.
    public let range: SyntaxByteRange
    public let kind: SyntaxSemanticKind

    public init(range: SyntaxByteRange, kind: SyntaxSemanticKind) {
        self.range = range
        self.kind = kind
    }
}

/// State passed between adjacent chunks. Passing the previous result's
/// `endState` makes quoted strings, comments, fenced blocks, and XML tags safe
/// to highlight even when a viewport boundary splits a token.
public struct SyntaxLexicalState: Equatable, Sendable {
    public enum Mode: Equatable, Sendable {
        case normal
        case quotedString(delimiter: UInt8, escaped: Bool)
        case lineComment
        case blockComment(depth: Int)
        /// A block-comment chunk ended in '/'; the next '*' may begin a nested
        /// comment without requiring an overlap allocation.
        case blockCommentAfterSlash(depth: Int)
        /// A block-comment chunk ended in '*'; the next '/' may close it.
        case blockCommentAfterAsterisk(depth: Int)
        case xmlComment
        case xmlCommentContinuation(matchedTerminatorBytes: Int)
        case xmlCDATA
        case xmlCDATAContinuation(matchedTerminatorBytes: Int)
        case xmlProcessingInstruction
        case xmlProcessingInstructionContinuation(matchedTerminatorBytes: Int)
        case xmlTag(quote: UInt8?, expectsElementName: Bool)
        case markdownFence(marker: UInt8, count: Int)
        case sqlDollarQuoted(delimiter: [UInt8])
        case csvQuotedField
        case yamlBlockScalar(parentIndent: Int)
    }

    public var mode: Mode
    /// Whether byte zero of the next chunk is the start of a logical line.
    public var atLineStart: Bool

    public init(mode: Mode = .normal, atLineStart: Bool = true) {
        self.mode = mode
        self.atLineStart = atLineStart
    }

    public static let neutral = SyntaxLexicalState()
}

public struct SyntaxHighlightResult: Sendable {
    public let spans: [SyntaxSpan]
    public let endState: SyntaxLexicalState
    /// True when `maximumSpans` was reached. Scanning still completes so the
    /// returned continuation state remains valid.
    public let wasTruncated: Bool

    public init(spans: [SyntaxSpan], endState: SyntaxLexicalState, wasTruncated: Bool) {
        self.spans = spans
        self.endState = endState
        self.wasTruncated = wasTruncated
    }
}

public enum SyntaxDiagnosticSeverity: String, Sendable {
    case information
    case warning
    case error
}

public struct SyntaxDiagnostic: Hashable, Sendable {
    public let severity: SyntaxDiagnosticSeverity
    public let code: String
    public let message: String
    public let range: SyntaxByteRange

    public init(
        severity: SyntaxDiagnosticSeverity,
        code: String,
        message: String,
        range: SyntaxByteRange
    ) {
        self.severity = severity
        self.code = code
        self.message = message
        self.range = range
    }
}

public enum SyntaxFoldKind: String, Sendable {
    case object
    case array
    case element
    case mapping
    case sequence
    case scalar
    case comment
}

public struct SyntaxFoldRange: Hashable, Sendable {
    /// Complete construct, including delimiters or the YAML header.
    public let range: SyntaxByteRange
    /// Portion retained on screen when the range is collapsed.
    public let headerRange: SyntaxByteRange
    /// Bytes hidden by a collapse operation.
    public let contentRange: SyntaxByteRange
    public let kind: SyntaxFoldKind
    public let depth: Int

    public init(
        range: SyntaxByteRange,
        headerRange: SyntaxByteRange,
        contentRange: SyntaxByteRange,
        kind: SyntaxFoldKind,
        depth: Int
    ) {
        self.range = range
        self.headerRange = headerRange
        self.contentRange = contentRange
        self.kind = kind
        self.depth = max(0, depth)
    }
}

public struct SyntaxFoldResult: Sendable {
    public let ranges: [SyntaxFoldRange]
    /// True when matching continued but additional fold ranges were discarded
    /// after reaching `maximumFoldRanges`.
    public let wasTruncated: Bool

    public init(ranges: [SyntaxFoldRange], wasTruncated: Bool) {
        self.ranges = ranges
        self.wasTruncated = wasTruncated
    }
}

/// Hard caps keep every operation predictable on adversarial or multi-gigabyte
/// files. Results are proportional to the viewport, diagnostic cap, or folding
/// cap rather than to the source file's textual representation.
public struct SyntaxLimits: Hashable, Sendable {
    public var maximumSpans: Int
    public var maximumDiagnostics: Int
    public var maximumFoldRanges: Int
    public var maximumNestingDepth: Int
    public var maximumTokenBytes: Int
    /// Single-line JSON/XML constructs at least this large remain foldable;
    /// tiny inline values stay visually quiet.
    public var minimumFoldByteCount: Int
    public var csvDelimiter: UInt8

    public init(
        maximumSpans: Int = 32_768,
        maximumDiagnostics: Int = 128,
        maximumFoldRanges: Int = 65_536,
        maximumNestingDepth: Int = 512,
        maximumTokenBytes: Int = 1_048_576,
        minimumFoldByteCount: Int = 24,
        csvDelimiter: UInt8 = 0x2C
    ) {
        self.maximumSpans = max(0, maximumSpans)
        self.maximumDiagnostics = max(0, maximumDiagnostics)
        self.maximumFoldRanges = max(0, maximumFoldRanges)
        self.maximumNestingDepth = max(1, maximumNestingDepth)
        self.maximumTokenBytes = max(16, maximumTokenBytes)
        self.minimumFoldByteCount = max(2, minimumFoldByteCount)
        self.csvDelimiter = csvDelimiter
    }

    public static let `default` = SyntaxLimits()
}
