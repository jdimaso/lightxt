import Foundation

/// A byte-oriented lexical highlighter intended for file-backed viewport
/// slices. It never converts the viewport into a `String` and never retains the
/// input buffer.
public enum ViewportSyntaxHighlighter {
    private static let xmlCommentTerminator: [UInt8] = [0x2D, 0x2D, 0x3E]
    private static let xmlCDATATerminator: [UInt8] = [0x5D, 0x5D, 0x3E]
    private static let xmlProcessingInstructionTerminator: [UInt8] = [0x3F, 0x3E]

    public static func highlight(
        _ data: Data,
        as fileType: SyntaxFileType,
        baseByteOffset: Int = 0,
        initialState: SyntaxLexicalState = .neutral,
        limits: SyntaxLimits = .default
    ) -> SyntaxHighlightResult {
        data.withUnsafeBytes { rawBuffer in
            highlight(
                rawBuffer.bindMemory(to: UInt8.self),
                as: fileType,
                baseByteOffset: baseByteOffset,
                initialState: initialState,
                limits: limits
            )
        }
    }

    public static func highlight(
        _ bytes: UnsafeBufferPointer<UInt8>,
        as fileType: SyntaxFileType,
        baseByteOffset: Int = 0,
        initialState: SyntaxLexicalState = .neutral,
        limits: SyntaxLimits = .default
    ) -> SyntaxHighlightResult {
        var collector = SyntaxSpanCollector(
            baseOffset: baseByteOffset,
            maximumCount: limits.maximumSpans
        )
        let endMode: SyntaxLexicalState.Mode
        switch fileType {
        case .plainText, .parquet:
            endMode = .normal
        case .json:
            endMode = highlightJSON(bytes, initialMode: initialState.mode, collector: &collector)
        case .markdown:
            endMode = highlightMarkdown(
                bytes,
                initialMode: initialState.mode,
                initialAtLineStart: initialState.atLineStart,
                collector: &collector
            )
        case .sql:
            endMode = highlightSQL(bytes, initialMode: initialState.mode, collector: &collector)
        case .xml:
            endMode = highlightXML(bytes, initialMode: initialState.mode, collector: &collector)
        case .csv:
            endMode = highlightCSV(
                bytes,
                initialMode: initialState.mode,
                delimiter: limits.csvDelimiter,
                collector: &collector
            )
        case .yaml:
            endMode = highlightYAML(
                bytes,
                initialMode: initialState.mode,
                initialAtLineStart: initialState.atLineStart,
                collector: &collector
            )
        }

        let atLineStart = bytes.last.map(SyntaxByteUtilities.isLineBreak) ?? initialState.atLineStart
        return SyntaxHighlightResult(
            spans: collector.spans,
            endState: SyntaxLexicalState(mode: endMode, atLineStart: atLineStart),
            wasTruncated: collector.wasTruncated
        )
    }

    /// Raw-buffer overload for direct use inside file or piece-table slice
    /// callbacks.
    public static func highlight(
        _ bytes: UnsafeRawBufferPointer,
        as fileType: SyntaxFileType,
        baseByteOffset: Int = 0,
        initialState: SyntaxLexicalState = .neutral,
        limits: SyntaxLimits = .default
    ) -> SyntaxHighlightResult {
        highlight(
            bytes.bindMemory(to: UInt8.self),
            as: fileType,
            baseByteOffset: baseByteOffset,
            initialState: initialState,
            limits: limits
        )
    }

    // MARK: - JSON

    private static func highlightJSON(
        _ bytes: UnsafeBufferPointer<UInt8>,
        initialMode: SyntaxLexicalState.Mode,
        collector: inout SyntaxSpanCollector
    ) -> SyntaxLexicalState.Mode {
        var index = 0
        if case let .quotedString(delimiter, escaped) = initialMode {
            let result = scanBackslashQuoted(
                bytes, from: 0, delimiter: delimiter, escaped: escaped, includesOpening: false
            )
            collector.append(0, result.end, .string)
            if !result.closed { return .quotedString(delimiter: delimiter, escaped: result.escaped) }
            index = result.end
        }

        while index < bytes.count {
            let byte = bytes[index]
            if SyntaxByteUtilities.isWhitespace(byte) {
                index += 1
            } else if byte == 0x22 {
                let result = scanBackslashQuoted(
                    bytes, from: index, delimiter: byte, escaped: false, includesOpening: true
                )
                let kind: SyntaxSemanticKind
                if result.closed {
                    var lookahead = result.end
                    while lookahead < bytes.count, SyntaxByteUtilities.isWhitespace(bytes[lookahead]) {
                        lookahead += 1
                    }
                    kind = lookahead < bytes.count && bytes[lookahead] == 0x3A ? .key : .string
                } else {
                    kind = .string
                }
                collector.append(index, result.end, kind)
                if !result.closed { return .quotedString(delimiter: byte, escaped: result.escaped) }
                index = result.end
            } else if byte == 0x2D || SyntaxByteUtilities.isDigit(byte) {
                let end = scanNumber(bytes, from: index)
                collector.append(index, end, .number)
                index = max(index + 1, end)
            } else if SyntaxByteUtilities.isASCIIAlpha(byte) {
                var end = index + 1
                while end < bytes.count, SyntaxByteUtilities.isASCIIAlpha(bytes[end]) { end += 1 }
                let kind: SyntaxSemanticKind
                if SyntaxByteUtilities.equalsASCII(bytes, from: index, to: end, "true") ||
                    SyntaxByteUtilities.equalsASCII(bytes, from: index, to: end, "false") {
                    kind = .boolean
                } else if SyntaxByteUtilities.equalsASCII(bytes, from: index, to: end, "null") {
                    kind = .null
                } else {
                    kind = .error
                }
                collector.append(index, end, kind)
                index = end
            } else if isJSONPunctuation(byte) {
                collector.append(index, index + 1, .punctuation)
                index += 1
            } else {
                collector.append(index, index + 1, .error)
                index += 1
            }
        }
        return .normal
    }

    // MARK: - SQL

    private static let sqlKeywords = [
        "all", "alter", "and", "as", "asc", "begin", "between", "by", "case", "check",
        "column", "commit", "constraint", "create", "cross", "database", "default", "delete",
        "desc", "distinct", "drop", "else", "end", "except", "exists", "false", "foreign",
        "from", "full", "group", "having", "in", "index", "inner", "insert", "intersect", "into",
        "is", "join", "key", "left", "like", "limit", "not", "null", "offset", "on", "or",
        "order", "outer", "primary", "references", "returning", "right", "rollback", "select",
        "set", "table", "then", "true", "union", "unique", "update", "using", "values", "view",
        "when", "where", "with"
    ]

    private static func highlightSQL(
        _ bytes: UnsafeBufferPointer<UInt8>,
        initialMode: SyntaxLexicalState.Mode,
        collector: inout SyntaxSpanCollector
    ) -> SyntaxLexicalState.Mode {
        var index = 0
        switch initialMode {
        case .lineComment:
            let end = scanToLineEnd(bytes, from: 0)
            collector.append(0, end, .comment)
            if end == bytes.count { return .lineComment }
            index = end
        case let .blockComment(depth):
            let result = scanBlockComment(
                bytes,
                from: 0,
                depth: max(1, depth),
                pending: nil,
                includesOpening: false
            )
            collector.append(0, result.end, .comment)
            if result.depth > 0 { return blockCommentMode(depth: result.depth, pending: result.pending) }
            index = result.end
        case let .blockCommentAfterSlash(depth):
            let result = scanBlockComment(
                bytes, from: 0, depth: max(1, depth), pending: 0x2F, includesOpening: false
            )
            collector.append(0, result.end, .comment)
            if result.depth > 0 { return blockCommentMode(depth: result.depth, pending: result.pending) }
            index = result.end
        case let .blockCommentAfterAsterisk(depth):
            let result = scanBlockComment(
                bytes, from: 0, depth: max(1, depth), pending: 0x2A, includesOpening: false
            )
            collector.append(0, result.end, .comment)
            if result.depth > 0 { return blockCommentMode(depth: result.depth, pending: result.pending) }
            index = result.end
        case let .quotedString(delimiter, escaped):
            let result = scanSQLQuoted(
                bytes, from: 0, delimiter: delimiter, includesOpening: false, escaped: escaped
            )
            collector.append(0, result.end, delimiter == 0x27 ? .string : .attributeName)
            if !result.closed { return .quotedString(delimiter: delimiter, escaped: result.escaped) }
            index = result.end
        case let .sqlDollarQuoted(delimiter):
            if let end = findSequence(bytes, sequence: delimiter, from: 0) {
                collector.append(0, end + delimiter.count, .string)
                index = end + delimiter.count
            } else {
                collector.append(0, bytes.count, .string)
                return .sqlDollarQuoted(delimiter: delimiter)
            }
        default:
            break
        }

        while index < bytes.count {
            let byte = bytes[index]
            if SyntaxByteUtilities.isWhitespace(byte) {
                index += 1
            } else if byte == 0x2D, index + 1 < bytes.count, bytes[index + 1] == 0x2D {
                let end = scanToLineEnd(bytes, from: index + 2)
                collector.append(index, end, .comment)
                if end == bytes.count { return .lineComment }
                index = end
            } else if byte == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x2A {
                let result = scanBlockComment(
                    bytes, from: index, depth: 0, pending: nil, includesOpening: true
                )
                collector.append(index, result.end, .comment)
                if result.depth > 0 { return blockCommentMode(depth: result.depth, pending: result.pending) }
                index = result.end
            } else if byte == 0x27 || byte == 0x22 || byte == 0x60 {
                let result = scanSQLQuoted(
                    bytes, from: index, delimiter: byte, includesOpening: true, escaped: false
                )
                collector.append(index, result.end, byte == 0x27 ? .string : .attributeName)
                if !result.closed { return .quotedString(delimiter: byte, escaped: result.escaped) }
                index = result.end
            } else if byte == 0x5B { // SQL Server quoted identifier
                var end = index + 1
                while end < bytes.count {
                    if bytes[end] == 0x5D {
                        if end + 1 < bytes.count, bytes[end + 1] == 0x5D { end += 2; continue }
                        end += 1
                        break
                    }
                    end += 1
                }
                collector.append(index, end, .attributeName)
                index = end
            } else if byte == 0x24, let delimiterEnd = sqlDollarDelimiterEnd(bytes, from: index) {
                let delimiter = Array(bytes[index..<delimiterEnd])
                if let close = findSequence(bytes, sequence: delimiter, from: delimiterEnd) {
                    collector.append(index, close + delimiter.count, .string)
                    index = close + delimiter.count
                } else {
                    collector.append(index, bytes.count, .string)
                    return .sqlDollarQuoted(delimiter: delimiter)
                }
            } else if SyntaxByteUtilities.isDigit(byte) ||
                        (byte == 0x2E && index + 1 < bytes.count && SyntaxByteUtilities.isDigit(bytes[index + 1])) {
                let end = scanNumber(bytes, from: index)
                collector.append(index, end, .number)
                index = max(index + 1, end)
            } else if SyntaxByteUtilities.isIdentifierStart(byte) {
                var end = index + 1
                while end < bytes.count, SyntaxByteUtilities.isIdentifierContinue(bytes[end]) { end += 1 }
                if isSQLKeyword(bytes, from: index, to: end) {
                    let kind: SyntaxSemanticKind
                    if SyntaxByteUtilities.equalsASCII(bytes, from: index, to: end, "true", caseInsensitive: true) ||
                        SyntaxByteUtilities.equalsASCII(bytes, from: index, to: end, "false", caseInsensitive: true) {
                        kind = .boolean
                    } else if SyntaxByteUtilities.equalsASCII(bytes, from: index, to: end, "null", caseInsensitive: true) {
                        kind = .null
                    } else {
                        kind = .keyword
                    }
                    collector.append(index, end, kind)
                }
                index = end
            } else if isSQLPunctuation(byte) {
                collector.append(index, index + 1, .punctuation)
                index += 1
            } else if isSQLOperator(byte) {
                var end = index + 1
                if end < bytes.count,
                   isSQLCompoundOperatorTail(bytes[end]) { end += 1 }
                collector.append(index, end, .operator)
                index = end
            } else {
                index += 1
            }
        }
        return .normal
    }

    private static func isSQLKeyword(
        _ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int
    ) -> Bool {
        sqlKeywords.contains {
            SyntaxByteUtilities.equalsASCII(bytes, from: start, to: end, $0, caseInsensitive: true)
        }
    }

    // MARK: - XML

    private static func highlightXML(
        _ bytes: UnsafeBufferPointer<UInt8>,
        initialMode: SyntaxLexicalState.Mode,
        collector: inout SyntaxSpanCollector
    ) -> SyntaxLexicalState.Mode {
        var index = 0
        switch initialMode {
        case .xmlComment:
            let result = scanTerminator(
                bytes, terminator: xmlCommentTerminator, from: 0, matchedPrefix: 0
            )
            if let end = result.end {
                collector.append(0, end, .comment)
                index = end
            } else {
                collector.append(0, bytes.count, .comment)
                return .xmlCommentContinuation(matchedTerminatorBytes: result.matchedPrefix)
            }
        case let .xmlCommentContinuation(matched):
            let result = scanTerminator(
                bytes, terminator: xmlCommentTerminator, from: 0, matchedPrefix: matched
            )
            if let end = result.end {
                collector.append(0, end, .comment)
                index = end
            } else {
                collector.append(0, bytes.count, .comment)
                return .xmlCommentContinuation(matchedTerminatorBytes: result.matchedPrefix)
            }
        case .xmlCDATA:
            let result = scanTerminator(
                bytes, terminator: xmlCDATATerminator, from: 0, matchedPrefix: 0
            )
            if let end = result.end {
                collector.append(0, end, .string)
                index = end
            } else {
                collector.append(0, bytes.count, .string)
                return .xmlCDATAContinuation(matchedTerminatorBytes: result.matchedPrefix)
            }
        case let .xmlCDATAContinuation(matched):
            let result = scanTerminator(
                bytes, terminator: xmlCDATATerminator, from: 0, matchedPrefix: matched
            )
            if let end = result.end {
                collector.append(0, end, .string)
                index = end
            } else {
                collector.append(0, bytes.count, .string)
                return .xmlCDATAContinuation(matchedTerminatorBytes: result.matchedPrefix)
            }
        case .xmlProcessingInstruction:
            let result = scanTerminator(
                bytes,
                terminator: xmlProcessingInstructionTerminator,
                from: 0,
                matchedPrefix: 0
            )
            if let end = result.end {
                collector.append(0, end, .directive)
                index = end
            } else {
                collector.append(0, bytes.count, .directive)
                return .xmlProcessingInstructionContinuation(
                    matchedTerminatorBytes: result.matchedPrefix
                )
            }
        case let .xmlProcessingInstructionContinuation(matched):
            let result = scanTerminator(
                bytes,
                terminator: xmlProcessingInstructionTerminator,
                from: 0,
                matchedPrefix: matched
            )
            if let end = result.end {
                collector.append(0, end, .directive)
                index = end
            } else {
                collector.append(0, bytes.count, .directive)
                return .xmlProcessingInstructionContinuation(
                    matchedTerminatorBytes: result.matchedPrefix
                )
            }
        case let .xmlTag(quote, expectsElementName):
            let result = scanXMLTag(
                bytes, from: 0, quote: quote, expectsElementName: expectsElementName, collector: &collector
            )
            if result.mode != .normal { return result.mode }
            index = result.end
        default:
            break
        }

        while index < bytes.count {
            if bytes[index] == 0x3C { // <
                if SyntaxByteUtilities.hasASCII(bytes, at: index, "<!--") {
                    let result = scanTerminator(
                        bytes,
                        terminator: xmlCommentTerminator,
                        from: index + 4,
                        matchedPrefix: 0
                    )
                    if let end = result.end {
                        collector.append(index, end, .comment)
                        index = end
                    } else {
                        collector.append(index, bytes.count, .comment)
                        return .xmlCommentContinuation(
                            matchedTerminatorBytes: result.matchedPrefix
                        )
                    }
                } else if SyntaxByteUtilities.hasASCII(bytes, at: index, "<![CDATA[") {
                    let result = scanTerminator(
                        bytes,
                        terminator: xmlCDATATerminator,
                        from: index + 9,
                        matchedPrefix: 0
                    )
                    if let end = result.end {
                        collector.append(index, end, .string)
                        index = end
                    } else {
                        collector.append(index, bytes.count, .string)
                        return .xmlCDATAContinuation(
                            matchedTerminatorBytes: result.matchedPrefix
                        )
                    }
                } else if SyntaxByteUtilities.hasASCII(bytes, at: index, "<?") {
                    let result = scanTerminator(
                        bytes,
                        terminator: xmlProcessingInstructionTerminator,
                        from: index + 2,
                        matchedPrefix: 0
                    )
                    if let end = result.end {
                        collector.append(index, end, .directive)
                        index = end
                    } else {
                        collector.append(index, bytes.count, .directive)
                        return .xmlProcessingInstructionContinuation(
                            matchedTerminatorBytes: result.matchedPrefix
                        )
                    }
                } else if SyntaxByteUtilities.hasASCII(bytes, at: index, "<!") {
                    let end = scanMarkupDeclarationEnd(bytes, from: index + 2)
                    collector.append(index, end, .directive)
                    index = end
                } else {
                    collector.append(index, index + 1, .punctuation)
                    index += 1
                    if index < bytes.count, bytes[index] == 0x2F {
                        collector.append(index, index + 1, .punctuation)
                        index += 1
                    }
                    let result = scanXMLTag(
                        bytes, from: index, quote: nil, expectsElementName: true, collector: &collector
                    )
                    if result.mode != .normal { return result.mode }
                    index = result.end
                }
            } else if bytes[index] == 0x26 { // &entity;
                var end = index + 1
                while end < bytes.count, end - index <= 64,
                      !SyntaxByteUtilities.isWhitespace(bytes[end]), bytes[end] != 0x3C {
                    if bytes[end] == 0x3B { end += 1; break }
                    end += 1
                }
                collector.append(index, end, .entity)
                index = end
            } else {
                index += 1
            }
        }
        return .normal
    }

    private static func scanXMLTag(
        _ bytes: UnsafeBufferPointer<UInt8>,
        from start: Int,
        quote initialQuote: UInt8?,
        expectsElementName initialExpectation: Bool,
        collector: inout SyntaxSpanCollector
    ) -> (end: Int, mode: SyntaxLexicalState.Mode) {
        var index = start
        var quote = initialQuote
        var expectsElementName = initialExpectation
        if let activeQuote = quote {
            let result = scanSimpleQuoted(
                bytes, from: index, delimiter: activeQuote, includesOpening: false
            )
            collector.append(index, result.end, .attributeValue)
            if !result.closed {
                return (bytes.count, .xmlTag(quote: activeQuote, expectsElementName: expectsElementName))
            }
            quote = nil
            index = result.end
        }

        while index < bytes.count {
            let byte = bytes[index]
            if SyntaxByteUtilities.isWhitespace(byte) {
                index += 1
            } else if byte == 0x3E {
                collector.append(index, index + 1, .punctuation)
                return (index + 1, .normal)
            } else if byte == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x3E {
                collector.append(index, index + 2, .punctuation)
                return (index + 2, .normal)
            } else if byte == 0x3D {
                collector.append(index, index + 1, .operator)
                index += 1
            } else if byte == 0x22 || byte == 0x27 {
                let result = scanSimpleQuoted(
                    bytes, from: index, delimiter: byte, includesOpening: true
                )
                collector.append(index, result.end, .attributeValue)
                if !result.closed {
                    return (bytes.count, .xmlTag(quote: byte, expectsElementName: expectsElementName))
                }
                index = result.end
            } else if isXMLNameByte(byte) {
                var end = index + 1
                while end < bytes.count, isXMLNameByte(bytes[end]) { end += 1 }
                collector.append(index, end, expectsElementName ? .tag : .attributeName)
                expectsElementName = false
                index = end
            } else {
                collector.append(index, index + 1, .error)
                index += 1
            }
        }
        return (bytes.count, .xmlTag(quote: quote, expectsElementName: expectsElementName))
    }

    // MARK: - CSV

    private static func highlightCSV(
        _ bytes: UnsafeBufferPointer<UInt8>,
        initialMode: SyntaxLexicalState.Mode,
        delimiter: UInt8,
        collector: inout SyntaxSpanCollector
    ) -> SyntaxLexicalState.Mode {
        var index = 0
        if initialMode == .csvQuotedField {
            let result = scanCSVQuoted(bytes, from: 0, includesOpening: false)
            collector.append(0, result.end, .string)
            if !result.closed { return .csvQuotedField }
            index = result.end
        }

        while index < bytes.count {
            let byte = bytes[index]
            if byte == delimiter {
                collector.append(index, index + 1, .punctuation)
                index += 1
            } else if SyntaxByteUtilities.isLineBreak(byte) {
                index += 1
            } else if byte == 0x22 {
                let result = scanCSVQuoted(bytes, from: index, includesOpening: true)
                collector.append(index, result.end, .string)
                if !result.closed { return .csvQuotedField }
                index = result.end
            } else {
                let start = index
                while index < bytes.count,
                      bytes[index] != delimiter,
                      !SyntaxByteUtilities.isLineBreak(bytes[index]) { index += 1 }
                var lower = start
                var upper = index
                while lower < upper, SyntaxByteUtilities.isSpace(bytes[lower]) { lower += 1 }
                while upper > lower, SyntaxByteUtilities.isSpace(bytes[upper - 1]) { upper -= 1 }
                if lower < upper, let kind = scalarKind(bytes, from: lower, to: upper) {
                    collector.append(lower, upper, kind)
                }
            }
        }
        return .normal
    }

    // MARK: - YAML

    private static func highlightYAML(
        _ bytes: UnsafeBufferPointer<UInt8>,
        initialMode: SyntaxLexicalState.Mode,
        initialAtLineStart: Bool,
        collector: inout SyntaxSpanCollector
    ) -> SyntaxLexicalState.Mode {
        var lineStart = 0
        var carriedMode = initialMode
        var currentStartsAtLineStart = initialAtLineStart

        if case let .quotedString(delimiter, escaped) = carriedMode {
            let result = scanYAMLQuoted(
                bytes, from: 0, delimiter: delimiter, includesOpening: false, escaped: escaped
            )
            collector.append(0, result.end, .string)
            if !result.closed { return .quotedString(delimiter: delimiter, escaped: result.escaped) }
            lineStart = result.end
            currentStartsAtLineStart = false
            carriedMode = .normal
        }

        while lineStart < bytes.count {
            let lineEnd = SyntaxByteUtilities.lineEnd(bytes, from: lineStart)
            let isLogicalLineStart = currentStartsAtLineStart
            var content = lineStart
            var indentation = 0
            while isLogicalLineStart, content < lineEnd, bytes[content] == 0x20 {
                indentation += 1
                content += 1
            }

            if case let .yamlBlockScalar(parentIndent) = carriedMode {
                if !isLogicalLineStart || content == lineEnd || indentation > parentIndent {
                    collector.append(lineStart, lineEnd, .string)
                    lineStart = SyntaxByteUtilities.nextLineStart(bytes, after: lineEnd)
                    currentStartsAtLineStart = true
                    continue
                }
                carriedMode = .normal
            }

            if content < lineEnd {
                if SyntaxByteUtilities.hasASCII(bytes, at: content, "---") ||
                    SyntaxByteUtilities.hasASCII(bytes, at: content, "...") {
                    let markerEnd = min(lineEnd, content + 3)
                    collector.append(content, markerEnd, .directive)
                } else {
                    var scanStart = content
                    if isLogicalLineStart, bytes[content] == 0x2D,
                       content + 1 == lineEnd || SyntaxByteUtilities.isSpace(bytes[content + 1]) {
                        collector.append(content, content + 1, .listMarker)
                        scanStart = min(lineEnd, content + 1)
                    }
                    let result = highlightYAMLLine(
                        bytes,
                        from: scanStart,
                        to: lineEnd,
                        indentation: indentation,
                        recognizesBlockSyntax: isLogicalLineStart,
                        collector: &collector
                    )
                    if let mode = result.continuation { return mode }
                    if let resumeAt = result.resumeAt {
                        lineStart = resumeAt
                        currentStartsAtLineStart = false
                        continue
                    }
                    if isLogicalLineStart,
                       lineEndsInBlockScalar(bytes, from: scanStart, to: lineEnd) {
                        carriedMode = .yamlBlockScalar(parentIndent: indentation)
                    }
                }
            }
            lineStart = SyntaxByteUtilities.nextLineStart(bytes, after: lineEnd)
            currentStartsAtLineStart = true
        }
        return carriedMode
    }

    private static func highlightYAMLLine(
        _ bytes: UnsafeBufferPointer<UInt8>,
        from start: Int,
        to end: Int,
        indentation: Int,
        recognizesBlockSyntax: Bool,
        collector: inout SyntaxSpanCollector
    ) -> (continuation: SyntaxLexicalState.Mode?, resumeAt: Int?) {
        var colon: Int?
        var commentStart: Int?
        var quote: UInt8?
        var escaped = false
        var probe = start
        while probe < end {
            let byte = bytes[probe]
            if let active = quote {
                if active == 0x22, byte == 0x5C { escaped.toggle() }
                else {
                    if byte == active, !escaped { quote = nil }
                    escaped = false
                }
            } else if byte == 0x22 || byte == 0x27 {
                quote = byte
            } else if byte == 0x23, probe == start || SyntaxByteUtilities.isSpace(bytes[probe - 1]) {
                commentStart = probe
                break
            } else if recognizesBlockSyntax, byte == 0x3A,
                      probe + 1 == end || SyntaxByteUtilities.isWhitespace(bytes[probe + 1]) {
                colon = colon ?? probe
            }
            probe += 1
        }

        let syntaxEnd = commentStart ?? end
        var index = start
        if let colon, colon < syntaxEnd {
            var keyStart = start
            while keyStart < colon, SyntaxByteUtilities.isSpace(bytes[keyStart]) { keyStart += 1 }
            var keyEnd = colon
            while keyEnd > keyStart, SyntaxByteUtilities.isSpace(bytes[keyEnd - 1]) { keyEnd -= 1 }
            if keyStart < keyEnd { collector.append(keyStart, keyEnd, .key) }
            collector.append(colon, colon + 1, .punctuation)
            index = colon + 1
        }

        while index < syntaxEnd {
            let byte = bytes[index]
            if SyntaxByteUtilities.isSpace(byte) {
                index += 1
            } else if byte == 0x22 || byte == 0x27 {
                let result = scanYAMLQuoted(
                    bytes, from: index, delimiter: byte, includesOpening: true, escaped: false
                )
                collector.append(index, result.end, .string)
                if !result.closed, result.end >= bytes.count {
                    return (
                        .quotedString(delimiter: byte, escaped: result.escaped),
                        nil
                    )
                }
                if result.end > syntaxEnd { return (nil, result.end) }
                index = max(index + 1, result.end)
            } else if byte == 0x26 || byte == 0x2A || byte == 0x21 { // &, *, !
                var tokenEnd = index + 1
                while tokenEnd < syntaxEnd,
                      !SyntaxByteUtilities.isWhitespace(bytes[tokenEnd]),
                      !isYAMLFlowPunctuation(bytes[tokenEnd]) {
                    tokenEnd += 1
                }
                collector.append(index, tokenEnd, byte == 0x26 ? .anchor : (byte == 0x2A ? .alias : .directive))
                index = tokenEnd
            } else if isYAMLFlowPunctuation(byte) {
                collector.append(index, index + 1, .punctuation)
                index += 1
            } else if byte == 0x7C || byte == 0x3E {
                collector.append(index, index + 1, .operator)
                index += 1
            } else {
                let tokenStart = index
                while index < syntaxEnd,
                      !SyntaxByteUtilities.isWhitespace(bytes[index]),
                      !isYAMLFlowPunctuation(bytes[index]) { index += 1 }
                if let kind = scalarKind(bytes, from: tokenStart, to: index) {
                    collector.append(tokenStart, index, kind)
                }
            }
        }
        if let commentStart { collector.append(commentStart, end, .comment) }
        _ = indentation
        return (nil, nil)
    }

    // MARK: - Markdown

    private static func highlightMarkdown(
        _ bytes: UnsafeBufferPointer<UInt8>,
        initialMode: SyntaxLexicalState.Mode,
        initialAtLineStart: Bool,
        collector: inout SyntaxSpanCollector
    ) -> SyntaxLexicalState.Mode {
        var lineStart = 0
        var mode = initialMode
        var currentStartsAtLineStart = initialAtLineStart

        if mode == .xmlComment {
            let result = scanTerminator(
                bytes, terminator: xmlCommentTerminator, from: 0, matchedPrefix: 0
            )
            if let end = result.end {
                collector.append(0, end, .comment)
                lineStart = end
                currentStartsAtLineStart = false
                mode = .normal
            } else {
                collector.append(0, bytes.count, .comment)
                return .xmlCommentContinuation(matchedTerminatorBytes: result.matchedPrefix)
            }
        } else if case let .xmlCommentContinuation(matched) = mode {
            let result = scanTerminator(
                bytes, terminator: xmlCommentTerminator, from: 0, matchedPrefix: matched
            )
            if let end = result.end {
                collector.append(0, end, .comment)
                lineStart = end
                currentStartsAtLineStart = false
                mode = .normal
            } else {
                collector.append(0, bytes.count, .comment)
                return .xmlCommentContinuation(matchedTerminatorBytes: result.matchedPrefix)
            }
        }

        while lineStart < bytes.count {
            let lineEnd = SyntaxByteUtilities.lineEnd(bytes, from: lineStart)
            let isLogicalLineStart = currentStartsAtLineStart
            var content = lineStart
            var leadingSpaces = 0
            while isLogicalLineStart, content < lineEnd, bytes[content] == 0x20, leadingSpaces < 4 {
                content += 1
                leadingSpaces += 1
            }

            if case let .markdownFence(marker, count) = mode {
                collector.append(lineStart, lineEnd, .code)
                if isLogicalLineStart, leadingSpaces <= 3,
                   let run = markerRun(bytes, from: content, limit: lineEnd),
                   run.marker == marker, run.count >= count,
                   onlyWhitespace(bytes, from: run.end, to: lineEnd) {
                    mode = .normal
                }
                lineStart = SyntaxByteUtilities.nextLineStart(bytes, after: lineEnd)
                currentStartsAtLineStart = true
                continue
            }

            if isLogicalLineStart, leadingSpaces <= 3,
               let run = markerRun(bytes, from: content, limit: lineEnd), run.count >= 3 {
                collector.append(content, lineEnd, .codeFence)
                mode = .markdownFence(marker: run.marker, count: run.count)
                lineStart = SyntaxByteUtilities.nextLineStart(bytes, after: lineEnd)
                currentStartsAtLineStart = true
                continue
            }

            if SyntaxByteUtilities.hasASCII(bytes, at: content, "<!--") {
                let result = scanTerminator(
                    bytes,
                    terminator: xmlCommentTerminator,
                    from: content + 4,
                    matchedPrefix: 0
                )
                if let closeEnd = result.end {
                    collector.append(content, closeEnd, .comment)
                    lineStart = closeEnd
                    currentStartsAtLineStart = false
                    continue
                } else {
                    collector.append(content, bytes.count, .comment)
                    return .xmlCommentContinuation(
                        matchedTerminatorBytes: result.matchedPrefix
                    )
                }
            } else if isLogicalLineStart, content < lineEnd, bytes[content] == 0x23 {
                var markerEnd = content
                while markerEnd < lineEnd, markerEnd - content < 6, bytes[markerEnd] == 0x23 {
                    markerEnd += 1
                }
                if markerEnd == lineEnd || SyntaxByteUtilities.isSpace(bytes[markerEnd]) {
                    collector.append(content, lineEnd, .heading)
                } else {
                    highlightMarkdownInline(bytes, from: content, to: lineEnd, collector: &collector)
                }
            } else {
                var inlineStart = content
                if isLogicalLineStart, content < lineEnd, bytes[content] == 0x3E {
                    collector.append(content, content + 1, .quoteMarker)
                    inlineStart = content + 1
                } else if isLogicalLineStart,
                          let markerEnd = markdownListMarkerEnd(bytes, from: content, to: lineEnd) {
                    collector.append(content, markerEnd, .listMarker)
                    inlineStart = markerEnd
                }
                highlightMarkdownInline(bytes, from: inlineStart, to: lineEnd, collector: &collector)
            }
            lineStart = SyntaxByteUtilities.nextLineStart(bytes, after: lineEnd)
            currentStartsAtLineStart = true
        }
        return mode
    }

    private static func highlightMarkdownInline(
        _ bytes: UnsafeBufferPointer<UInt8>,
        from start: Int,
        to end: Int,
        collector: inout SyntaxSpanCollector
    ) {
        var index = start
        while index < end {
            let byte = bytes[index]
            if byte == 0x60 { // inline code
                var runEnd = index
                while runEnd < end, bytes[runEnd] == 0x60 { runEnd += 1 }
                let delimiterLength = runEnd - index
                var close = runEnd
                while close < end {
                    if bytes[close] == 0x60 {
                        var candidateEnd = close
                        while candidateEnd < end, bytes[candidateEnd] == 0x60 { candidateEnd += 1 }
                        if candidateEnd - close == delimiterLength {
                            collector.append(index, candidateEnd, .code)
                            index = candidateEnd
                            break
                        }
                        close = candidateEnd
                    } else {
                        close += 1
                    }
                }
                if index < runEnd { index = runEnd }
            } else if byte == 0x5B, let closeBracket = findByte(bytes, 0x5D, from: index + 1, limit: end),
                      closeBracket + 1 < end, bytes[closeBracket + 1] == 0x28,
                      let closeParen = findByte(bytes, 0x29, from: closeBracket + 2, limit: end) {
                collector.append(index, closeParen + 1, .link)
                index = closeParen + 1
            } else if byte == 0x2A || byte == 0x5F {
                let markerLength = index + 1 < end && bytes[index + 1] == byte ? 2 : 1
                if let close = findRepeatedByte(
                    bytes, byte, count: markerLength, from: index + markerLength, limit: end
                ) {
                    collector.append(index, close + markerLength, .emphasis)
                    index = close + markerLength
                } else {
                    index += markerLength
                }
            } else if byte == 0x3C, let close = findByte(bytes, 0x3E, from: index + 1, limit: end) {
                collector.append(index, close + 1, .tag)
                index = close + 1
            } else {
                index += 1
            }
        }
    }

    // MARK: - Shared scanners

    private static func scanBackslashQuoted(
        _ bytes: UnsafeBufferPointer<UInt8>,
        from start: Int,
        delimiter: UInt8,
        escaped initialEscaped: Bool,
        includesOpening: Bool
    ) -> (end: Int, closed: Bool, escaped: Bool) {
        var index = min(bytes.count, start + (includesOpening ? 1 : 0))
        var escaped = initialEscaped
        while index < bytes.count {
            let byte = bytes[index]
            if escaped {
                escaped = false
            } else if byte == 0x5C {
                escaped = true
            } else if byte == delimiter {
                return (index + 1, true, false)
            }
            index += 1
        }
        return (bytes.count, false, escaped)
    }

    private static func scanSQLQuoted(
        _ bytes: UnsafeBufferPointer<UInt8>,
        from start: Int,
        delimiter: UInt8,
        includesOpening: Bool,
        escaped initialEscaped: Bool
    ) -> (end: Int, closed: Bool, escaped: Bool) {
        var index = min(bytes.count, start + (includesOpening ? 1 : 0))
        var escaped = initialEscaped
        while index < bytes.count {
            let byte = bytes[index]
            if escaped {
                escaped = false
            } else if byte == 0x5C {
                escaped = true
            } else if byte == delimiter {
                if index + 1 < bytes.count, bytes[index + 1] == delimiter {
                    index += 2
                    continue
                }
                return (index + 1, true, false)
            }
            index += 1
        }
        return (bytes.count, false, escaped)
    }

    private static func scanSimpleQuoted(
        _ bytes: UnsafeBufferPointer<UInt8>,
        from start: Int,
        delimiter: UInt8,
        includesOpening: Bool
    ) -> (end: Int, closed: Bool) {
        var index = min(bytes.count, start + (includesOpening ? 1 : 0))
        while index < bytes.count {
            if bytes[index] == delimiter { return (index + 1, true) }
            index += 1
        }
        return (bytes.count, false)
    }

    private static func scanYAMLQuoted(
        _ bytes: UnsafeBufferPointer<UInt8>,
        from start: Int,
        delimiter: UInt8,
        includesOpening: Bool,
        escaped initialEscaped: Bool
    ) -> (end: Int, closed: Bool, escaped: Bool) {
        var index = min(bytes.count, start + (includesOpening ? 1 : 0))
        var escaped = initialEscaped
        while index < bytes.count {
            let byte = bytes[index]
            if delimiter == 0x22 {
                if escaped { escaped = false }
                else if byte == 0x5C { escaped = true }
                else if byte == delimiter { return (index + 1, true, false) }
            } else if byte == delimiter {
                if index + 1 < bytes.count, bytes[index + 1] == delimiter {
                    index += 2
                    continue
                }
                return (index + 1, true, false)
            }
            index += 1
        }
        return (bytes.count, false, escaped)
    }

    private static func scanCSVQuoted(
        _ bytes: UnsafeBufferPointer<UInt8>, from start: Int, includesOpening: Bool
    ) -> (end: Int, closed: Bool) {
        var index = min(bytes.count, start + (includesOpening ? 1 : 0))
        while index < bytes.count {
            if bytes[index] == 0x22 {
                if index + 1 < bytes.count, bytes[index + 1] == 0x22 {
                    index += 2
                    continue
                }
                return (index + 1, true)
            }
            index += 1
        }
        return (bytes.count, false)
    }

    private static func scanBlockComment(
        _ bytes: UnsafeBufferPointer<UInt8>,
        from start: Int,
        depth initialDepth: Int,
        pending initialPending: UInt8?,
        includesOpening: Bool
    ) -> (end: Int, depth: Int, pending: UInt8?) {
        var index = start
        var depth = initialDepth
        if includesOpening { depth += 1; index += 2 }
        if let pending = initialPending, index < bytes.count {
            if pending == 0x2A, bytes[index] == 0x2F {
                depth -= 1
                index += 1
                if depth == 0 { return (index, 0, nil) }
            } else if pending == 0x2F, bytes[index] == 0x2A {
                depth += 1
                index += 1
            }
        } else if initialPending != nil, index == bytes.count {
            return (bytes.count, depth, initialPending)
        }
        while index < bytes.count {
            if index + 1 < bytes.count, bytes[index] == 0x2F, bytes[index + 1] == 0x2A {
                depth += 1
                index += 2
            } else if index + 1 < bytes.count, bytes[index] == 0x2A, bytes[index + 1] == 0x2F {
                depth -= 1
                index += 2
                if depth == 0 { return (index, 0, nil) }
            } else {
                if index + 1 == bytes.count,
                   bytes[index] == 0x2F || bytes[index] == 0x2A {
                    return (bytes.count, depth, bytes[index])
                }
                index += 1
            }
        }
        return (bytes.count, depth, nil)
    }

    private static func blockCommentMode(
        depth: Int, pending: UInt8?
    ) -> SyntaxLexicalState.Mode {
        if pending == 0x2F { return .blockCommentAfterSlash(depth: depth) }
        if pending == 0x2A { return .blockCommentAfterAsterisk(depth: depth) }
        return .blockComment(depth: depth)
    }

    private static func scanNumber(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        var index = start
        if index < bytes.count, bytes[index] == 0x2D || bytes[index] == 0x2B { index += 1 }
        if index + 1 < bytes.count, bytes[index] == 0x30,
           bytes[index + 1] == 0x78 || bytes[index + 1] == 0x58 {
            index += 2
            while index < bytes.count, SyntaxByteUtilities.isHexDigit(bytes[index]) { index += 1 }
            return index
        }
        while index < bytes.count, SyntaxByteUtilities.isDigit(bytes[index]) { index += 1 }
        if index < bytes.count, bytes[index] == 0x2E {
            index += 1
            while index < bytes.count, SyntaxByteUtilities.isDigit(bytes[index]) { index += 1 }
        }
        if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
            index += 1
            if index < bytes.count, bytes[index] == 0x2D || bytes[index] == 0x2B { index += 1 }
            while index < bytes.count, SyntaxByteUtilities.isDigit(bytes[index]) { index += 1 }
        }
        return index
    }

    private static func scalarKind(
        _ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int
    ) -> SyntaxSemanticKind? {
        guard start < end else { return nil }
        if SyntaxByteUtilities.equalsASCII(bytes, from: start, to: end, "true", caseInsensitive: true) ||
            SyntaxByteUtilities.equalsASCII(bytes, from: start, to: end, "false", caseInsensitive: true) ||
            SyntaxByteUtilities.equalsASCII(bytes, from: start, to: end, "yes", caseInsensitive: true) ||
            SyntaxByteUtilities.equalsASCII(bytes, from: start, to: end, "no", caseInsensitive: true) ||
            SyntaxByteUtilities.equalsASCII(bytes, from: start, to: end, "on", caseInsensitive: true) ||
            SyntaxByteUtilities.equalsASCII(bytes, from: start, to: end, "off", caseInsensitive: true) {
            return .boolean
        }
        if SyntaxByteUtilities.equalsASCII(bytes, from: start, to: end, "null", caseInsensitive: true) ||
            SyntaxByteUtilities.equalsASCII(bytes, from: start, to: end, "nil", caseInsensitive: true) ||
            SyntaxByteUtilities.equalsASCII(bytes, from: start, to: end, "~") {
            return .null
        }
        var index = start
        if bytes[index] == 0x2D || bytes[index] == 0x2B { index += 1 }
        var sawDigit = false
        while index < end, SyntaxByteUtilities.isDigit(bytes[index]) { sawDigit = true; index += 1 }
        if index < end, bytes[index] == 0x2E {
            index += 1
            while index < end, SyntaxByteUtilities.isDigit(bytes[index]) { sawDigit = true; index += 1 }
        }
        if sawDigit, index == end { return .number }
        return nil
    }

    private static func lineEndsInBlockScalar(
        _ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int
    ) -> Bool {
        var upper = end
        while upper > start, SyntaxByteUtilities.isSpace(bytes[upper - 1]) { upper -= 1 }
        if upper > start, bytes[upper - 1] == 0x2B || bytes[upper - 1] == 0x2D { upper -= 1 }
        if upper > start, SyntaxByteUtilities.isDigit(bytes[upper - 1]) { upper -= 1 }
        return upper > start && (bytes[upper - 1] == 0x7C || bytes[upper - 1] == 0x3E)
    }

    private static func scanToLineEnd(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        SyntaxByteUtilities.lineEnd(bytes, from: start)
    }

    private static func findASCII(
        _ bytes: UnsafeBufferPointer<UInt8>, _ text: String, from start: Int
    ) -> Int? {
        let count = text.utf8.count
        guard count > 0, start >= 0, start <= bytes.count, count <= bytes.count else { return nil }
        var index = start
        let last = bytes.count - count
        while index <= last {
            if SyntaxByteUtilities.hasASCII(bytes, at: index, text) { return index }
            index += 1
        }
        return nil
    }

    private static func findSequence(
        _ bytes: UnsafeBufferPointer<UInt8>, sequence: [UInt8], from start: Int
    ) -> Int? {
        guard !sequence.isEmpty, sequence.count <= bytes.count else { return nil }
        var index = max(0, start)
        let last = bytes.count - sequence.count
        while index <= last {
            var matches = true
            for offset in sequence.indices where bytes[index + offset] != sequence[offset] {
                matches = false
                break
            }
            if matches { return index }
            index += 1
        }
        return nil
    }

    /// Streaming terminator matcher. `matchedPrefix` is at most the tiny
    /// delimiter length; source bytes are never copied when a delimiter spans
    /// adjacent viewport buffers.
    private static func scanTerminator(
        _ bytes: UnsafeBufferPointer<UInt8>,
        terminator: [UInt8],
        from start: Int,
        matchedPrefix initialMatchedPrefix: Int
    ) -> (end: Int?, matchedPrefix: Int) {
        guard !terminator.isEmpty else { return (start, 0) }
        var matched = min(max(0, initialMatchedPrefix), terminator.count - 1)
        var index = max(0, start)
        while index < bytes.count {
            matched = nextTerminatorPrefix(
                terminator,
                previouslyMatched: matched,
                nextByte: bytes[index]
            )
            index += 1
            if matched == terminator.count { return (index, 0) }
        }
        return (nil, matched)
    }

    private static func nextTerminatorPrefix(
        _ terminator: [UInt8],
        previouslyMatched: Int,
        nextByte: UInt8
    ) -> Int {
        if previouslyMatched < terminator.count,
           nextByte == terminator[previouslyMatched] {
            return previouslyMatched + 1
        }

        let virtualLength = previouslyMatched + 1
        var candidate = min(terminator.count - 1, virtualLength)
        while candidate > 0 {
            var matches = true
            let suffixStart = virtualLength - candidate
            for offset in 0..<candidate {
                let virtualIndex = suffixStart + offset
                let actual = virtualIndex < previouslyMatched
                    ? terminator[virtualIndex]
                    : nextByte
                if actual != terminator[offset] {
                    matches = false
                    break
                }
            }
            if matches { return candidate }
            candidate -= 1
        }
        return 0
    }

    private static func findByte(
        _ bytes: UnsafeBufferPointer<UInt8>, _ byte: UInt8, from start: Int, limit: Int
    ) -> Int? {
        var index = start
        while index < min(bytes.count, limit) {
            if bytes[index] == byte { return index }
            index += 1
        }
        return nil
    }

    private static func findRepeatedByte(
        _ bytes: UnsafeBufferPointer<UInt8>, _ byte: UInt8, count: Int, from start: Int, limit: Int
    ) -> Int? {
        var index = start
        while index + count <= min(bytes.count, limit) {
            var matches = true
            for offset in 0..<count where bytes[index + offset] != byte { matches = false; break }
            if matches { return index }
            index += 1
        }
        return nil
    }

    private static func sqlDollarDelimiterEnd(
        _ bytes: UnsafeBufferPointer<UInt8>, from start: Int
    ) -> Int? {
        guard start < bytes.count, bytes[start] == 0x24 else { return nil }
        var index = start + 1
        while index < bytes.count, index - start <= 65 {
            if bytes[index] == 0x24 { return index + 1 }
            if !SyntaxByteUtilities.isASCIIAlpha(bytes[index]),
               !SyntaxByteUtilities.isDigit(bytes[index]), bytes[index] != 0x5F { return nil }
            index += 1
        }
        return nil
    }

    private static func scanMarkupDeclarationEnd(
        _ bytes: UnsafeBufferPointer<UInt8>, from start: Int
    ) -> Int {
        var index = start
        var bracketDepth = 0
        var quote: UInt8?
        while index < bytes.count {
            let byte = bytes[index]
            if let active = quote {
                if byte == active { quote = nil }
            } else if byte == 0x22 || byte == 0x27 {
                quote = byte
            } else if byte == 0x5B {
                bracketDepth += 1
            } else if byte == 0x5D, bracketDepth > 0 {
                bracketDepth -= 1
            } else if byte == 0x3E, bracketDepth == 0 {
                return index + 1
            }
            index += 1
        }
        return bytes.count
    }

    private static func isXMLNameByte(_ byte: UInt8) -> Bool {
        SyntaxByteUtilities.isIdentifierContinue(byte) || byte == 0x3A || byte == 0x2E
    }

    private static func markerRun(
        _ bytes: UnsafeBufferPointer<UInt8>, from start: Int, limit: Int
    ) -> (marker: UInt8, count: Int, end: Int)? {
        guard start < limit, bytes[start] == 0x60 || bytes[start] == 0x7E else { return nil }
        let marker = bytes[start]
        var end = start
        while end < limit, bytes[end] == marker { end += 1 }
        return (marker, end - start, end)
    }

    private static func onlyWhitespace(
        _ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int
    ) -> Bool {
        guard start <= end else { return false }
        for index in start..<end where !SyntaxByteUtilities.isSpace(bytes[index]) { return false }
        return true
    }

    private static func markdownListMarkerEnd(
        _ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int
    ) -> Int? {
        guard start < end else { return nil }
        if isMarkdownBullet(bytes[start]),
           start + 1 < end, SyntaxByteUtilities.isSpace(bytes[start + 1]) { return start + 1 }
        var index = start
        while index < end, index - start < 9, SyntaxByteUtilities.isDigit(bytes[index]) { index += 1 }
        if index > start, index + 1 < end,
           (bytes[index] == 0x2E || bytes[index] == 0x29), SyntaxByteUtilities.isSpace(bytes[index + 1]) {
            return index + 1
        }
        return nil
    }

    @inline(__always)
    private static func isJSONPunctuation(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x7B, 0x7D, 0x5B, 0x5D, 0x2C, 0x3A: true
        default: false
        }
    }

    @inline(__always)
    private static func isSQLPunctuation(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x28, 0x29, 0x2C, 0x3B, 0x2E: true
        default: false
        }
    }

    @inline(__always)
    private static func isSQLOperator(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x2B, 0x2A, 0x2F, 0x25, 0x3D, 0x3C, 0x3E, 0x21, 0x7C, 0x26, 0x5E: true
        default: false
        }
    }

    @inline(__always)
    private static func isSQLCompoundOperatorTail(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x3D, 0x3E, 0x3C, 0x7C, 0x26: true
        default: false
        }
    }

    @inline(__always)
    private static func isYAMLFlowPunctuation(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x2C, 0x5B, 0x5D, 0x7B, 0x7D: true
        default: false
        }
    }

    @inline(__always)
    private static func isMarkdownBullet(_ byte: UInt8) -> Bool {
        byte == 0x2D || byte == 0x2B || byte == 0x2A
    }
}
