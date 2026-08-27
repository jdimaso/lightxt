#if LIGHTXT_STANDALONE_MARKDOWN_QA
import AppKit
import Foundation
import PDFKit

// Minimal declarations used only when this file is compiled as the standalone
// renderer QA executable. The production app receives these types from its
// normal editor/model sources.
enum SyntaxFileType {}
final class DocumentSnapshot: @unchecked Sendable {
    private let bytes: Data
    let byteCount: Int64
    init(_ bytes: Data) {
        self.bytes = bytes
        byteCount = Int64(bytes.count)
    }
    func data(in range: Range<Int64>) throws -> Data {
        bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
    }
    func forEachByteSlice(
        in requestedRange: Range<Int64>? = nil,
        _ body: (UnsafeRawBufferPointer) throws -> Void
    ) throws {
        let range = requestedRange ?? 0..<byteCount
        var offset = range.lowerBound
        while offset < range.upperBound {
            let upper = min(range.upperBound, offset + 4_096)
            try bytes.withUnsafeBytes { rawBytes in
                let slice = UnsafeRawBufferPointer(
                    rebasing: rawBytes[Int(offset)..<Int(upper)]
                )
                try body(slice)
            }
            offset = upper
        }
    }
}
final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}
struct EditorLineLocation {}
struct SyntaxFoldRange {}

@MainActor
protocol VirtualTextEditorDelegate: AnyObject {
    var editorDocumentByteCount: Int64 { get }
    var editorSyntaxFileType: SyntaxFileType { get }
    func editorSnapshot() throws -> DocumentSnapshot
    func editorReadBytes(in range: Range<Int64>) throws -> Data
    func editorReplaceBytes(in range: Range<Int64>, with bytes: Data) throws
    func editorLineLocation(at byteOffset: Int64) -> EditorLineLocation
    func editorDidCommitEdit(replaced range: Range<Int64>, insertedByteCount: Int64)
    func editorSelectionDidChange(byteRange: Range<Int64>, line: Int64, column: Int)
    func editorDidLoadViewport(byteRange: Range<Int64>)
    func editorDidExpose(byteRange: Range<Int64>)
    func editorDidDiscoverStructure(
        folds: [SyntaxFoldRange],
        viewportData: Data,
        viewportBaseOffset: Int64
    )
    func editorDidFail(_ error: Error)
}

@main
@MainActor
struct MarkdownRendererRuntimeQA {
    static func main() throws {
        guard CommandLine.arguments.count >= 3 else {
            throw QAError.usage
        }
        _ = NSApplication.shared
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let source = try String(contentsOf: fixtureURL, encoding: .utf8)

        let light = NSAppearance(named: .aqua)!
        let dark = NSAppearance(named: .darkAqua)!
        let lightResult = MarkdownNativeRenderer.render(
            source,
            appearance: light,
            startsMidDocument: false
        )
        let darkResult = MarkdownNativeRenderer.render(
            source,
            appearance: dark,
            startsMidDocument: false
        )
        try assertSemanticRendering(lightResult)
        try assertSemanticRendering(darkResult)
        try assertVisualAttributes(lightResult)
        try assertWideTableLayout(lightResult)
        try render(lightResult, appearance: light, to: outputDirectory.appendingPathComponent("markdown-light.png"))
        try render(darkResult, appearance: dark, to: outputDirectory.appendingPathComponent("markdown-dark.png"))
        let pdfSummary = try assertPDFExport(
            fixtureSource: source,
            outputDirectory: outputDirectory
        )
        let mainApplyMilliseconds = try measureBoundedMainApply(appearance: light)
        guard mainApplyMilliseconds < 100 else {
            throw QAError.failed(
                "Bounded Markdown main-thread apply took \(mainApplyMilliseconds) ms"
            )
        }
        let asyncSample = try assertAsyncViewportAndStalePublicationGate()
        let partialTableSummary = try assertPartialTableWindow()
        var scrollingSummary = ""
        if CommandLine.arguments.count >= 4 {
            let scrollingFixtureURL = URL(fileURLWithPath: CommandLine.arguments[3])
            let scrollingSource = try String(contentsOf: scrollingFixtureURL, encoding: .utf8)
            scrollingSummary = try assertProductionScrolling(
                source: scrollingSource,
                outputDirectory: outputDirectory
            )
        }
        print(
            "Markdown renderer QA passed: delimiters hidden, semantic attributes present, "
                + "bounded main apply \(String(format: "%.3f", mainApplyMilliseconds)) ms, "
                + "production switch enqueue \(String(format: "%.3f", asyncSample.enqueue)) ms / "
                + "apply \(String(format: "%.3f", asyncSample.apply)) ms, stale publication rejected; "
                + "light/dark captures rendered, \(pdfSummary), \(partialTableSummary)\(scrollingSummary)"
        )
    }

    private static func assertPDFExport(
        fixtureSource: String,
        outputDirectory: URL
    ) throws -> String {
        let pageSetup = pdfPageSetup()

        let semanticURL = outputDirectory.appendingPathComponent("markdown-runtime-qa.pdf")
        let lineAndFenceEdges = "\r## Bare CR Heading\rBare CR paragraph\r\n\n"
            + "```swift\nMIXED FENCE CONTENT\n~~~\n# STILL CODE\n```\n\n"
            + "## AFTER FENCE\n\n"
        let semanticSource = fixtureSource + lineAndFenceEdges + String(
            repeating: "A printable Markdown paragraph keeps this semantic fixture on multiple pages.\n\n",
            count: 60
        )
        let semanticResult = try DocumentPDFExporter.export(
            snapshot: DocumentSnapshot(Data(semanticSource.utf8)),
            kind: .markdown,
            title: "RuntimeQA",
            to: semanticURL,
            pageSetup: pageSetup,
            cancellation: CancellationToken(),
            progress: nil
        )
        let semanticPDF = try inspectPDF(at: semanticURL)
        guard semanticResult.pageCount == semanticPDF.pageCount,
              semanticPDF.pageCount > 1 else {
            throw QAError.failed(
                "RuntimeQA Markdown PDF did not paginate: exporter \(semanticResult.pageCount), PDFKit \(semanticPDF.pageCount)"
            )
        }
        let semanticText = extractedText(from: semanticPDF)
        let required = [
            "LighTxt Markdown Preview",
            "clean",
            "calm",
            "Clickable links",
            "inline code",
            "let message = \"Rendered without WebKit\"",
            "Bare CR Heading",
            "# STILL CODE",
            "AFTER FENCE",
        ]
        let forbidden = [
            "# LighTxt Markdown Preview",
            "**clean**",
            "*calm*",
            "[Clickable links](",
            "https://example.com",
            "`inline code`",
            "```swift",
            "## Bare CR Heading",
            "## AFTER FENCE",
        ]
        guard required.allSatisfy(semanticText.contains) else {
            throw QAError.failed("Markdown PDF omitted rendered fixture semantics")
        }
        guard forbidden.allSatisfy({ !semanticText.contains($0) }) else {
            throw QAError.failed("Markdown PDF exposed source delimiters or link destinations")
        }
        try assertLinkAnnotation(in: semanticPDF, destination: "https://example.com")
        try assertPrintablePaletteIfInspectable(in: semanticPDF, locating: "LighTxt Markdown Preview")

        let markdownHead = "PDFMARKDOWNHEAD7E6A"
        let markdownTail = "PDFMARKDOWNTAIL9C31"
        let markdownBody = String(
            repeating: "- A **bounded** export row with [a link](https://example.com) and `inline code`.\n",
            count: 700
        )
        let oversizedMarkdown = "# \(markdownHead)\n\n" + markdownBody + "\n## \(markdownTail)\n"
        guard oversizedMarkdown.utf8.count > MarkdownPreviewView.maximumViewportBytes else {
            throw QAError.failed("Generated Markdown PDF fixture did not exceed the View-mode window")
        }
        let oversizedMarkdownURL = outputDirectory.appendingPathComponent("markdown-over-viewport.pdf")
        let oversizedMarkdownResult = try DocumentPDFExporter.export(
            snapshot: DocumentSnapshot(Data(oversizedMarkdown.utf8)),
            kind: .markdown,
            title: "Oversized Markdown",
            to: oversizedMarkdownURL,
            pageSetup: pageSetup,
            cancellation: CancellationToken(),
            progress: nil
        )
        let oversizedMarkdownPDF = try inspectPDF(at: oversizedMarkdownURL)
        let oversizedMarkdownText = extractedText(from: oversizedMarkdownPDF)
        guard oversizedMarkdownResult.pageCount == oversizedMarkdownPDF.pageCount,
              oversizedMarkdownPDF.pageCount > 1,
              oversizedMarkdownText.contains(markdownHead),
              oversizedMarkdownText.contains(markdownTail) else {
            throw QAError.failed("Markdown PDF lost content beyond its 48 KiB View-mode window")
        }

        let plainTextHead = "PDFPLAINTEXTHEAD4B20"
        let plainTextTail = "PDFPLAINTEXTTAIL1D8F"
        let plainTextBody = String(
            repeating: "Plain text remains complete when printing through the shared PDF pipeline.\n",
            count: 7_500
        )
        let oversizedPlainText = plainTextHead + "\n" + plainTextBody + plainTextTail + "\n"
        guard oversizedPlainText.utf8.count > 512 * 1_024 else {
            throw QAError.failed("Generated plain-text PDF fixture did not exceed the editor window")
        }
        let plainTextURL = outputDirectory.appendingPathComponent("plain-text-over-viewport.pdf")
        let plainTextResult = try DocumentPDFExporter.export(
            snapshot: DocumentSnapshot(Data(oversizedPlainText.utf8)),
            kind: .plainText,
            title: "Oversized Plain Text",
            to: plainTextURL,
            pageSetup: pageSetup,
            cancellation: CancellationToken(),
            progress: nil
        )
        let plainTextPDF = try inspectPDF(at: plainTextURL)
        let plainText = extractedText(from: plainTextPDF)
        guard plainTextResult.pageCount == plainTextPDF.pageCount,
              plainTextPDF.pageCount > 1,
              plainText.contains(plainTextHead),
              plainText.contains(plainTextTail) else {
            throw QAError.failed("Plain-text PDF lost content beyond its bounded source window")
        }

        let emptyURL = outputDirectory.appendingPathComponent("empty-document.pdf")
        let emptyResult = try DocumentPDFExporter.export(
            snapshot: DocumentSnapshot(Data()),
            kind: .plainText,
            title: "Empty Document",
            to: emptyURL,
            pageSetup: pageSetup,
            cancellation: CancellationToken(),
            progress: nil
        )
        let emptyPDF = try inspectPDF(at: emptyURL)
        guard emptyResult.pageCount == 1, emptyPDF.pageCount == 1,
              let page = emptyPDF.page(at: 0), !page.bounds(for: .mediaBox).isEmpty else {
            throw QAError.failed("An empty document did not produce exactly one valid PDF page")
        }

        return "four complete PDF export cases rendered"
    }

    private static func pdfPageSetup() -> DocumentPDFPageSetup {
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        info.orientation = .portrait
        info.paperSize = NSSize(width: 612, height: 792)
        info.topMargin = 54
        info.bottomMargin = 54
        info.leftMargin = 54
        info.rightMargin = 54
        return DocumentPDFPageSetup.from(info)
    }

    private static func inspectPDF(at url: URL) throws -> PDFDocument {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > 8,
              let document = PDFDocument(url: url),
              document.pageCount > 0 else {
            throw QAError.failed("Could not open valid PDF output at \(url.lastPathComponent)")
        }
        return document
    }

    private static func extractedText(from document: PDFDocument) -> String {
        (0..<document.pageCount).compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n")
    }

    private static func assertLinkAnnotation(
        in document: PDFDocument,
        destination: String
    ) throws {
        guard let expected = URL(string: destination) else {
            throw QAError.failed("Invalid expected PDF link URL: \(destination)")
        }
        let links = (0..<document.pageCount).flatMap { pageIndex in
            document.page(at: pageIndex)?.annotations.compactMap(\.url) ?? []
        }
        guard links.contains(expected) else {
            throw QAError.failed("Markdown PDF lost the clickable \(destination) link annotation")
        }
    }

    /// PDFKit preserves text color on some OS releases but omits it from the
    /// extracted selection on others. When exposed, verify the print renderer
    /// did not inherit light-on-dark screen colors for white paper.
    private static func assertPrintablePaletteIfInspectable(
        in document: PDFDocument,
        locating marker: String
    ) throws {
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex),
                  let pageText = page.string else { continue }
            let range = (pageText as NSString).range(of: marker)
            guard range.location != NSNotFound,
                  let attributed = page.selection(for: range)?.attributedString,
                  attributed.length > 0,
                  let color = attributed.attribute(
                    .foregroundColor,
                    at: 0,
                    effectiveRange: nil
                  ) as? NSColor,
                  let rgb = color.usingColorSpace(.deviceRGB) else { continue }
            let luminance = 0.2126 * rgb.redComponent
                + 0.7152 * rgb.greenComponent
                + 0.0722 * rgb.blueComponent
            guard luminance < 0.55 else {
                throw QAError.failed("PDF text did not use a printable dark-on-light palette")
            }
            return
        }
    }

    private static func assertSemanticRendering(_ rendered: NSAttributedString) throws {
        let visible = rendered.string
        let required = [
            "LighTxt Markdown Preview",
            "clean",
            "calm",
            "Clickable links",
            "inline code",
            "let message = \"Rendered without WebKit\"",
            "Mode",
            "Memory behavior",
            "tpi.query_artifact_analysis_with_an_extremely_long_unbreakable_identifier_that_must_wrap_inside_column_one",
            "scope|tool",
            "Escaped | prose",
            "Unmatched backtick remains a row",
        ]
        let forbidden = [
            "# LighTxt",
            "**clean**",
            "*calm*",
            "[Clickable links](",
            "https://example.com",
            "`inline code`",
            "```swift",
            "| --- |",
            ":---",
            "---:",
            "Escaped \\| prose",
        ]
        guard required.allSatisfy(visible.contains) else {
            throw QAError.failed("Rendered text omitted expected fixture content: \(visible)")
        }
        guard forbidden.allSatisfy({ !visible.contains($0) }) else {
            throw QAError.failed("Rendered text exposed Markdown syntax: \(visible)")
        }
    }

    private static func assertVisualAttributes(_ rendered: NSAttributedString) throws {
        let source = rendered.string as NSString
        let titleRange = source.range(of: "LighTxt Markdown Preview")
        let bodyRange = source.range(of: "Native rendering")
        let boldRange = source.range(of: "clean")
        let italicRange = source.range(of: "calm")
        let inlineCodeRange = source.range(of: "inline code")
        let linkRange = source.range(of: "Clickable links")
        let fencedCodeRange = source.range(of: "let message")
        guard [titleRange, bodyRange, boldRange, italicRange, inlineCodeRange, linkRange, fencedCodeRange]
            .allSatisfy({ $0.location != NSNotFound }) else {
            throw QAError.failed("Could not locate semantic ranges in rendered fixture")
        }

        let titleFont = rendered.attribute(.font, at: titleRange.location, effectiveRange: nil) as? NSFont
        let bodyFont = rendered.attribute(.font, at: bodyRange.location, effectiveRange: nil) as? NSFont
        let boldFont = rendered.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
        let italicFont = rendered.attribute(.font, at: italicRange.location, effectiveRange: nil) as? NSFont
        let inlineFont = rendered.attribute(.font, at: inlineCodeRange.location, effectiveRange: nil) as? NSFont
        let fencedFont = rendered.attribute(.font, at: fencedCodeRange.location, effectiveRange: nil) as? NSFont
        guard let titleFont, let bodyFont, titleFont.pointSize > bodyFont.pointSize else {
            throw QAError.failed("Heading hierarchy was not reflected in font size")
        }
        let manager = NSFontManager.shared
        guard let boldFont, manager.traits(of: boldFont).contains(.boldFontMask) else {
            throw QAError.failed("Strong emphasis was not rendered bold")
        }
        guard let italicFont, manager.traits(of: italicFont).contains(.italicFontMask) else {
            throw QAError.failed("Emphasis was not rendered italic")
        }
        guard let inlineFont, manager.traits(of: inlineFont).contains(.fixedPitchFontMask),
              let fencedFont, manager.traits(of: fencedFont).contains(.fixedPitchFontMask) else {
            throw QAError.failed("Inline or fenced code was not rendered monospaced")
        }
        guard rendered.attribute(.link, at: linkRange.location, effectiveRange: nil) as? URL
                == URL(string: "https://example.com") else {
            throw QAError.failed("Link label did not retain its clickable URL attribute")
        }
        guard rendered.attribute(.backgroundColor, at: fencedCodeRange.location, effectiveRange: nil) != nil else {
            throw QAError.failed("Fenced code did not receive its code background")
        }
    }

    /// Logical column boundaries belong to the entire table. A long value may
    /// wrap inside its own cell, but must never move later cells for only that
    /// row (the fixed-tab implementation regressed exactly this invariant).
    private static func assertWideTableLayout(_ rendered: NSAttributedString) throws {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 620, height: 6_000))
        textView.isEditable = false
        textView.isRichText = true
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(
            width: 620,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(rendered)
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            throw QAError.failed("Could not lay out the Markdown table regression fixture")
        }
        layoutManager.ensureLayout(for: textContainer)

        let longTool = try inspectCell(
            "tpi.query_artifact_analysis_with_an_extremely_long_unbreakable_identifier_that_must_wrap_inside_column_one",
            in: rendered,
            layoutManager: layoutManager,
            textContainer: textContainer
        )
        let longCalls = try inspectCell(
            "043",
            in: rendered,
            layoutManager: layoutManager,
            textContainer: textContainer
        )
        let longDescription = try inspectCell(
            "Third-A",
            in: rendered,
            layoutManager: layoutManager,
            textContainer: textContainer
        )
        let shortTool = try inspectCell(
            "Short",
            in: rendered,
            layoutManager: layoutManager,
            textContainer: textContainer
        )
        let shortCalls = try inspectCell(
            "007",
            in: rendered,
            layoutManager: layoutManager,
            textContainer: textContainer
        )
        let shortDescription = try inspectCell(
            "Third-B",
            in: rendered,
            layoutManager: layoutManager,
            textContainer: textContainer
        )

        let primaryTable = longTool.block.table
        let primaryCells = [
            longTool,
            longCalls,
            longDescription,
            shortTool,
            shortCalls,
            shortDescription,
        ]
        guard primaryCells.allSatisfy({ $0.block.table === primaryTable }) else {
            throw QAError.failed("Rows in one Markdown table did not share a native table layout")
        }
        guard longTool.block.startingColumn == 0,
              longCalls.block.startingColumn == 1,
              longDescription.block.startingColumn == 2,
              shortTool.block.startingColumn == 0,
              shortCalls.block.startingColumn == 1,
              shortDescription.block.startingColumn == 2 else {
            throw QAError.failed("Markdown table cells lost their logical column identities")
        }
        try assertAligned(
            longCalls,
            shortCalls,
            label: "second column after a long first cell"
        )
        try assertAligned(
            longDescription,
            shortDescription,
            label: "third column after a long first cell"
        )

        let longGlyphRange = layoutManager.glyphRange(
            forCharacterRange: longTool.characterRange,
            actualCharacterRange: nil
        )
        var wrappedLineCount = 0
        layoutManager.enumerateLineFragments(forGlyphRange: longGlyphRange) { _, _, _, _, _ in
            wrappedLineCount += 1
        }
        guard wrappedLineCount >= 2 else {
            throw QAError.failed("Long unbreakable Markdown table content did not wrap inside its cell")
        }

        let inlinePipe = try inspectCell(
            "scope|tool",
            in: rendered,
            layoutManager: layoutManager,
            textContainer: textContainer
        )
        let inlineCalls = try inspectCell(
            "011",
            in: rendered,
            layoutManager: layoutManager,
            textContainer: textContainer
        )
        let escapedPipe = try inspectCell(
            "Escaped | prose",
            in: rendered,
            layoutManager: layoutManager,
            textContainer: textContainer
        )
        let escapedCalls = try inspectCell(
            "012",
            in: rendered,
            layoutManager: layoutManager,
            textContainer: textContainer
        )
        guard inlinePipe.block.startingColumn == 0,
              inlineCalls.block.startingColumn == 1,
              escapedPipe.block.startingColumn == 0,
              escapedCalls.block.startingColumn == 1 else {
            throw QAError.failed("An escaped or inline-code pipe split a Markdown table cell")
        }
        let unmatchedBacktick = try inspectCell(
            "unclosed marker",
            in: rendered,
            layoutManager: layoutManager,
            textContainer: textContainer
        )
        let unmatchedCalls = try inspectCell(
            "013",
            in: rendered,
            layoutManager: layoutManager,
            textContainer: textContainer
        )
        let unmatchedDescription = try inspectCell(
            "Unmatched backtick remains a row",
            in: rendered,
            layoutManager: layoutManager,
            textContainer: textContainer
        )
        guard unmatchedBacktick.block.startingColumn == 0,
              unmatchedCalls.block.startingColumn == 1,
              unmatchedDescription.block.startingColumn == 2 else {
            throw QAError.failed("An unmatched backtick suppressed later Markdown table delimiters")
        }

        let wideSecondA = try inspectCell(
            "W2-A",
            in: rendered,
            layoutManager: layoutManager,
            textContainer: textContainer
        )
        let wideSecondB = try inspectCell(
            "W2-B",
            in: rendered,
            layoutManager: layoutManager,
            textContainer: textContainer
        )
        let wideSixthA = try inspectCell(
            "W6-A",
            in: rendered,
            layoutManager: layoutManager,
            textContainer: textContainer
        )
        let wideSixthB = try inspectCell(
            "W6-B",
            in: rendered,
            layoutManager: layoutManager,
            textContainer: textContainer
        )
        guard wideSecondA.block.startingColumn == 1,
              wideSecondB.block.startingColumn == 1,
              wideSixthA.block.startingColumn == 5,
              wideSixthB.block.startingColumn == 5,
              wideSecondA.block.table === wideSixthA.block.table else {
            throw QAError.failed("A wide Markdown table did not retain all six logical columns")
        }
        try assertAligned(wideSecondA, wideSecondB, label: "wide-table second column")
        try assertAligned(wideSixthA, wideSixthB, label: "wide-table sixth column")
    }

    private struct InspectedTableCell {
        let block: NSTextTableBlock
        let characterRange: NSRange
        let glyphRect: NSRect
        let lineFragmentRect: NSRect
    }

    private static func inspectCell(
        _ marker: String,
        in rendered: NSAttributedString,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) throws -> InspectedTableCell {
        let range = (rendered.string as NSString).range(of: marker)
        guard range.location != NSNotFound,
              range.length > 0,
              let paragraph = rendered.attribute(
                .paragraphStyle,
                at: range.location,
                effectiveRange: nil
              ) as? NSParagraphStyle,
              let block = paragraph.textBlocks.compactMap({ $0 as? NSTextTableBlock }).last else {
            throw QAError.failed("Could not resolve native Markdown table cell ‘\(marker)’")
        }
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: range,
            actualCharacterRange: nil
        )
        guard glyphRange.length > 0 else {
            throw QAError.failed("Markdown table marker ‘\(marker)’ had no laid-out glyph")
        }
        let firstGlyph = NSRange(location: glyphRange.location, length: 1)
        return InspectedTableCell(
            block: block,
            characterRange: range,
            glyphRect: layoutManager.boundingRect(forGlyphRange: firstGlyph, in: textContainer),
            lineFragmentRect: layoutManager.lineFragmentRect(
                forGlyphAt: glyphRange.location,
                effectiveRange: nil
            )
        )
    }

    private static func assertAligned(
        _ first: InspectedTableCell,
        _ second: InspectedTableCell,
        label: String
    ) throws {
        let glyphDelta = abs(first.glyphRect.minX - second.glyphRect.minX)
        let fragmentStartDelta = abs(first.lineFragmentRect.minX - second.lineFragmentRect.minX)
        let fragmentWidthDelta = abs(first.lineFragmentRect.width - second.lineFragmentRect.width)
        guard glyphDelta <= 1.5,
              fragmentStartDelta <= 1.5,
              fragmentWidthDelta <= 1.5 else {
            throw QAError.failed(
                "Markdown \(label) drifted across rows: glyph Δ \(glyphDelta), "
                    + "cell origin Δ \(fragmentStartDelta), width Δ \(fragmentWidthDelta)"
            )
        }
    }

    private static func render(
        _ content: NSAttributedString,
        appearance: NSAppearance,
        to url: URL
    ) throws {
        let width: CGFloat = 1_000
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 720))
        textView.appearance = appearance
        textView.isEditable = false
        textView.isRichText = true
        textView.drawsBackground = true
        textView.backgroundColor = LighTxtTheme.resolved(LighTxtTheme.editorBackground, for: appearance)
        textView.textContainerInset = NSSize(width: 48, height: 36)
        textView.textContainer?.containerSize = NSSize(width: width - 96, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(content)
        if let layoutManager = textView.layoutManager, let container = textView.textContainer {
            layoutManager.ensureLayout(for: container)
            let height = max(720, ceil(layoutManager.usedRect(for: container).height + 72))
            textView.setFrameSize(NSSize(width: width, height: height))
        }
        guard let bitmap = textView.bitmapImageRepForCachingDisplay(in: textView.bounds) else {
            throw QAError.failed("Could not create the renderer capture buffer")
        }
        textView.cacheDisplay(in: textView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw QAError.failed("Could not encode the renderer capture")
        }
        try png.write(to: url, options: .atomic)
    }

    private static func measureBoundedMainApply(appearance: NSAppearance) throws -> Double {
        let line = "- A **rendered** item with [a link](https://example.com) and `code` stays bounded.\n"
        let repetitions = (48 * 1_024) / line.utf8.count
        let source = String(repeating: line, count: repetitions)
        let prepared = try MarkdownSemanticPreparer.prepare(source)
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 720))
        textView.textContainer?.widthTracksTextView = true
        textView.layoutManager?.allowsNonContiguousLayout = true
        let clock = ContinuousClock()
        let started = clock.now
        let rendered = MarkdownNativeRenderer.render(
            prepared,
            appearance: appearance,
            startsMidDocument: false
        )
        textView.textStorage?.setAttributedString(rendered)
        let components = started.duration(to: clock.now).components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private static func assertAsyncViewportAndStalePublicationGate() throws -> (enqueue: Double, apply: Double) {
        let repeated = String(
            repeating: "- A **bounded** row with [link](https://example.com) and `code`.\n",
            count: 1_200
        )
        let oldDelegate = QAMarkdownDelegate(source: "# OLD STALE MARKER\n" + repeated)
        let newDelegate = QAMarkdownDelegate(source: "# NEW CURRENT MARKER\n" + repeated)
        let preview = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 720))
        var applyMilliseconds: Double?
        preview.onPerformanceSample = { milliseconds, _ in applyMilliseconds = milliseconds }
        preview.editorDelegate = oldDelegate
        let clock = ContinuousClock()
        let started = clock.now
        preview.editorDelegate = newDelegate
        let enqueueMilliseconds = durationMilliseconds(started.duration(to: clock.now))
        try wait(
            until: { applyMilliseconds != nil },
            timeout: 5,
            failure: "Asynchronous Markdown viewport did not publish"
        )
        guard let textView = descendant(of: preview, as: NSTextView.self) else {
            throw QAError.failed("Could not inspect the production Markdown text view")
        }
        guard textView.string.contains("NEW CURRENT MARKER"),
              !textView.string.contains("OLD STALE MARKER") else {
            throw QAError.failed("A cancelled Markdown generation published stale content")
        }
        guard enqueueMilliseconds < 20, let applyMilliseconds, applyMilliseconds < 100 else {
            throw QAError.failed(
                "Production Markdown latency exceeded its gate: enqueue \(enqueueMilliseconds), apply \(String(describing: applyMilliseconds))"
            )
        }
        preview.deactivate()
        return (enqueueMilliseconds, applyMilliseconds)
    }

    /// Exercises a table whose header and separator are outside the bounded
    /// render window. A mid-document viewport must still build one coherent
    /// table with stable cell geometry; it cannot rely on seeing the table's
    /// first source row.
    private static func assertPartialTableWindow() throws -> String {
        let prelude = String(
            repeating: "Prelude filler keeps the requested viewport away from byte zero.\n",
            count: 900
        )
        let header = "| Name | Count | Detail |\n| :--- | ---: | :---: |\n"
        let rows = (0..<720).map { row in
            let ordinal = String(format: "%04d", row)
            return "| partial_row_\(ordinal)_with_a_long_unbreakable_identifier_that_wraps_inside_its_cell | C\(ordinal) | Tail\(ordinal) |"
        }
        let midpoint = rows.count / 2
        let tablePrefix = header + rows[..<midpoint].joined(separator: "\n") + "\n"
        let tableSource = header + rows.joined(separator: "\n") + "\n"
        let postlude = String(
            repeating: "Postlude filler keeps the requested viewport away from true EOF.\n",
            count: 900
        )
        let source = prelude + tableSource + postlude
        let tableStart = Int64(prelude.utf8.count)
        let tableEnd = tableStart + Int64(tableSource.utf8.count)
        let target = tableStart + Int64(tablePrefix.utf8.count)

        let preview = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 700, height: 520))
        preview.appearance = NSAppearance(named: .aqua)
        var applyCount = 0
        preview.onPerformanceSample = { _, _ in applyCount += 1 }
        let delegate = QAMarkdownDelegate(source: source)
        preview.editorDelegate = delegate
        preview.layoutSubtreeIfNeeded()
        try wait(
            until: { applyCount >= 1 },
            timeout: 5,
            failure: "Initial render for the partial Markdown table fixture did not publish"
        )
        let appliesBeforePartialWindow = applyCount
        preview.scrollTo(byteOffset: target)
        try wait(
            until: { applyCount > appliesBeforePartialWindow },
            timeout: 5,
            failure: "Bounded mid-table Markdown viewport did not publish"
        )
        preview.layoutSubtreeIfNeeded()
        defer { preview.deactivate() }

        guard let exposed = delegate.lastExposedRange,
              exposed.lowerBound > tableStart,
              exposed.upperBound < tableEnd else {
            throw QAError.failed(
                "Partial-table QA did not actually render a bounded window inside the table: "
                    + "\(String(describing: delegate.lastExposedRange)) / \(tableStart)..<\(tableEnd)"
            )
        }
        guard let textView = descendant(of: preview, as: NSTextView.self),
              let rendered = textView.textStorage,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              rendered.string.contains("partial_row_") else {
            throw QAError.failed("Could not inspect the rendered partial Markdown table window")
        }
        layoutManager.ensureLayout(for: textContainer)
        let cells = tableCells(
            in: rendered,
            layoutManager: layoutManager,
            textContainer: textContainer
        )
        guard cells.count >= 90,
              let first = cells.first,
              cells.allSatisfy({ $0.block.table === first.block.table }) else {
            throw QAError.failed(
                "A bounded Markdown table window did not retain one shared native table (\(cells.count) cells)"
            )
        }
        let columns = Set(cells.map { $0.block.startingColumn })
        guard columns == Set(0..<3) else {
            throw QAError.failed("A bounded Markdown table window exposed columns \(columns), expected 0, 1, 2")
        }
        for column in 0..<3 {
            let columnCells = cells.filter { $0.block.startingColumn == column }
            guard columnCells.count >= 30 else {
                throw QAError.failed("Bounded Markdown column \(column) contained only \(columnCells.count) cells")
            }
            let glyphXs = columnCells.map(\.glyphRect.minX)
            let fragmentXs = columnCells.map(\.lineFragmentRect.minX)
            let fragmentWidths = columnCells.map(\.lineFragmentRect.width)
            guard spread(glyphXs) <= 1.5,
                  spread(fragmentXs) <= 1.5,
                  spread(fragmentWidths) <= 1.5 else {
                throw QAError.failed(
                    "Bounded Markdown column \(column) drifted across rows: glyph spread "
                        + "\(spread(glyphXs)), origin spread \(spread(fragmentXs)), "
                        + "width spread \(spread(fragmentWidths))"
                )
            }
        }
        return "partial-table window retained \(cells.count) aligned native cells"
    }

    private static func tableCells(
        in rendered: NSAttributedString,
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer
    ) -> [InspectedTableCell] {
        var cells: [InspectedTableCell] = []
        var seenBlocks: Set<ObjectIdentifier> = []
        let full = NSRange(location: 0, length: rendered.length)
        rendered.enumerateAttribute(.paragraphStyle, in: full) { value, range, _ in
            guard range.length > 0,
                  let paragraph = value as? NSParagraphStyle,
                  let block = paragraph.textBlocks.compactMap({ $0 as? NSTextTableBlock }).last,
                  seenBlocks.insert(ObjectIdentifier(block)).inserted else { return }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: range,
                actualCharacterRange: nil
            )
            guard glyphRange.length > 0 else { return }
            let firstGlyph = NSRange(location: glyphRange.location, length: 1)
            cells.append(InspectedTableCell(
                block: block,
                characterRange: range,
                glyphRect: layoutManager.boundingRect(
                    forGlyphRange: firstGlyph,
                    in: textContainer
                ),
                lineFragmentRect: layoutManager.lineFragmentRect(
                    forGlyphAt: glyphRange.location,
                    effectiveRange: nil
                )
            ))
        }
        return cells
    }

    private static func spread(_ values: [CGFloat]) -> CGFloat {
        guard let minimum = values.min(), let maximum = values.max() else {
            return .greatestFiniteMagnitude
        }
        return maximum - minimum
    }

    private static func assertProductionScrolling(
        source: String,
        outputDirectory: URL
    ) throws -> String {
        let preview = MarkdownPreviewView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 720))
        preview.appearance = NSAppearance(named: .aqua)
        var applyCount = 0
        preview.onPerformanceSample = { _, _ in applyCount += 1 }
        let attachedDelegate = QAMarkdownDelegate(source: source)
        preview.editorDelegate = attachedDelegate
        preview.layoutSubtreeIfNeeded()
        try wait(
            until: { applyCount >= 1 },
            timeout: 5,
            failure: "Attached Markdown scrolling fixture did not render"
        )
        preview.layoutSubtreeIfNeeded()

        guard let scrollView = descendant(of: preview, as: NSScrollView.self),
              let textView = descendant(of: preview, as: NSTextView.self) else {
            throw QAError.failed("Could not inspect the production Markdown scroll hierarchy")
        }
        guard !scrollView.hasVerticalScroller else {
            throw QAError.failed("Markdown preview exposed a second viewport-only vertical scroller")
        }
        let wholeDocumentScrollers = preview.subviews.compactMap { $0 as? NSScroller }
        guard wholeDocumentScrollers.count == 1 else {
            throw QAError.failed(
                "Expected one whole-document Markdown scroller, found \(wholeDocumentScrollers.count)"
            )
        }
        let clip = scrollView.contentView
        let maximumY = max(0, textView.frame.height - clip.bounds.height)
        guard maximumY > 100 else {
            throw QAError.failed(
                "Attached Markdown fixture did not create scrollable text geometry (height \(textView.frame.height))"
            )
        }

        clip.scroll(to: NSPoint(x: 0, y: maximumY))
        scrollView.reflectScrolledClipView(clip)
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        guard clip.bounds.minY >= maximumY - 2 else {
            throw QAError.failed("Markdown preview reset to the top after reaching its bottom")
        }

        // Reinstalling View mode should retain the visible source line rather
        // than implicitly treating every reload as a new document.
        let appliesBeforeReload = applyCount
        preview.reloadDocument()
        try wait(
            until: { applyCount > appliesBeforeReload },
            timeout: 5,
            failure: "Markdown position-preserving reload did not publish"
        )
        preview.layoutSubtreeIfNeeded()
        let reloadedMaximumY = max(0, textView.frame.height - clip.bounds.height)
        guard clip.bounds.minY > reloadedMaximumY * 0.25 else {
            throw QAError.failed(
                "Markdown View reload lost its bottom position: \(clip.bounds.minY) / \(reloadedMaximumY)"
            )
        }

        pumpRunLoop(for: 0.4)
        let appliesBeforeFinalWindow = applyCount
        clip.scroll(to: NSPoint(x: 0, y: reloadedMaximumY))
        scrollView.reflectScrolledClipView(clip)
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: clip
        )
        try wait(
            until: { applyCount > appliesBeforeFinalWindow },
            timeout: 5,
            failure: "Attached Markdown fixture did not advance to its final bounded window"
        )
        guard textView.string.contains("Initial release") else {
            throw QAError.failed("Attached Markdown final window omitted its final V1 content")
        }
        let finalMaximumY = max(0, textView.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: finalMaximumY))
        scrollView.reflectScrolledClipView(clip)
        pumpRunLoop(for: 0.5)
        guard clip.bounds.minY >= finalMaximumY - 2 else {
            throw QAError.failed("Attached Markdown final window reset after reaching true EOF")
        }
        try capture(
            preview,
            to: outputDirectory.appendingPathComponent("markdown-attached-bottom.png")
        )

        let appliesBeforeDarkCapture = applyCount
        preview.appearance = NSAppearance(named: .darkAqua)
        try wait(
            until: { applyCount > appliesBeforeDarkCapture },
            timeout: 5,
            failure: "Attached Markdown dark appearance did not republish"
        )
        preview.layoutSubtreeIfNeeded()
        let darkMaximumY = max(0, textView.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: darkMaximumY))
        scrollView.reflectScrolledClipView(clip)
        pumpRunLoop(for: 0.25)
        guard textView.string.contains("Initial release"),
              clip.bounds.minY >= darkMaximumY - 2 else {
            throw QAError.failed("Attached Markdown dark capture did not retain true EOF")
        }
        try capture(
            preview,
            to: outputDirectory.appendingPathComponent("markdown-attached-bottom-dark.png")
        )

        // A much larger source exercises the bounded handoff between rendered
        // windows. The top source line must advance and remain on screen.
        let virtualSource = (0..<6_000).map {
            "## Virtual section \($0)\nParagraph marker-\($0) keeps the bounded reader moving forward."
        }.joined(separator: "\n\n")
        let virtualPreview = MarkdownPreviewView(
            frame: NSRect(x: 0, y: 0, width: 1_000, height: 720)
        )
        var virtualApplyCount = 0
        virtualPreview.onPerformanceSample = { _, _ in virtualApplyCount += 1 }
        let virtualDelegate = QAMarkdownDelegate(source: virtualSource)
        virtualPreview.editorDelegate = virtualDelegate
        virtualPreview.layoutSubtreeIfNeeded()
        try wait(
            until: { virtualApplyCount == 1 },
            timeout: 5,
            failure: "Virtual Markdown fixture did not render its first window"
        )
        guard let virtualScroll = descendant(of: virtualPreview, as: NSScrollView.self),
              let virtualText = descendant(of: virtualPreview, as: NSTextView.self) else {
            throw QAError.failed("Could not inspect virtual Markdown hierarchy")
        }
        pumpRunLoop(for: 0.45)
        let virtualMaximumY = max(0, virtualText.frame.height - virtualScroll.contentView.bounds.height)
        virtualScroll.contentView.scroll(to: NSPoint(x: 0, y: virtualMaximumY))
        virtualScroll.reflectScrolledClipView(virtualScroll.contentView)
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: virtualScroll.contentView
        )
        try wait(
            until: { virtualApplyCount >= 2 },
            timeout: 5,
            failure: "Markdown virtual edge did not load the next bounded window"
        )
        guard !virtualText.string.contains("Virtual section 0"),
              virtualScroll.contentView.bounds.minY > 10 else {
            throw QAError.failed("Markdown virtual handoff reset to the beginning")
        }
        virtualPreview.deactivate()
        preview.deactivate()
        return "; attached 57.5 KiB scroll/reload and multi-window handoff passed"
    }

    private static func capture(_ view: NSView, to url: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw QAError.failed("Could not create attached-fixture capture buffer")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw QAError.failed("Could not encode attached-fixture capture")
        }
        try png.write(to: url, options: .atomic)
    }

    private static func descendant<T: NSView>(of root: NSView, as type: T.Type) -> T? {
        if let match = root as? T { return match }
        for child in root.subviews {
            if let match = descendant(of: child, as: type) { return match }
        }
        return nil
    }

    private static func wait(
        until condition: () -> Bool,
        timeout: TimeInterval,
        failure: String
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        guard condition() else { throw QAError.failed(failure) }
    }

    private static func pumpRunLoop(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
    }

    private static func durationMilliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private enum QAError: Error, LocalizedError {
        case usage
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .usage:
                return "Usage: markdown-renderer-qa <fixture.md> <capture-directory> [scroll-fixture.md]"
            case let .failed(message):
                return message
            }
        }
    }
}

@MainActor
private final class QAMarkdownDelegate: VirtualTextEditorDelegate {
    private let bytes: Data
    private let snapshot: DocumentSnapshot
    private(set) var lastExposedRange: Range<Int64>?
    init(source: String) {
        bytes = Data(source.utf8)
        snapshot = DocumentSnapshot(bytes)
    }
    var editorDocumentByteCount: Int64 { Int64(bytes.count) }
    var editorSyntaxFileType: SyntaxFileType { fatalError() }
    func editorSnapshot() throws -> DocumentSnapshot { snapshot }
    func editorReadBytes(in range: Range<Int64>) throws -> Data {
        bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
    }
    func editorReplaceBytes(in range: Range<Int64>, with bytes: Data) throws {}
    func editorLineLocation(at byteOffset: Int64) -> EditorLineLocation { EditorLineLocation() }
    func editorDidCommitEdit(replaced range: Range<Int64>, insertedByteCount: Int64) {}
    func editorSelectionDidChange(byteRange: Range<Int64>, line: Int64, column: Int) {}
    func editorDidLoadViewport(byteRange: Range<Int64>) {}
    func editorDidExpose(byteRange: Range<Int64>) { lastExposedRange = byteRange }
    func editorDidDiscoverStructure(
        folds: [SyntaxFoldRange],
        viewportData: Data,
        viewportBaseOffset: Int64
    ) {}
    func editorDidFail(_ error: Error) { fatalError(error.localizedDescription) }
}
#endif
