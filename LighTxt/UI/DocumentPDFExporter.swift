import AppKit
import CoreGraphics
import CoreText
import Foundation

enum DocumentPDFSourceKind: Sendable, Equatable {
    case markdown
    case plainText
}

struct DocumentPDFPageSetup: Sendable, Equatable {
    var paperWidth: Double
    var paperHeight: Double
    var leftMargin: Double
    var rightMargin: Double
    var topMargin: Double
    var bottomMargin: Double
    var headerHeight: Double
    var footerHeight: Double

    static let letter = DocumentPDFPageSetup(
        paperWidth: 612,
        paperHeight: 792,
        leftMargin: 54,
        rightMargin: 54,
        topMargin: 42,
        bottomMargin: 36,
        headerHeight: 22,
        footerHeight: 22
    )

    static let a4 = DocumentPDFPageSetup(
        paperWidth: 595.28,
        paperHeight: 841.89,
        leftMargin: 54,
        rightMargin: 54,
        topMargin: 42,
        bottomMargin: 36,
        headerHeight: 22,
        footerHeight: 22
    )

    @MainActor
    static func from(_ printInfo: NSPrintInfo) -> DocumentPDFPageSetup {
        var width = Double(printInfo.paperSize.width)
        var height = Double(printInfo.paperSize.height)
        if printInfo.orientation == .landscape, height > width {
            swap(&width, &height)
        }
        return DocumentPDFPageSetup(
            paperWidth: width,
            paperHeight: height,
            leftMargin: max(24, Double(printInfo.leftMargin)),
            rightMargin: max(24, Double(printInfo.rightMargin)),
            topMargin: max(24, Double(printInfo.topMargin)),
            bottomMargin: max(24, Double(printInfo.bottomMargin)),
            headerHeight: 22,
            footerHeight: 22
        )
    }
}

struct DocumentPDFProgress: Sendable, Equatable {
    let bytesCompleted: Int64
    let totalBytes: Int64
    let pagesCompleted: Int

    var fractionCompleted: Double {
        guard totalBytes > 0 else { return 1 }
        return min(1, max(0, Double(bytesCompleted) / Double(totalBytes)))
    }
}

struct DocumentPDFExportResult: Sendable, Equatable {
    let pageCount: Int
}

enum DocumentPDFExportError: Error, LocalizedError, Equatable {
    case invalidPageGeometry
    case couldNotCreatePDF(path: String)
    case emptyPDF(path: String)
    case invalidPDF(path: String)

    var errorDescription: String? {
        switch self {
        case .invalidPageGeometry:
            "The selected paper size and margins leave no printable area."
        case let .couldNotCreatePDF(path):
            "LighTxt could not create a PDF at \(path)."
        case let .emptyPDF(path):
            "LighTxt could not finish the PDF at \(path)."
        case let .invalidPDF(path):
            "LighTxt created a PDF at \(path), but it could not be verified."
        }
    }
}

/// Streams an immutable document revision into a paginated PDF. The source,
/// decoded text, attributed text, and page display lists are never
/// materialized as whole-document values.
nonisolated enum DocumentPDFExporter {
    static func export(
        snapshot: DocumentSnapshot,
        kind: DocumentPDFSourceKind,
        title: String,
        to destinationURL: URL,
        pageSetup: DocumentPDFPageSetup = .letter,
        cancellation: CancellationToken = CancellationToken(),
        progress: (@Sendable (DocumentPDFProgress) -> Void)? = nil
    ) throws -> DocumentPDFExportResult {
        let renderer = StreamingDocumentPDFRenderer(
            snapshot: snapshot,
            kind: kind,
            title: title,
            destinationURL: destinationURL,
            pageSetup: pageSetup,
            cancellation: cancellation,
            progress: progress
        )
        return try renderer.render()
    }
}

private nonisolated final class StreamingDocumentPDFRenderer {
    /// Pathological physical lines are split without omitting bytes. A split
    /// preserves block styling and grapheme boundaries; inline Markdown whose
    /// opening and closing delimiters straddle the cap degrades to literal text
    /// instead of forcing an unbounded whole-line allocation.
    private static let maximumLineFragmentBytes = 256 * 1_024

    private let snapshot: DocumentSnapshot
    private let kind: DocumentPDFSourceKind
    private let title: String
    private let destinationURL: URL
    private let pageSetup: DocumentPDFPageSetup
    private let cancellation: CancellationToken
    private let progress: (@Sendable (DocumentPDFProgress) -> Void)?
    private var markdownFence: MarkdownFence?
    private var markdownContinuation: MarkdownContinuation?
    private var pagesCompleted = 0

    init(
        snapshot: DocumentSnapshot,
        kind: DocumentPDFSourceKind,
        title: String,
        destinationURL: URL,
        pageSetup: DocumentPDFPageSetup,
        cancellation: CancellationToken,
        progress: (@Sendable (DocumentPDFProgress) -> Void)?
    ) {
        self.snapshot = snapshot
        self.kind = kind
        self.title = title
        self.destinationURL = destinationURL
        self.pageSetup = pageSetup
        self.cancellation = cancellation
        self.progress = progress
    }

    func render() throws -> DocumentPDFExportResult {
        try validatePageGeometry()
        if cancellation.isCancelled { throw CancellationError() }

        var mediaBox = CGRect(
            x: 0,
            y: 0,
            width: pageSetup.paperWidth,
            height: pageSetup.paperHeight
        )
        let metadata = [
            kCGPDFContextTitle as String: title,
            kCGPDFContextCreator as String: "LighTxt",
        ] as CFDictionary
        guard let context = CGContext(
            destinationURL as CFURL,
            mediaBox: &mediaBox,
            metadata
        ) else {
            throw DocumentPDFExportError.couldNotCreatePDF(path: destinationURL.path)
        }
        let pager = DocumentPDFPager(
            context: context,
            title: title,
            pageSetup: pageSetup,
            cancellation: cancellation
        ) { [weak self] pageCount in
            self?.pagesCompleted = pageCount
        }

        var lineReader = BoundedUTF8LineReader(
            maximumFragmentBytes: Self.maximumLineFragmentBytes
        )
        var bytesCompleted: Int64 = 0
        do {
            try snapshot.forEachByteSlice { bytes in
                if cancellation.isCancelled { throw CancellationError() }
                try lineReader.consume(bytes) { [self] fragment in
                    try autoreleasepool {
                        try render(fragment, into: pager)
                    }
                }
                bytesCompleted += Int64(bytes.count)
                progress?(DocumentPDFProgress(
                    bytesCompleted: bytesCompleted,
                    totalBytes: snapshot.byteCount,
                    pagesCompleted: pagesCompleted
                ))
            }
            try lineReader.finish { [self] fragment in
                try autoreleasepool {
                    try render(fragment, into: pager)
                }
            }
            try pager.finish()
            pagesCompleted = pager.pageCount
            context.closePDF()
        } catch {
            context.closePDF()
            throw error
        }

        if cancellation.isCancelled { throw CancellationError() }
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: destinationURL.path
        ), let byteCount = attributes[.size] as? NSNumber, byteCount.intValue > 8 else {
            throw DocumentPDFExportError.emptyPDF(path: destinationURL.path)
        }
        guard let pdf = CGPDFDocument(destinationURL as CFURL),
              pdf.numberOfPages == pagesCompleted,
              pdf.numberOfPages > 0,
              (1...pdf.numberOfPages).allSatisfy({ pageNumber in
                  guard let page = pdf.page(at: pageNumber) else { return false }
                  return !page.getBoxRect(.mediaBox).isEmpty
              }) else {
            throw DocumentPDFExportError.invalidPDF(path: destinationURL.path)
        }
        progress?(DocumentPDFProgress(
            bytesCompleted: snapshot.byteCount,
            totalBytes: snapshot.byteCount,
            pagesCompleted: pagesCompleted
        ))
        return DocumentPDFExportResult(pageCount: pagesCompleted)
    }

    private func validatePageGeometry() throws {
        let contentWidth = pageSetup.paperWidth
            - pageSetup.leftMargin
            - pageSetup.rightMargin
        let contentHeight = pageSetup.paperHeight
            - pageSetup.topMargin
            - pageSetup.bottomMargin
            - pageSetup.headerHeight
            - pageSetup.footerHeight
        guard pageSetup.paperWidth.isFinite,
              pageSetup.paperHeight.isFinite,
              contentWidth >= 72,
              contentHeight >= 72 else {
            throw DocumentPDFExportError.invalidPageGeometry
        }
    }

    private func render(
        _ fragment: BoundedUTF8LineReader.Fragment,
        into pager: DocumentPDFPager
    ) throws {
        if cancellation.isCancelled { throw CancellationError() }
        switch kind {
        case .plainText:
            try pager.append(PDFTextStyler.plainText(
                fragment.text,
                endsLine: fragment.endsLine
            ))
        case .markdown:
            try renderMarkdown(fragment, into: pager)
        }
    }

    private func renderMarkdown(
        _ fragment: BoundedUTF8LineReader.Fragment,
        into pager: DocumentPDFPager
    ) throws {
        if fragment.isContinuation, let continuation = markdownContinuation {
            try pager.append(PDFTextStyler.markdownContinuation(
                fragment.text,
                kind: continuation,
                endsLine: fragment.endsLine
            ))
            if fragment.endsLine { markdownContinuation = nil }
            return
        }

        if let fence = markdownFence {
            if fragment.endsLine, fence.isClosingLine(fragment.text) {
                markdownFence = nil
                markdownContinuation = nil
                return
            }
            try pager.append(PDFTextStyler.code(
                fragment.text,
                endsLine: fragment.endsLine
            ))
            markdownContinuation = fragment.endsLine ? nil : .code
            return
        }
        if let fence = MarkdownFence.openingLine(fragment.text) {
            markdownFence = fence
            markdownContinuation = nil
            return
        }

        let prepared = try? MarkdownSemanticPreparer.prepare(fragment.text)
        let block = prepared?.blocks.first
            ?? .paragraph(content: AttributedString(fragment.text), isBlank: fragment.text.isEmpty)
        switch block {
        case .hidden, .tableSeparator:
            markdownContinuation = nil
        case let .code(text):
            try pager.append(PDFTextStyler.code(text, endsLine: fragment.endsLine))
            markdownContinuation = fragment.endsLine ? nil : .code
        case let .heading(level, content):
            try pager.append(PDFTextStyler.heading(
                content,
                level: level,
                endsLine: fragment.endsLine
            ))
            markdownContinuation = fragment.endsLine ? nil : .heading(level)
        case let .list(prefix, content):
            try pager.append(PDFTextStyler.list(
                prefix: prefix,
                content: content,
                endsLine: fragment.endsLine
            ))
            markdownContinuation = fragment.endsLine ? nil : .list
        case let .quote(content):
            try pager.append(PDFTextStyler.quote(
                content,
                endsLine: fragment.endsLine
            ))
            markdownContinuation = fragment.endsLine ? nil : .quote
        case let .table(cells):
            try pager.append(PDFTextStyler.table(
                cells,
                endsLine: fragment.endsLine
            ))
            markdownContinuation = fragment.endsLine ? nil : .table
        case .rule:
            try pager.appendRule()
            markdownContinuation = nil
        case let .paragraph(content, isBlank):
            try pager.append(PDFTextStyler.paragraph(
                content,
                isBlank: isBlank,
                endsLine: fragment.endsLine
            ))
            markdownContinuation = fragment.endsLine ? nil : .paragraph
        }
    }
}

private nonisolated enum MarkdownContinuation {
    case code
    case heading(Int)
    case list
    case quote
    case table
    case paragraph
}

private nonisolated struct MarkdownFence {
    let marker: UInt8
    let length: Int

    static func openingLine(_ line: String) -> MarkdownFence? {
        let bytes = line.utf8
        guard var index = fenceContentStart(in: bytes), index < bytes.endIndex else {
            return nil
        }
        let first = bytes[index]
        guard first == 0x60 || first == 0x7E else { return nil }
        var length = 0
        while index < bytes.endIndex, bytes[index] == first {
            length += 1
            index = bytes.index(after: index)
        }
        guard length >= 3 else { return nil }
        if first == 0x60 {
            while index < bytes.endIndex {
                if bytes[index] == 0x60 { return nil }
                index = bytes.index(after: index)
            }
        }
        return MarkdownFence(marker: first, length: length)
    }

    func isClosingLine(_ line: String) -> Bool {
        let bytes = line.utf8
        guard var index = Self.fenceContentStart(in: bytes),
              index < bytes.endIndex,
              bytes[index] == marker else { return false }
        var closingLength = 0
        while index < bytes.endIndex, bytes[index] == marker {
            closingLength += 1
            index = bytes.index(after: index)
        }
        guard closingLength >= length else { return false }
        while index < bytes.endIndex {
            let byte = bytes[index]
            guard byte == 0x20 || byte == 0x09 else { return false }
            index = bytes.index(after: index)
        }
        return true
    }

    private static func fenceContentStart(
        in bytes: String.UTF8View
    ) -> String.UTF8View.Index? {
        var index = bytes.startIndex
        var indentation = 0
        while index < bytes.endIndex, bytes[index] == 0x20 {
            indentation += 1
            guard indentation <= 3 else { return nil }
            index = bytes.index(after: index)
        }
        return index
    }
}

private nonisolated struct BoundedUTF8LineReader {
    struct Fragment {
        let text: String
        let endsLine: Bool
        let isContinuation: Bool
    }

    private let maximumFragmentBytes: Int
    private var buffer = Data()
    private var isContinuingLine = false
    private var shouldSkipLeadingLineFeed = false

    init(maximumFragmentBytes: Int) {
        self.maximumFragmentBytes = max(4, maximumFragmentBytes)
        buffer.reserveCapacity(min(maximumFragmentBytes, 64 * 1_024))
    }

    mutating func consume(
        _ bytes: UnsafeRawBufferPointer,
        emit: (Fragment) throws -> Void
    ) throws {
        var cursor = 0
        if shouldSkipLeadingLineFeed {
            if cursor < bytes.count, bytes[cursor] == 0x0A { cursor += 1 }
            shouldSkipLeadingLineFeed = false
        }
        while cursor < bytes.count {
            var lineEnding: Int?
            var probe = cursor
            while probe < bytes.count {
                if bytes[probe] == 0x0A || bytes[probe] == 0x0D {
                    lineEnding = probe
                    break
                }
                probe += 1
            }
            let end = lineEnding ?? bytes.count
            while cursor < end {
                let room = max(1, maximumFragmentBytes + 4 - buffer.count)
                let copyEnd = min(end, cursor + room)
                buffer.append(contentsOf: UnsafeRawBufferPointer(
                    rebasing: bytes[cursor..<copyEnd]
                ))
                cursor = copyEnd
                try flushOversizedFragments(emit: emit)
            }
            guard let lineEnding else { break }
            try emit(Fragment(
                text: String(decoding: buffer, as: UTF8.self),
                endsLine: true,
                isContinuation: isContinuingLine
            ))
            buffer.removeAll(keepingCapacity: true)
            isContinuingLine = false
            let terminator = bytes[lineEnding]
            cursor = lineEnding + 1
            if terminator == 0x0D {
                if cursor < bytes.count, bytes[cursor] == 0x0A {
                    cursor += 1
                } else if cursor == bytes.count {
                    shouldSkipLeadingLineFeed = true
                }
            }
        }
    }

    mutating func finish(emit: (Fragment) throws -> Void) throws {
        try flushOversizedFragments(emit: emit)
        guard !buffer.isEmpty else { return }
        try emit(Fragment(
            text: String(decoding: buffer, as: UTF8.self),
            endsLine: true,
            isContinuation: isContinuingLine
        ))
        buffer.removeAll(keepingCapacity: false)
        isContinuingLine = false
    }

    private mutating func flushOversizedFragments(
        emit: (Fragment) throws -> Void
    ) throws {
        while buffer.count > maximumFragmentBytes {
            let prefixLength = utf8AlignedPrefixLength()
            let prefix = buffer.prefix(prefixLength)
            try emit(Fragment(
                text: String(decoding: prefix, as: UTF8.self),
                endsLine: false,
                isContinuation: isContinuingLine
            ))
            buffer.removeFirst(prefixLength)
            isContinuingLine = true
        }
    }

    private func utf8AlignedPrefixLength() -> Int {
        var end = min(maximumFragmentBytes, buffer.count)
        while end > 0, end < buffer.count, buffer[end] & 0xC0 == 0x80 {
            end -= 1
        }
        let scalarAlignedEnd = max(1, end)
        let candidate = String(
            decoding: buffer.prefix(scalarAlignedEnd),
            as: UTF8.self
        )
        var graphemeAlignedEnd = 0
        var previousGraphemeEnd = 0
        for character in candidate {
            let next = graphemeAlignedEnd + character.utf8.count
            guard next <= maximumFragmentBytes else { break }
            previousGraphemeEnd = graphemeAlignedEnd
            graphemeAlignedEnd = next
        }
        if scalarAlignedEnd < buffer.count, previousGraphemeEnd > 0 {
            return previousGraphemeEnd
        }
        return graphemeAlignedEnd > 0 ? graphemeAlignedEnd : scalarAlignedEnd
    }
}

private nonisolated enum PDFTextStyler {
    private static let primary = NSColor(
        calibratedRed: 0.12,
        green: 0.14,
        blue: 0.15,
        alpha: 1
    )
    private static let secondary = NSColor(
        calibratedRed: 0.34,
        green: 0.39,
        blue: 0.40,
        alpha: 1
    )
    private static let accent = NSColor(
        calibratedRed: 0.02,
        green: 0.38,
        blue: 0.42,
        alpha: 1
    )
    private static let codeBackground = NSColor(
        calibratedRed: 0.94,
        green: 0.96,
        blue: 0.96,
        alpha: 1
    )

    static func plainText(_ text: String, endsLine: Bool) -> NSAttributedString {
        attributed(
            AttributedString(text),
            font: .monospacedSystemFont(ofSize: 10.5, weight: .regular),
            color: primary,
            paragraph: paragraphStyle(lineSpacing: 1, spacingAfter: 0),
            endsLine: endsLine
        )
    }

    static func code(_ text: String, endsLine: Bool) -> NSAttributedString {
        let value = attributed(
            AttributedString(text.isEmpty ? " " : text),
            font: .monospacedSystemFont(ofSize: 9.75, weight: .regular),
            color: primary,
            paragraph: paragraphStyle(lineSpacing: 1.5, spacingAfter: 0),
            endsLine: endsLine
        ) as! NSMutableAttributedString
        value.addAttribute(
            .backgroundColor,
            value: codeBackground,
            range: NSRange(location: 0, length: value.length)
        )
        return value
    }

    static func heading(
        _ content: AttributedString,
        level: Int,
        endsLine: Bool
    ) -> NSAttributedString {
        let size = max(13, 24 - CGFloat(level * 2))
        return attributed(
            content,
            font: .systemFont(ofSize: size, weight: level <= 2 ? .semibold : .medium),
            color: primary,
            paragraph: paragraphStyle(
                lineSpacing: 2,
                spacingBefore: level == 1 ? 12 : 8,
                spacingAfter: endsLine ? 6 : 0
            ),
            endsLine: endsLine
        )
    }

    static func list(
        prefix: String,
        content: AttributedString,
        endsLine: Bool
    ) -> NSAttributedString {
        let paragraph = paragraphStyle(
            lineSpacing: 2,
            spacingAfter: endsLine ? 2 : 0,
            headIndent: 20,
            firstLineHeadIndent: 0
        )
        let output = NSMutableAttributedString(
            string: prefix,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .semibold),
                .foregroundColor: accent,
                .paragraphStyle: paragraph,
            ]
        )
        output.append(attributed(
            content,
            font: .systemFont(ofSize: 11.5),
            color: primary,
            paragraph: paragraph,
            endsLine: endsLine
        ))
        return output
    }

    static func quote(
        _ content: AttributedString,
        endsLine: Bool
    ) -> NSAttributedString {
        let paragraph = paragraphStyle(
            lineSpacing: 2,
            spacingAfter: endsLine ? 4 : 0,
            headIndent: 18,
            firstLineHeadIndent: 0
        )
        let output = NSMutableAttributedString(
            string: "│  ",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .medium),
                .foregroundColor: accent,
                .paragraphStyle: paragraph,
            ]
        )
        let font = NSFontManager.shared.convert(
            NSFont.systemFont(ofSize: 11.5),
            toHaveTrait: .italicFontMask
        )
        output.append(attributed(
            content,
            font: font,
            color: secondary,
            paragraph: paragraph,
            endsLine: endsLine
        ))
        return output
    }

    static func table(
        _ cells: [AttributedString],
        endsLine: Bool
    ) -> NSAttributedString {
        let paragraph = paragraphStyle(
            lineSpacing: 1.5,
            spacingAfter: endsLine ? 2 : 0
        )
        let output = NSMutableAttributedString()
        for (index, cell) in cells.enumerated() {
            if index > 0 {
                output.append(NSAttributedString(
                    string: "  |  ",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 9.5, weight: .regular),
                        .foregroundColor: secondary,
                        .paragraphStyle: paragraph,
                    ]
                ))
            }
            output.append(attributed(
                cell,
                font: .systemFont(ofSize: 9.5),
                color: primary,
                paragraph: paragraph,
                endsLine: false
            ))
        }
        if endsLine {
            output.append(NSAttributedString(
                string: "\n",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 9.5),
                    .foregroundColor: primary,
                    .paragraphStyle: paragraph,
                ]
            ))
        }
        return output
    }

    static func paragraph(
        _ content: AttributedString,
        isBlank: Bool,
        endsLine: Bool
    ) -> NSAttributedString {
        attributed(
            content,
            font: .systemFont(ofSize: 11.5),
            color: primary,
            paragraph: paragraphStyle(
                lineSpacing: 2,
                spacingAfter: endsLine ? (isBlank ? 2 : 5) : 0
            ),
            endsLine: endsLine
        )
    }

    static func markdownContinuation(
        _ text: String,
        kind: MarkdownContinuation,
        endsLine: Bool
    ) -> NSAttributedString {
        switch kind {
        case .code:
            code(text, endsLine: endsLine)
        case let .heading(level):
            heading(AttributedString(text), level: level, endsLine: endsLine)
        case .list:
            attributed(
                AttributedString(text),
                font: .systemFont(ofSize: 11.5),
                color: primary,
                paragraph: paragraphStyle(
                    lineSpacing: 2,
                    spacingAfter: endsLine ? 2 : 0,
                    headIndent: 20,
                    firstLineHeadIndent: 20
                ),
                endsLine: endsLine
            )
        case .quote:
            attributed(
                AttributedString(text),
                font: NSFontManager.shared.convert(
                    NSFont.systemFont(ofSize: 11.5),
                    toHaveTrait: .italicFontMask
                ),
                color: secondary,
                paragraph: paragraphStyle(
                    lineSpacing: 2,
                    spacingAfter: endsLine ? 4 : 0,
                    headIndent: 18,
                    firstLineHeadIndent: 18
                ),
                endsLine: endsLine
            )
        case .table:
            attributed(
                AttributedString(text),
                font: .systemFont(ofSize: 9.5),
                color: primary,
                paragraph: paragraphStyle(
                    lineSpacing: 1.5,
                    spacingAfter: endsLine ? 2 : 0
                ),
                endsLine: endsLine
            )
        case .paragraph:
            paragraph(AttributedString(text), isBlank: false, endsLine: endsLine)
        }
    }

    private static func attributed(
        _ parsed: AttributedString,
        font: NSFont,
        color: NSColor,
        paragraph: NSParagraphStyle,
        endsLine: Bool
    ) -> NSAttributedString {
        let output = NSMutableAttributedString(parsed)
        if endsLine { output.append(NSAttributedString(string: "\n")) }
        let full = NSRange(location: 0, length: output.length)
        output.addAttributes([
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ], range: full)

        output.enumerateAttribute(.inlinePresentationIntent, in: full) { value, range, _ in
            guard let raw = value as? NSNumber else { return }
            let intent = InlinePresentationIntent(rawValue: raw.uintValue)
            if intent.contains(.code) {
                output.addAttributes([
                    .font: NSFont.monospacedSystemFont(
                        ofSize: max(8.5, font.pointSize - 1),
                        weight: .regular
                    ),
                    .foregroundColor: accent,
                    .backgroundColor: codeBackground,
                ], range: range)
                return
            }
            var traits: NSFontTraitMask = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
            if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
            if !traits.isEmpty {
                output.addAttribute(
                    .font,
                    value: NSFontManager.shared.convert(font, toHaveTrait: traits),
                    range: range
                )
            }
        }
        output.enumerateAttribute(.link, in: full) { value, range, _ in
            guard value != nil else { return }
            output.addAttributes([
                .foregroundColor: accent,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: range)
        }
        return output
    }

    private static func paragraphStyle(
        lineSpacing: CGFloat,
        spacingBefore: CGFloat = 0,
        spacingAfter: CGFloat,
        headIndent: CGFloat = 0,
        firstLineHeadIndent: CGFloat = 0
    ) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.paragraphSpacingBefore = spacingBefore
        paragraph.paragraphSpacing = spacingAfter
        paragraph.headIndent = headIndent
        paragraph.firstLineHeadIndent = firstLineHeadIndent
        paragraph.lineBreakMode = .byWordWrapping
        return paragraph
    }
}

private nonisolated final class DocumentPDFPager {
    private static let minimumTextHeight: CGFloat = 13

    private let context: CGContext
    private let title: String
    private let pageSetup: DocumentPDFPageSetup
    private let cancellation: CancellationToken
    private let onPageCompleted: (Int) -> Void
    private let pageWidth: CGFloat
    private let pageHeight: CGFloat
    private let contentLeft: CGFloat
    private let contentWidth: CGFloat
    private let contentTop: CGFloat
    private let contentBottom: CGFloat
    private var cursorTop: CGFloat = 0
    private var pageIsOpen = false
    private(set) var pageCount = 0

    init(
        context: CGContext,
        title: String,
        pageSetup: DocumentPDFPageSetup,
        cancellation: CancellationToken,
        onPageCompleted: @escaping (Int) -> Void
    ) {
        self.context = context
        self.title = title
        self.pageSetup = pageSetup
        self.cancellation = cancellation
        self.onPageCompleted = onPageCompleted
        pageWidth = CGFloat(pageSetup.paperWidth)
        pageHeight = CGFloat(pageSetup.paperHeight)
        contentLeft = CGFloat(pageSetup.leftMargin)
        contentWidth = pageWidth
            - CGFloat(pageSetup.leftMargin)
            - CGFloat(pageSetup.rightMargin)
        contentTop = pageHeight
            - CGFloat(pageSetup.topMargin)
            - CGFloat(pageSetup.headerHeight)
        contentBottom = CGFloat(pageSetup.bottomMargin)
            + CGFloat(pageSetup.footerHeight)
    }

    func append(_ attributedString: NSAttributedString) throws {
        guard attributedString.length > 0 else { return }
        let framesetter = CTFramesetterCreateWithAttributedString(attributedString)
        var location = 0
        while location < attributedString.length {
            if cancellation.isCancelled { throw CancellationError() }
            try ensurePage()
            var availableHeight = cursorTop - contentBottom
            if availableHeight < Self.minimumTextHeight {
                endPage()
                try ensurePage()
                availableHeight = cursorTop - contentBottom
            }

            let remaining = CFRange(
                location: location,
                length: attributedString.length - location
            )
            let localBounds = CGRect(
                x: 0,
                y: 0,
                width: contentWidth,
                height: availableHeight
            )
            let path = CGPath(rect: localBounds, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, remaining, path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else {
                endPage()
                continue
            }

            context.saveGState()
            context.translateBy(x: contentLeft, y: contentBottom)
            drawBackgrounds(in: frame)
            CTFrameDraw(frame, context)
            context.restoreGState()
            addLinks(in: frame, pageOffset: CGPoint(x: contentLeft, y: contentBottom))

            let allRemainingWasDrawn = visible.length >= remaining.length
            let usedHeight: CGFloat
            if allRemainingWasDrawn {
                let suggested = CTFramesetterSuggestFrameSizeWithConstraints(
                    framesetter,
                    visible,
                    nil,
                    CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
                    nil
                )
                usedHeight = min(
                    availableHeight,
                    max(Self.minimumTextHeight, ceil(suggested.height))
                )
            } else {
                usedHeight = availableHeight
            }
            cursorTop -= usedHeight
            location += visible.length
            if !allRemainingWasDrawn { endPage() }
        }
    }

    func appendRule() throws {
        try ensurePage()
        if cursorTop - contentBottom < 18 {
            endPage()
            try ensurePage()
        }
        context.saveGState()
        context.setStrokeColor(
            NSColor(calibratedWhite: 0.72, alpha: 1).cgColor
        )
        context.setLineWidth(0.7)
        context.move(to: CGPoint(x: contentLeft, y: cursorTop - 7))
        context.addLine(to: CGPoint(x: contentLeft + contentWidth, y: cursorTop - 7))
        context.strokePath()
        context.restoreGState()
        cursorTop -= 18
    }

    func finish() throws {
        if cancellation.isCancelled { throw CancellationError() }
        try ensurePage()
        endPage()
    }

    private func ensurePage() throws {
        guard !pageIsOpen else { return }
        if cancellation.isCancelled { throw CancellationError() }
        context.beginPDFPage(nil)
        pageIsOpen = true
        pageCount += 1
        cursorTop = contentTop
        drawPaperAndChrome()
    }

    private func endPage() {
        guard pageIsOpen else { return }
        context.endPDFPage()
        pageIsOpen = false
        onPageCompleted(pageCount)
    }

    private func drawPaperAndChrome() {
        context.saveGState()
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))

        let secondary = NSColor(calibratedWhite: 0.38, alpha: 1)
        let headerFont = NSFont.systemFont(ofSize: 8.5, weight: .medium)
        let footerFont = NSFont.monospacedDigitSystemFont(ofSize: 8, weight: .regular)
        drawSingleLine(
            title,
            font: headerFont,
            color: secondary,
            at: CGPoint(
                x: contentLeft,
                y: contentTop + CGFloat(pageSetup.headerHeight) - 13
            ),
            maximumWidth: contentWidth
        )
        drawSingleLine(
            "Page \(pageCount)",
            font: footerFont,
            color: secondary,
            at: CGPoint(
                x: contentLeft,
                y: CGFloat(pageSetup.bottomMargin) + 6
            ),
            maximumWidth: contentWidth
        )

        context.setStrokeColor(NSColor(calibratedWhite: 0.84, alpha: 1).cgColor)
        context.setLineWidth(0.5)
        context.move(to: CGPoint(x: contentLeft, y: contentTop + 3))
        context.addLine(to: CGPoint(x: contentLeft + contentWidth, y: contentTop + 3))
        context.move(to: CGPoint(x: contentLeft, y: contentBottom - 3))
        context.addLine(to: CGPoint(x: contentLeft + contentWidth, y: contentBottom - 3))
        context.strokePath()
        context.restoreGState()
    }

    private func drawSingleLine(
        _ text: String,
        font: NSFont,
        color: NSColor,
        at point: CGPoint,
        maximumWidth: CGFloat
    ) {
        let source = NSAttributedString(
            string: text,
            attributes: [.font: font, .foregroundColor: color]
        )
        let line = CTLineCreateWithAttributedString(source)
        let ellipsis = CTLineCreateWithAttributedString(NSAttributedString(
            string: "…",
            attributes: [.font: font, .foregroundColor: color]
        ))
        let fitted = CTLineCreateTruncatedLine(line, Double(maximumWidth), .end, ellipsis)
            ?? line
        context.textMatrix = .identity
        context.textPosition = point
        CTLineDraw(fitted, context)
    }

    private func drawBackgrounds(in frame: CTFrame) {
        enumerateRuns(in: frame) { run, _, rect in
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let color = attributes[NSAttributedString.Key.backgroundColor] as? NSColor else {
                return
            }
            context.setFillColor(color.cgColor)
            context.fill(rect.insetBy(dx: -1, dy: -0.5))
        }
    }

    private func addLinks(in frame: CTFrame, pageOffset: CGPoint) {
        enumerateRuns(in: frame) { run, _, rect in
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let value = attributes[NSAttributedString.Key.link]
            let url: URL?
            if let candidate = value as? URL {
                url = candidate
            } else if let candidate = value as? NSURL {
                url = candidate as URL
            } else if let candidate = value as? String {
                url = URL(string: candidate)
            } else {
                url = nil
            }
            guard let url else { return }
            context.setURL(
                url as CFURL,
                for: rect.offsetBy(dx: pageOffset.x, dy: pageOffset.y)
            )
        }
    }

    private func enumerateRuns(
        in frame: CTFrame,
        _ body: (CTRun, CTLine, CGRect) -> Void
    ) {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        guard !lines.isEmpty else { return }
        var origins = [CGPoint](repeating: .zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        for (index, line) in lines.enumerated() {
            let runs = CTLineGetGlyphRuns(line) as! [CTRun]
            for run in runs {
                let range = CTRunGetStringRange(run)
                var startSecondary: CGFloat = 0
                var endSecondary: CGFloat = 0
                let startPrimary = CTLineGetOffsetForStringIndex(
                    line,
                    range.location,
                    &startSecondary
                )
                let endPrimary = CTLineGetOffsetForStringIndex(
                    line,
                    range.location + range.length,
                    &endSecondary
                )
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                let typographicWidth = CGFloat(CTRunGetTypographicBounds(
                    run,
                    CFRange(location: 0, length: 0),
                    &ascent,
                    &descent,
                    nil
                ))
                let minimumOffset = min(
                    min(startPrimary, startSecondary),
                    min(endPrimary, endSecondary)
                )
                let maximumOffset = max(
                    max(startPrimary, startSecondary),
                    max(endPrimary, endSecondary)
                )
                let width = max(typographicWidth, maximumOffset - minimumOffset)
                guard width > 0, ascent + descent > 0 else { continue }
                body(
                    run,
                    line,
                    CGRect(
                        x: origins[index].x + minimumOffset,
                        y: origins[index].y - descent,
                        width: width,
                        height: ascent + descent
                    )
                )
            }
        }
    }
}
