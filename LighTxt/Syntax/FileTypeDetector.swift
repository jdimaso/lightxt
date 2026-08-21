import Foundation

public enum SyntaxFileTypeDetector {
    private static let sniffedSQLKeywords = [
        "select", "insert", "update", "delete", "create", "alter", "drop", "with"
    ]

    /// Returns nil for an extension LighTxt does not explicitly support.
    public static func knownType(forPathExtension pathExtension: String) -> SyntaxFileType? {
        switch pathExtension.lowercased() {
        case "txt", "text", "log", "script": .plainText
        case "json": .json
        case "md", "markdown": .markdown
        case "sql": .sql
        case "xml": .xml
        case "csv": .csv
        case "yaml", "yml": .yaml
        case "parquet": .parquet
        default: nil
        }
    }

    public static func detect(fileName: String, sample: Data? = nil) -> SyntaxFileType {
        let pathExtension = URL(fileURLWithPath: fileName).pathExtension
        if let explicit = knownType(forPathExtension: pathExtension) { return explicit }
        if let sample, let sniffed = sniff(sample) { return sniffed }
        return .plainText
    }

    public static func detect(url: URL, sample: Data? = nil) -> SyntaxFileType {
        if let explicit = knownType(forPathExtension: url.pathExtension) { return explicit }
        if let sample, let sniffed = sniff(sample) { return sniffed }
        return .plainText
    }

    /// Conservative content detection for extensionless files. It examines at
    /// most 64 KiB and deliberately returns nil when signals conflict.
    public static func sniff(_ sample: Data) -> SyntaxFileType? {
        sample.withUnsafeBytes { rawBuffer in
            sniff(rawBuffer.bindMemory(to: UInt8.self))
        }
    }

    public static func sniff(_ bytes: UnsafeRawBufferPointer) -> SyntaxFileType? {
        sniff(bytes.bindMemory(to: UInt8.self))
    }

    public static func sniff(_ bytes: UnsafeBufferPointer<UInt8>) -> SyntaxFileType? {
        let byteCount = min(bytes.count, 65_536)
        // This engine's coordinates and lexers are UTF-8-native. Do not
        // misclassify UTF-16/32 samples based on their interleaved ASCII bytes;
        // the document-opening layer can offer an explicit transcoding choice.
        if byteCount >= 2,
           (bytes[0] == 0xFF && bytes[1] == 0xFE) ||
           (bytes[0] == 0xFE && bytes[1] == 0xFF) {
            return nil
        }
        if byteCount >= 4,
           (bytes[0] == 0x00 && bytes[1] == 0x00 && bytes[2] == 0xFE && bytes[3] == 0xFF) ||
           (bytes[0] == 0xFF && bytes[1] == 0xFE && bytes[2] == 0x00 && bytes[3] == 0x00) {
            return nil
        }
        guard let first = SyntaxByteUtilities.firstNonWhitespace(bytes, limit: byteCount) else {
            return .plainText
        }

        if byteCount >= 4,
           bytes[0] == 0x50, bytes[1] == 0x41,
           bytes[2] == 0x52, bytes[3] == 0x31 { // PAR1
            return .parquet
        }

        if bytes[first] == 0x7B || bytes[first] == 0x5B { // { or [
            return .json
        }
        if SyntaxByteUtilities.hasASCII(bytes, at: first, "<?xml", caseInsensitive: true) ||
            SyntaxByteUtilities.hasASCII(bytes, at: first, "<!--") || looksLikeXML(bytes, first: first, limit: byteCount) {
            return .xml
        }

        var lineStart = 0
        var inspectedLines = 0
        var markdownScore = 0
        var yamlScore = 0
        var sqlScore = 0
        var commaRows = 0
        var commaCount: Int?

        while lineStart < byteCount, inspectedLines < 40 {
            var end = lineStart
            while end < byteCount, !SyntaxByteUtilities.isLineBreak(bytes[end]) { end += 1 }
            var content = lineStart
            while content < end, SyntaxByteUtilities.isSpace(bytes[content]) { content += 1 }
            if content < end {
                if bytes[content] == 0x23 { markdownScore += 2 } // #
                if SyntaxByteUtilities.hasASCII(bytes, at: content, "```") ||
                    SyntaxByteUtilities.hasASCII(bytes, at: content, "~~~") { markdownScore += 3 }
                if SyntaxByteUtilities.hasASCII(bytes, at: content, "---") { yamlScore += 2 }
                if bytes[content] == 0x2D, content + 1 < end,
                   SyntaxByteUtilities.isSpace(bytes[content + 1]) { yamlScore += 1 }

                let wordEnd = firstWordEnd(bytes, from: content, limit: end)
                if sniffedSQLKeywords.contains(where: {
                    SyntaxByteUtilities.equalsASCII(bytes, from: content, to: wordEnd, $0, caseInsensitive: true)
                }) { sqlScore += 3 }

                var commas = 0
                var colons = 0
                var quote: UInt8?
                var index = content
                while index < end {
                    let byte = bytes[index]
                    if let active = quote {
                        if byte == active { quote = nil }
                    } else if byte == 0x22 || byte == 0x27 {
                        quote = byte
                    } else if byte == 0x2C {
                        commas += 1
                    } else if byte == 0x3A, index + 1 == end || SyntaxByteUtilities.isSpace(bytes[index + 1]) {
                        colons += 1
                    }
                    index += 1
                }
                if colons > 0 { yamlScore += 1 }
                if commas > 0 {
                    if commaCount == nil || commaCount == commas {
                        commaRows += 1
                        commaCount = commas
                    } else {
                        commaRows = 0
                    }
                }
            }
            inspectedLines += 1
            if end < byteCount {
                lineStart = end + 1
                if bytes[end] == 0x0D, lineStart < byteCount, bytes[lineStart] == 0x0A {
                    lineStart += 1
                }
            } else {
                lineStart = byteCount
            }
        }

        if sqlScore >= 3, sqlScore > markdownScore, sqlScore > yamlScore { return .sql }
        if markdownScore >= 3, markdownScore > yamlScore { return .markdown }
        if commaRows >= 2 { return .csv }
        if yamlScore >= 2 { return .yaml }
        return nil
    }

    private static func firstWordEnd(
        _ bytes: UnsafeBufferPointer<UInt8>,
        from start: Int,
        limit: Int
    ) -> Int {
        var end = start
        while end < limit, SyntaxByteUtilities.isASCIIAlpha(bytes[end]) { end += 1 }
        return end
    }

    private static func looksLikeXML(
        _ bytes: UnsafeBufferPointer<UInt8>,
        first: Int,
        limit: Int
    ) -> Bool {
        guard first + 2 < limit, bytes[first] == 0x3C,
              SyntaxByteUtilities.isIdentifierStart(bytes[first + 1]) else { return false }
        var index = first + 2
        while index < limit, index - first < 256 {
            if bytes[index] == 0x3E { return true }
            if SyntaxByteUtilities.isLineBreak(bytes[index]) { return false }
            index += 1
        }
        return false
    }
}
