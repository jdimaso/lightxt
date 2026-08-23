import Foundation

/// Content and dialect detection that reads only a caller-supplied prefix. Even
/// when `sample` is larger, no byte after `maximumSampleByteCount` is inspected.
public enum SampledDocumentDetector {
    public static let maximumSampleByteCount = 64 * 1_024

    public static func detect(
        sample: Data,
        fileName: String? = nil
    ) -> SampledDocumentDetection {
        let bounded = Data(sample.prefix(maximumSampleByteCount))
        let encoding = detectEncoding(in: bounded)
        return detect(
            boundedSample: bounded,
            fileName: fileName,
            encoding: encoding
        )
    }

    /// Classifies the bounded prefix using an explicit Open As encoding rather
    /// than borrowing automatic BOM/byte-pattern inference. A matching BOM is
    /// consumed; a conflicting BOM remains input and normally makes strict
    /// decoding fail closed to an extension hint or plain text.
    public static func detect(
        sample: Data,
        fileName: String? = nil,
        assuming encoding: DocumentTextEncoding
    ) -> SampledDocumentDetection {
        let bounded = Data(sample.prefix(maximumSampleByteCount))
        let observed = detectEncoding(in: bounded)
        let matchesObservedEncoding = observed.encoding == encoding
        let selection = TextEncodingDetection(
            encoding: encoding,
            byteOrderMarkByteCount: matchesObservedEncoding
                ? observed.byteOrderMarkByteCount
                : 0,
            confidence: matchesObservedEncoding ? observed.confidence : .low,
            evidence: .explicitSelection
        )
        return detect(
            boundedSample: bounded,
            fileName: fileName,
            encoding: selection
        )
    }

    private static func detect(
        boundedSample bounded: Data,
        fileName: String?,
        encoding: TextEncodingDetection
    ) -> SampledDocumentDetection {
        guard let decoded = decode(bounded, detection: encoding) else {
            return SampledDocumentDetection(
                format: extensionHint(fileName) ?? .plainText,
                formatConfidence: .low,
                textEncoding: encoding,
                tableDialect: nil,
                sampledByteCount: bounded.count
            )
        }

        let classified = classify(text: decoded, fileName: fileName)
        return SampledDocumentDetection(
            format: classified.format,
            formatConfidence: classified.confidence,
            textEncoding: encoding,
            tableDialect: classified.dialect,
            sampledByteCount: bounded.count
        )
    }

    public static func detectEncoding(in sample: Data) -> TextEncodingDetection {
        let bounded = Data(sample.prefix(maximumSampleByteCount))
        let bytes = [UInt8](bounded)

        if bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]) {
            return bom(.utf32BigEndian, length: 4)
        }
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) {
            return bom(.utf32LittleEndian, length: 4)
        }
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return bom(.utf8, length: 3)
        }
        if bytes.starts(with: [0xFE, 0xFF]) {
            return bom(.utf16BigEndian, length: 2)
        }
        if bytes.starts(with: [0xFF, 0xFE]) {
            return bom(.utf16LittleEndian, length: 2)
        }

        if let inferred = inferZeroPatternEncoding(bytes),
           decodeBytes(bounded, as: inferred) != nil {
            return TextEncodingDetection(
                encoding: inferred,
                byteOrderMarkByteCount: 0,
                confidence: .medium,
                evidence: .bytePattern
            )
        }

        if let text = decodeUTF8Sample(bounded) {
            let containsNonASCII = bounded.contains { $0 >= 0x80 }
            return TextEncodingDetection(
                encoding: .utf8,
                byteOrderMarkByteCount: 0,
                confidence: containsNonASCII && !text.isEmpty ? .high : .medium,
                evidence: .validUTF8
            )
        }

        return TextEncodingDetection(
            encoding: nil,
            byteOrderMarkByteCount: 0,
            confidence: .low,
            evidence: .unavailable
        )
    }

    private static func bom(
        _ encoding: DocumentTextEncoding,
        length: Int
    ) -> TextEncodingDetection {
        TextEncodingDetection(
            encoding: encoding,
            byteOrderMarkByteCount: length,
            confidence: .high,
            evidence: .byteOrderMark
        )
    }

    private static func inferZeroPatternEncoding(_ bytes: [UInt8]) -> DocumentTextEncoding? {
        guard bytes.count >= 16 else { return nil }

        let quadCount = min(bytes.count / 4, 4_096)
        if quadCount >= 4 {
            var zeroCounts = [Int](repeating: 0, count: 4)
            for group in 0..<quadCount {
                for lane in 0..<4 where bytes[group * 4 + lane] == 0 {
                    zeroCounts[lane] += 1
                }
            }
            let ratios = zeroCounts.map { Double($0) / Double(quadCount) }
            if ratios[0] < 0.20, ratios[1] > 0.70, ratios[2] > 0.70, ratios[3] > 0.70 {
                return .utf32LittleEndian
            }
            if ratios[0] > 0.70, ratios[1] > 0.70, ratios[2] > 0.70, ratios[3] < 0.20 {
                return .utf32BigEndian
            }
        }

        let pairCount = min(bytes.count / 2, 8_192)
        guard pairCount >= 8 else { return nil }
        var evenZeros = 0
        var oddZeros = 0
        for pair in 0..<pairCount {
            if bytes[pair * 2] == 0 { evenZeros += 1 }
            if bytes[pair * 2 + 1] == 0 { oddZeros += 1 }
        }
        let evenRatio = Double(evenZeros) / Double(pairCount)
        let oddRatio = Double(oddZeros) / Double(pairCount)
        if evenRatio < 0.20, oddRatio > 0.60 { return .utf16LittleEndian }
        if evenRatio > 0.60, oddRatio < 0.20 { return .utf16BigEndian }
        return nil
    }

    private static func decode(
        _ sample: Data,
        detection: TextEncodingDetection
    ) -> String? {
        guard let encoding = detection.encoding else { return nil }
        let payload = Data(sample.dropFirst(min(sample.count, detection.byteOrderMarkByteCount)))
        return decodeBytes(payload, as: encoding)
    }

    /// A sampled prefix can end between code units or at the first half of a
    /// surrogate pair. UTF-8 uses structural validation below; fixed-width
    /// encodings trim no more than two trailing code units.
    private static func decodeBytes(
        _ data: Data,
        as encoding: DocumentTextEncoding
    ) -> String? {
        if encoding == .utf8 {
            return decodeUTF8Sample(data)
        }
        let unit = encoding.codeUnitByteCount
        var candidate = data
        let remainder = candidate.count % unit
        if remainder > 0 { candidate.removeLast(remainder) }
        for attempt in 0..<3 {
            if let decoded = String(data: candidate, encoding: encoding.foundationEncoding) {
                return decoded
            }
            guard attempt < 2, candidate.count >= unit else { break }
            candidate.removeLast(unit)
        }
        return nil
    }

    /// Strictly decodes UTF-8, except for one valid sequence prefix cut off at
    /// the sample boundary. A UTF-8 scalar can contribute at most three bytes
    /// before that boundary; illegal leads, stray continuations, overlong
    /// prefixes, surrogate prefixes, and values above U+10FFFF remain errors.
    private static func decodeUTF8Sample(_ data: Data) -> String? {
        if let decoded = String(data: data, encoding: .utf8) {
            return decoded
        }

        let bytes = [UInt8](data)
        for suffixByteCount in 1...min(3, bytes.count) {
            let suffixStart = bytes.count - suffixByteCount
            let suffix = Array(bytes[suffixStart...])
            guard isPlausiblyIncompleteUTF8Sequence(suffix) else { continue }
            let prefix = Data(bytes[..<suffixStart])
            if let decoded = String(data: prefix, encoding: .utf8) {
                return decoded
            }
        }
        return nil
    }

    private static func isPlausiblyIncompleteUTF8Sequence(_ bytes: [UInt8]) -> Bool {
        guard let lead = bytes.first else { return false }
        let expectedByteCount: Int
        switch lead {
        case 0xC2...0xDF: expectedByteCount = 2
        case 0xE0...0xEF: expectedByteCount = 3
        case 0xF0...0xF4: expectedByteCount = 4
        default: return false
        }
        guard bytes.count < expectedByteCount else { return false }

        for index in bytes.indices.dropFirst() {
            let byte = bytes[index]
            if index == 1 {
                let validFirstContinuation: ClosedRange<UInt8> = switch lead {
                case 0xE0: 0xA0...0xBF
                case 0xED: 0x80...0x9F
                case 0xF0: 0x90...0xBF
                case 0xF4: 0x80...0x8F
                default: 0x80...0xBF
                }
                guard validFirstContinuation.contains(byte) else { return false }
            } else {
                guard (0x80...0xBF).contains(byte) else { return false }
            }
        }
        return true
    }

    private struct Classification {
        let format: DocumentOpenAsFormat
        let confidence: SampleDetectionConfidence
        let dialect: DelimitedTextDialect?
    }

    private struct ScoredFormat {
        let format: DocumentOpenAsFormat
        let score: Int
    }

    private static func classify(text: String, fileName: String?) -> Classification {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Classification(
                format: extensionHint(fileName) ?? .plainText,
                confidence: .low,
                dialect: nil
            )
        }

        if looksLikeXML(trimmed) {
            return Classification(format: .xml, confidence: .high, dialect: nil)
        }
        if let confidence = jsonConfidence(trimmed) {
            return Classification(format: .json, confidence: confidence, dialect: nil)
        }

        let lines = sampledLines(text)
        let knownDelimitedExtension = delimiterHint(fileName)
        var candidates = [
            ScoredFormat(format: .sql, score: sqlScore(trimmed, lines: lines)),
            ScoredFormat(format: .markdown, score: markdownScore(trimmed, lines: lines)),
            ScoredFormat(format: .yaml, score: yamlScore(lines)),
        ]
        // YAML is necessarily heuristic here; unlike JSON/XML it has no
        // bounded parser-backed signature. A declared table extension is
        // therefore authoritative over YAML-like punctuation inside data
        // fields. SQL and Markdown candidates remain eligible for genuinely
        // misnamed files.
        if knownDelimitedExtension != nil {
            candidates.removeAll { $0.format == .yaml }
        }
        candidates.sort { $0.score > $1.score }
        if let first = candidates.first,
           first.score >= 4,
           first.score - (candidates.dropFirst().first?.score ?? 0) >= 2 {
            return Classification(
                format: first.format,
                confidence: first.score >= 7 ? .high : .medium,
                dialect: nil
            )
        }

        if let table = detectDelimitedText(in: text, preferred: knownDelimitedExtension) {
            return Classification(
                format: .delimitedText(table.dialect.delimiter),
                confidence: table.confidence,
                dialect: table.dialect
            )
        }

        if let hint = extensionHint(fileName) {
            return Classification(format: hint, confidence: .low, dialect: nil)
        }
        return Classification(format: .plainText, confidence: .low, dialect: nil)
    }

    private static func sampledLines(_ text: String) -> [Substring] {
        var lines: [Substring] = []
        lines.reserveCapacity(80)
        for line in text.split(whereSeparator: { $0.isNewline }) {
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            guard !trimmed.isEmpty else { continue }
            lines.append(trimmed)
            if lines.count == 80 { break }
        }
        return lines
    }

    private static func looksLikeXML(_ text: String) -> Bool {
        if text.hasPrefix("<?xml") || text.hasPrefix("<!--") || text.hasPrefix("<!DOCTYPE") {
            return text.contains(">")
        }
        guard text.first == "<", text.count >= 3 else { return false }
        let next = text.index(after: text.startIndex)
        guard text[next].isLetter || text[next] == "_" else { return false }
        guard let close = text.firstIndex(of: ">") else { return false }
        return text.distance(from: text.startIndex, to: close) <= 256
    }

    private static func jsonConfidence(_ text: String) -> SampleDetectionConfidence? {
        guard let first = text.first, first == "{" || first == "[" else { return nil }
        let data = Data(text.utf8)
        if (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil {
            return .high
        }
        if first == "{" {
            guard text.contains(":"), text.contains("\"") else { return nil }
            return .medium
        }
        let remainder = text.dropFirst().drop(while: { $0.isWhitespace })
        guard let token = remainder.first,
              token == "\"" || token == "{" || token == "[" || token == "-"
                || token.isNumber || token == "t" || token == "f" || token == "n" else {
            return nil
        }
        return .medium
    }

    private static func sqlScore(_ text: String, lines: [Substring]) -> Int {
        let lower = text.lowercased()
        let firstWord = lower.prefix { $0.isLetter }
        let leadingKeywords: Set<Substring> = [
            "select", "insert", "update", "delete", "create", "alter", "drop", "with", "merge",
        ]
        guard leadingKeywords.contains(firstWord) else { return 0 }
        var score = 3
        for phrase in [" from ", " into ", " values ", " set ", " table ", " join ", " where "] {
            if lower.contains(phrase) { score += 2 }
        }
        if lower.contains(";") { score += 1 }
        if lines.contains(where: { $0.hasPrefix("--") }) { score += 1 }
        return score
    }

    private static func markdownScore(_ text: String, lines: [Substring]) -> Int {
        var score = 0
        var listCount = 0
        var quoteCount = 0
        for line in lines {
            if line.hasPrefix("```") || line.hasPrefix("~~~") { score += 4 }
            if markdownHeading(line) { score += 3 }
            if line.hasPrefix("> ") { quoteCount += 1 }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("+ ")
                || orderedListMarker(line) { listCount += 1 }
            if markdownTableSeparator(line) { score += 4 }
        }
        score += min(2, listCount)
        score += min(2, quoteCount)
        if text.contains("](") { score += 2 }
        return score
    }

    private static func markdownHeading(_ line: Substring) -> Bool {
        var hashes = 0
        var cursor = line.startIndex
        while cursor < line.endIndex, line[cursor] == "#", hashes < 7 {
            hashes += 1
            cursor = line.index(after: cursor)
        }
        return (1...6).contains(hashes)
            && cursor < line.endIndex
            && line[cursor].isWhitespace
    }

    private static func orderedListMarker(_ line: Substring) -> Bool {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 4 else { return false }
        let suffix = line.dropFirst(digits.count)
        return suffix.hasPrefix(". ") || suffix.hasPrefix(") ")
    }

    private static func markdownTableSeparator(_ line: Substring) -> Bool {
        guard line.contains("|") else { return false }
        let meaningful = line.filter { $0 != "|" && $0 != ":" && !$0.isWhitespace }
        return meaningful.count >= 3 && meaningful.allSatisfy { $0 == "-" }
    }

    private static func yamlScore(_ lines: [Substring]) -> Int {
        var score = 0
        var mappings = 0
        var sequences = 0
        var documentMarkers = 0
        var anchorOrAliasTokens = 0
        var blockScalars = 0
        for line in lines {
            if line == "---" || line == "..." { documentMarkers += 1 }
            if yamlMappingLine(line) { mappings += 1 }
            if line.hasPrefix("- ") { sequences += 1 }
            if yamlAnchorOrAliasToken(line) || line.hasPrefix("!!") {
                anchorOrAliasTokens += 1
            }
            if line.hasSuffix(": |") || line.hasSuffix(": >") { blockScalars += 1 }
        }
        score += min(4, documentMarkers * 2)
        if mappings >= 2 { score += min(6, mappings * 2) }
        else if mappings == 1, sequences > 0 { score += 3 }
        if sequences >= 2 { score += 2 }
        let hasDocumentStructure = mappings > 0 || sequences > 0 || documentMarkers > 0
        if hasDocumentStructure {
            // Anchors, aliases, and tags modify YAML nodes; they are not YAML
            // structure on their own. Keep their contribution bounded so
            // ordinary prose or CSV values containing ampersands cannot win.
            score += min(2, anchorOrAliasTokens)
            if mappings > 0 { score += min(2, blockScalars * 2) }
        }
        return score
    }

    private static func yamlAnchorOrAliasToken(_ line: Substring) -> Bool {
        var quote: Character?
        var previous: Character?
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\"" || character == "'" {
                if quote == character { quote = nil }
                else if quote == nil { quote = character }
            } else if quote == nil, character == "&" || character == "*" {
                let separated = previous == nil
                    || previous?.isWhitespace == true
                    || previous == "["
                    || previous == "{"
                    || previous == ","
                let next = line.index(after: index)
                if separated, next < line.endIndex {
                    let nameStart = line[next]
                    if nameStart.isLetter || nameStart.isNumber
                        || nameStart == "_" || nameStart == "-" {
                        return true
                    }
                }
            }
            previous = character
            index = line.index(after: index)
        }
        return false
    }

    private static func yamlMappingLine(_ line: Substring) -> Bool {
        var quote: Character?
        for index in line.indices {
            let character = line[index]
            if character == "\"" || character == "'" {
                if quote == character { quote = nil }
                else if quote == nil { quote = character }
                continue
            }
            guard quote == nil, character == ":" else { continue }
            let after = line.index(after: index)
            guard after == line.endIndex || line[after].isWhitespace else { continue }
            let key = line[..<index].trimmingCharacters(in: .whitespaces)
            return !key.isEmpty && key.count <= 256
        }
        return false
    }

    private struct TableClassification {
        let dialect: DelimitedTextDialect
        let confidence: SampleDetectionConfidence
    }

    private struct ParsedTableCandidate {
        let delimiter: DelimitedTextDelimiter
        let records: [[String]]
        let dominantColumnCount: Int
        let consistentRecordCount: Int
        let consideredRecordCount: Int

        var score: Int {
            consistentRecordCount * 100
                + min(20, dominantColumnCount)
                - max(0, consideredRecordCount - consistentRecordCount) * 40
        }
    }

    private static func detectDelimitedText(
        in text: String,
        preferred: DelimitedTextDelimiter?
    ) -> TableClassification? {
        let bytes = [UInt8](text.utf8)
        let candidates = DelimitedTextDelimiter.allCases.compactMap {
            parseTableCandidate(bytes, delimiter: $0)
        }.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.delimiter == preferred { return true }
            if rhs.delimiter == preferred { return false }
            return lhs.delimiter.rawValue < rhs.delimiter.rawValue
        }
        guard let best = candidates.first,
              best.consistentRecordCount >= 3,
              Double(best.consistentRecordCount) / Double(max(1, best.consideredRecordCount)) >= 0.80 else {
            return nil
        }
        if let second = candidates.dropFirst().first,
           second.score == best.score,
           best.delimiter != preferred {
            return nil
        }

        let lineEnding = detectLineEnding(in: bytes)
        let header = inferHeader(from: best.records, columnCount: best.dominantColumnCount)
        let dialect = DelimitedTextDialect(
            delimiter: best.delimiter,
            columnCount: best.dominantColumnCount,
            sampledRecordCount: best.consideredRecordCount,
            firstRowLikelyHeader: header,
            lineEnding: lineEnding
        )
        let ratio = Double(best.consistentRecordCount) / Double(max(1, best.consideredRecordCount))
        let confidence: SampleDetectionConfidence = best.consistentRecordCount >= 5 && ratio >= 0.95
            ? .high
            : .medium
        return TableClassification(dialect: dialect, confidence: confidence)
    }

    private static func parseTableCandidate(
        _ bytes: [UInt8],
        delimiter: DelimitedTextDelimiter
    ) -> ParsedTableCandidate? {
        let separator = delimiter.rawValue
        var records: [[String]] = []
        var record: [String] = []
        var field: [UInt8] = []
        var inQuotes = false
        var atFieldStart = true
        var recordHasContent = false
        var index = 0

        func finishField() {
            if record.count < 256 {
                record.append(String(decoding: field.prefix(1_024), as: UTF8.self))
            }
            field.removeAll(keepingCapacity: true)
            atFieldStart = true
        }

        func finishRecord() {
            finishField()
            if recordHasContent || record.count > 1 {
                records.append(record)
            }
            record.removeAll(keepingCapacity: true)
            recordHasContent = false
        }

        while index < bytes.count, records.count < 64 {
            let byte = bytes[index]
            if inQuotes {
                if byte == 0x22 {
                    if index + 1 < bytes.count, bytes[index + 1] == 0x22 {
                        if field.count < 1_024 { field.append(0x22) }
                        index += 2
                        continue
                    }
                    inQuotes = false
                } else if field.count < 1_024 {
                    field.append(byte)
                }
                recordHasContent = true
                index += 1
                continue
            }

            if byte == 0x22, atFieldStart {
                inQuotes = true
                recordHasContent = true
            } else if byte == separator {
                finishField()
                recordHasContent = true
            } else if byte == 0x0A || byte == 0x0D {
                finishRecord()
                if byte == 0x0D, index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    index += 1
                }
            } else {
                if field.count < 1_024 { field.append(byte) }
                if byte != 0x20 && byte != 0x09 { recordHasContent = true }
                atFieldStart = false
            }
            index += 1
        }
        if !inQuotes, records.count < 64, recordHasContent || !field.isEmpty || !record.isEmpty {
            finishRecord()
        }

        let considered = records.filter { !$0.isEmpty }
        let frequencies = Dictionary(grouping: considered, by: \.count)
        guard let dominant = frequencies
            .filter({ $0.key >= 2 })
            .max(by: { lhs, rhs in
                if lhs.value.count != rhs.value.count { return lhs.value.count < rhs.value.count }
                return lhs.key < rhs.key
            }) else { return nil }
        return ParsedTableCandidate(
            delimiter: delimiter,
            records: considered,
            dominantColumnCount: dominant.key,
            consistentRecordCount: dominant.value.count,
            consideredRecordCount: considered.count
        )
    }

    private enum FieldShape: Equatable {
        case empty
        case number
        case boolean
        case text
    }

    private static func inferHeader(
        from records: [[String]],
        columnCount: Int
    ) -> Bool? {
        guard records.count >= 3,
              records[0].count == columnCount else { return nil }
        let first = records[0].map(fieldShape)
        guard first.allSatisfy({ $0 == .text }) else { return nil }
        let following = records.dropFirst().prefix(8).filter { $0.count == columnCount }
        guard following.count >= 2 else { return nil }
        var typedColumns = 0
        for column in 0..<columnCount {
            let shapes = following.map { fieldShape($0[column]) }
            if shapes.contains(where: { $0 == .number || $0 == .boolean }) {
                typedColumns += 1
            }
        }
        return typedColumns * 2 >= columnCount ? true : nil
    }

    private static func fieldShape(_ raw: String) -> FieldShape {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return .empty }
        if Double(value) != nil { return .number }
        switch value.lowercased() {
        case "true", "false", "yes", "no": return .boolean
        default: return .text
        }
    }

    private static func detectLineEnding(in bytes: [UInt8]) -> SampledLineEnding {
        var lf = 0
        var crlf = 0
        var cr = 0
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x0D {
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                    crlf += 1
                    index += 1
                } else {
                    cr += 1
                }
            } else if bytes[index] == 0x0A {
                lf += 1
            }
            index += 1
        }
        let present = [lf, crlf, cr].filter { $0 > 0 }.count
        if present == 0 { return .unknown }
        if present > 1 { return .mixed }
        if crlf > 0 { return .carriageReturnLineFeed }
        if cr > 0 { return .carriageReturn }
        return .lineFeed
    }

    private static func extensionHint(_ fileName: String?) -> DocumentOpenAsFormat? {
        guard let fileName else { return nil }
        let ext = URL(fileURLWithPath: fileName).pathExtension.lowercased()
        return switch ext {
        case "txt", "text", "log", "script": .plainText
        case "json": .json
        case "md", "markdown": .markdown
        case "sql": .sql
        case "xml": .xml
        case "yaml", "yml": .yaml
        case "csv": .delimitedText(.comma)
        case "tsv": .delimitedText(.tab)
        case "psv": .delimitedText(.pipe)
        default: nil
        }
    }

    private static func delimiterHint(_ fileName: String?) -> DelimitedTextDelimiter? {
        guard case .delimitedText(let delimiter) = extensionHint(fileName) else { return nil }
        return delimiter
    }
}
