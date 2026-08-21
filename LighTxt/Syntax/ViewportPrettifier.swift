import Foundation

/// A bounded, presentation-only formatter for the bytes already materialized
/// by the virtual editor. It never returns byte edits and never reaches beyond
/// the supplied viewport.
public nonisolated enum ViewportPrettifier {
    public static let maximumInputBytes = 512 * 1_024
    public static let defaultMaximumOutputBytes = 2 * 1_024 * 1_024

    public struct Result: Sendable, Equatable {
        public let text: String
        public let didPrettify: Bool
        public let status: String
        public let inputByteCount: Int
        public let outputByteCount: Int
        public let omittedUTF8BOM: Bool
        public let preservedLeadingPartialLine: Bool

        public init(
            text: String,
            didPrettify: Bool,
            status: String,
            inputByteCount: Int,
            outputByteCount: Int,
            omittedUTF8BOM: Bool,
            preservedLeadingPartialLine: Bool
        ) {
            self.text = text
            self.didPrettify = didPrettify
            self.status = status
            self.inputByteCount = inputByteCount
            self.outputByteCount = outputByteCount
            self.omittedUTF8BOM = omittedUTF8BOM
            self.preservedLeadingPartialLine = preservedLeadingPartialLine
        }
    }

    public static func prettify(
        _ data: Data,
        as fileType: SyntaxFileType,
        viewportRange: Range<Int64>,
        documentByteCount: Int64,
        leadingContext: Data = Data(),
        leadingContextStartByteOffset: Int64? = nil,
        maximumOutputBytes requestedMaximumOutputBytes: Int = defaultMaximumOutputBytes,
        cancellation: CancellationToken? = nil
    ) throws -> Result {
        if cancellation?.isCancelled == true { throw CancellationError() }
        guard data.count <= maximumInputBytes else {
            return fallback(
                data,
                reason: "the viewport exceeds the 512 KiB formatting limit",
                viewportRange: viewportRange
            )
        }
        guard String(data: data, encoding: .utf8) != nil else {
            return fallback(
                data,
                reason: "the viewport is not valid UTF-8",
                viewportRange: viewportRange
            )
        }

        let maximumOutputBytes = max(data.count, min(8 * 1_024 * 1_024, requestedMaximumOutputBytes))
        switch fileType {
        case .json:
            return try prettifyJSON(
                data,
                viewportRange: viewportRange,
                documentByteCount: documentByteCount,
                leadingContext: leadingContext,
                leadingContextStartByteOffset: leadingContextStartByteOffset,
                maximumOutputBytes: maximumOutputBytes,
                cancellation: cancellation
            )
        case .yaml:
            return try prettifyYAML(
                data,
                viewportRange: viewportRange,
                documentByteCount: documentByteCount,
                maximumOutputBytes: maximumOutputBytes,
                cancellation: cancellation
            )
        default:
            return fallback(
                data,
                reason: "Prettify is available only for JSON and YAML",
                viewportRange: viewportRange
            )
        }
    }

    // MARK: - JSON

    private static func prettifyJSON(
        _ data: Data,
        viewportRange: Range<Int64>,
        documentByteCount: Int64,
        leadingContext: Data,
        leadingContextStartByteOffset: Int64?,
        maximumOutputBytes: Int,
        cancellation: CancellationToken?
    ) throws -> Result {
        let bytes = [UInt8](data)
        let hasBOM = viewportRange.lowerBound == 0 && bytes.starts(with: [0xEF, 0xBB, 0xBF])
        let contentStart = hasBOM ? 3 : 0
        let isWholeDocument = viewportRange.lowerBound == 0
            && viewportRange.upperBound == documentByteCount

        if isWholeDocument {
            let validationData = Data(bytes[contentStart...])
            do {
                _ = try JSONSerialization.jsonObject(with: validationData, options: [.fragmentsAllowed])
            } catch {
                return fallback(
                    data,
                    reason: "the bounded document is not valid JSON",
                    viewportRange: viewportRange
                )
            }
        }

        let safeStart: Int
        let preservedPartialLine: Bool
        let initialStack: [UInt8]
        var usedLeadingContext = false
        if viewportRange.lowerBound == 0 {
            safeStart = contentStart
            preservedPartialLine = false
            initialStack = []
        } else if leadingContext.count <= maximumInputBytes,
                  let contextStart = leadingContextStartByteOffset,
                  contextStart >= 0,
                  contextStart + Int64(leadingContext.count) == viewportRange.lowerBound,
                  let state = provenJSONContext(
                    [UInt8](leadingContext),
                    startingAtDocumentByte: contextStart
                  ) {
            initialStack = state.stack
            usedLeadingContext = true
            if state.inString {
                guard let stringEnd = endOfLeadingJSONString(in: bytes) else {
                    return fallback(
                        data,
                        reason: "the partial JSON viewport ends inside a string",
                        viewportRange: viewportRange
                    )
                }
                safeStart = stringEnd
                preservedPartialLine = true
            } else {
                safeStart = contentStart
                preservedPartialLine = false
            }
        } else if let boundary = firstLineBoundary(in: bytes, startingAt: contentStart) {
            safeStart = boundary
            preservedPartialLine = true
            initialStack = []
        } else {
            return fallback(
                data,
                reason: "this partial JSON window has no proven string-safe line boundary",
                viewportRange: viewportRange
            )
        }

        guard safeStart < bytes.count else {
            return fallback(
                data,
                reason: "this viewport contains no complete JSON line to format",
                viewportRange: viewportRange
            )
        }

        var output = BoundedByteOutput(limit: maximumOutputBytes)
        do {
            if safeStart > 0, !hasBOM || preservedPartialLine {
                try output.append(contentsOf: bytes[0..<safeStart])
            }
            let baseline = leadingIndentWidth(in: bytes, startingAt: safeStart)
            try formatJSONBytes(
                bytes,
                startingAt: safeStart,
                baselineIndent: baseline,
                initialStack: initialStack,
                output: &output,
                documentEndsHere: viewportRange.upperBound == documentByteCount,
                cancellation: cancellation
            )
        } catch let failure as FormattingFailure {
            switch failure {
            case .cancelled:
                throw CancellationError()
            case .outputLimit:
                return fallback(
                    data,
                    reason: "formatted output would exceed the bounded preview limit",
                    viewportRange: viewportRange
                )
            case .unsafe(let reason):
                return fallback(data, reason: reason, viewportRange: viewportRange)
            }
        }

        var details = [
            "Read-only JSON preview",
            "2-space indentation",
            "LF display",
            "token spelling and key order preserved",
        ]
        if hasBOM { details.append("UTF-8 BOM hidden in preview") }
        if preservedPartialLine { details.append("leading partial line preserved exactly") }
        if usedLeadingContext { details.append("lexical state proven from bounded preceding context") }
        if !isWholeDocument { details.append("viewport-relative fragment") }
        return Result(
            text: String(decoding: output.data, as: UTF8.self),
            didPrettify: true,
            status: details.joined(separator: "  ·  "),
            inputByteCount: data.count,
            outputByteCount: output.data.count,
            omittedUTF8BOM: hasBOM,
            preservedLeadingPartialLine: preservedPartialLine
        )
    }

    private static func formatJSONBytes(
        _ bytes: [UInt8],
        startingAt start: Int,
        baselineIndent: Int,
        initialStack: [UInt8],
        output: inout BoundedByteOutput,
        documentEndsHere: Bool,
        cancellation: CancellationToken?
    ) throws {
        var index = start
        var stack = initialStack
        let initialDepth = initialStack.count
        var inString = false
        var lastSignificant: UInt8?
        var beganFormattedContent = false

        while index < bytes.count {
            if index.isMultiple(of: 4_096), cancellation?.isCancelled == true {
                throw FormattingFailure.cancelled
            }
            let byte = bytes[index]
            if inString {
                if byte < 0x20 {
                    throw FormattingFailure.unsafe("a JSON string contains an unescaped control byte")
                }
                try output.append(byte)
                if byte == 0x5C {
                    guard index + 1 < bytes.count else {
                        if documentEndsHere {
                            throw FormattingFailure.unsafe("a JSON escape is incomplete")
                        }
                        return
                    }
                    let escaped = bytes[index + 1]
                    guard escaped == 0x22 || escaped == 0x5C || escaped == 0x2F
                            || escaped == 0x62 || escaped == 0x66 || escaped == 0x6E
                            || escaped == 0x72 || escaped == 0x74 || escaped == 0x75 else {
                        throw FormattingFailure.unsafe("a JSON string contains an invalid escape")
                    }
                    try output.append(escaped)
                    index += 2
                    if escaped == 0x75 {
                        guard index + 4 <= bytes.count else {
                            if documentEndsHere {
                                throw FormattingFailure.unsafe("a JSON Unicode escape is incomplete")
                            }
                            return
                        }
                        for _ in 0..<4 {
                            guard isHexDigit(bytes[index]) else {
                                throw FormattingFailure.unsafe("a JSON Unicode escape is invalid")
                            }
                            try output.append(bytes[index])
                            index += 1
                        }
                    }
                    continue
                }
                if byte == 0x22 { inString = false }
                index += 1
                continue
            }

            if isJSONWhitespace(byte) {
                if beganFormattedContent,
                   let previous = lastSignificant,
                   let next = nextJSONSignificantByte(in: bytes, after: index),
                   !isJSONStructural(previous),
                   !isJSONStructural(next) {
                    // Whitespace between two primitive tokens is not valid
                    // JSON and removing it would silently fuse `1 2` into
                    // `12`. A partial window cannot prove otherwise.
                    throw FormattingFailure.unsafe("adjacent JSON scalar tokens are ambiguous in this viewport")
                }
                index += 1
                continue
            }
            if !beganFormattedContent {
                try output.appendSpaces(baselineIndent)
                beganFormattedContent = true
            }

            switch byte {
            case 0x22: // string
                inString = true
                try output.append(byte)
            case 0x7B, 0x5B: // { [
                stack.append(byte)
                try output.append(byte)
                if let next = nextJSONSignificantByte(in: bytes, after: index),
                   !matches(open: byte, close: next) {
                    try output.newline(indent: baselineIndent + max(0, stack.count - initialDepth) * 2)
                }
            case 0x7D, 0x5D: // } ]
                guard let open = stack.last,
                      matches(open: open, close: byte) else {
                    throw FormattingFailure.unsafe("a closing JSON delimiter has no proven preceding container")
                }
                stack.removeLast()
                if let lastSignificant, !matches(open: lastSignificant, close: byte) {
                    try output.newline(indent: baselineIndent + max(0, stack.count - initialDepth) * 2)
                }
                try output.append(byte)
            case 0x2C: // ,
                try output.append(byte)
                try output.newline(indent: baselineIndent + max(0, stack.count - initialDepth) * 2)
            case 0x3A: // :
                try output.append(byte)
                try output.append(0x20)
            default:
                try output.append(byte)
            }
            lastSignificant = byte
            index += 1
        }

        if inString, documentEndsHere {
            throw FormattingFailure.unsafe("a JSON string is unterminated")
        }
        output.trimTrailingSpaces()
    }

    // MARK: - YAML

    private static func prettifyYAML(
        _ data: Data,
        viewportRange: Range<Int64>,
        documentByteCount: Int64,
        maximumOutputBytes: Int,
        cancellation: CancellationToken?
    ) throws -> Result {
        let bytes = [UInt8](data)
        let hasBOM = viewportRange.lowerBound == 0 && bytes.starts(with: [0xEF, 0xBB, 0xBF])
        let contentStart = hasBOM ? 3 : 0
        let safeStart: Int
        let preservedPartialLine: Bool
        if viewportRange.lowerBound == 0 {
            safeStart = contentStart
            preservedPartialLine = false
        } else if let boundary = firstLineBoundary(in: bytes, startingAt: contentStart) {
            safeStart = boundary
            preservedPartialLine = true
        } else {
            return fallback(
                data,
                reason: "this partial YAML window has no complete line boundary",
                viewportRange: viewportRange
            )
        }

        let lines = yamlLines(in: bytes, startingAt: safeStart)
        var analyzed: [YAMLAnalyzedLine] = []
        analyzed.reserveCapacity(lines.count)
        var structuralDepths: [Int?] = []
        structuralDepths.reserveCapacity(lines.count)
        var lastStructural: YAMLAnalyzedLine?
        var structuralIndentStack: [Int] = []

        for (offset, line) in lines.enumerated() {
            if offset.isMultiple(of: 1_024), cancellation?.isCancelled == true {
                throw CancellationError()
            }
            let result: YAMLAnalyzedLine
            do {
                result = try analyzeYAMLLine(line, bytes: bytes)
            } catch let failure as FormattingFailure {
                switch failure {
                case .cancelled:
                    throw CancellationError()
                case .outputLimit:
                    return fallback(
                        data,
                        reason: "formatted output would exceed the bounded preview limit",
                        viewportRange: viewportRange
                    )
                case .unsafe(let reason):
                    return fallback(data, reason: reason, viewportRange: viewportRange)
                }
            }
            if result.resetsIndentation {
                structuralIndentStack.removeAll(keepingCapacity: true)
                lastStructural = nil
            }
            if result.isStructural {
                if let previous = lastStructural {
                    if result.indent > previous.indent {
                        guard previous.canOwnChildren else {
                            return fallback(
                                data,
                                reason: "YAML indentation increases after a scalar and cannot be proven safe",
                                viewportRange: viewportRange
                            )
                        }
                        structuralIndentStack.append(result.indent)
                    } else if result.indent < previous.indent {
                        while let deepest = structuralIndentStack.last, deepest > result.indent {
                            structuralIndentStack.removeLast()
                        }
                        guard structuralIndentStack.last == result.indent else {
                            return fallback(
                                data,
                                reason: "YAML indentation does not return to a proven parent level",
                                viewportRange: viewportRange
                            )
                        }
                    }
                } else {
                    structuralIndentStack = [result.indent]
                }
                lastStructural = result
                structuralDepths.append(max(0, structuralIndentStack.count - 1))
            } else {
                structuralDepths.append(nil)
            }
            analyzed.append(result)
        }
        var output = BoundedByteOutput(limit: maximumOutputBytes)
        do {
            if safeStart > 0, !hasBOM || preservedPartialLine {
                try output.append(contentsOf: bytes[0..<safeStart])
            }
            for (offset, line) in analyzed.enumerated() {
                if offset.isMultiple(of: 1_024), cancellation?.isCancelled == true {
                    throw FormattingFailure.cancelled
                }
                if line.isStructural {
                    try output.appendSpaces((structuralDepths[offset] ?? 0) * 2)
                    try output.append(contentsOf: bytes[line.payloadRange])
                } else {
                    // Comments, blank lines, and document markers are copied as
                    // complete source lines. Their payload is never rewritten.
                    try output.append(contentsOf: bytes[line.fullContentRange])
                }
                if line.hadLineEnding { try output.append(0x0A) }
            }
        } catch let failure as FormattingFailure {
            switch failure {
            case .cancelled:
                throw CancellationError()
            case .outputLimit:
                return fallback(
                    data,
                    reason: "formatted output would exceed the bounded preview limit",
                    viewportRange: viewportRange
                )
            case .unsafe(let reason):
                return fallback(data, reason: reason, viewportRange: viewportRange)
            }
        }

        var details = [
            "Read-only YAML preview",
            "viewport-relative 2-space indentation",
            "LF display",
            "scalar and comment text preserved",
        ]
        if hasBOM { details.append("UTF-8 BOM hidden in preview") }
        if preservedPartialLine { details.append("leading partial line preserved exactly") }
        if viewportRange.upperBound != documentByteCount { details.append("bounded viewport") }
        return Result(
            text: String(decoding: output.data, as: UTF8.self),
            didPrettify: true,
            status: details.joined(separator: "  ·  "),
            inputByteCount: data.count,
            outputByteCount: output.data.count,
            omittedUTF8BOM: hasBOM,
            preservedLeadingPartialLine: preservedPartialLine
        )
    }

    private struct YAMLSourceLine {
        let fullContentRange: Range<Int>
        let payloadRange: Range<Int>
        let indent: Int
        let hadLineEnding: Bool
    }

    private struct YAMLAnalyzedLine {
        let fullContentRange: Range<Int>
        let payloadRange: Range<Int>
        let indent: Int
        let hadLineEnding: Bool
        let isStructural: Bool
        let canOwnChildren: Bool
        let resetsIndentation: Bool
    }

    private static func yamlLines(in bytes: [UInt8], startingAt start: Int) -> [YAMLSourceLine] {
        var lines: [YAMLSourceLine] = []
        var cursor = start
        while cursor < bytes.count {
            let lineStart = cursor
            while cursor < bytes.count, bytes[cursor] != 0x0A, bytes[cursor] != 0x0D {
                cursor += 1
            }
            let contentEnd = cursor
            var indentEnd = lineStart
            while indentEnd < contentEnd, bytes[indentEnd] == 0x20 { indentEnd += 1 }
            if cursor < bytes.count {
                if bytes[cursor] == 0x0D, cursor + 1 < bytes.count, bytes[cursor + 1] == 0x0A {
                    cursor += 2
                } else {
                    cursor += 1
                }
            }
            lines.append(YAMLSourceLine(
                fullContentRange: lineStart..<contentEnd,
                payloadRange: indentEnd..<contentEnd,
                indent: indentEnd - lineStart,
                hadLineEnding: cursor > contentEnd
            ))
        }
        if start == bytes.count {
            lines.append(YAMLSourceLine(
                fullContentRange: start..<start,
                payloadRange: start..<start,
                indent: 0,
                hadLineEnding: false
            ))
        }
        return lines
    }

    private static func analyzeYAMLLine(
        _ line: YAMLSourceLine,
        bytes: [UInt8]
    ) throws -> YAMLAnalyzedLine {
        if line.payloadRange.lowerBound < line.fullContentRange.upperBound,
           bytes[line.payloadRange.lowerBound] == 0x09 {
            throw FormattingFailure.unsafe("YAML indentation contains a tab")
        }
        let payload = Array(bytes[line.payloadRange])
        let scan = try scanYAMLPayload(payload)
        let code = payload[0..<scan.codeEnd]
        let trimmed = trimASCIIWhitespace(code)
        let marker = trimmed.elementsEqual([0x2D, 0x2D, 0x2D])
            || trimmed.elementsEqual([0x2E, 0x2E, 0x2E])
        if trimmed.isEmpty || marker || trimmed.first == 0x23 {
            return YAMLAnalyzedLine(
                fullContentRange: line.fullContentRange,
                payloadRange: line.payloadRange,
                indent: line.indent,
                hadLineEnding: line.hadLineEnding,
                isStructural: false,
                canOwnChildren: false,
                resetsIndentation: marker
            )
        }
        if scan.hasUnsafeFeature {
            throw FormattingFailure.unsafe(
                "this YAML viewport uses flow, anchor, alias, tag, or block-scalar syntax"
            )
        }

        let isSequence = trimmed.first == 0x2D
            && (trimmed.count == 1 || isASCIIWhitespace(trimmed[trimmed.index(after: trimmed.startIndex)]))
        let mappingColon = scan.mappingColon
        guard isSequence || mappingColon != nil else {
            throw FormattingFailure.unsafe(
                "a YAML scalar continuation makes structural reindentation ambiguous"
            )
        }
        // A scalar sequence item (`- value`) cannot own an indented child.
        // Only an empty item or an inline mapping with an empty value is a
        // structurally proven parent in this conservative formatter.
        var canOwnChildren = false
        if isSequence {
            let item = trimASCIIWhitespace(trimmed.dropFirst())
            canOwnChildren = item.isEmpty
        }
        if let mappingColon {
            let absoluteColon = payload.startIndex + mappingColon
            let head = trimASCIIWhitespace(payload[payload.startIndex..<absoluteColon])
            guard !head.isEmpty, !head.elementsEqual([0x2D]) else {
                throw FormattingFailure.unsafe("a YAML mapping key is missing")
            }
            let tailStart = min(payload.endIndex, absoluteColon + 1)
            let tail = trimASCIIWhitespace(payload[tailStart..<scan.codeEnd])
            canOwnChildren = canOwnChildren || tail.isEmpty
            if isSequence { canOwnChildren = true }
        }
        return YAMLAnalyzedLine(
            fullContentRange: line.fullContentRange,
            payloadRange: line.payloadRange,
            indent: line.indent,
            hadLineEnding: line.hadLineEnding,
            isStructural: true,
            canOwnChildren: canOwnChildren,
            resetsIndentation: false
        )
    }

    private struct YAMLPayloadScan {
        let codeEnd: Int
        let mappingColon: Int?
        let hasUnsafeFeature: Bool
    }

    private static func scanYAMLPayload(_ bytes: [UInt8]) throws -> YAMLPayloadScan {
        var index = 0
        var singleQuoted = false
        var doubleQuoted = false
        var escaped = false
        var mappingColon: Int?
        var codeEnd = bytes.count
        var hasUnsafeFeature = false

        while index < bytes.count {
            let byte = bytes[index]
            if doubleQuoted {
                if escaped {
                    let simpleEscapes: Set<UInt8> = [
                        0x30, 0x61, 0x62, 0x74, 0x6E, 0x76, 0x66, 0x72, 0x65,
                        0x20, 0x22, 0x2F, 0x5C, 0x4E, 0x5F, 0x4C, 0x50,
                    ]
                    if byte == 0x78 || byte == 0x75 || byte == 0x55 {
                        let digitCount = byte == 0x78 ? 2 : (byte == 0x75 ? 4 : 8)
                        guard index + digitCount < bytes.count else {
                            throw FormattingFailure.unsafe("a YAML hexadecimal escape is incomplete")
                        }
                        for digitIndex in (index + 1)...(index + digitCount) {
                            guard isHexDigit(bytes[digitIndex]) else {
                                throw FormattingFailure.unsafe("a YAML hexadecimal escape is invalid")
                            }
                        }
                        index += digitCount
                    } else if !simpleEscapes.contains(byte) {
                        throw FormattingFailure.unsafe("a YAML double-quoted scalar contains an unsupported escape")
                    }
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    doubleQuoted = false
                } else if byte < 0x20 {
                    throw FormattingFailure.unsafe("a YAML quoted scalar contains a raw control byte")
                }
                index += 1
                continue
            }
            if singleQuoted {
                if byte < 0x20 {
                    throw FormattingFailure.unsafe("a YAML quoted scalar contains a raw control byte")
                }
                if byte == 0x27 {
                    if index + 1 < bytes.count, bytes[index + 1] == 0x27 {
                        index += 2
                        continue
                    }
                    singleQuoted = false
                }
                index += 1
                continue
            }
            if byte == 0x22 {
                doubleQuoted = true
            } else if byte == 0x27 {
                singleQuoted = true
            } else if byte == 0x23,
                      index == 0 || isASCIIWhitespace(bytes[index - 1]) {
                codeEnd = index
                break
            } else if byte == 0x26 || byte == 0x2A || byte == 0x21
                        || byte == 0x7B || byte == 0x7D || byte == 0x5B || byte == 0x5D
                        || byte == 0x7C || byte == 0x3E {
                hasUnsafeFeature = true
            } else if byte == 0x3A,
                      index + 1 == bytes.count || isASCIIWhitespace(bytes[index + 1]),
                      mappingColon == nil {
                mappingColon = index
            } else if byte < 0x20 {
                throw FormattingFailure.unsafe("a YAML scalar contains a raw control byte")
            }
            index += 1
        }
        if singleQuoted || doubleQuoted || escaped {
            throw FormattingFailure.unsafe("a multiline or unterminated YAML quote cannot be safely reindented")
        }
        return YAMLPayloadScan(
            codeEnd: codeEnd,
            mappingColon: mappingColon,
            hasUnsafeFeature: hasUnsafeFeature
        )
    }

    // MARK: - Helpers

    private struct JSONContextState {
        let inString: Bool
        let stack: [UInt8]
    }

    /// Reconstructs only lexical/container state that can be proven from a
    /// bounded prefix. A prefix beginning at byte zero is authoritative; a
    /// later prefix needs a raw line boundary, which cannot occur inside a
    /// valid JSON string. Any unmatched delimiter or incomplete escape fails
    /// closed rather than inventing ancestry.
    private static func provenJSONContext(
        _ bytes: [UInt8],
        startingAtDocumentByte startByte: Int64
    ) -> JSONContextState? {
        let scanStart: Int
        if startByte == 0 {
            scanStart = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
        } else {
            guard let boundary = bytes.lastIndex(where: { $0 == 0x0A || $0 == 0x0D }) else {
                return nil
            }
            scanStart = boundary + 1
        }

        var index = scanStart
        var inString = false
        var stack: [UInt8] = []
        while index < bytes.count {
            let byte = bytes[index]
            if inString {
                guard byte >= 0x20 else { return nil }
                if byte == 0x5C {
                    guard index + 1 < bytes.count else { return nil }
                    let escaped = bytes[index + 1]
                    guard escaped == 0x22 || escaped == 0x5C || escaped == 0x2F
                            || escaped == 0x62 || escaped == 0x66 || escaped == 0x6E
                            || escaped == 0x72 || escaped == 0x74 || escaped == 0x75 else {
                        return nil
                    }
                    index += 2
                    if escaped == 0x75 {
                        guard index + 4 <= bytes.count else { return nil }
                        for digit in bytes[index..<(index + 4)] where !isHexDigit(digit) {
                            return nil
                        }
                        index += 4
                    }
                    continue
                }
                if byte == 0x22 { inString = false }
            } else {
                switch byte {
                case 0x22:
                    inString = true
                case 0x7B, 0x5B:
                    stack.append(byte)
                case 0x7D, 0x5D:
                    guard let open = stack.last, matches(open: open, close: byte) else {
                        return nil
                    }
                    stack.removeLast()
                default:
                    if byte < 0x20, !isJSONWhitespace(byte) { return nil }
                }
            }
            index += 1
        }
        return JSONContextState(inString: inString, stack: stack)
    }

    /// The caller has proven that the viewport starts inside a string. Copy
    /// that partial token exactly and begin structural formatting only after
    /// its unescaped closing quote.
    private static func endOfLeadingJSONString(in bytes: [UInt8]) -> Int? {
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            guard byte >= 0x20 else { return nil }
            if byte == 0x5C {
                guard index + 1 < bytes.count else { return nil }
                let escaped = bytes[index + 1]
                guard escaped == 0x22 || escaped == 0x5C || escaped == 0x2F
                        || escaped == 0x62 || escaped == 0x66 || escaped == 0x6E
                        || escaped == 0x72 || escaped == 0x74 || escaped == 0x75 else {
                    return nil
                }
                index += 2
                if escaped == 0x75 {
                    guard index + 4 <= bytes.count else { return nil }
                    for digit in bytes[index..<(index + 4)] where !isHexDigit(digit) {
                        return nil
                    }
                    index += 4
                }
                continue
            }
            if byte == 0x22 { return index + 1 }
            index += 1
        }
        return nil
    }

    private enum FormattingFailure: Error {
        case cancelled
        case outputLimit
        case unsafe(String)
    }

    private struct BoundedByteOutput {
        var data = Data()
        let limit: Int

        init(limit: Int) {
            self.limit = max(0, limit)
            data.reserveCapacity(min(limit, 1 * 1_024 * 1_024))
        }

        mutating func append(_ byte: UInt8) throws {
            guard data.count < limit else { throw FormattingFailure.outputLimit }
            data.append(byte)
        }

        mutating func append<S: Sequence>(contentsOf bytes: S) throws where S.Element == UInt8 {
            for byte in bytes { try append(byte) }
        }

        mutating func appendSpaces(_ count: Int) throws {
            guard count > 0 else { return }
            guard data.count <= limit - min(count, limit) else { throw FormattingFailure.outputLimit }
            for _ in 0..<count { try append(0x20) }
        }

        mutating func newline(indent: Int) throws {
            trimTrailingSpaces()
            if data.last != 0x0A { try append(0x0A) }
            try appendSpaces(max(0, indent))
        }

        mutating func trimTrailingSpaces() {
            while data.last == 0x20 || data.last == 0x09 { data.removeLast() }
        }
    }

    private static func fallback(
        _ data: Data,
        reason: String,
        viewportRange: Range<Int64>
    ) -> Result {
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        return Result(
            text: text,
            didPrettify: false,
            status: "Could not safely prettify this viewport: \(reason). Showing bounded source read-only; source bytes are unchanged.",
            inputByteCount: data.count,
            outputByteCount: data.count,
            omittedUTF8BOM: false,
            preservedLeadingPartialLine: viewportRange.lowerBound > 0
        )
    }

    private static func firstLineBoundary(in bytes: [UInt8], startingAt start: Int) -> Int? {
        var index = start
        while index < bytes.count {
            if bytes[index] == 0x0A { return index + 1 }
            if bytes[index] == 0x0D {
                return index + ((index + 1 < bytes.count && bytes[index + 1] == 0x0A) ? 2 : 1)
            }
            index += 1
        }
        return nil
    }

    private static func leadingIndentWidth(in bytes: [UInt8], startingAt start: Int) -> Int {
        var index = start
        var width = 0
        while index < bytes.count {
            if bytes[index] == 0x20 { width += 1 }
            else if bytes[index] == 0x09 { width += 2 }
            else { break }
            index += 1
        }
        return min(256, width)
    }

    private static func nextJSONSignificantByte(in bytes: [UInt8], after index: Int) -> UInt8? {
        var cursor = index + 1
        while cursor < bytes.count, isJSONWhitespace(bytes[cursor]) { cursor += 1 }
        return cursor < bytes.count ? bytes[cursor] : nil
    }

    private static func matches(open: UInt8, close: UInt8) -> Bool {
        (open == 0x7B && close == 0x7D) || (open == 0x5B && close == 0x5D)
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func isJSONStructural(_ byte: UInt8) -> Bool {
        byte == 0x7B || byte == 0x7D || byte == 0x5B || byte == 0x5D
            || byte == 0x2C || byte == 0x3A
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09
    }

    private static func trimASCIIWhitespace<C: BidirectionalCollection>(_ bytes: C) -> C.SubSequence where C.Element == UInt8 {
        var lower = bytes.startIndex
        var upper = bytes.endIndex
        while lower < upper, isASCIIWhitespace(bytes[lower]) { lower = bytes.index(after: lower) }
        while lower < upper {
            let before = bytes.index(upper, offsetBy: -1)
            guard isASCIIWhitespace(bytes[before]) else { break }
            upper = before
        }
        return bytes[lower..<upper]
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39)
            || (byte >= 0x41 && byte <= 0x46)
            || (byte >= 0x61 && byte <= 0x66)
    }
}
