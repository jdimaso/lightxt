import Foundation

/// Confidence reported by bounded, sample-only document detection. Callers
/// should offer an explicit Open As choice for anything below `.high` rather
/// than silently treating the result as authoritative.
public enum SampleDetectionConfidence: Int, Comparable, Sendable {
    case low
    case medium
    case high

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Text encodings that LighTxt can identify from a bounded prefix. This is an
/// opening-time description only: selecting one does not change the byte-backed
/// document engine or imply that the complete file has been transcoded.
public enum DocumentTextEncoding: String, CaseIterable, Sendable {
    case utf8 = "UTF-8"
    case utf16LittleEndian = "UTF-16 LE"
    case utf16BigEndian = "UTF-16 BE"
    case utf32LittleEndian = "UTF-32 LE"
    case utf32BigEndian = "UTF-32 BE"

    public var codeUnitByteCount: Int {
        switch self {
        case .utf8: 1
        case .utf16LittleEndian, .utf16BigEndian: 2
        case .utf32LittleEndian, .utf32BigEndian: 4
        }
    }

    var foundationEncoding: String.Encoding {
        switch self {
        case .utf8: .utf8
        case .utf16LittleEndian: .utf16LittleEndian
        case .utf16BigEndian: .utf16BigEndian
        case .utf32LittleEndian: .utf32LittleEndian
        case .utf32BigEndian: .utf32BigEndian
        }
    }
}

public enum TextEncodingEvidence: String, Sendable {
    case byteOrderMark
    case bytePattern
    case validUTF8
    case explicitSelection
    case unavailable
}

public struct TextEncodingDetection: Equatable, Sendable {
    /// Nil means the prefix did not conservatively identify one of the supported
    /// Unicode encodings. An Open As UI can still let the user choose explicitly.
    public let encoding: DocumentTextEncoding?
    public let byteOrderMarkByteCount: Int
    public let confidence: SampleDetectionConfidence
    public let evidence: TextEncodingEvidence

    public init(
        encoding: DocumentTextEncoding?,
        byteOrderMarkByteCount: Int,
        confidence: SampleDetectionConfidence,
        evidence: TextEncodingEvidence
    ) {
        self.encoding = encoding
        self.byteOrderMarkByteCount = max(0, byteOrderMarkByteCount)
        self.confidence = confidence
        self.evidence = evidence
    }

    public var hasByteOrderMark: Bool { byteOrderMarkByteCount > 0 }
}

public enum DelimitedTextDelimiter: UInt8, CaseIterable, Sendable {
    case comma = 0x2C
    case tab = 0x09
    case semicolon = 0x3B
    case pipe = 0x7C

    public var displayName: String {
        switch self {
        case .comma: "Comma"
        case .tab: "Tab"
        case .semicolon: "Semicolon"
        case .pipe: "Pipe"
        }
    }

    /// A conservative filename suggestion for a newly saved document. PSV is
    /// used for an explicitly detected/selected pipe-separated table; only
    /// content without a supported signal falls back to `.txt`.
    public var preferredPathExtension: String {
        switch self {
        case .comma, .semicolon: "csv"
        case .tab: "tsv"
        case .pipe: "psv"
        }
    }
}

public enum SampledLineEnding: String, Sendable {
    case lineFeed
    case carriageReturnLineFeed
    case carriageReturn
    case mixed
    case unknown
}

public struct DelimitedTextDialect: Equatable, Sendable {
    public let delimiter: DelimitedTextDelimiter
    public let columnCount: Int
    public let sampledRecordCount: Int
    public let firstRowLikelyHeader: Bool?
    public let lineEnding: SampledLineEnding

    public init(
        delimiter: DelimitedTextDelimiter,
        columnCount: Int,
        sampledRecordCount: Int,
        firstRowLikelyHeader: Bool?,
        lineEnding: SampledLineEnding
    ) {
        self.delimiter = delimiter
        self.columnCount = max(0, columnCount)
        self.sampledRecordCount = max(0, sampledRecordCount)
        self.firstRowLikelyHeader = firstRowLikelyHeader
        self.lineEnding = lineEnding
    }
}

/// Format selected by an Open As control. `.automatic` asks the caller to use a
/// `SampledDocumentDetection`; every other case is an explicit user override.
public enum DocumentOpenAsFormat: Equatable, Sendable {
    case automatic
    case plainText
    case json
    case markdown
    case sql
    case xml
    case yaml
    case delimitedText(DelimitedTextDelimiter)

    public static let defaultUntitledPathExtension = "txt"

    public var syntaxFileType: SyntaxFileType? {
        switch self {
        case .automatic: nil
        case .plainText: .plainText
        case .json: .json
        case .markdown: .markdown
        case .sql: .sql
        case .xml: .xml
        case .yaml: .yaml
        case .delimitedText: .csv
        }
    }

    public var preferredPathExtension: String {
        switch self {
        case .automatic, .plainText: Self.defaultUntitledPathExtension
        case .json: "json"
        case .markdown: "md"
        case .sql: "sql"
        case .xml: "xml"
        case .yaml: "yaml"
        case .delimitedText(let delimiter): delimiter.preferredPathExtension
        }
    }
}

public enum DocumentEncodingSelection: Equatable, Sendable {
    case automatic
    case explicit(DocumentTextEncoding)
}

/// Value model suitable for an Open As sheet. It deliberately contains no
/// whole-file bytes and can be adopted without changing the large-file engine.
public struct DocumentOpenOptions: Equatable, Sendable {
    public var format: DocumentOpenAsFormat
    public var encoding: DocumentEncodingSelection

    public init(
        format: DocumentOpenAsFormat = .automatic,
        encoding: DocumentEncodingSelection = .automatic
    ) {
        self.format = format
        self.encoding = encoding
    }

    public static let defaultUntitled = DocumentOpenOptions(
        format: .plainText,
        encoding: .explicit(.utf8)
    )

    public var preferredPathExtension: String { format.preferredPathExtension }
}

public struct SampledDocumentDetection: Equatable, Sendable {
    public let format: DocumentOpenAsFormat
    public let formatConfidence: SampleDetectionConfidence
    public let textEncoding: TextEncodingDetection
    public let tableDialect: DelimitedTextDialect?
    public let sampledByteCount: Int

    public init(
        format: DocumentOpenAsFormat,
        formatConfidence: SampleDetectionConfidence,
        textEncoding: TextEncodingDetection,
        tableDialect: DelimitedTextDialect?,
        sampledByteCount: Int
    ) {
        self.format = format
        self.formatConfidence = formatConfidence
        self.textEncoding = textEncoding
        self.tableDialect = tableDialect
        self.sampledByteCount = max(0, sampledByteCount)
    }

    public var syntaxFileType: SyntaxFileType {
        format.syntaxFileType ?? .plainText
    }

    public var preferredPathExtension: String { format.preferredPathExtension }

    /// Resolves an ordinary automatic open. Specific supported extensions are
    /// authoritative; sampled content is used for unknown or extensionless
    /// names. Explicit Open As choices are applied by the session before this
    /// policy is consulted.
    public func resolvedSyntaxFileType(
        forPathExtension pathExtension: String,
        parquetMagicDetected: Bool = false
    ) -> SyntaxFileType {
        SyntaxFileTypeDetector.knownType(forPathExtension: pathExtension)
            ?? (parquetMagicDetected ? .parquet : syntaxFileType)
    }

    /// TSV and PSV are unambiguous dialect declarations, so punctuation
    /// inside their fields must not outvote the filename. CSV remains
    /// sample-driven because semicolon-separated CSV is common in practice.
    public func resolvedDelimitedTextDelimiter(
        forPathExtension pathExtension: String
    ) -> DelimitedTextDelimiter {
        switch pathExtension.lowercased() {
        case "tsv": return .tab
        case "psv": return .pipe
        default: return tableDialect?.delimiter ?? .comma
        }
    }

    public var suggestedOpenOptions: DocumentOpenOptions {
        DocumentOpenOptions(
            format: format,
            encoding: textEncoding.encoding.map(DocumentEncodingSelection.explicit) ?? .automatic
        )
    }
}
