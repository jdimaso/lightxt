import Foundation

/// Discovers collapsible structure without building a syntax tree. The input
/// remains owned by the caller; retained state is bounded by nesting depth and
/// `maximumFoldRanges`.
public enum SyntaxFoldDiscovery {
    public static func discover(
        _ data: Data,
        as fileType: SyntaxFileType,
        baseByteOffset: Int = 0,
        limits: SyntaxLimits = .default
    ) -> SyntaxFoldResult {
        data.withUnsafeBytes { rawBuffer in
            discover(
                rawBuffer.bindMemory(to: UInt8.self),
                as: fileType,
                baseByteOffset: baseByteOffset,
                limits: limits
            )
        }
    }

    public static func discover(
        _ bytes: UnsafeBufferPointer<UInt8>,
        as fileType: SyntaxFileType,
        baseByteOffset: Int = 0,
        limits: SyntaxLimits = .default
    ) -> SyntaxFoldResult {
        var collector = FoldCollector(baseOffset: baseByteOffset, maximumCount: limits.maximumFoldRanges)
        switch fileType {
        case .json:
            discoverJSON(bytes, limits: limits, collector: &collector)
        case .xml:
            discoverXML(bytes, limits: limits, collector: &collector)
        case .yaml:
            discoverYAML(bytes, limits: limits, collector: &collector)
        default:
            break
        }
        collector.sortBySourceOrder()
        return SyntaxFoldResult(ranges: collector.ranges, wasTruncated: collector.wasTruncated)
    }

    public static func discover(
        _ bytes: UnsafeRawBufferPointer,
        as fileType: SyntaxFileType,
        baseByteOffset: Int = 0,
        limits: SyntaxLimits = .default
    ) -> SyntaxFoldResult {
        discover(
            bytes.bindMemory(to: UInt8.self),
            as: fileType,
            baseByteOffset: baseByteOffset,
            limits: limits
        )
    }

    // MARK: - JSON

    private struct JSONOpening {
        let byte: UInt8
        let offset: Int
        let depth: Int
    }

    private static func discoverJSON(
        _ bytes: UnsafeBufferPointer<UInt8>,
        limits: SyntaxLimits,
        collector: inout FoldCollector
    ) {
        var stack: [JSONOpening] = []
        stack.reserveCapacity(min(limits.maximumNestingDepth, 64))
        var overflowDepth = 0
        var quote = false
        var escaped = false
        var index = 0

        while index < bytes.count {
            let byte = bytes[index]
            if quote {
                if escaped { escaped = false }
                else if byte == 0x5C { escaped = true }
                else if byte == 0x22 { quote = false }
                index += 1
                continue
            }
            if byte == 0x22 {
                quote = true
            } else if byte == 0x7B || byte == 0x5B {
                if stack.count < limits.maximumNestingDepth {
                    stack.append(JSONOpening(byte: byte, offset: index, depth: stack.count))
                } else {
                    overflowDepth += 1
                }
            } else if byte == 0x7D || byte == 0x5D {
                if overflowDepth > 0 {
                    overflowDepth -= 1
                } else if let opening = stack.popLast() {
                    let matches = (opening.byte == 0x7B && byte == 0x7D) ||
                                  (opening.byte == 0x5B && byte == 0x5D)
                    let foldLength = index + 1 - opening.offset
                    if matches,
                       (foldLength >= limits.minimumFoldByteCount ||
                        SyntaxByteUtilities.containsLineBreak(
                            bytes, from: opening.offset, to: index + 1
                        )) {
                        collector.append(
                            range: opening.offset..<(index + 1),
                            header: opening.offset..<(opening.offset + 1),
                            content: (opening.offset + 1)..<index,
                            kind: opening.byte == 0x7B ? .object : .array,
                            depth: opening.depth
                        )
                    }
                }
            }
            index += 1
        }
    }

    // MARK: - XML

    private struct XMLOpening {
        let name: Range<Int>
        let opening: Int
        let openingTagEnd: Int
        let depth: Int
    }

    private struct XMLTag {
        let opening: Int
        let end: Int
        let name: Range<Int>
        let isClosing: Bool
        let isSelfClosing: Bool
    }

    private static func discoverXML(
        _ bytes: UnsafeBufferPointer<UInt8>,
        limits: SyntaxLimits,
        collector: inout FoldCollector
    ) {
        var stack: [XMLOpening] = []
        stack.reserveCapacity(min(limits.maximumNestingDepth, 64))
        var overflowDepth = 0
        var index = 0

        while index < bytes.count {
            guard bytes[index] == 0x3C else { index += 1; continue }
            if SyntaxByteUtilities.hasASCII(bytes, at: index, "<!--") {
                if let close = findASCII(bytes, "-->", from: index + 4) {
                    let end = close + 3
                    if end - index >= limits.minimumFoldByteCount ||
                        SyntaxByteUtilities.containsLineBreak(bytes, from: index, to: end) {
                        collector.append(
                            range: index..<end,
                            header: index..<min(end, index + 4),
                            content: min(end, index + 4)..<max(min(end, index + 4), close),
                            kind: .comment,
                            depth: stack.count
                        )
                    }
                    index = end
                } else {
                    break
                }
            } else if SyntaxByteUtilities.hasASCII(bytes, at: index, "<![CDATA[") {
                guard let close = findASCII(bytes, "]]>", from: index + 9) else { break }
                index = close + 3
            } else if SyntaxByteUtilities.hasASCII(bytes, at: index, "<?") {
                guard let close = findASCII(bytes, "?>", from: index + 2) else { break }
                index = close + 2
            } else if SyntaxByteUtilities.hasASCII(bytes, at: index, "<!") {
                index = xmlDeclarationEnd(bytes, from: index + 2)
            } else if let tag = parseXMLTag(bytes, from: index) {
                index = tag.end
                if tag.isClosing {
                    if overflowDepth > 0 {
                        overflowDepth -= 1
                    } else if let opening = stack.popLast(),
                              SyntaxByteUtilities.matchingASCII(bytes, lhs: opening.name, rhs: tag.name),
                              (tag.end - opening.opening >= limits.minimumFoldByteCount ||
                               SyntaxByteUtilities.containsLineBreak(
                                bytes, from: opening.opening, to: tag.end
                               )) {
                        collector.append(
                            range: opening.opening..<tag.end,
                            header: opening.opening..<opening.openingTagEnd,
                            content: opening.openingTagEnd..<tag.opening,
                            kind: .element,
                            depth: opening.depth
                        )
                    }
                } else if !tag.isSelfClosing {
                    if stack.count < limits.maximumNestingDepth {
                        stack.append(
                            XMLOpening(
                                name: tag.name,
                                opening: tag.opening,
                                openingTagEnd: tag.end,
                                depth: stack.count
                            )
                        )
                    } else {
                        overflowDepth += 1
                    }
                }
            } else {
                index += 1
            }
        }
    }

    private static func parseXMLTag(
        _ bytes: UnsafeBufferPointer<UInt8>, from opening: Int
    ) -> XMLTag? {
        var index = opening + 1
        var isClosing = false
        if index < bytes.count, bytes[index] == 0x2F {
            isClosing = true
            index += 1
        }
        guard index < bytes.count, isXMLNameStart(bytes[index]) else { return nil }
        let nameStart = index
        index += 1
        while index < bytes.count, isXMLNameByte(bytes[index]) { index += 1 }
        let name = nameStart..<index
        var quote: UInt8?
        while index < bytes.count {
            let byte = bytes[index]
            if let active = quote {
                if byte == active { quote = nil }
            } else if byte == 0x22 || byte == 0x27 {
                quote = byte
            } else if byte == 0x3E {
                var probe = index
                while probe > name.upperBound, SyntaxByteUtilities.isSpace(bytes[probe - 1]) { probe -= 1 }
                return XMLTag(
                    opening: opening,
                    end: index + 1,
                    name: name,
                    isClosing: isClosing,
                    isSelfClosing: !isClosing && probe > name.upperBound && bytes[probe - 1] == 0x2F
                )
            }
            index += 1
        }
        return nil
    }

    // MARK: - YAML

    private struct YAMLOpening {
        let indentation: Int
        let start: Int
        let headerEnd: Int
        let kind: SyntaxFoldKind
        let depth: Int
        var hasChild: Bool
        let isSequenceGroup: Bool
    }

    private static func discoverYAML(
        _ bytes: UnsafeBufferPointer<UInt8>,
        limits: SyntaxLimits,
        collector: inout FoldCollector
    ) {
        var stack: [YAMLOpening] = []
        stack.reserveCapacity(min(limits.maximumNestingDepth, 64))
        var lineStart = 0

        func closeTop(at end: Int, stack: inout [YAMLOpening], collector: inout FoldCollector) {
            guard let opening = stack.popLast(), opening.hasChild, end > opening.headerEnd else { return }
            collector.append(
                range: opening.start..<end,
                header: opening.start..<opening.headerEnd,
                content: opening.headerEnd..<end,
                kind: opening.kind,
                depth: opening.depth
            )
        }

        while lineStart < bytes.count {
            let lineEnd = SyntaxByteUtilities.lineEnd(bytes, from: lineStart)
            var content = lineStart
            var indentation = 0
            while content < lineEnd, bytes[content] == 0x20 {
                indentation += 1
                content += 1
            }
            let syntaxEnd = yamlSyntaxEnd(bytes, from: content, to: lineEnd)
            let isBlank = content >= syntaxEnd
            let isComment = !isBlank && bytes[content] == 0x23
            if isBlank || isComment {
                lineStart = SyntaxByteUtilities.nextLineStart(bytes, after: lineEnd)
                continue
            }

            let isSequence = bytes[content] == 0x2D &&
                (content + 1 == syntaxEnd || SyntaxByteUtilities.isSpace(bytes[content + 1]))

            while let top = stack.last {
                if top.isSequenceGroup, indentation == top.indentation, isSequence {
                    stack[stack.count - 1].hasChild = true
                    break
                }
                if indentation > top.indentation {
                    stack[stack.count - 1].hasChild = true
                    break
                }
                closeTop(at: lineStart, stack: &stack, collector: &collector)
            }

            if isSequence,
               !(stack.last.map { $0.isSequenceGroup && $0.indentation == indentation } ?? false),
               stack.count < limits.maximumNestingDepth {
                stack.append(
                    YAMLOpening(
                        indentation: indentation,
                        start: content,
                        headerEnd: lineEnd,
                        kind: .sequence,
                        depth: stack.count,
                        hasChild: false,
                        isSequenceGroup: true
                    )
                )
            }

            var logicalContent = content
            var logicalIndentation = indentation
            if isSequence {
                logicalContent += 1
                while logicalContent < syntaxEnd, SyntaxByteUtilities.isSpace(bytes[logicalContent]) {
                    logicalContent += 1
                    logicalIndentation += 1
                }
                logicalIndentation = max(logicalIndentation, indentation + 1)
            }
            if stack.count < limits.maximumNestingDepth,
               let kind = yamlCandidateKind(bytes, from: logicalContent, to: syntaxEnd) {
                stack.append(
                    YAMLOpening(
                        indentation: logicalIndentation,
                        start: content,
                        headerEnd: lineEnd,
                        kind: kind,
                        depth: stack.count,
                        hasChild: false,
                        isSequenceGroup: false
                    )
                )
            }

            lineStart = SyntaxByteUtilities.nextLineStart(bytes, after: lineEnd)
        }
        while !stack.isEmpty {
            closeTop(at: bytes.count, stack: &stack, collector: &collector)
        }
    }

    private static func yamlSyntaxEnd(
        _ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int
    ) -> Int {
        var quote: UInt8?
        var escaped = false
        var index = start
        while index < end {
            let byte = bytes[index]
            if let active = quote {
                if active == 0x22, byte == 0x5C { escaped.toggle() }
                else {
                    if byte == active, !escaped { quote = nil }
                    escaped = false
                }
            } else if byte == 0x22 || byte == 0x27 {
                quote = byte
            } else if byte == 0x23, index == start || SyntaxByteUtilities.isSpace(bytes[index - 1]) {
                return index
            }
            index += 1
        }
        return end
    }

    private static func yamlCandidateKind(
        _ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int
    ) -> SyntaxFoldKind? {
        var lower = start
        var upper = end
        while lower < upper, SyntaxByteUtilities.isSpace(bytes[lower]) { lower += 1 }
        while upper > lower, SyntaxByteUtilities.isSpace(bytes[upper - 1]) { upper -= 1 }
        guard lower < upper else { return nil }

        var scalarEnd = upper
        if bytes[scalarEnd - 1] == 0x2B || bytes[scalarEnd - 1] == 0x2D { scalarEnd -= 1 }
        if scalarEnd > lower, SyntaxByteUtilities.isDigit(bytes[scalarEnd - 1]) { scalarEnd -= 1 }
        if scalarEnd > lower, bytes[scalarEnd - 1] == 0x7C || bytes[scalarEnd - 1] == 0x3E {
            return .scalar
        }
        if bytes[upper - 1] == 0x3A { return .mapping }
        return nil
    }

    // MARK: - Shared helpers

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

    private static func xmlDeclarationEnd(
        _ bytes: UnsafeBufferPointer<UInt8>, from start: Int
    ) -> Int {
        var index = start
        var brackets = 0
        var quote: UInt8?
        while index < bytes.count {
            let byte = bytes[index]
            if let active = quote {
                if byte == active { quote = nil }
            } else if byte == 0x22 || byte == 0x27 {
                quote = byte
            } else if byte == 0x5B {
                brackets += 1
            } else if byte == 0x5D, brackets > 0 {
                brackets -= 1
            } else if byte == 0x3E, brackets == 0 {
                return index + 1
            }
            index += 1
        }
        return bytes.count
    }

    private static func isXMLNameStart(_ byte: UInt8) -> Bool {
        SyntaxByteUtilities.isIdentifierStart(byte) || byte == 0x3A
    }

    private static func isXMLNameByte(_ byte: UInt8) -> Bool {
        isXMLNameStart(byte) || SyntaxByteUtilities.isDigit(byte) || byte == 0x2D || byte == 0x2E
    }
}

private struct FoldCollector {
    let baseOffset: Int
    let maximumCount: Int
    private(set) var ranges: [SyntaxFoldRange] = []
    private(set) var wasTruncated = false

    init(baseOffset: Int, maximumCount: Int) {
        self.baseOffset = max(0, baseOffset)
        self.maximumCount = max(0, maximumCount)
        ranges.reserveCapacity(min(maximumCount, 1_024))
    }

    mutating func append(
        range: Range<Int>,
        header: Range<Int>,
        content: Range<Int>,
        kind: SyntaxFoldKind,
        depth: Int
    ) {
        guard range.lowerBound >= 0, range.upperBound >= range.lowerBound,
              header.lowerBound >= range.lowerBound, header.upperBound <= range.upperBound,
              content.lowerBound >= range.lowerBound, content.upperBound <= range.upperBound else { return }
        guard ranges.count < maximumCount else {
            wasTruncated = true
            return
        }
        ranges.append(
            SyntaxFoldRange(
                range: absolute(range),
                headerRange: absolute(header),
                contentRange: absolute(content),
                kind: kind,
                depth: depth
            )
        )
    }

    mutating func sortBySourceOrder() {
        ranges.sort {
            if $0.range.start == $1.range.start { return $0.range.length > $1.range.length }
            return $0.range.start < $1.range.start
        }
    }

    private func absolute(_ range: Range<Int>) -> SyntaxByteRange {
        SyntaxByteRange(
            start: SyntaxByteUtilities.absoluteOffset(range.lowerBound, base: baseOffset),
            length: range.count
        )
    }
}
