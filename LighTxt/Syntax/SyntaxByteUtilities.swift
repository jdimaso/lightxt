import Foundation

@usableFromInline
enum SyntaxByteUtilities {
    @inline(__always)
    static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09
    }

    @inline(__always)
    static func isWhitespace(_ byte: UInt8) -> Bool {
        isSpace(byte) || byte == 0x0A || byte == 0x0D
    }

    @inline(__always)
    static func isLineBreak(_ byte: UInt8) -> Bool {
        byte == 0x0A || byte == 0x0D
    }

    @inline(__always)
    static func isDigit(_ byte: UInt8) -> Bool {
        byte >= 0x30 && byte <= 0x39
    }

    @inline(__always)
    static func isHexDigit(_ byte: UInt8) -> Bool {
        isDigit(byte) || (byte >= 0x41 && byte <= 0x46) || (byte >= 0x61 && byte <= 0x66)
    }

    @inline(__always)
    static func isASCIIAlpha(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }

    @inline(__always)
    static func isIdentifierStart(_ byte: UInt8) -> Bool {
        isASCIIAlpha(byte) || byte == 0x5F || byte >= 0x80
    }

    @inline(__always)
    static func isIdentifierContinue(_ byte: UInt8) -> Bool {
        isIdentifierStart(byte) || isDigit(byte) || byte == 0x2D || byte == 0x24
    }

    @inline(__always)
    static func asciiLowercased(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte &+ 0x20 : byte
    }

    static func equalsASCII(
        _ bytes: UnsafeBufferPointer<UInt8>,
        from start: Int,
        to end: Int,
        _ text: String,
        caseInsensitive: Bool = false
    ) -> Bool {
        guard start >= 0, end >= start, end <= bytes.count else { return false }
        let utf8 = text.utf8
        guard end - start == utf8.count else { return false }
        var index = start
        for expected in utf8 {
            let actual = bytes[index]
            if caseInsensitive {
                guard asciiLowercased(actual) == asciiLowercased(expected) else { return false }
            } else if actual != expected {
                return false
            }
            index += 1
        }
        return true
    }

    static func hasASCII(
        _ bytes: UnsafeBufferPointer<UInt8>,
        at start: Int,
        _ text: String,
        caseInsensitive: Bool = false
    ) -> Bool {
        equalsASCII(bytes, from: start, to: start + text.utf8.count, text, caseInsensitive: caseInsensitive)
    }

    static func firstNonWhitespace(
        _ bytes: UnsafeBufferPointer<UInt8>,
        from initial: Int = 0,
        limit: Int? = nil
    ) -> Int? {
        var index = max(0, initial)
        let end = min(bytes.count, limit ?? bytes.count)
        if index == 0, end >= 3,
           bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            index = 3
        }
        while index < end {
            if !isWhitespace(bytes[index]) { return index }
            index += 1
        }
        return nil
    }

    static func lineEnd(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int {
        var index = start
        while index < bytes.count, !isLineBreak(bytes[index]) { index += 1 }
        return index
    }

    static func nextLineStart(_ bytes: UnsafeBufferPointer<UInt8>, after lineEnd: Int) -> Int {
        guard lineEnd < bytes.count else { return bytes.count }
        if bytes[lineEnd] == 0x0D, lineEnd + 1 < bytes.count, bytes[lineEnd + 1] == 0x0A {
            return lineEnd + 2
        }
        return lineEnd + 1
    }

    static func containsLineBreak(
        _ bytes: UnsafeBufferPointer<UInt8>,
        from start: Int,
        to end: Int
    ) -> Bool {
        var index = max(0, start)
        let upper = min(bytes.count, end)
        while index < upper {
            if isLineBreak(bytes[index]) { return true }
            index += 1
        }
        return false
    }

    static func matchingASCII(
        _ bytes: UnsafeBufferPointer<UInt8>,
        lhs: Range<Int>,
        rhs: Range<Int>
    ) -> Bool {
        guard lhs.count == rhs.count,
              lhs.lowerBound >= 0, rhs.lowerBound >= 0,
              lhs.upperBound <= bytes.count, rhs.upperBound <= bytes.count else { return false }
        for offset in 0..<lhs.count where bytes[lhs.lowerBound + offset] != bytes[rhs.lowerBound + offset] {
            return false
        }
        return true
    }

    static func isValidUTF8Sequence(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> Int {
        guard index < bytes.count else { return 0 }
        let first = bytes[index]
        if first < 0x80 { return 1 }

        let length: Int
        let minimumSecond: UInt8
        let maximumSecond: UInt8
        switch first {
        case 0xC2...0xDF:
            length = 2; minimumSecond = 0x80; maximumSecond = 0xBF
        case 0xE0:
            length = 3; minimumSecond = 0xA0; maximumSecond = 0xBF
        case 0xE1...0xEC, 0xEE...0xEF:
            length = 3; minimumSecond = 0x80; maximumSecond = 0xBF
        case 0xED:
            length = 3; minimumSecond = 0x80; maximumSecond = 0x9F
        case 0xF0:
            length = 4; minimumSecond = 0x90; maximumSecond = 0xBF
        case 0xF1...0xF3:
            length = 4; minimumSecond = 0x80; maximumSecond = 0xBF
        case 0xF4:
            length = 4; minimumSecond = 0x80; maximumSecond = 0x8F
        default:
            return 0
        }
        guard index + length <= bytes.count else { return 0 }
        guard bytes[index + 1] >= minimumSecond, bytes[index + 1] <= maximumSecond else { return 0 }
        if length > 2 {
            for continuation in (index + 2)..<(index + length) where !(0x80...0xBF).contains(bytes[continuation]) {
                return 0
            }
        }
        return length
    }

    @inline(__always)
    static func absoluteOffset(_ local: Int, base: Int) -> Int {
        let (result, overflow) = max(0, base).addingReportingOverflow(max(0, local))
        return overflow ? Int.max : result
    }
}

@usableFromInline
struct SyntaxSpanCollector {
    let baseOffset: Int
    let maximumCount: Int
    private(set) var spans: [SyntaxSpan] = []
    private(set) var wasTruncated = false

    init(baseOffset: Int, maximumCount: Int) {
        self.baseOffset = max(0, baseOffset)
        self.maximumCount = max(0, maximumCount)
        spans.reserveCapacity(min(maximumCount, 1_024))
    }

    mutating func append(_ start: Int, _ end: Int, _ kind: SyntaxSemanticKind) {
        guard end > start else { return }
        guard spans.count < maximumCount else {
            wasTruncated = true
            return
        }
        let absoluteStart = SyntaxByteUtilities.absoluteOffset(start, base: baseOffset)
        let length = end - start
        if let previous = spans.last,
           previous.kind == kind,
           previous.range.end == absoluteStart {
            spans[spans.count - 1] = SyntaxSpan(
                range: SyntaxByteRange(start: previous.range.start, length: previous.range.length + length),
                kind: kind
            )
        } else {
            spans.append(SyntaxSpan(range: SyntaxByteRange(start: absoluteStart, length: length), kind: kind))
        }
    }
}

@usableFromInline
struct SyntaxDiagnosticCollector {
    let baseOffset: Int
    let maximumCount: Int
    private(set) var diagnostics: [SyntaxDiagnostic] = []

    init(baseOffset: Int, maximumCount: Int) {
        self.baseOffset = max(0, baseOffset)
        self.maximumCount = max(0, maximumCount)
        diagnostics.reserveCapacity(min(maximumCount, 32))
    }

    var isFull: Bool { diagnostics.count >= maximumCount }

    mutating func append(
        _ severity: SyntaxDiagnosticSeverity,
        _ code: String,
        _ message: String,
        at start: Int,
        length: Int = 1
    ) {
        guard !isFull else { return }
        diagnostics.append(
            SyntaxDiagnostic(
                severity: severity,
                code: code,
                message: message,
                range: SyntaxByteRange(
                    start: SyntaxByteUtilities.absoluteOffset(start, base: baseOffset),
                    length: max(0, length)
                )
            )
        )
    }
}
