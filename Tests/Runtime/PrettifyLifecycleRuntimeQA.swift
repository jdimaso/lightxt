#if LIGHTXT_STANDALONE_PRETTIFY_QA
import AppKit
import Foundation

extension SyntaxFileType {
    var displayName: String {
        switch self {
        case .json: "JSON"
        case .yaml: "YAML"
        default: rawValue
        }
    }
}

public nonisolated final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
    public func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

final class DocumentSnapshot: @unchecked Sendable {
    private let bytes: Data
    let revision: UInt64
    let byteCount: Int64
    init(_ bytes: Data, revision: UInt64) {
        self.bytes = bytes
        self.revision = revision
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
struct PrettifyLifecycleRuntimeQA {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw QAError.usage }
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try assertHeaderAtMinimumWidth()
        try assertNonDestructiveDetachRestore(
            lightCapture: output.appendingPathComponent("prettify-light.png"),
            darkCapture: output.appendingPathComponent("prettify-dark.png")
        )
        print(
            "Prettify runtime QA passed: Edit-only keyboard checkbox fits 1000pt; "
                + "read-only light/dark preview; Cmd +/-/0; exact revision/dirty/undo, "
                + "caret, and visible byte range survive toggle on/off."
        )
    }

    private static func assertHeaderAtMinimumWidth() throws {
        let header = DocumentHeaderView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 60))
        var callback: Bool?
        header.onPrettifyChanged = { callback = $0 }
        header.update(
            fileURL: URL(fileURLWithPath: "/tmp/runtime.json"),
            title: "runtime.json",
            typeName: "JSON",
            typeAbbreviation: "JSON",
            byteCount: 128,
            edited: false,
            structureAvailable: true
        )
        header.presentationMode = .edit
        header.setPrettifyAvailable(true)
        let window = host(header, size: header.frame.size, appearance: .aqua)
        defer { window.close() }
        settle(window)
        guard header.qaPrettifyIsVisible,
              header.qaPrettifyIsEnabled,
              header.qaPrettifyAccessibilityLabel == "Prettify read-only preview",
              header.qaPrettifyFrame.width > 0,
              header.qaPrettifyFrame.maxX <= 281 else {
            throw QAError.failed("Prettify checkbox clipped or inaccessible at the 1000pt minimum")
        }
        header.qaActivatePrettify()
        guard callback == true else { throw QAError.failed("Keyboard/button activation did not toggle Prettify") }
        header.setPrettifyOn(true)
        guard header.qaPrettifyIsOn else { throw QAError.failed("Prettify state was not exposed") }
        header.presentationMode = .view
        header.setPrettifyAvailable(false)
        guard !header.qaPrettifyIsVisible, !header.qaPrettifyIsOn else {
            throw QAError.failed("Prettify remained visible outside JSON/YAML Edit mode")
        }
    }

    private static func assertNonDestructiveDetachRestore(
        lightCapture: URL,
        darkCapture: URL
    ) throws {
        let padding = String(repeating: "x", count: 160)
        let rows = (0..<4_000).map {
            #"{"id":\#($0),"padding":"\#(padding)","marker":"target-\#($0)"}"#
        }
        let bytes = Data(("[\n" + rows.joined(separator: ",\n") + "\n]").utf8)
        let delegate = QAEditorDelegate(bytes: bytes, revision: 42)
        let editor = VirtualTextEditorView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 620))
        editor.editorDelegate = delegate
        let hostView = NSView(frame: editor.frame)
        install(editor, in: hostView)
        let pinnedHostSize = hostView.frame.size
        let window = host(hostView, size: pinnedHostSize, appearance: .aqua)
        defer { window.close() }
        try wait(until: {
            guard let count = try? editor.presentationSnapshot().data.count else { return false }
            return count > 0 && count <= VirtualTextEditorView.maximumViewportBytes
        })

        let needle = Data("target-3000".utf8)
        let local = try XCTUnwrap(bytes.range(of: needle), "Missing selection fixture")
        let selected = Int64(local.lowerBound)..<Int64(local.upperBound)
        editor.scrollTo(byteRange: selected)
        try wait(until: { editor.selectedGlobalByteRange == selected })
        settle(window)
        try wait(until: { editor.selectedGlobalByteRange == selected })
        try assertHostSize(hostView, window: window, expected: pinnedHostSize, stage: "source")
        let selectionBefore = editor.selectedGlobalByteRange
        let presentationBefore = editor.capturePresentationState()
        let geometryBefore = editorGeometry(editor)
        guard let sourceScrollView = descendant(of: editor, as: NSScrollView.self) else {
            throw QAError.failed("Could not inspect source editor geometry")
        }
        let physicalHorizontalBefore = sourceScrollView.contentView.bounds.minX
        guard presentationBefore.anchorByteOffset > 0,
              presentationBefore.horizontalOffset > 100,
              abs(physicalHorizontalBefore - presentationBefore.horizontalOffset) < 0.5 else {
            throw QAError.failed(
                "Prettify fixture did not exercise off-origin vertical and horizontal state: "
                    + "anchor=\(presentationBefore.anchorByteOffset), "
                    + "remembered horizontal=\(presentationBefore.horizontalOffset), "
                    + "physical horizontal=\(physicalHorizontalBefore)"
            )
        }
        let revisionBefore = delegate.revision
        let dirtyBefore = delegate.isDirty
        let undoBefore = delegate.undoCount

        let snapshot = try editor.presentationSnapshot()
        let formatted = try ViewportPrettifier.prettify(
            snapshot.data,
            as: .json,
            viewportRange: snapshot.byteRange,
            documentByteCount: snapshot.documentByteCount,
            leadingContext: snapshot.leadingContext,
            leadingContextStartByteOffset: snapshot.leadingContextStartByteOffset
        )
        guard formatted.didPrettify else { throw QAError.failed(formatted.status) }
        let preview = PrettifiedViewportView(frame: hostView.bounds)
        install(preview, in: hostView)
        preview.show(formatted)
        settle(window)
        try assertHostSize(hostView, window: window, expected: pinnedHostSize, stage: "preview")
        guard !preview.qaIsEditable,
              preview.qaIsSelectable,
              preview.qaAccessibilityLabel == "Read-only prettified viewport",
              preview.qaTextAccessibilityLabel == "Read-only prettified source",
              preview.qaText.contains("\n") else {
            throw QAError.failed("Prettify overlay was not a readable, selectable, read-only surface")
        }
        for _ in 0..<30 { preview.changeFontSize(by: 1) }
        guard preview.qaFontSize == 30 else { throw QAError.failed("Prettify maximum zoom changed") }
        preview.resetFontSize()
        guard preview.qaFontSize == 13 else { throw QAError.failed("Prettify reset zoom changed") }
        try capture(hostView, to: lightCapture)
        hostView.appearance = NSAppearance(named: .darkAqua)
        settle(window)
        try capture(hostView, to: darkCapture)

        install(editor, in: hostView)
        editor.restorePresentationState(presentationBefore)
        settle(window)
        try assertHostSize(hostView, window: window, expected: pinnedHostSize, stage: "restored source")
        let presentationAfter = editor.capturePresentationState()
        let geometryAfter = editorGeometry(editor)
        guard let restoredScrollView = descendant(of: editor, as: NSScrollView.self),
              let restoredTextView = descendant(of: editor, as: NSTextView.self) else {
            throw QAError.failed("Could not inspect restored editor geometry")
        }
        let restoredLeadingX = -(restoredScrollView.verticalRulerView?.ruleThickness ?? 0)
        let restoredMaximumX = restoredLeadingX + max(
            0,
            restoredTextView.frame.width - restoredScrollView.contentView.bounds.width
        )
        let expectedHorizontalOffset = min(
            max(restoredLeadingX, presentationBefore.horizontalOffset),
            restoredMaximumX
        )
        guard delegate.revision == revisionBefore,
              delegate.isDirty == dirtyBefore,
              delegate.undoCount == undoBefore,
              editor.selectedGlobalByteRange == selectionBefore,
              editor.visibleGlobalByteRange.lowerBound == presentationBefore.anchorByteOffset,
              abs(expectedHorizontalOffset - presentationBefore.horizontalOffset) < 0.5,
              abs(
                presentationAfter.horizontalOffset
                    - expectedHorizontalOffset
              ) < 0.5,
              abs(
                restoredScrollView.contentView.bounds.minX
                    - presentationAfter.horizontalOffset
              ) < 0.5 else {
            throw QAError.failed(
                "Toggle changed source state or editor geometry: "
                    + "revision \(revisionBefore) -> \(delegate.revision), "
                    + "dirty \(dirtyBefore) -> \(delegate.isDirty), "
                    + "undo \(undoBefore) -> \(delegate.undoCount), "
                    + "selection \(selectionBefore) -> \(editor.selectedGlobalByteRange), "
                    + "anchor \(presentationBefore.anchorByteOffset) -> \(editor.visibleGlobalByteRange), "
                    + "horizontal \(presentationBefore.horizontalOffset) -> \(presentationAfter.horizontalOffset) "
                    + "(expected clamped \(expectedHorizontalOffset)), "
                    + "geometry [\(geometryBefore)] -> [\(geometryAfter)]"
            )
        }
    }

    private static func editorGeometry(_ editor: NSView) -> String {
        guard let scrollView = descendant(of: editor, as: NSScrollView.self),
              let textView = descendant(of: editor, as: NSTextView.self) else {
            return "unavailable"
        }
        let usedWidth: CGFloat
        if let manager = textView.layoutManager,
           let container = textView.textContainer {
            manager.ensureLayout(for: container)
            usedWidth = manager.usedRect(for: container).width
        } else {
            usedWidth = -1
        }
        return "clipX=\(scrollView.contentView.bounds.minX), "
            + "clipW=\(scrollView.contentView.bounds.width), "
            + "contentW=\(scrollView.contentSize.width), "
            + "frameW=\(textView.frame.width), minW=\(textView.minSize.width), "
            + "usedW=\(usedWidth)"
    }

    private static func descendant<T: NSView>(of root: NSView, as type: T.Type) -> T? {
        if let match = root as? T { return match }
        for child in root.subviews {
            if let match = descendant(of: child, as: type) { return match }
        }
        return nil
    }

    private static func assertHostSize(
        _ hostView: NSView,
        window: NSWindow,
        expected: NSSize,
        stage: String
    ) throws {
        let contentSize = window.contentView?.bounds.size ?? .zero
        guard abs(hostView.bounds.width - expected.width) < 0.5,
              abs(hostView.bounds.height - expected.height) < 0.5,
              abs(contentSize.width - expected.width) < 0.5,
              abs(contentSize.height - expected.height) < 0.5 else {
            throw QAError.failed(
                "Prettify QA host resized during \(stage): "
                    + "expected \(expected), host \(hostView.bounds.size), window \(contentSize)"
            )
        }
    }

    private static func install(_ child: NSView, in parent: NSView) {
        parent.subviews.forEach { $0.removeFromSuperview() }
        child.frame = parent.bounds
        child.autoresizingMask = [.width, .height]
        parent.addSubview(child)
        child.layoutSubtreeIfNeeded()
    }

    private static func host(_ view: NSView, size: NSSize, appearance: NSAppearance.Name) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        window.setContentSize(size)
        window.contentMinSize = size
        window.contentMaxSize = size
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: size.width),
            view.heightAnchor.constraint(equalToConstant: size.height),
        ])
        window.layoutIfNeeded()
        return window
    }

    private static func settle(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private static func wait(
        timeout: TimeInterval = 3,
        until condition: () -> Bool
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
        guard condition() else { throw QAError.failed("Timed out waiting for editor state") }
    }

    private static func capture(_ view: NSView, to url: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw QAError.failed("Could not render Prettify QA")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw QAError.failed("Could not encode Prettify QA")
        }
        try png.write(to: url, options: .atomic)
    }

    private static func XCTUnwrap<T>(_ value: T?, _ message: String) throws -> T {
        guard let value else { throw QAError.failed(message) }
        return value
    }

    private enum QAError: Error, LocalizedError {
        case usage
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .usage: "Usage: prettify-runtime-qa <capture-directory>"
            case .failed(let message): message
            }
        }
    }
}

@MainActor
private final class QAEditorDelegate: VirtualTextEditorDelegate {
    private let bytes: Data
    let revision: UInt64
    var isDirty = false
    var undoCount = 0

    init(bytes: Data, revision: UInt64) {
        self.bytes = bytes
        self.revision = revision
    }

    var editorDocumentByteCount: Int64 { Int64(bytes.count) }
    var editorSyntaxFileType: SyntaxFileType { .json }
    func editorSnapshot() throws -> DocumentSnapshot { DocumentSnapshot(bytes, revision: revision) }
    func editorReadBytes(in range: Range<Int64>) throws -> Data {
        bytes.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
    }
    func editorReplaceBytes(in range: Range<Int64>, with bytes: Data) throws {
        throw QAError.mutation
    }
    func editorLineLocation(at byteOffset: Int64) -> EditorLineLocation {
        EditorLineLocation(lineNumber: 1, lineStartByteOffset: 0)
    }
    func editorDidCommitEdit(replaced range: Range<Int64>, insertedByteCount: Int64) {
        isDirty = true
        undoCount += 1
    }
    func editorSelectionDidChange(byteRange: Range<Int64>, line: Int64, column: Int) {}
    func editorDidLoadViewport(byteRange: Range<Int64>) {}
    func editorDidExpose(byteRange: Range<Int64>) {}
    func editorDidDiscoverStructure(
        folds: [SyntaxFoldRange],
        viewportData: Data,
        viewportBaseOffset: Int64
    ) {}
    func editorDidFail(_ error: Error) { fatalError(error.localizedDescription) }

    private enum QAError: Error { case mutation }
}
#endif
