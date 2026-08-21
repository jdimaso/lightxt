#if LIGHTXT_STANDALONE_STRUCTURE_QA
import AppKit
import Foundation

// Minimal declarations used only when the production structured-view sources
// are compiled as this standalone AppKit QA executable.
enum SyntaxFileType { case plainText, json, markdown, sql, xml, csv, yaml, parquet }
enum SyntaxFoldKind: String { case object, array, element, mapping, sequence, scalar, comment }
struct SyntaxByteRange: Hashable {
    let start: Int
    let length: Int
    init(start: Int, length: Int) {
        self.start = start
        self.length = length
    }
    var end: Int { start + length }
}
struct SyntaxFoldRange: Hashable {
    let range: SyntaxByteRange
    let headerRange: SyntaxByteRange
    let contentRange: SyntaxByteRange
    let kind: SyntaxFoldKind
    let depth: Int
}
struct SearchMatch: Sendable, Equatable {
    let byteRange: Range<Int64>
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

final class DocumentSnapshot: @unchecked Sendable {
    private let data: Data
    private let lock = NSLock()
    private(set) var byteCount: Int64
    private var recordedRanges: [Range<Int64>] = []

    init(_ data: Data) {
        self.data = data
        byteCount = Int64(data.count)
    }

    func data(in range: Range<Int64>) throws -> Data {
        lock.lock()
        recordedRanges.append(range)
        lock.unlock()
        return data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound))
    }

    var readRanges: [Range<Int64>] {
        lock.lock()
        defer { lock.unlock() }
        return recordedRanges
    }
}

enum LighTxtTheme {
    static let primaryText = NSColor.labelColor
    static let secondaryText = NSColor.secondaryLabelColor
    static let separator = NSColor.separatorColor
    static let chromeBackground = NSColor.windowBackgroundColor
    static let accent = NSColor.systemTeal
    static let selection = NSColor.selectedContentBackgroundColor
    static let error = NSColor.systemRed

    static func resolved(_ color: NSColor, for appearance: NSAppearance) -> NSColor {
        var result = color
        appearance.performAsCurrentDrawingAppearance {
            result = color.usingColorSpace(.deviceRGB) ?? color
        }
        return result
    }
}

extension ByteCountFormatter {
    static let lighTxt: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()
}

@MainActor
final class HeaderIconButton: NSView {
    var onActivate: (() -> Void)?
    init(symbolName: String, accessibilityLabel: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(accessibilityLabel)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 32),
            heightAnchor.constraint(equalToConstant: 32),
        ])
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

@main
@MainActor
struct StructuredViewRuntimeQA {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw QAError.usage }
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        try assertFindOnlyLayoutAtMinimumWidth()
        let sourceResult = try assertSourceFaithfulUnicodeHighlight()
        try assertBoundedAndCancellablePreviewReads()
        try assertStructureInteractionsAndZoom()
        try assertYAMLOffViewportParity(sourceResult: sourceResult)
        try renderSearchResults(sourceResult, appearance: .aqua, to: output.appendingPathComponent("structured-search-light.png"))
        try renderSearchResults(sourceResult, appearance: .darkAqua, to: output.appendingPathComponent("structured-search-dark.png"))

        print(
            "Structured View runtime QA passed: find-only 1000pt layout, exact Unicode source highlight, "
                + "bounded/cancellable previews, single-expand/double-collapse, 15–28pt zoom with fitting rows, "
                + "YAML off-viewport search navigation, light/dark rendering, and accessibility labels."
        )
    }

    private static func assertFindOnlyLayoutAtMinimumWidth() throws {
        let bar = FindBarView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 56))
        bar.presentation = .findOnly
        let window = host(bar, size: bar.frame.size, appearance: .aqua)
        defer { window.close() }
        settle(window)

        guard bar.preferredHeight == 56,
              bar.qaSecondRowIsHidden,
              !bar.qaReplaceControlsAreEnabled else {
            throw QAError.failed("View mode did not produce a one-row Find-only bar")
        }
        guard bar.qaSearchFieldFrame.width >= 180,
              bar.bounds.contains(bar.qaSearchFieldFrame) else {
            throw QAError.failed("Find query field clipped at the 1000pt minimum width: \(bar.qaSearchFieldFrame)")
        }
        let frames = bar.qaFirstRowControlFrames.sorted { $0.minX < $1.minX }
        guard frames.allSatisfy({ bar.bounds.insetBy(dx: -0.5, dy: -0.5).contains($0) }) else {
            throw QAError.failed("A Find-only control escaped the 1000pt bar: \(frames)")
        }
        guard zip(frames, frames.dropFirst()).allSatisfy({ $0.maxX <= $1.minX + 0.5 }) else {
            throw QAError.failed("Find-only controls overlap at 1000pt: \(frames)")
        }
        guard Set(bar.qaVisibleActionLabels) == ["Previous match", "Next match", "Find all"] else {
            throw QAError.failed("View Find exposed Replace actions: \(bar.qaVisibleActionLabels)")
        }

        bar.frame.size.height = 104
        bar.presentation = .findAndReplace
        settle(window)
        guard !bar.qaSecondRowIsHidden, bar.qaReplaceControlsAreEnabled,
              bar.preferredHeight == 104 else {
            throw QAError.failed("Edit mode did not restore the two-row Find and Replace UI")
        }
    }

    private static func assertSourceFaithfulUnicodeHighlight() throws -> StructureSearchResult {
        let source = #"{"note":"before 🚀 café \u00E9 after"}"#
        let bytes = Data(source.utf8)
        let needle = Data("🚀 café".utf8)
        guard let localRange = bytes.range(of: needle) else {
            throw QAError.failed("Unicode QA fixture is invalid")
        }
        let match = SearchMatch(
            byteRange: Int64(localRange.lowerBound)..<Int64(localRange.upperBound)
        )
        guard let result = StructureSearchResultBuilder.build(
            snapshot: DocumentSnapshot(bytes),
            matches: [match]
        ).first else {
            throw QAError.failed("No source preview was built for the Unicode match")
        }
        let highlighted = (result.text as NSString).substring(
            with: NSRange(
                location: result.highlightUTF16Range.lowerBound,
                length: result.highlightUTF16Range.count
            )
        )
        guard highlighted == "🚀 café",
              result.highlightUTF16Range.count == (highlighted as NSString).length else {
            throw QAError.failed(
                "UTF-8 bytes did not map to the exact displayed UTF-16 match: \(highlighted) / \(result.highlightUTF16Range)"
            )
        }
        return result
    }

    private static func assertBoundedAndCancellablePreviewReads() throws {
        let source = Data(repeating: 0x61, count: 4 << 20)
        let snapshot = DocumentSnapshot(source)
        let largeRegexMatch = SearchMatch(byteRange: 128..<Int64((3 << 20) + 128))
        let result = StructureSearchResultBuilder.build(
            snapshot: snapshot,
            matches: [largeRegexMatch]
        )
        guard result.count == 1,
              snapshot.readRanges.count == 3,
              snapshot.readRanges.map(\.count).max() ?? 0 <= 2 << 10 else {
            throw QAError.failed("A large regex match caused an unbounded source-preview read: \(snapshot.readRanges)")
        }

        let cancelledSnapshot = DocumentSnapshot(source)
        let cancellation = CancellationToken()
        cancellation.cancel()
        let cancelled = StructureSearchResultBuilder.build(
            snapshot: cancelledSnapshot,
            matches: Array(repeating: largeRegexMatch, count: 20_000),
            cancellation: cancellation
        )
        guard cancelled.isEmpty, cancelledSnapshot.readRanges.isEmpty else {
            throw QAError.failed("A stale Find All preview ignored cancellation")
        }
    }

    private static func assertStructureInteractionsAndZoom() throws {
        let child = StructureSidebarNode(
            identifier: "json-child",
            title: "child",
            subtitle: "String",
            range: 8..<15,
            kind: .scalar
        )
        let root = StructureSidebarNode(
            identifier: "json-root",
            title: "Root object",
            subtitle: "Object · 1 member",
            range: 0..<32,
            kind: .object,
            children: [child]
        )
        let scalar = StructureSidebarNode(
            identifier: "json-scalar",
            title: "version",
            subtitle: "String",
            range: 33..<40,
            kind: .scalar
        )
        let view = StructureSidebarView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 620))
        view.presentation = .fullWorkspace
        let window = host(view, size: view.frame.size, appearance: .aqua)
        defer { window.close() }
        view.applyTreeSnapshot([root, scalar], title: "JSON Explorer", preservingExpansion: false)
        settle(window)

        guard !view.qaIsExpanded(identifier: "json-root") else {
            throw QAError.failed("Two-root JSON fixture should begin collapsed")
        }
        view.qaPerformRowGesture(identifier: "json-root", clickCount: 1)
        guard view.qaIsExpanded(identifier: "json-root") else {
            throw QAError.failed("A single container-row click did not expand JSON")
        }
        view.qaPerformRowGesture(identifier: "json-root", clickCount: 2)
        guard !view.qaIsExpanded(identifier: "json-root") else {
            throw QAError.failed("A double container-row click did not collapse JSON")
        }
        view.qaPerformRowGesture(identifier: "json-scalar", clickCount: 1)
        guard !view.qaIsExpanded(identifier: "json-scalar") else {
            throw QAError.failed("A scalar row became expandable")
        }
        view.appendChildren(
            of: "json-root",
            page: [StructureSidebarNode(
                identifier: "late-child",
                title: "late",
                subtitle: "String",
                range: 16..<20,
                kind: .scalar
            )],
            continuation: nil,
            final: true
        )
        guard !view.qaIsExpanded(identifier: "json-root") else {
            throw QAError.failed("Late child publication reopened a double-collapsed JSON row")
        }

        guard view.qaFullWorkspaceFontSize == 15 else {
            throw QAError.failed("Structured View did not default to the larger 15pt font")
        }
        for _ in 0..<20 { view.changeFullWorkspaceFontSize(by: 1) }
        guard view.qaFullWorkspaceFontSize == 28, view.qaRowHeight >= 66 else {
            throw QAError.failed("Maximum structured zoom clips its two-line rows: \(view.qaRowHeight)")
        }
        for _ in 0..<30 { view.changeFullWorkspaceFontSize(by: -1) }
        guard view.qaFullWorkspaceFontSize == 11 else {
            throw QAError.failed("Structured zoom-out did not honor its readable lower bound")
        }
        view.resetFullWorkspaceFontSize()
        guard view.qaFullWorkspaceFontSize == 15 else {
            throw QAError.failed("Structured zoom reset did not restore the 15pt default")
        }
    }

    private static func assertYAMLOffViewportParity(
        sourceResult: StructureSearchResult
    ) throws {
        let base = 2_000_000
        let yaml = Data("claims:\n  - id: 2026\n    state: open\n".utf8)
        let folds = [
            SyntaxFoldRange(
                range: SyntaxByteRange(start: base, length: yaml.count),
                headerRange: SyntaxByteRange(start: base, length: 7),
                contentRange: SyntaxByteRange(start: base + 7, length: yaml.count - 7),
                kind: .mapping,
                depth: 0
            ),
            SyntaxFoldRange(
                range: SyntaxByteRange(start: base + 8, length: yaml.count - 8),
                headerRange: SyntaxByteRange(start: base + 8, length: 10),
                contentRange: SyntaxByteRange(start: base + 18, length: yaml.count - 18),
                kind: .sequence,
                depth: 1
            ),
        ]
        let view = StructureSidebarView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 620))
        view.presentation = .fullWorkspace
        let delegate = RevealSpy()
        view.delegate = delegate
        let window = host(view, size: view.frame.size, appearance: .aqua)
        defer { window.close() }
        view.update(folds: folds, viewportData: yaml, viewportBaseOffset: Int64(base), fileType: .yaml)
        settle(window)
        guard view.qaTitle == "Document Structure", view.qaScope.contains("groups") else {
            throw QAError.failed("YAML did not use the structured View adapter")
        }

        let farMatch = StructureSearchResult(
            match: SearchMatch(byteRange: 9_000_100..<9_000_109),
            text: sourceResult.text,
            highlightUTF16Range: sourceResult.highlightUTF16Range
        )
        view.updateSearchResults([farMatch], total: 1, truncated: false, title: "YAML Explorer")
        settle(window)
        guard view.qaSelectedRange == nil, delegate.activationCount == 0 else {
            throw QAError.failed("Find All selected/activated a result before user input")
        }
        view.selectSearchResult(matching: farMatch.match.byteRange)
        settle(window)
        guard view.qaSelectedRange == farMatch.match.byteRange,
              delegate.lastRange == farMatch.match.byteRange,
              delegate.activationCount == 1,
              view.qaTitle == "YAML Explorer" else {
            throw QAError.failed("An off-viewport YAML match was not selected/revealed in View")
        }

        // This is the same bounded restoration used when Find closes.
        view.update(folds: folds, viewportData: yaml, viewportBaseOffset: Int64(base), fileType: .yaml)
        guard view.qaTitle == "Document Structure", !view.qaScope.contains("matches") else {
            throw QAError.failed("Closing YAML Find would strand the Find Results list")
        }
    }

    private static func renderSearchResults(
        _ result: StructureSearchResult,
        appearance: NSAppearance.Name,
        to url: URL
    ) throws {
        let view = StructureSidebarView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 260))
        view.presentation = .fullWorkspace
        let window = host(view, size: view.frame.size, appearance: appearance)
        defer { window.close() }
        view.updateSearchResults([result], total: 1, truncated: false, title: "JSON Explorer")
        view.selectSearchResult(matching: result.match.byteRange)
        settle(window)

        let identifier = "search:\(result.match.byteRange.lowerBound):\(result.match.byteRange.upperBound):0"
        guard let title = view.qaAttributedTitle(identifier: identifier) else {
            throw QAError.failed("Search result row did not render")
        }
        let highlight = NSRange(
            location: result.highlightUTF16Range.lowerBound,
            length: result.highlightUTF16Range.count
        )
        guard title.attribute(.backgroundColor, at: highlight.location, effectiveRange: nil) is NSColor,
              view.qaToolTip(identifier: identifier)?.contains("🚀 café") == true else {
            throw QAError.failed("Exact match emphasis or full source tooltip was missing in \(appearance.rawValue)")
        }
        let accessibility = recursiveSubviews(of: view)
            .compactMap { $0.accessibilityLabel() }
        guard accessibility.contains(where: { $0.contains("Search match") }) else {
            throw QAError.failed("Search result lacked an accessibility label in \(appearance.rawValue)")
        }
        try capture(view, to: url)
    }

    private static func host(
        _ view: NSView,
        size: NSSize,
        appearance: NSAppearance.Name
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        window.orderFrontRegardless()
        return window
    }

    private static func settle(_ window: NSWindow) {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private static func capture(_ view: NSView, to url: URL) throws {
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw QAError.failed("Could not allocate structured-view capture")
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw QAError.failed("Could not encode structured-view capture")
        }
        try png.write(to: url, options: .atomic)
    }

    private static func recursiveSubviews(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(recursiveSubviews)
    }
}

@MainActor
private final class RevealSpy: StructureSidebarDelegate {
    var lastRange: Range<Int64>?
    var activationCount = 0
    func structureSidebar(_ sidebar: StructureSidebarView, revealByteRange range: Range<Int64>) {
        activationCount += 1
        lastRange = range
    }
}

private enum QAError: Error, CustomStringConvertible {
    case usage
    case failed(String)
    var description: String {
        switch self {
        case .usage: "Usage: structured-view-qa <capture-directory>"
        case .failed(let message): message
        }
    }
}
#endif
