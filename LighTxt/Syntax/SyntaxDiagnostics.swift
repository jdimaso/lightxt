import Foundation

/// Lightweight, allocation-bounded structural checks. These validators are
/// intentionally not schema engines: they catch damaged syntax while keeping
/// memory bounded by nesting depth and `maximumDiagnostics`.
public enum SyntaxDiagnostics {
    public static func inspect(
        _ data: Data,
        as fileType: SyntaxFileType,
        baseByteOffset: Int = 0,
        limits: SyntaxLimits = .default
    ) -> [SyntaxDiagnostic] {
        data.withUnsafeBytes { rawBuffer in
            inspect(
                rawBuffer.bindMemory(to: UInt8.self),
                as: fileType,
                baseByteOffset: baseByteOffset,
                limits: limits
            )
        }
    }

    /// `bytes` is expected to contain a complete document. For viewport-only
    /// input, use `ViewportSyntaxHighlighter`; incomplete tails are correctly
    /// treated as syntax errors here.
    public static func inspect(
        _ bytes: UnsafeBufferPointer<UInt8>,
        as fileType: SyntaxFileType,
        baseByteOffset: Int = 0,
        limits: SyntaxLimits = .default
    ) -> [SyntaxDiagnostic] {
        guard limits.maximumDiagnostics > 0 else { return [] }
        switch fileType {
        case .plainText:
            return utf8Diagnostics(bytes, baseByteOffset: baseByteOffset, limits: limits)
        case .parquet:
            return []
        case .json:
            var validator = JSONValidator(
                bytes: bytes, baseByteOffset: baseByteOffset, limits: limits
            )
            return validator.validate()
        case .xml:
            var validator = XMLValidator(
                bytes: bytes, baseByteOffset: baseByteOffset, limits: limits
            )
            return validator.validate()
        case .yaml:
            return yamlDiagnostics(bytes, baseByteOffset: baseByteOffset, limits: limits)
        case .csv:
            return csvDiagnostics(bytes, baseByteOffset: baseByteOffset, limits: limits)
        case .sql:
            return sqlDiagnostics(bytes, baseByteOffset: baseByteOffset, limits: limits)
        case .markdown:
            return markdownDiagnostics(bytes, baseByteOffset: baseByteOffset, limits: limits)
        }
    }

    public static func inspect(
        _ bytes: UnsafeRawBufferPointer,
        as fileType: SyntaxFileType,
        baseByteOffset: Int = 0,
        limits: SyntaxLimits = .default
    ) -> [SyntaxDiagnostic] {
        inspect(
            bytes.bindMemory(to: UInt8.self),
            as: fileType,
            baseByteOffset: baseByteOffset,
            limits: limits
        )
    }

    // MARK: - UTF-8

    private static func utf8Diagnostics(
        _ bytes: UnsafeBufferPointer<UInt8>,
        baseByteOffset: Int,
        limits: SyntaxLimits
    ) -> [SyntaxDiagnostic] {
        var collector = SyntaxDiagnosticCollector(
            baseOffset: baseByteOffset, maximumCount: limits.maximumDiagnostics
        )
        var index = 0
        while index < bytes.count, !collector.isFull {
            let length = SyntaxByteUtilities.isValidUTF8Sequence(bytes, at: index)
            if length == 0 {
                collector.append(.error, "encoding.invalid-utf8", "Invalid UTF-8 byte sequence.", at: index)
                index += 1
            } else {
                index += length
            }
        }
        return collector.diagnostics
    }

    // MARK: - JSON

    private struct JSONValidator {
        let bytes: UnsafeBufferPointer<UInt8>
        let limits: SyntaxLimits
        var index = 0
        var collector: SyntaxDiagnosticCollector

        init(bytes: UnsafeBufferPointer<UInt8>, baseByteOffset: Int, limits: SyntaxLimits) {
            self.bytes = bytes
            self.limits = limits
            collector = SyntaxDiagnosticCollector(
                baseOffset: baseByteOffset, maximumCount: limits.maximumDiagnostics
            )
        }

        mutating func validate() -> [SyntaxDiagnostic] {
            if bytes.count >= 3,
               bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { index = 3 }
            skipWhitespace()
            guard index < bytes.count else {
                fail("json.empty", "A JSON document must contain a value.", at: index, length: 0)
                return collector.diagnostics
            }
            guard parseValue(depth: 0) else { return collector.diagnostics }
            skipWhitespace()
            if index < bytes.count {
                fail("json.trailing-content", "Unexpected content after the top-level JSON value.", at: index)
            }
            return collector.diagnostics
        }

        mutating func parseValue(depth: Int) -> Bool {
            skipWhitespace()
            guard index < bytes.count else {
                return fail("json.expected-value", "Expected a JSON value before end of file.", at: index, length: 0)
            }
            if depth > limits.maximumNestingDepth {
                return fail("json.depth-limit", "JSON nesting exceeds the configured safety limit.", at: index)
            }
            switch bytes[index] {
            case 0x7B: return parseObject(depth: depth)
            case 0x5B: return parseArray(depth: depth)
            case 0x22: return parseString()
            case 0x74:
                return consumeLiteral("true")
            case 0x66:
                return consumeLiteral("false")
            case 0x6E:
                return consumeLiteral("null")
            case 0x2D, 0x30...0x39:
                return parseNumber()
            default:
                return fail("json.expected-value", "Expected an object, array, string, number, boolean, or null.", at: index)
            }
        }

        mutating func parseObject(depth: Int) -> Bool {
            index += 1
            skipWhitespace()
            if consume(0x7D) { return true }
            while index < bytes.count {
                guard bytes[index] == 0x22 else {
                    return fail("json.expected-key", "Object keys must be double-quoted strings.", at: index)
                }
                guard parseString() else { return false }
                skipWhitespace()
                guard consume(0x3A) else {
                    return fail("json.expected-colon", "Expected ':' after the object key.", at: index, length: index < bytes.count ? 1 : 0)
                }
                guard parseValue(depth: depth + 1) else { return false }
                skipWhitespace()
                if consume(0x7D) { return true }
                guard consume(0x2C) else {
                    return fail("json.expected-object-separator", "Expected ',' or '}' after the object value.", at: index, length: index < bytes.count ? 1 : 0)
                }
                skipWhitespace()
                if index < bytes.count, bytes[index] == 0x7D {
                    return fail("json.trailing-comma", "Trailing commas are not valid JSON.", at: index)
                }
            }
            return fail("json.unclosed-object", "Expected '}' before end of file.", at: index, length: 0)
        }

        mutating func parseArray(depth: Int) -> Bool {
            index += 1
            skipWhitespace()
            if consume(0x5D) { return true }
            while index < bytes.count {
                guard parseValue(depth: depth + 1) else { return false }
                skipWhitespace()
                if consume(0x5D) { return true }
                guard consume(0x2C) else {
                    return fail("json.expected-array-separator", "Expected ',' or ']' after the array value.", at: index, length: index < bytes.count ? 1 : 0)
                }
                skipWhitespace()
                if index < bytes.count, bytes[index] == 0x5D {
                    return fail("json.trailing-comma", "Trailing commas are not valid JSON.", at: index)
                }
            }
            return fail("json.unclosed-array", "Expected ']' before end of file.", at: index, length: 0)
        }

        mutating func parseString() -> Bool {
            let opening = index
            index += 1
            while index < bytes.count {
                let byte = bytes[index]
                if byte == 0x22 {
                    index += 1
                    return true
                }
                if byte < 0x20 {
                    return fail("json.control-in-string", "Unescaped control character in JSON string.", at: index)
                }
                if byte == 0x5C {
                    let escapeStart = index
                    index += 1
                    guard index < bytes.count else {
                        return fail("json.incomplete-escape", "Incomplete escape sequence at end of string.", at: escapeStart, length: bytes.count - escapeStart)
                    }
                    switch bytes[index] {
                    case 0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74:
                        index += 1
                    case 0x75:
                        guard let scalar = readHexQuad(at: index + 1) else {
                            return fail("json.invalid-unicode-escape", "A Unicode escape must contain four hexadecimal digits.", at: escapeStart, length: min(6, bytes.count - escapeStart))
                        }
                        index += 5
                        if (0xD800...0xDBFF).contains(scalar) {
                            let lowStart = index
                            guard lowStart + 6 <= bytes.count,
                                  bytes[lowStart] == 0x5C, bytes[lowStart + 1] == 0x75,
                                  let low = readHexQuad(at: lowStart + 2),
                                  (0xDC00...0xDFFF).contains(low) else {
                                return fail("json.invalid-surrogate-pair", "A high surrogate must be followed by a low-surrogate Unicode escape.", at: escapeStart, length: min(6, bytes.count - escapeStart))
                            }
                            index += 6
                        } else if (0xDC00...0xDFFF).contains(scalar) {
                            return fail("json.invalid-surrogate-pair", "A low surrogate cannot appear without a preceding high surrogate.", at: escapeStart, length: min(6, bytes.count - escapeStart))
                        }
                    default:
                        return fail("json.invalid-escape", "Invalid JSON escape sequence.", at: escapeStart, length: min(2, bytes.count - escapeStart))
                    }
                } else if byte >= 0x80 {
                    let length = SyntaxByteUtilities.isValidUTF8Sequence(bytes, at: index)
                    guard length > 0 else {
                        return fail("encoding.invalid-utf8", "Invalid UTF-8 byte sequence in JSON string.", at: index)
                    }
                    index += length
                } else {
                    index += 1
                }
            }
            return fail("json.unclosed-string", "Expected a closing double quote before end of file.", at: opening, length: min(1, bytes.count - opening))
        }

        mutating func parseNumber() -> Bool {
            let start = index
            if consume(0x2D), index == bytes.count {
                return fail("json.invalid-number", "A minus sign must be followed by a number.", at: start)
            }
            if consume(0x30) {
                if index < bytes.count, SyntaxByteUtilities.isDigit(bytes[index]) {
                    return fail("json.leading-zero", "JSON numbers cannot contain leading zeroes.", at: index)
                }
            } else {
                guard index < bytes.count, (0x31...0x39).contains(bytes[index]) else {
                    return fail("json.invalid-number", "Expected a digit in the JSON number.", at: index, length: index < bytes.count ? 1 : 0)
                }
                while index < bytes.count, SyntaxByteUtilities.isDigit(bytes[index]) { index += 1 }
            }
            if consume(0x2E) {
                guard index < bytes.count, SyntaxByteUtilities.isDigit(bytes[index]) else {
                    return fail("json.invalid-fraction", "A decimal point must be followed by at least one digit.", at: index, length: index < bytes.count ? 1 : 0)
                }
                while index < bytes.count, SyntaxByteUtilities.isDigit(bytes[index]) { index += 1 }
            }
            if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
                index += 1
                if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
                guard index < bytes.count, SyntaxByteUtilities.isDigit(bytes[index]) else {
                    return fail("json.invalid-exponent", "A number exponent must contain at least one digit.", at: index, length: index < bytes.count ? 1 : 0)
                }
                while index < bytes.count, SyntaxByteUtilities.isDigit(bytes[index]) { index += 1 }
            }
            return true
        }

        mutating func consumeLiteral(_ literal: String) -> Bool {
            let start = index
            guard SyntaxByteUtilities.hasASCII(bytes, at: index, literal) else {
                return fail("json.invalid-literal", "Invalid JSON literal.", at: start)
            }
            index += literal.utf8.count
            if index < bytes.count, SyntaxByteUtilities.isIdentifierContinue(bytes[index]) {
                return fail("json.invalid-literal", "Unexpected character after JSON literal.", at: index)
            }
            return true
        }

        func readHexQuad(at start: Int) -> UInt16? {
            guard start + 4 <= bytes.count else { return nil }
            var value: UInt16 = 0
            for offset in 0..<4 {
                let byte = bytes[start + offset]
                let digit: UInt16
                switch byte {
                case 0x30...0x39: digit = UInt16(byte - 0x30)
                case 0x41...0x46: digit = UInt16(byte - 0x41 + 10)
                case 0x61...0x66: digit = UInt16(byte - 0x61 + 10)
                default: return nil
                }
                value = value * 16 + digit
            }
            return value
        }

        mutating func skipWhitespace() {
            while index < bytes.count, SyntaxByteUtilities.isWhitespace(bytes[index]) { index += 1 }
        }

        mutating func consume(_ byte: UInt8) -> Bool {
            guard index < bytes.count, bytes[index] == byte else { return false }
            index += 1
            return true
        }

        @discardableResult
        mutating func fail(_ code: String, _ message: String, at offset: Int, length: Int = 1) -> Bool {
            collector.append(.error, code, message, at: offset, length: max(0, length))
            return false
        }
    }

    // MARK: - XML

    private struct XMLValidator {
        struct OpenElement {
            let name: Range<Int>
            let opening: Int
        }

        let bytes: UnsafeBufferPointer<UInt8>
        let limits: SyntaxLimits
        var collector: SyntaxDiagnosticCollector
        var stack: [OpenElement] = []
        var overflowDepth = 0
        var rootCount = 0
        var rootClosed = false

        init(bytes: UnsafeBufferPointer<UInt8>, baseByteOffset: Int, limits: SyntaxLimits) {
            self.bytes = bytes
            self.limits = limits
            collector = SyntaxDiagnosticCollector(
                baseOffset: baseByteOffset, maximumCount: limits.maximumDiagnostics
            )
            stack.reserveCapacity(min(limits.maximumNestingDepth, 64))
        }

        mutating func validate() -> [SyntaxDiagnostic] {
            var index = 0
            if bytes.count >= 3,
               bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { index = 3 }
            while index < bytes.count, !collector.isFull {
                if bytes[index] != 0x3C {
                    if bytes[index] == 0x26 {
                        index = validateEntity(from: index)
                    } else {
                        if stack.isEmpty, !SyntaxByteUtilities.isWhitespace(bytes[index]) {
                            collector.append(
                                .error, "xml.text-outside-root",
                                "Non-whitespace text is not allowed outside the root element.", at: index
                            )
                        }
                        let length = SyntaxByteUtilities.isValidUTF8Sequence(bytes, at: index)
                        if length == 0 {
                            collector.append(.error, "encoding.invalid-utf8", "Invalid UTF-8 byte sequence.", at: index)
                            index += 1
                        } else {
                            index += length
                        }
                    }
                    continue
                }

                if SyntaxByteUtilities.hasASCII(bytes, at: index, "<!--") {
                    index = validateComment(from: index)
                } else if SyntaxByteUtilities.hasASCII(bytes, at: index, "<![CDATA[") {
                    guard let end = findASCII("]]>", from: index + 9) else {
                        collector.append(.error, "xml.unclosed-cdata", "CDATA section is missing ']]>'.", at: index, length: 9)
                        break
                    }
                    index = end + 3
                } else if SyntaxByteUtilities.hasASCII(bytes, at: index, "<?") {
                    guard let end = findASCII("?>", from: index + 2) else {
                        collector.append(.error, "xml.unclosed-processing-instruction", "Processing instruction is missing '?>'.", at: index, length: 2)
                        break
                    }
                    index = end + 2
                } else if SyntaxByteUtilities.hasASCII(bytes, at: index, "<!") {
                    let end = declarationEnd(from: index + 2)
                    if end == bytes.count, bytes.last != 0x3E {
                        collector.append(.error, "xml.unclosed-declaration", "Markup declaration is missing '>'.", at: index, length: 2)
                        break
                    }
                    index = end
                } else if index + 1 < bytes.count, bytes[index + 1] == 0x2F {
                    index = validateClosingTag(from: index)
                } else {
                    index = validateOpeningTag(from: index)
                }
            }

            if !stack.isEmpty, !collector.isFull {
                for element in stack.reversed() where !collector.isFull {
                    collector.append(.error, "xml.unclosed-element", "Element is missing a closing tag.", at: element.opening)
                }
            }
            if rootCount == 0, !collector.isFull {
                collector.append(.error, "xml.missing-root", "An XML document must contain one root element.", at: bytes.count, length: 0)
            }
            return collector.diagnostics
        }

        mutating func validateOpeningTag(from opening: Int) -> Int {
            var index = opening + 1
            guard let name = parseName(at: &index) else {
                collector.append(.error, "xml.expected-element-name", "Expected an element name after '<'.", at: min(index, bytes.count), length: index < bytes.count ? 1 : 0)
                return min(bytes.count, opening + 1)
            }
            if stack.isEmpty {
                rootCount += 1
                if rootCount > 1 || rootClosed {
                    collector.append(.error, "xml.multiple-roots", "An XML document can contain only one root element.", at: opening)
                }
            }

            while index < bytes.count {
                skipSpaces(&index)
                guard index < bytes.count else {
                    collector.append(.error, "xml.unclosed-start-tag", "Start tag is missing '>'.", at: opening)
                    return bytes.count
                }
                if bytes[index] == 0x3E {
                    push(name: name, opening: opening)
                    return index + 1
                }
                if bytes[index] == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x3E {
                    if stack.isEmpty { rootClosed = true }
                    return index + 2
                }
                let attributeStart = index
                guard parseName(at: &index) != nil else {
                    collector.append(.error, "xml.invalid-attribute", "Expected an attribute name, '/>', or '>'.", at: attributeStart)
                    return recoverTagEnd(from: index)
                }
                skipSpaces(&index)
                guard index < bytes.count, bytes[index] == 0x3D else {
                    collector.append(.error, "xml.expected-equals", "Expected '=' after the attribute name.", at: index, length: index < bytes.count ? 1 : 0)
                    return recoverTagEnd(from: index)
                }
                index += 1
                skipSpaces(&index)
                guard index < bytes.count, bytes[index] == 0x22 || bytes[index] == 0x27 else {
                    collector.append(.error, "xml.expected-attribute-quote", "XML attribute values must be quoted.", at: index, length: index < bytes.count ? 1 : 0)
                    return recoverTagEnd(from: index)
                }
                let quote = bytes[index]
                let quoteStart = index
                index += 1
                while index < bytes.count, bytes[index] != quote {
                    if bytes[index] == 0x3C {
                        collector.append(.error, "xml.less-than-in-attribute", "Attribute values cannot contain an unescaped '<'.", at: index)
                    }
                    index += 1
                }
                guard index < bytes.count else {
                    collector.append(.error, "xml.unclosed-attribute", "Attribute value is missing its closing quote.", at: quoteStart)
                    return bytes.count
                }
                index += 1
            }
            return bytes.count
        }

        mutating func validateClosingTag(from opening: Int) -> Int {
            var index = opening + 2
            guard let name = parseName(at: &index) else {
                collector.append(.error, "xml.expected-closing-name", "Expected an element name after '</'.", at: min(index, bytes.count), length: index < bytes.count ? 1 : 0)
                return recoverTagEnd(from: index)
            }
            skipSpaces(&index)
            guard index < bytes.count, bytes[index] == 0x3E else {
                collector.append(.error, "xml.invalid-closing-tag", "Closing tag must end with '>'.", at: index, length: index < bytes.count ? 1 : 0)
                return recoverTagEnd(from: index)
            }
            index += 1
            if overflowDepth > 0 {
                overflowDepth -= 1
            } else if let element = stack.popLast() {
                if !SyntaxByteUtilities.matchingASCII(bytes, lhs: element.name, rhs: name) {
                    collector.append(.error, "xml.mismatched-closing-tag", "Closing tag does not match the open element.", at: name.lowerBound, length: name.count)
                }
                if stack.isEmpty { rootClosed = true }
            } else {
                collector.append(.error, "xml.unexpected-closing-tag", "Closing tag has no matching open element.", at: opening, length: index - opening)
            }
            return index
        }

        mutating func push(name: Range<Int>, opening: Int) {
            if stack.count < limits.maximumNestingDepth {
                stack.append(OpenElement(name: name, opening: opening))
            } else {
                if overflowDepth == 0 {
                    collector.append(.error, "xml.depth-limit", "XML nesting exceeds the configured safety limit.", at: opening)
                }
                overflowDepth += 1
            }
        }

        mutating func validateComment(from opening: Int) -> Int {
            var index = opening + 4
            while index + 2 < bytes.count {
                if bytes[index] == 0x2D, bytes[index + 1] == 0x2D {
                    if bytes[index + 2] == 0x3E { return index + 3 }
                    collector.append(.error, "xml.double-hyphen-in-comment", "XML comments cannot contain '--'.", at: index, length: 2)
                }
                index += 1
            }
            collector.append(.error, "xml.unclosed-comment", "XML comment is missing '-->'.", at: opening, length: 4)
            return bytes.count
        }

        mutating func validateEntity(from opening: Int) -> Int {
            var index = opening + 1
            let limit = min(bytes.count, opening + limits.maximumTokenBytes)
            guard index < limit else {
                collector.append(.error, "xml.unclosed-entity", "Entity reference is missing ';'.", at: opening)
                return min(bytes.count, opening + 1)
            }

            if bytes[index] == 0x23 { // numeric character reference
                index += 1
                var hexadecimal = false
                if index < limit, bytes[index] == 0x78 || bytes[index] == 0x58 {
                    hexadecimal = true
                    index += 1
                }
                let digitStart = index
                while index < limit,
                      hexadecimal
                        ? SyntaxByteUtilities.isHexDigit(bytes[index])
                        : SyntaxByteUtilities.isDigit(bytes[index]) {
                    index += 1
                }
                guard index > digitStart else {
                    collector.append(.error, "xml.invalid-entity", "Numeric entity reference must contain digits.", at: opening, length: max(1, index - opening))
                    return max(opening + 1, index)
                }
            } else {
                guard isXMLNameStart(bytes[index]) else {
                    collector.append(.error, "xml.invalid-entity", "Entity reference must contain a valid name or numeric value.", at: opening, length: min(2, bytes.count - opening))
                    return max(opening + 1, index + 1)
                }
                index += 1
                while index < limit, isXMLNameByte(bytes[index]) { index += 1 }
            }

            if index < limit, bytes[index] == 0x3B { return index + 1 }
            if index - opening >= limits.maximumTokenBytes {
                collector.append(.error, "xml.entity-too-long", "Entity reference exceeds the configured token limit.", at: opening, length: index - opening)
            } else {
                collector.append(.error, "xml.unclosed-entity", "Entity reference is missing ';'.", at: opening, length: max(1, index - opening))
            }
            return max(opening + 1, index)
        }

        func parseName(at index: inout Int) -> Range<Int>? {
            guard index < bytes.count, isXMLNameStart(bytes[index]) else { return nil }
            let start = index
            index += 1
            while index < bytes.count, isXMLNameByte(bytes[index]) { index += 1 }
            return start..<index
        }

        func skipSpaces(_ index: inout Int) {
            while index < bytes.count, SyntaxByteUtilities.isWhitespace(bytes[index]) { index += 1 }
        }

        func recoverTagEnd(from start: Int) -> Int {
            var index = start
            while index < bytes.count {
                if bytes[index] == 0x3E { return index + 1 }
                index += 1
            }
            return bytes.count
        }

        func declarationEnd(from start: Int) -> Int {
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

        func findASCII(_ text: String, from start: Int) -> Int? {
            let count = text.utf8.count
            guard count > 0, count <= bytes.count else { return nil }
            var index = start
            let last = bytes.count - count
            while index <= last {
                if SyntaxByteUtilities.hasASCII(bytes, at: index, text) { return index }
                index += 1
            }
            return nil
        }

        func isXMLNameStart(_ byte: UInt8) -> Bool {
            SyntaxByteUtilities.isIdentifierStart(byte) || byte == 0x3A
        }

        func isXMLNameByte(_ byte: UInt8) -> Bool {
            isXMLNameStart(byte) || SyntaxByteUtilities.isDigit(byte) || byte == 0x2D || byte == 0x2E
        }
    }

    // MARK: - YAML

    private static func yamlDiagnostics(
        _ bytes: UnsafeBufferPointer<UInt8>,
        baseByteOffset: Int,
        limits: SyntaxLimits
    ) -> [SyntaxDiagnostic] {
        struct FlowEntry { let byte: UInt8; let offset: Int }
        var collector = SyntaxDiagnosticCollector(
            baseOffset: baseByteOffset, maximumCount: limits.maximumDiagnostics
        )
        var flow: [FlowEntry] = []
        flow.reserveCapacity(min(limits.maximumNestingDepth, 32))
        var overflowDepth = 0
        var quote: UInt8?
        var quoteStart = 0
        var escaped = false
        var blockScalarParentIndent: Int?
        var lineStart = 0

        while lineStart < bytes.count, !collector.isFull {
            let lineEnd = SyntaxByteUtilities.lineEnd(bytes, from: lineStart)
            var content = lineStart
            var indentation = 0
            while content < lineEnd, bytes[content] == 0x20 {
                indentation += 1
                content += 1
            }
            if content < lineEnd, bytes[content] == 0x09 {
                collector.append(.error, "yaml.tab-indentation", "YAML indentation cannot use tab characters.", at: content)
                while content < lineEnd, bytes[content] == 0x09 { content += 1 }
            }
            if let parent = blockScalarParentIndent {
                if content == lineEnd || indentation > parent {
                    lineStart = SyntaxByteUtilities.nextLineStart(bytes, after: lineEnd)
                    continue
                }
                blockScalarParentIndent = nil
            }

            if quote == nil, content < lineEnd, bytes[content] == 0x3A,
               content + 1 == lineEnd || SyntaxByteUtilities.isWhitespace(bytes[content + 1]) {
                collector.append(.error, "yaml.missing-key", "Mapping entry is missing a key before ':'.", at: content)
            }

            var index = content
            var commentStart: Int?
            while index < lineEnd, !collector.isFull {
                let byte = bytes[index]
                if let active = quote {
                    if active == 0x22 {
                        if escaped {
                            if !isValidYAMLEscape(byte) {
                                collector.append(.error, "yaml.invalid-escape", "Invalid escape in double-quoted YAML scalar.", at: index - 1, length: 2)
                            }
                            escaped = false
                        } else if byte == 0x5C {
                            escaped = true
                        } else if byte == active {
                            quote = nil
                        }
                    } else if byte == active {
                        if index + 1 < lineEnd, bytes[index + 1] == active {
                            index += 1
                        } else {
                            quote = nil
                        }
                    }
                    index += 1
                    continue
                }

                if byte == 0x23, index == content || SyntaxByteUtilities.isSpace(bytes[index - 1]) {
                    commentStart = index
                    break
                }
                if (byte == 0x22 || byte == 0x27), yamlQuoteCanStart(bytes, at: index, lineStart: content) {
                    quote = byte
                    quoteStart = index
                    escaped = false
                } else if byte == 0x5B || byte == 0x7B {
                    if flow.count < limits.maximumNestingDepth {
                        flow.append(FlowEntry(byte: byte, offset: index))
                    } else {
                        if overflowDepth == 0 {
                            collector.append(.error, "yaml.depth-limit", "YAML flow nesting exceeds the configured safety limit.", at: index)
                        }
                        overflowDepth += 1
                    }
                } else if byte == 0x5D || byte == 0x7D {
                    if overflowDepth > 0 {
                        overflowDepth -= 1
                    } else if let entry = flow.popLast() {
                        let expected: UInt8 = entry.byte == 0x5B ? 0x5D : 0x7D
                        if byte != expected {
                            collector.append(.error, "yaml.mismatched-flow-delimiter", "Mismatched YAML flow collection delimiter.", at: index)
                        }
                    } else {
                        collector.append(.error, "yaml.unexpected-flow-close", "Flow collection closing delimiter has no opener.", at: index)
                    }
                }
                index += 1
            }

            let syntaxEnd = commentStart ?? lineEnd
            if quote == nil, yamlLineEndsInBlockScalar(bytes, from: content, to: syntaxEnd) {
                blockScalarParentIndent = indentation
            }
            lineStart = SyntaxByteUtilities.nextLineStart(bytes, after: lineEnd)
        }

        if let active = quote, !collector.isFull {
            let name = active == 0x22 ? "double" : "single"
            collector.append(.error, "yaml.unclosed-quote", "Unclosed \(name)-quoted YAML scalar.", at: quoteStart)
        }
        for entry in flow.reversed() where !collector.isFull {
            collector.append(.error, "yaml.unclosed-flow-collection", "YAML flow collection is missing its closing delimiter.", at: entry.offset)
        }
        return collector.diagnostics
    }

    private static func yamlQuoteCanStart(
        _ bytes: UnsafeBufferPointer<UInt8>, at index: Int, lineStart: Int
    ) -> Bool {
        guard index > lineStart else { return true }
        let previous = bytes[index - 1]
        if SyntaxByteUtilities.isWhitespace(previous) { return true }
        switch previous {
        case 0x3A, 0x2D, 0x3F, 0x2C, 0x5B, 0x7B: return true
        default: return false
        }
    }

    private static func isValidYAMLEscape(_ byte: UInt8) -> Bool {
        switch byte {
        case 0x30, 0x61, 0x62, 0x74, 0x6E, 0x76, 0x66, 0x72, 0x65, 0x20,
             0x22, 0x2F, 0x5C, 0x4E, 0x5F, 0x4C, 0x50, 0x78, 0x75, 0x55:
            return true
        default:
            return false
        }
    }

    private static func yamlLineEndsInBlockScalar(
        _ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int
    ) -> Bool {
        var upper = end
        while upper > start, SyntaxByteUtilities.isSpace(bytes[upper - 1]) { upper -= 1 }
        if upper > start, bytes[upper - 1] == 0x2B || bytes[upper - 1] == 0x2D { upper -= 1 }
        if upper > start, SyntaxByteUtilities.isDigit(bytes[upper - 1]) { upper -= 1 }
        return upper > start && (bytes[upper - 1] == 0x7C || bytes[upper - 1] == 0x3E)
    }

    // MARK: - CSV

    private static func csvDiagnostics(
        _ bytes: UnsafeBufferPointer<UInt8>,
        baseByteOffset: Int,
        limits: SyntaxLimits
    ) -> [SyntaxDiagnostic] {
        enum FieldState { case start, unquoted, quoted, afterQuote }
        var collector = SyntaxDiagnosticCollector(
            baseOffset: baseByteOffset, maximumCount: limits.maximumDiagnostics
        )
        var state = FieldState.start
        var fieldCount = 1
        var expectedFieldCount: Int?
        var recordStart = 0
        var recordHasData = false
        var quoteStart = 0
        var index = 0

        func finishRecord(at end: Int, collector: inout SyntaxDiagnosticCollector) {
            guard recordHasData else { return }
            if let expected = expectedFieldCount {
                if fieldCount != expected {
                    collector.append(
                        .error, "csv.inconsistent-columns",
                        "CSV record has \(fieldCount) fields; expected \(expected).",
                        at: recordStart, length: max(0, end - recordStart)
                    )
                }
            } else {
                expectedFieldCount = fieldCount
            }
        }

        while index < bytes.count {
            let byte = bytes[index]
            switch state {
            case .quoted:
                if byte == 0x22 {
                    if index + 1 < bytes.count, bytes[index + 1] == 0x22 {
                        index += 2
                        continue
                    }
                    state = .afterQuote
                }
                index += 1
            case .afterQuote:
                if byte == limits.csvDelimiter {
                    fieldCount += 1
                    state = .start
                    recordHasData = true
                    index += 1
                } else if SyntaxByteUtilities.isLineBreak(byte) {
                    finishRecord(at: index, collector: &collector)
                    index = consumeLineBreak(bytes, at: index)
                    state = .start
                    fieldCount = 1
                    recordStart = index
                    recordHasData = false
                } else if SyntaxByteUtilities.isSpace(byte) {
                    index += 1
                } else {
                    collector.append(.error, "csv.content-after-quote", "Only a delimiter or line break may follow a quoted field.", at: index)
                    state = .unquoted
                    recordHasData = true
                    index += 1
                }
            case .start:
                if byte == limits.csvDelimiter {
                    fieldCount += 1
                    recordHasData = true
                    index += 1
                } else if SyntaxByteUtilities.isLineBreak(byte) {
                    finishRecord(at: index, collector: &collector)
                    index = consumeLineBreak(bytes, at: index)
                    fieldCount = 1
                    recordStart = index
                    recordHasData = false
                } else if byte == 0x22 {
                    quoteStart = index
                    state = .quoted
                    recordHasData = true
                    index += 1
                } else {
                    state = .unquoted
                    if !SyntaxByteUtilities.isSpace(byte) { recordHasData = true }
                    index += 1
                }
            case .unquoted:
                if byte == limits.csvDelimiter {
                    fieldCount += 1
                    state = .start
                    recordHasData = true
                    index += 1
                } else if SyntaxByteUtilities.isLineBreak(byte) {
                    finishRecord(at: index, collector: &collector)
                    index = consumeLineBreak(bytes, at: index)
                    state = .start
                    fieldCount = 1
                    recordStart = index
                    recordHasData = false
                } else {
                    if byte == 0x22 {
                        collector.append(.error, "csv.quote-in-unquoted-field", "Quote appears inside an unquoted CSV field.", at: index)
                    }
                    if !SyntaxByteUtilities.isSpace(byte) { recordHasData = true }
                    index += 1
                }
            }
        }
        if state == .quoted {
            collector.append(.error, "csv.unclosed-quote", "Quoted CSV field is missing its closing quote.", at: quoteStart)
        }
        finishRecord(at: bytes.count, collector: &collector)
        return collector.diagnostics
    }

    // MARK: - SQL

    private static func sqlDiagnostics(
        _ bytes: UnsafeBufferPointer<UInt8>,
        baseByteOffset: Int,
        limits: SyntaxLimits
    ) -> [SyntaxDiagnostic] {
        var collector = SyntaxDiagnosticCollector(
            baseOffset: baseByteOffset, maximumCount: limits.maximumDiagnostics
        )
        var parentheses: [Int] = []
        parentheses.reserveCapacity(min(limits.maximumNestingDepth, 64))
        var overflowDepth = 0
        var index = 0

        while index < bytes.count, !collector.isFull {
            let byte = bytes[index]
            if byte == 0x2D, index + 1 < bytes.count, bytes[index + 1] == 0x2D {
                index += 2
                while index < bytes.count, !SyntaxByteUtilities.isLineBreak(bytes[index]) { index += 1 }
            } else if byte == 0x2F, index + 1 < bytes.count, bytes[index + 1] == 0x2A {
                let opening = index
                index += 2
                var depth = 1
                while index < bytes.count, depth > 0 {
                    if index + 1 < bytes.count, bytes[index] == 0x2F, bytes[index + 1] == 0x2A {
                        depth += 1; index += 2
                    } else if index + 1 < bytes.count, bytes[index] == 0x2A, bytes[index + 1] == 0x2F {
                        depth -= 1; index += 2
                    } else {
                        index += 1
                    }
                }
                if depth > 0 {
                    collector.append(.error, "sql.unclosed-comment", "Block comment is missing '*/'.", at: opening, length: 2)
                }
            } else if byte == 0x27 || byte == 0x22 || byte == 0x60 {
                let opening = index
                let delimiter = byte
                index += 1
                var closed = false
                while index < bytes.count {
                    if bytes[index] == delimiter {
                        if index + 1 < bytes.count, bytes[index + 1] == delimiter {
                            index += 2
                            continue
                        }
                        index += 1
                        closed = true
                        break
                    }
                    if bytes[index] == 0x5C, index + 1 < bytes.count { index += 2 }
                    else { index += 1 }
                }
                if !closed {
                    collector.append(.error, "sql.unclosed-quote", "Quoted SQL token is missing its closing delimiter.", at: opening)
                }
            } else if byte == 0x5B {
                let opening = index
                index += 1
                var closed = false
                while index < bytes.count {
                    if bytes[index] == 0x5D {
                        if index + 1 < bytes.count, bytes[index + 1] == 0x5D { index += 2; continue }
                        index += 1; closed = true; break
                    }
                    index += 1
                }
                if !closed {
                    collector.append(.error, "sql.unclosed-identifier", "Bracketed SQL identifier is missing ']'.", at: opening)
                }
            } else if byte == 0x24, let delimiter = sqlDollarDelimiter(bytes, from: index) {
                let opening = index
                if let close = findRange(bytes, needle: delimiter, from: delimiter.upperBound) {
                    index = close + delimiter.count
                } else {
                    collector.append(.error, "sql.unclosed-dollar-quote", "Dollar-quoted SQL string is missing its closing delimiter.", at: opening, length: delimiter.count)
                    index = bytes.count
                }
            } else if byte == 0x28 {
                if parentheses.count < limits.maximumNestingDepth {
                    parentheses.append(index)
                } else {
                    if overflowDepth == 0 {
                        collector.append(.error, "sql.depth-limit", "Parenthesis nesting exceeds the configured safety limit.", at: index)
                    }
                    overflowDepth += 1
                }
                index += 1
            } else if byte == 0x29 {
                if overflowDepth > 0 { overflowDepth -= 1 }
                else if parentheses.popLast() == nil {
                    collector.append(.error, "sql.unexpected-close-paren", "Closing parenthesis has no matching opener.", at: index)
                }
                index += 1
            } else {
                index += 1
            }
        }
        for opening in parentheses.reversed() where !collector.isFull {
            collector.append(.error, "sql.unclosed-parenthesis", "Opening parenthesis has no matching ')'.", at: opening)
        }
        return collector.diagnostics
    }

    // MARK: - Markdown

    private static func markdownDiagnostics(
        _ bytes: UnsafeBufferPointer<UInt8>,
        baseByteOffset: Int,
        limits: SyntaxLimits
    ) -> [SyntaxDiagnostic] {
        var collector = SyntaxDiagnosticCollector(
            baseOffset: baseByteOffset, maximumCount: limits.maximumDiagnostics
        )
        var fence: (marker: UInt8, count: Int, opening: Int)?
        var lineStart = 0
        var commentThrough = 0
        var index = 0
        while index < bytes.count, !collector.isFull {
            if bytes[index] == 0 {
                collector.append(.error, "markdown.nul-byte", "NUL bytes are not valid Markdown text.", at: index)
                index += 1
            } else {
                let length = SyntaxByteUtilities.isValidUTF8Sequence(bytes, at: index)
                if length == 0 {
                    collector.append(.error, "encoding.invalid-utf8", "Invalid UTF-8 byte sequence.", at: index)
                    index += 1
                } else {
                    index += length
                }
            }
        }

        while lineStart < bytes.count, !collector.isFull {
            let lineEnd = SyntaxByteUtilities.lineEnd(bytes, from: lineStart)
            if lineStart < commentThrough {
                lineStart = SyntaxByteUtilities.nextLineStart(bytes, after: lineEnd)
                continue
            }
            var content = lineStart
            var spaces = 0
            while content < lineEnd, bytes[content] == 0x20, spaces < 4 { content += 1; spaces += 1 }
            if spaces <= 3, content < lineEnd,
               bytes[content] == 0x60 || bytes[content] == 0x7E {
                let marker = bytes[content]
                var end = content
                while end < lineEnd, bytes[end] == marker { end += 1 }
                let count = end - content
                if count >= 3 {
                    if let open = fence {
                        if marker == open.marker, count >= open.count,
                           markdownOnlySpaces(bytes, from: end, to: lineEnd) { fence = nil }
                    } else {
                        fence = (marker, count, content)
                    }
                }
            } else if fence == nil, lineStart >= commentThrough,
                      let commentOpening = markdownHTMLCommentStart(
                        bytes, from: lineStart, to: lineEnd
                      ) {
                if let close = findASCII(bytes, "-->", from: commentOpening + 4) {
                    commentThrough = close + 3
                } else {
                    collector.append(
                        .warning, "markdown.unclosed-html-comment",
                        "HTML comment is missing '-->'.", at: commentOpening, length: 4
                    )
                    break
                }
            }
            lineStart = SyntaxByteUtilities.nextLineStart(bytes, after: lineEnd)
        }
        if let fence, !collector.isFull {
            collector.append(
                .information, "markdown.open-fence",
                "Fenced code block reaches end of file without an explicit closing fence.",
                at: fence.opening, length: fence.count
            )
        }
        return collector.diagnostics
    }

    // MARK: - Shared diagnostic helpers

    private static func consumeLineBreak(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Int {
        if bytes[index] == 0x0D, index + 1 < bytes.count, bytes[index + 1] == 0x0A { return index + 2 }
        return index + 1
    }

    private static func sqlDollarDelimiter(
        _ bytes: UnsafeBufferPointer<UInt8>, from start: Int
    ) -> Range<Int>? {
        guard start < bytes.count, bytes[start] == 0x24 else { return nil }
        var index = start + 1
        while index < bytes.count, index - start <= 65 {
            if bytes[index] == 0x24 { return start..<(index + 1) }
            if !SyntaxByteUtilities.isASCIIAlpha(bytes[index]),
               !SyntaxByteUtilities.isDigit(bytes[index]), bytes[index] != 0x5F { return nil }
            index += 1
        }
        return nil
    }

    private static func findRange(
        _ bytes: UnsafeBufferPointer<UInt8>, needle: Range<Int>, from start: Int
    ) -> Int? {
        guard !needle.isEmpty, needle.upperBound <= bytes.count else { return nil }
        var index = start
        while index + needle.count <= bytes.count {
            var matches = true
            for offset in 0..<needle.count where bytes[index + offset] != bytes[needle.lowerBound + offset] {
                matches = false
                break
            }
            if matches { return index }
            index += 1
        }
        return nil
    }

    private static func findASCII(
        _ bytes: UnsafeBufferPointer<UInt8>, _ text: String, from start: Int
    ) -> Int? {
        let count = text.utf8.count
        guard count > 0, count <= bytes.count else { return nil }
        var index = start
        let last = bytes.count - count
        while index <= last {
            if SyntaxByteUtilities.hasASCII(bytes, at: index, text) { return index }
            index += 1
        }
        return nil
    }

    private static func markdownOnlySpaces(
        _ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int
    ) -> Bool {
        guard start <= end else { return false }
        for index in start..<end where !SyntaxByteUtilities.isSpace(bytes[index]) { return false }
        return true
    }

    private static func markdownHTMLCommentStart(
        _ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int
    ) -> Int? {
        var codeDelimiterLength = 0
        var index = start
        while index < end {
            if bytes[index] == 0x60 {
                var runEnd = index + 1
                while runEnd < end, bytes[runEnd] == 0x60 { runEnd += 1 }
                let runLength = runEnd - index
                if codeDelimiterLength == 0 { codeDelimiterLength = runLength }
                else if runLength == codeDelimiterLength { codeDelimiterLength = 0 }
                index = runEnd
            } else if codeDelimiterLength == 0,
                      SyntaxByteUtilities.hasASCII(bytes, at: index, "<!--") {
                return index
            } else {
                index += 1
            }
        }
        return nil
    }
}
