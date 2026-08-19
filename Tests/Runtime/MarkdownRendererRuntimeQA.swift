#if LIGHTXT_STANDALONE_MARKDOWN_QA
import AppKit
import Foundation

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
        try render(lightResult, appearance: light, to: outputDirectory.appendingPathComponent("markdown-light.png"))
        try render(darkResult, appearance: dark, to: outputDirectory.appendingPathComponent("markdown-dark.png"))
        let mainApplyMilliseconds = try measureBoundedMainApply(appearance: light)
        guard mainApplyMilliseconds < 100 else {
            throw QAError.failed(
                "Bounded Markdown main-thread apply took \(mainApplyMilliseconds) ms"
            )
        }
        let asyncSample = try assertAsyncViewportAndStalePublicationGate()
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
                + "light/dark captures rendered\(scrollingSummary)"
        )
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
            "Mode\tMemory behavior",
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
    func editorDidExpose(byteRange: Range<Int64>) {}
    func editorDidDiscoverStructure(
        folds: [SyntaxFoldRange],
        viewportData: Data,
        viewportBaseOffset: Int64
    ) {}
    func editorDidFail(_ error: Error) { fatalError(error.localizedDescription) }
}
#endif
