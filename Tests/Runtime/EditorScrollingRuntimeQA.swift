#if LIGHTXT_STANDALONE_EDITOR_SCROLL_QA
import AppKit
import Foundation

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

enum LighTxtSignpost {
    static func begin(_ name: StaticString, bytes: Int64) {}
    static func end(_ name: StaticString, bytes: Int64) {}
}

@MainActor
final class LighTxtEditorViewController: NSViewController {
    @objc func undoDocumentEdit(_ sender: Any?) {}
}

@main
@MainActor
struct EditorScrollingRuntimeQA {
    static func main() throws {
        guard CommandLine.arguments.count >= 3 else { throw QAError.usage }
        _ = NSApplication.shared
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1])
        let capture = URL(fileURLWithPath: CommandLine.arguments[2])
        let source = try Data(contentsOf: fixture)
        guard source.count == 57_531 else {
            throw QAError.failed("Expected exact 57,531-byte attachment, got \(source.count)")
        }

        let delegate = QAEditorDelegate(bytes: source)
        let editor = VirtualTextEditorView(
            frame: NSRect(x: 0, y: 0, width: 1_000, height: 720)
        )
        editor.editorDelegate = delegate
        editor.layoutSubtreeIfNeeded()

        guard let scrollView = descendant(of: editor, as: NSScrollView.self),
              let textView = descendant(of: editor, as: NSTextView.self) else {
            throw QAError.failed("Could not inspect the production Edit hierarchy")
        }
        guard !scrollView.hasVerticalScroller else {
            throw QAError.failed("Edit exposed a second viewport-only vertical scroller")
        }
        let wholeDocumentScrollers = editor.subviews.compactMap { $0 as? NSScroller }
        guard wholeDocumentScrollers.count == 1 else {
            throw QAError.failed(
                "Expected one whole-document Edit scroller, found \(wholeDocumentScrollers.count)"
            )
        }
        guard let wholeDocumentScroller = wholeDocumentScrollers.first as? LighTxtComfortScroller,
              scrollView.horizontalScroller is LighTxtComfortScroller else {
            throw QAError.failed("Edit did not install the production comfort scrollers")
        }
        try assertComfortScrollerMetrics()
        let expectedWholeDocumentWidth = LighTxtComfortScroller.scrollerWidth(
            for: .small,
            scrollerStyle: .overlay
        )
        guard abs(wholeDocumentScroller.bounds.width - expectedWholeDocumentWidth) < 0.5 else {
            throw QAError.failed(
                "Whole-document scroller width was \(wholeDocumentScroller.bounds.width), "
                    + "expected \(expectedWholeDocumentWidth)"
            )
        }
        guard let horizontalScroller = scrollView.horizontalScroller else {
            throw QAError.failed("Edit horizontal comfort scroller disappeared during layout")
        }
        let nativeHorizontalHeight = NSScroller.scrollerWidth(
            for: horizontalScroller.controlSize,
            scrollerStyle: horizontalScroller.scrollerStyle
        )
        let expectedHorizontalHeight = LighTxtComfortScroller.scrollerWidth(
            for: horizontalScroller.controlSize,
            scrollerStyle: horizontalScroller.scrollerStyle
        )
        guard abs(horizontalScroller.bounds.height - expectedHorizontalHeight) < 0.5,
              horizontalScroller.bounds.height >= nativeHorizontalHeight + 1.5 else {
            throw QAError.failed(
                "Edit managed horizontal scroller was not physically widened: "
                    + "actual \(horizontalScroller.bounds.height), native \(nativeHorizontalHeight), "
                    + "expected \(expectedHorizontalHeight)"
            )
        }
        guard scrollView.autohidesScrollers else {
            throw QAError.failed("Edit comfort scroller forced the horizontal bar to remain visible")
        }

        let clip = scrollView.contentView
        // AppKit has used both x=0 and a negative ruler-adjusted clip origin
        // across supported macOS releases. Treat the laid-out origin as the
        // visual leading edge and assert every subsequent delta from it.
        let leadingX = clip.bounds.minX
        let rulerWidth = scrollView.verticalRulerView?.ruleThickness ?? 0
        guard rulerWidth > 0,
              abs(leadingX) < 0.5 || abs(leadingX + rulerWidth) < 0.5 else {
            throw QAError.failed(
                "Edit initialized outside the supported ruler coordinate models: \(leadingX)"
            )
        }
        let maximumY = max(0, textView.frame.height - clip.bounds.height)
        guard maximumY > 100 else {
            throw QAError.failed(
                "Edit text geometry was not scrollable: text \(textView.frame.height), clip \(clip.bounds.height)"
            )
        }
        clip.scroll(to: NSPoint(x: leadingX, y: maximumY))
        scrollView.reflectScrolledClipView(clip)
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: clip
        )
        pumpRunLoop(for: 0.2)
        guard clip.bounds.minY >= maximumY - 2 else {
            throw QAError.failed("Edit reset before reaching the attached fixture's bottom")
        }
        guard abs(clip.bounds.minX - leadingX) < 0.5 else {
            throw QAError.failed("Vertical Edit scrolling introduced horizontal delta \(clip.bounds.minX - leadingX)")
        }

        editor.reloadPreservingSelection()
        editor.layoutSubtreeIfNeeded()
        let reloadedMaximumY = max(0, textView.frame.height - clip.bounds.height)
        guard clip.bounds.minY > reloadedMaximumY * 0.80 else {
            throw QAError.failed(
                "Edit/View mode-style reload lost its scroll position: \(clip.bounds.minY) / \(reloadedMaximumY)"
            )
        }
        guard abs(clip.bounds.minX - leadingX) < 0.5 else {
            throw QAError.failed("Mode-style Edit reload inherited horizontal delta \(clip.bounds.minX - leadingX)")
        }

        // A real user horizontal scroll is intentional and should survive a
        // bounded reload; vertical paging alone must never manufacture one.
        let deliberateDelta = min(160, max(0, textView.frame.width - clip.bounds.width))
        let deliberateX = leadingX + deliberateDelta
        guard deliberateDelta > 20 else {
            throw QAError.failed("Fixture unexpectedly has no horizontal Edit extent")
        }
        clip.scroll(to: NSPoint(x: deliberateX, y: clip.bounds.minY))
        scrollView.reflectScrolledClipView(clip)
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: clip
        )
        editor.reloadPreservingSelection()
        guard abs(clip.bounds.minX - deliberateX) < 2 else {
            throw QAError.failed(
                "Deliberate horizontal Edit position was not retained: \(clip.bounds.minX) / \(deliberateX)"
            )
        }

        clip.scroll(to: NSPoint(x: leadingX, y: clip.bounds.minY))
        scrollView.reflectScrolledClipView(clip)
        NotificationCenter.default.post(
            name: NSView.boundsDidChangeNotification,
            object: clip
        )
        editor.reloadPreservingSelection()
        guard abs(clip.bounds.minX - leadingX) < 0.5 else {
            throw QAError.failed("Returning Edit to the leading edge did not persist")
        }

        try captureView(editor, to: capture)

        editor.appearance = NSAppearance(named: .darkAqua)
        editor.layoutSubtreeIfNeeded()
        pumpRunLoop(for: 0.25)
        guard clip.bounds.minY > reloadedMaximumY * 0.80,
              abs(clip.bounds.minX - leadingX) < 0.5 else {
            throw QAError.failed("Dark appearance changed Edit's retained viewport")
        }
        let darkCapture = capture
            .deletingPathExtension()
            .appendingPathExtension("dark.png")
        try captureView(editor, to: darkCapture)
        print(
            "Edit scrolling QA passed: exact=57,531 bytes, one vertical scroller, "
                + "top→bottom=\(String(format: "%.1f", maximumY)) pt, reload retained position, "
                + "vertical leading x=\(String(format: "%.1f", leadingX)) / deliberate "
                + "horizontal x retained; native auto-hiding scrollers are +2 pt; "
                + "light/dark captures rendered"
        )
    }

    private static func assertComfortScrollerMetrics() throws {
        guard LighTxtComfortScroller.isCompatibleWithOverlayScrollers else {
            throw QAError.failed("Comfort scroller disabled native overlay compatibility")
        }
        for style in [NSScroller.Style.overlay, .legacy] {
            for size in [NSControl.ControlSize.small, .regular] {
                let native = NSScroller.scrollerWidth(for: size, scrollerStyle: style)
                let comfortable = LighTxtComfortScroller.scrollerWidth(
                    for: size,
                    scrollerStyle: style
                )
                guard abs((comfortable - native) - 2) < 0.01 else {
                    throw QAError.failed(
                        "Comfort scroller delta changed for \(style)/\(size): "
                            + "native \(native), comfortable \(comfortable)"
                    )
                }
            }
        }
    }

    private static func captureView(_ view: NSView, to url: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw QAError.failed("Could not create Edit scrolling capture")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw QAError.failed("Could not encode Edit scrolling capture")
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

    private static func pumpRunLoop(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
    }

    private enum QAError: Error, LocalizedError {
        case usage
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .usage:
                "Usage: editor-scroll-qa <exact-fixture> <capture.png>"
            case .failed(let message):
                message
            }
        }
    }
}

@MainActor
private final class QAEditorDelegate: VirtualTextEditorDelegate {
    private var bytes: Data

    init(bytes: Data) { self.bytes = bytes }

    var editorDocumentByteCount: Int64 { Int64(bytes.count) }
    var editorSyntaxFileType: SyntaxFileType { .markdown }
    func editorSnapshot() throws -> DocumentSnapshot { DocumentSnapshot(bytes) }
    func editorReadBytes(in range: Range<Int64>) throws -> Data {
        bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
    }
    func editorReplaceBytes(in range: Range<Int64>, with replacement: Data) throws {
        bytes.replaceSubrange(Int(range.lowerBound)..<Int(range.upperBound), with: replacement)
    }
    func editorLineLocation(at byteOffset: Int64) -> EditorLineLocation {
        let upper = min(bytes.count, max(0, Int(byteOffset)))
        var line: Int64 = 1
        var lineStart = 0
        for (index, byte) in bytes[..<upper].enumerated() where byte == 0x0A {
            line += 1
            lineStart = index + 1
        }
        return EditorLineLocation(
            lineNumber: line,
            lineStartByteOffset: Int64(lineStart)
        )
    }
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
