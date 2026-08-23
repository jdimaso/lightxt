import AppKit
import QuartzCore

/// A native, WebKit-free Markdown reader. Only a bounded byte window is ever
/// decoded or given to TextKit, so rendered view remains safe for very large
/// notes while the virtual scrollbar continues to address the entire file.
@MainActor
final class MarkdownPreviewView: NSView, NSTextViewDelegate {
    static let maximumViewportBytes = 48 * 1_024
    private static let preferredViewportBytes = 32 * 1_024
    private static let maximumLineAlignmentProbeBytes = 8 * 1_024
    private static let renderingQueue = DispatchQueue(
        label: "app.lightxt.markdown-render",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )

    weak var editorDelegate: VirtualTextEditorDelegate? {
        didSet {
            if oldValue !== editorDelegate {
                currentSourceOffset = 0
                reloadDocument()
            }
        }
    }
    var onStatusChange: ((String, Bool) -> Void)?
    var onPerformanceSample: ((_ mainThreadMilliseconds: Double, _ sourceBytes: Int) -> Void)?

    private let scrollView = NSScrollView()
    private let textView = NSTextView(frame: .zero)
    private let virtualScroller = NSScroller()
    private let progress = NSProgressIndicator()
    private var viewportRange: Range<Int64> = 0..<0
    private var sourceByteCount: Int64 = 0
    private var isApplyingViewport = false
    private var suppressEdgeRecenteringUntil: CFTimeInterval = 0
    private var recenterWork: DispatchWorkItem?
    private var renderGeneration: UInt64 = 0
    private var renderCancellation: CancellationToken?
    private var sourceLineStartOffsets: [Int64] = []
    private var renderedSourceLineUTF16Starts: [Int] = []
    private var currentSourceOffset: Int64 = 0
    private var isSynchronizingTextGeometry = false
    private var lastGeometryWidth: CGFloat = 0

    private enum ViewportPlacement {
        case beginning
        case centered(on: Int64)
        case preserveTop(byteOffset: Int64, screenOffset: CGFloat)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureTextView()
        configureLayout()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        recenterWork?.cancel()
        renderCancellation?.cancel()
    }

    func reloadDocument() {
        renderGeneration &+= 1
        recenterWork?.cancel()
        renderCancellation?.cancel()
        let offset = max(0, currentSourceOffset)
        loadViewport(
            centeredAt: offset,
            generation: renderGeneration,
            placement: offset == 0
                ? .beginning
                : .preserveTop(byteOffset: offset, screenOffset: 0)
        )
    }

    func scrollTo(byteOffset: Int64) {
        renderGeneration &+= 1
        renderCancellation?.cancel()
        loadViewport(
            centeredAt: byteOffset,
            generation: renderGeneration,
            placement: .centered(on: byteOffset)
        )
    }

    func deactivate() {
        renderGeneration &+= 1
        recenterWork?.cancel()
        renderCancellation?.cancel()
        renderCancellation = nil
        progress.stopAnimation(nil)
        onStatusChange?("Markdown preview paused", false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
        if editorDelegate != nil { reloadDocument() }
    }

    override func layout() {
        super.layout()
        guard !isApplyingViewport,
              abs(scrollView.contentSize.width - lastGeometryWidth) > 0.5 else { return }
        synchronizeTextGeometry()
    }

    private func configureTextView() {
        textView.delegate = self
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.drawsBackground = true
        textView.textContainerInset = NSSize(width: 42, height: 34)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.setAccessibilityLabel("Rendered Markdown")
        applyAppearance()
    }

    private func configureLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = textView
        // The custom scroller represents the whole file. Showing AppKit's
        // viewport-only scroller beside it produced two competing thumbs.
        // Wheel and trackpad scrolling still drive the clip view normally.
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.contentView.postsBoundsChangedNotifications = true
        addSubview(scrollView)

        virtualScroller.translatesAutoresizingMaskIntoConstraints = false
        virtualScroller.scrollerStyle = .overlay
        virtualScroller.controlSize = .small
        virtualScroller.target = self
        virtualScroller.action = #selector(virtualScroll(_:))
        virtualScroller.setAccessibilityLabel("Markdown document position")
        addSubview(virtualScroller)

        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.style = .spinning
        progress.controlSize = .small
        progress.isDisplayedWhenStopped = false
        progress.setAccessibilityLabel("Rendering Markdown")
        addSubview(progress)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            virtualScroller.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -3),
            virtualScroller.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            virtualScroller.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
            virtualScroller.widthAnchor.constraint(equalToConstant: 12),
            progress.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            progress.topAnchor.constraint(equalTo: topAnchor, constant: 16),
        ])
    }

    private func applyAppearance() {
        let background = LighTxtTheme.resolved(LighTxtTheme.editorBackground, for: effectiveAppearance)
        textView.backgroundColor = background
        scrollView.backgroundColor = background
        needsDisplay = true
    }

    private func loadViewport(
        centeredAt requestedOffset: Int64,
        generation: UInt64,
        placement: ViewportPlacement
    ) {
        guard let delegate = editorDelegate else {
            textView.string = ""
            viewportRange = 0..<0
            updateVirtualScroller(at: 0)
            return
        }
        let snapshot: DocumentSnapshot
        do {
            snapshot = try delegate.editorSnapshot()
        } catch {
            progress.stopAnimation(nil)
            onStatusChange?(error.localizedDescription, false)
            delegate.editorDidFail(error)
            return
        }
        sourceByteCount = max(0, snapshot.byteCount)
        let center = min(max(0, requestedOffset), sourceByteCount)
        onStatusChange?("Rendering Markdown…", true)
        progress.startAnimation(nil)
        renderCancellation?.cancel()
        let cancellation = CancellationToken()
        renderCancellation = cancellation
        let preferredBytes = Self.preferredViewportBytes
        let maximumBytes = Self.maximumViewportBytes
        let probeBytes = Self.maximumLineAlignmentProbeBytes
        Self.renderingQueue.async { [weak self] in
            do {
                let payload = try MarkdownViewportLoader.load(
                    snapshot: snapshot,
                    centeredAt: center,
                    preferredByteCount: preferredBytes,
                    maximumByteCount: maximumBytes,
                    maximumProbeByteCount: probeBytes,
                    cancellation: cancellation
                )
                guard !cancellation.isCancelled else { return }
                DispatchQueue.main.async { [weak self] in
                    self?.publish(
                        payload,
                        centeredAt: center,
                        generation: generation,
                        cancellation: cancellation,
                        placement: placement
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                DispatchQueue.main.async { [weak self] in
                    guard let self,
                          self.renderGeneration == generation,
                          !cancellation.isCancelled else { return }
                    self.progress.stopAnimation(nil)
                    self.onStatusChange?(error.localizedDescription, false)
                    self.editorDelegate?.editorDidFail(error)
                }
            }
        }
    }

    private func publish(
        _ payload: MarkdownViewportPayload,
        centeredAt _: Int64,
        generation: UInt64,
        cancellation: CancellationToken,
        placement: ViewportPlacement
    ) {
        guard generation == renderGeneration,
              !cancellation.isCancelled,
              let delegate = editorDelegate else { return }
        let applyStarted = ContinuousClock.now
        let rendered = MarkdownNativeRenderer.renderDocument(
            payload.prepared,
            appearance: effectiveAppearance,
            startsMidDocument: payload.range.lowerBound > 0
        )
        viewportRange = payload.range
        sourceLineStartOffsets = payload.sourceLineStartOffsets
        isApplyingViewport = true
        textView.textStorage?.setAttributedString(rendered.attributedString)
        renderedSourceLineUTF16Starts = rendered.sourceLineUTF16Starts
        synchronizeTextGeometry()
        restore(placement)
        isApplyingViewport = false
        suppressEdgeRecenteringUntil = CACurrentMediaTime() + 0.35
        currentSourceOffset = visibleSourceByteRange.lowerBound
        updateVirtualScroller(at: currentSourceOffset)
        progress.stopAnimation(nil)

        let message: String
        if viewportRange.count < sourceByteCount {
            message = "Rendered bytes \(viewportRange.lowerBound.formatted())–\(viewportRange.upperBound.formatted()) of \(sourceByteCount.formatted())"
        } else {
            message = "Rendered Markdown"
        }
        onStatusChange?(message, false)
        delegate.editorDidExpose(byteRange: viewportRange)
        let components = applyStarted.duration(to: ContinuousClock.now).components
        let milliseconds = Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
        onPerformanceSample?(milliseconds, Int(payload.range.count))
    }

    private func synchronizeTextGeometry() {
        guard !isSynchronizingTextGeometry else { return }
        isSynchronizingTextGeometry = true
        defer { isSynchronizingTextGeometry = false }
        let content = scrollView.contentSize
        let width = max(1, content.width)
        lastGeometryWidth = content.width
        textView.minSize = NSSize(width: width, height: max(1, content.height))
        textView.maxSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        if abs(textView.frame.width - width) > 0.5 {
            textView.setFrameSize(NSSize(width: width, height: max(1, textView.frame.height)))
        }
        textView.textContainer?.containerSize = NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        )
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let height = max(
            content.height,
            ceil(used.maxY + textView.textContainerInset.height * 2)
        )
        if abs(textView.frame.height - height) > 0.5 {
            textView.setFrameSize(NSSize(width: width, height: height))
        }
    }

    private func updateVirtualScroller(at offset: Int64) {
        guard sourceByteCount > 0 else {
            virtualScroller.doubleValue = 0
            virtualScroller.knobProportion = 1
            virtualScroller.isEnabled = false
            return
        }
        virtualScroller.isEnabled = true
        let visible = visibleSourceByteRange
        virtualScroller.doubleValue = min(1, max(0, Double(offset) / Double(sourceByteCount)))
        virtualScroller.knobProportion = min(
            1,
            max(0.02, Double(max(1, visible.count)) / Double(sourceByteCount))
        )
    }

    @objc private func virtualScroll(_ sender: NSScroller) {
        guard sourceByteCount > 0 else { return }
        var fraction = sender.doubleValue
        let visibleBytes = max(1, visibleSourceByteRange.count)
        let page = Double(visibleBytes) / Double(sourceByteCount)
        switch sender.hitPart {
        case .decrementLine: fraction -= max(0.000_001, page / 8)
        case .incrementLine: fraction += max(0.000_001, page / 8)
        case .decrementPage: fraction -= max(0.000_01, page)
        case .incrementPage: fraction += max(0.000_01, page)
        default: break
        }
        fraction = min(1, max(0, fraction))
        sender.doubleValue = fraction
        let target = Int64(Double(sourceByteCount) * fraction)
        if viewportRange.lowerBound <= target, target <= viewportRange.upperBound {
            isApplyingViewport = true
            restore(.centered(on: target))
            isApplyingViewport = false
            currentSourceOffset = visibleSourceByteRange.lowerBound
            updateVirtualScroller(at: currentSourceOffset)
            return
        }
        renderGeneration &+= 1
        let generation = renderGeneration
        recenterWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.loadViewport(
                centeredAt: target,
                generation: generation,
                placement: .centered(on: target)
            )
        }
        recenterWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    @objc private func clipBoundsChanged(_ notification: Notification) {
        guard !isApplyingViewport,
              textView.frame.height > 1 else { return }
        let bounds = scrollView.contentView.bounds
        let scrollable = max(1, textView.frame.height - bounds.height)
        let fraction = min(1, max(0, bounds.minY / scrollable))
        let visible = visibleSourceByteRange
        let approximate = visible.lowerBound
        currentSourceOffset = approximate
        updateVirtualScroller(at: approximate)

        guard sourceByteCount > Int64(viewportRange.count) else { return }

        let nearTop = fraction < 0.04 && viewportRange.lowerBound > 0
        let nearBottom = fraction > 0.96 && viewportRange.upperBound < sourceByteCount
        guard CACurrentMediaTime() >= suppressEdgeRecenteringUntil,
              nearTop || nearBottom else { return }
        renderGeneration &+= 1
        let generation = renderGeneration
        recenterWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.loadViewport(
                centeredAt: approximate,
                generation: generation,
                placement: .preserveTop(byteOffset: approximate, screenOffset: 0)
            )
        }
        recenterWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private var visibleSourceByteRange: Range<Int64> {
        guard !sourceLineStartOffsets.isEmpty,
              !renderedSourceLineUTF16Starts.isEmpty,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return viewportRange }
        let bounds = scrollView.contentView.bounds.offsetBy(
            dx: -textView.textContainerOrigin.x,
            dy: -textView.textContainerOrigin.y
        )
        let glyphRange = layoutManager.glyphRange(forBoundingRect: bounds, in: textContainer)
        let characterRange = layoutManager.characterRange(
            forGlyphRange: glyphRange,
            actualGlyphRange: nil
        )
        let firstSourceLine = Self.floorIndex(
            of: characterRange.location,
            in: renderedSourceLineUTF16Starts
        )
        let lastCharacter = max(characterRange.location, NSMaxRange(characterRange) - 1)
        let lastSourceLine = Self.floorIndex(of: lastCharacter, in: renderedSourceLineUTF16Starts)
        let lower = sourceLineStartOffsets[min(firstSourceLine, sourceLineStartOffsets.count - 1)]
        let nextLine = min(lastSourceLine + 1, sourceLineStartOffsets.count)
        let upper = nextLine < sourceLineStartOffsets.count
            ? sourceLineStartOffsets[nextLine]
            : viewportRange.upperBound
        return lower..<max(lower, upper)
    }

    private func restore(_ placement: ViewportPlacement) {
        let clip = scrollView.contentView
        let targetY: CGFloat
        switch placement {
        case .beginning:
            targetY = 0
        case .centered(let offset):
            targetY = verticalPosition(forSourceByteOffset: offset) - clip.bounds.height / 2
        case let .preserveTop(offset, screenOffset):
            targetY = verticalPosition(forSourceByteOffset: offset) - screenOffset
        }
        let maximumY = max(0, textView.frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(
            x: min(max(0, clip.bounds.minX), max(0, textView.frame.width - clip.bounds.width)),
            y: min(max(0, targetY), maximumY)
        ))
        scrollView.reflectScrolledClipView(clip)
    }

    private func verticalPosition(forSourceByteOffset offset: Int64) -> CGFloat {
        guard !sourceLineStartOffsets.isEmpty,
              !renderedSourceLineUTF16Starts.isEmpty,
              let layoutManager = textView.layoutManager,
              layoutManager.numberOfGlyphs > 0 else { return 0 }
        let sourceLine = Self.floorIndex(of: offset, in: sourceLineStartOffsets)
        let renderedSourceLine = min(sourceLine, renderedSourceLineUTF16Starts.count - 1)
        let character = min(
            renderedSourceLineUTF16Starts[renderedSourceLine],
            max(0, textView.string.utf16.count - 1)
        )
        let glyph = min(
            layoutManager.glyphIndexForCharacter(at: character),
            layoutManager.numberOfGlyphs - 1
        )
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return line.minY + textView.textContainerOrigin.y
    }

    private static func floorIndex<T: Comparable>(of value: T, in values: [T]) -> Int {
        guard !values.isEmpty else { return 0 }
        var lower = 0
        var upper = values.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if values[middle] <= value { lower = middle + 1 } else { upper = middle }
        }
        return max(0, lower - 1)
    }

    func textView(
        _ textView: NSTextView,
        clickedOnLink link: Any,
        at charIndex: Int
    ) -> Bool {
        guard let url = link as? URL else { return false }
        NSWorkspace.shared.open(url)
        return true
    }
}

private struct MarkdownViewportPayload: @unchecked Sendable {
    let range: Range<Int64>
    let prepared: MarkdownPreparedDocument
    let sourceLineStartOffsets: [Int64]
}

private nonisolated enum MarkdownViewportLoader {
    static func load(
        snapshot: DocumentSnapshot,
        centeredAt center: Int64,
        preferredByteCount: Int,
        maximumByteCount: Int,
        maximumProbeByteCount: Int,
        cancellation: CancellationToken
    ) throws -> MarkdownViewportPayload {
        if cancellation.isCancelled { throw CancellationError() }
        let range = try alignedRange(
            snapshot: snapshot,
            centeredAt: center,
            preferredByteCount: preferredByteCount,
            maximumByteCount: maximumByteCount,
            maximumProbeByteCount: maximumProbeByteCount
        )
        if cancellation.isCancelled { throw CancellationError() }
        let bytes = try snapshot.data(in: range)
        if cancellation.isCancelled { throw CancellationError() }
        let prepared = try MarkdownSemanticPreparer.prepare(
            String(decoding: bytes, as: UTF8.self),
            cancellation: cancellation
        )
        var lineStarts = [range.lowerBound]
        lineStarts.reserveCapacity(max(1, bytes.count / 48))
        for (index, byte) in bytes.enumerated() where byte == 0x0A {
            lineStarts.append(range.lowerBound + Int64(index + 1))
        }
        return MarkdownViewportPayload(
            range: range.lowerBound..<(range.lowerBound + Int64(bytes.count)),
            prepared: prepared,
            sourceLineStartOffsets: lineStarts
        )
    }

    private static func alignedRange(
        snapshot: DocumentSnapshot,
        centeredAt center: Int64,
        preferredByteCount: Int,
        maximumByteCount: Int,
        maximumProbeByteCount: Int
    ) throws -> Range<Int64> {
        let total = snapshot.byteCount
        guard total > 0 else { return 0..<0 }
        let preferred = Int64(preferredByteCount)
        var lower = max(0, center - preferred / 2)
        var upper = min(total, lower + preferred)
        lower = max(0, upper - preferred)

        if lower > 0 {
            let probeStart = max(0, lower - Int64(maximumProbeByteCount))
            let probe = try snapshot.data(in: probeStart..<lower)
            if let newline = probe.lastIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                lower = probeStart + Int64(newline + 1)
            }
        }
        if upper < total {
            let probeEnd = min(total, upper + Int64(maximumProbeByteCount))
            let probe = try snapshot.data(in: upper..<probeEnd)
            if let newline = probe.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                upper += Int64(newline + 1)
            }
        }
        if upper - lower > Int64(maximumByteCount) {
            upper = lower + Int64(maximumByteCount)
        }
        lower = try alignUTF8Start(lower, total: total, snapshot: snapshot)
        upper = try alignUTF8End(upper, lower: lower, total: total, snapshot: snapshot)
        return lower..<max(lower, upper)
    }

    private static func alignUTF8Start(
        _ requested: Int64,
        total: Int64,
        snapshot: DocumentSnapshot
    ) throws -> Int64 {
        guard requested > 0, requested < total else { return requested }
        let start = max(0, requested - 3)
        let probe = try snapshot.data(in: start..<min(total, requested + 1))
        var offset = requested
        var index = Int(requested - start)
        while offset > start, index < probe.count, probe[index] & 0xC0 == 0x80 {
            offset -= 1
            index -= 1
        }
        return offset
    }

    private static func alignUTF8End(
        _ requested: Int64,
        lower: Int64,
        total: Int64,
        snapshot: DocumentSnapshot
    ) throws -> Int64 {
        guard requested > lower, requested < total else { return min(total, requested) }
        let start = max(lower, requested - 3)
        let probe = try snapshot.data(in: start..<min(total, requested + 1))
        var offset = requested
        var index = Int(requested - start)
        while offset > start, index < probe.count, probe[index] & 0xC0 == 0x80 {
            offset -= 1
            index -= 1
        }
        return offset
    }
}

struct MarkdownPreparedDocument: @unchecked Sendable {
    let blocks: [MarkdownPreparedBlock]
}

enum MarkdownPreparedBlock: @unchecked Sendable {
    case hidden
    case code(String)
    case heading(level: Int, content: AttributedString)
    case list(prefix: String, content: AttributedString)
    case quote(AttributedString)
    case table([AttributedString])
    case tableSeparator
    case rule
    case paragraph(content: AttributedString, isBlank: Bool)
}

nonisolated enum MarkdownSemanticPreparer {
    private static let listExpression = try! NSRegularExpression(
        pattern: #"^[\t ]*([-+*]|(\d+)[.)])[\t ]+(.*)$"#
    )
    private static let quoteExpression = try! NSRegularExpression(
        pattern: #"^[\t ]*>[\t ]?(.*)$"#
    )
    private static let tableSeparatorExpression = try! NSRegularExpression(
        pattern: #"^:?-{3,}:?$"#
    )

    static func prepare(
        _ source: String,
        cancellation: CancellationToken? = nil
    ) throws -> MarkdownPreparedDocument {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var blocks: [MarkdownPreparedBlock] = []
        blocks.reserveCapacity(lines.count)
        var inFence = false
        for (lineIndex, sourceLine) in lines.enumerated() {
            if lineIndex.isMultiple(of: 32), cancellation?.isCancelled == true {
                throw CancellationError()
            }
            let line = String(sourceLine).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                blocks.append(.hidden)
            } else if inFence {
                blocks.append(.code(line))
            } else if let heading = headingContent(line) {
                blocks.append(.heading(level: heading.level, content: inline(heading.content)))
            } else if let list = listContent(line) {
                blocks.append(.list(prefix: list.prefix, content: inline(list.content)))
            } else if let quote = quoteContent(line) {
                blocks.append(.quote(inline(quote)))
            } else if let cells = tableCells(line) {
                blocks.append(isTableSeparator(cells) ? .tableSeparator : .table(cells.map(inline)))
            } else if isHorizontalRule(trimmed) {
                blocks.append(.rule)
            } else {
                blocks.append(.paragraph(content: inline(line), isBlank: trimmed.isEmpty))
            }
        }
        return MarkdownPreparedDocument(blocks: blocks)
    }

    private static func inline(_ markdown: String) -> AttributedString {
        (try? AttributedString(
            markdown: markdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(markdown)
    }

    private static func headingContent(_ line: String) -> (level: Int, content: String)? {
        var level = 0
        var index = line.startIndex
        while index < line.endIndex, line[index] == "#", level < 6 {
            level += 1
            index = line.index(after: index)
        }
        guard level > 0, index < line.endIndex, line[index].isWhitespace else { return nil }
        return (level, line[index...].trimmingCharacters(in: .whitespaces))
    }

    private static func listContent(_ line: String) -> (prefix: String, content: String)? {
        let source = line as NSString
        let full = NSRange(location: 0, length: source.length)
        guard let match = listExpression.firstMatch(in: line, range: full) else { return nil }
        let ordinal = match.range(at: 2).location == NSNotFound
            ? nil
            : source.substring(with: match.range(at: 2))
        return (
            ordinal.map { "\($0).  " } ?? "•  ",
            source.substring(with: match.range(at: 3))
        )
    }

    private static func quoteContent(_ line: String) -> String? {
        let source = line as NSString
        let full = NSRange(location: 0, length: source.length)
        guard let match = quoteExpression.firstMatch(in: line, range: full) else { return nil }
        return source.substring(with: match.range(at: 1))
    }

    private static func tableCells(_ line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        var cells: [String] = []
        var cell = ""
        var sawDelimiter = false
        var activeCodeFenceLength: Int?
        var remainingCodeFenceCounts = codeFenceCounts(in: line)
        var index = line.startIndex
        while index < line.endIndex {
            let character = line[index]
            if character == "\\" {
                cell.append(character)
                let next = line.index(after: index)
                if next < line.endIndex {
                    cell.append(line[next])
                    index = line.index(after: next)
                } else {
                    index = next
                }
                continue
            }
            if character == "`" {
                var end = index
                var fenceLength = 0
                while end < line.endIndex, line[end] == "`" {
                    cell.append("`")
                    fenceLength += 1
                    end = line.index(after: end)
                }
                remainingCodeFenceCounts[fenceLength, default: 0] -= 1
                if activeCodeFenceLength == fenceLength {
                    activeCodeFenceLength = nil
                } else if activeCodeFenceLength == nil,
                          remainingCodeFenceCounts[fenceLength, default: 0] > 0 {
                    activeCodeFenceLength = fenceLength
                }
                index = end
                continue
            }
            if character == "|", activeCodeFenceLength == nil {
                cells.append(cell.trimmingCharacters(in: .whitespaces))
                cell.removeAll(keepingCapacity: true)
                sawDelimiter = true
            } else {
                cell.append(character)
            }
            index = line.index(after: index)
        }
        cells.append(cell.trimmingCharacters(in: .whitespaces))
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return sawDelimiter && cells.count >= 2 ? cells : nil
    }

    private static func codeFenceCounts(in line: String) -> [Int: Int] {
        var counts: [Int: Int] = [:]
        var index = line.startIndex
        while index < line.endIndex {
            if line[index] == "\\" {
                let next = line.index(after: index)
                index = next < line.endIndex ? line.index(after: next) : next
                continue
            }
            guard line[index] == "`" else {
                index = line.index(after: index)
                continue
            }
            var end = index
            var length = 0
            while end < line.endIndex, line[end] == "`" {
                length += 1
                end = line.index(after: end)
            }
            counts[length, default: 0] += 1
            index = end
        }
        return counts
    }

    private static func isTableSeparator(_ cells: [String]) -> Bool {
        !cells.isEmpty && cells.allSatisfy { cell in
            let source = cell as NSString
            return tableSeparatorExpression.firstMatch(
                in: cell,
                range: NSRange(location: 0, length: source.length)
            ) != nil
        }
    }

    private static func isHorizontalRule(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        let characters = trimmed.filter { !$0.isWhitespace }
        guard let first = characters.first, first == "-" || first == "*" || first == "_" else {
            return false
        }
        return characters.allSatisfy { $0 == first }
    }
}

@MainActor
enum MarkdownNativeRenderer {
    struct RenderedDocument {
        let attributedString: NSAttributedString
        let sourceLineUTF16Starts: [Int]
    }

    static func render(
        _ source: String,
        appearance: NSAppearance,
        startsMidDocument: Bool
    ) -> NSAttributedString {
        let prepared = (try? MarkdownSemanticPreparer.prepare(source))
            ?? MarkdownPreparedDocument(blocks: [.paragraph(content: AttributedString(source), isBlank: source.isEmpty)])
        return render(prepared, appearance: appearance, startsMidDocument: startsMidDocument)
    }

    static func render(
        _ prepared: MarkdownPreparedDocument,
        appearance: NSAppearance,
        startsMidDocument: Bool
    ) -> NSAttributedString {
        renderDocument(
            prepared,
            appearance: appearance,
            startsMidDocument: startsMidDocument
        ).attributedString
    }

    static func renderDocument(
        _ prepared: MarkdownPreparedDocument,
        appearance: NSAppearance,
        startsMidDocument: Bool
    ) -> RenderedDocument {
        let primary = LighTxtTheme.resolved(LighTxtTheme.primaryText, for: appearance)
        let accent = LighTxtTheme.resolved(LighTxtTheme.accent, for: appearance)
        let soft = LighTxtTheme.resolved(LighTxtTheme.gutterBackground, for: appearance)
        let secondary = LighTxtTheme.resolved(LighTxtTheme.secondaryText, for: appearance)
        let output = NSMutableAttributedString()
        var sourceLineUTF16Starts: [Int] = []
        sourceLineUTF16Starts.reserveCapacity(prepared.blocks.count)
        var lineIndex = 0
        while lineIndex < prepared.blocks.count {
            if case .table = prepared.blocks[lineIndex] {
                var tableEnd = lineIndex + 1
                while tableEnd < prepared.blocks.count,
                      isTableRunBlock(prepared.blocks[tableEnd]) {
                    tableEnd += 1
                }
                appendTable(
                    blocks: prepared.blocks[lineIndex..<tableEnd],
                    isLastBlock: tableEnd == prepared.blocks.count,
                    to: output,
                    sourceLineUTF16Starts: &sourceLineUTF16Starts,
                    primary: primary,
                    accent: accent,
                    soft: soft
                )
                lineIndex = tableEnd
                continue
            }

            sourceLineUTF16Starts.append(output.length)
            let block = prepared.blocks[lineIndex]
            switch block {
            case .hidden, .tableSeparator:
                break
            case let .code(line):
                let paragraph = paragraphStyle(spacingAfter: 0)
                appendPlain(
                    line,
                    to: output,
                    font: .monospacedSystemFont(ofSize: 13, weight: .regular),
                    color: primary,
                    background: soft,
                    paragraph: paragraph
                )
            case let .heading(level, content):
                let size = max(17, 29 - CGFloat(level * 2))
                let paragraph = paragraphStyle(
                    spacingBefore: level == 1 ? 18 : 12,
                    spacingAfter: 9
                )
                output.append(inlineFragment(
                    content,
                    font: .systemFont(ofSize: size, weight: level <= 2 ? .semibold : .medium),
                    color: primary,
                    accent: accent,
                    codeBackground: soft,
                    paragraph: paragraph
                ))
            case let .list(prefix, content):
                let paragraph = paragraphStyle(spacingAfter: 3, headIndent: 24, firstLineHeadIndent: 0)
                appendPlain(
                    prefix,
                    to: output,
                    font: .systemFont(ofSize: 15, weight: .semibold),
                    color: accent,
                    paragraph: paragraph
                )
                output.append(inlineFragment(
                    content,
                    font: .systemFont(ofSize: 15),
                    color: primary,
                    accent: accent,
                    codeBackground: soft,
                    paragraph: paragraph
                ))
            case let .quote(content):
                let paragraph = paragraphStyle(spacingAfter: 6, headIndent: 18, firstLineHeadIndent: 0)
                appendPlain(
                    "│  ",
                    to: output,
                    font: .systemFont(ofSize: 15, weight: .medium),
                    color: accent,
                    paragraph: paragraph
                )
                let italic = NSFontManager.shared.convert(
                    NSFont.systemFont(ofSize: 15),
                    toHaveTrait: .italicFontMask
                )
                output.append(inlineFragment(
                    content,
                    font: italic,
                    color: secondary,
                    accent: accent,
                    codeBackground: soft,
                    paragraph: paragraph
                ))
            case .table:
                break
            case .rule:
                appendPlain(
                    "────────────────────────",
                    to: output,
                    font: .systemFont(ofSize: 10),
                    color: secondary,
                    paragraph: paragraphStyle(spacingBefore: 4, spacingAfter: 8)
                )
            case let .paragraph(content, isBlank):
                output.append(inlineFragment(
                    content,
                    font: .systemFont(ofSize: 15),
                    color: primary,
                    accent: accent,
                    codeBackground: soft,
                    paragraph: paragraphStyle(spacingAfter: isBlank ? 2 : 7)
                ))
            }

            if lineIndex < prepared.blocks.count - 1 { output.append(NSAttributedString(string: "\n")) }
            lineIndex += 1
        }
        _ = startsMidDocument // The viewport itself communicates position via its scroller/status.
        return RenderedDocument(
            attributedString: output,
            sourceLineUTF16Starts: sourceLineUTF16Starts
        )
    }

    private static func isTableRunBlock(_ block: MarkdownPreparedBlock) -> Bool {
        switch block {
        case .table, .tableSeparator:
            true
        default:
            false
        }
    }

    private static func appendTable(
        blocks: ArraySlice<MarkdownPreparedBlock>,
        isLastBlock: Bool,
        to output: NSMutableAttributedString,
        sourceLineUTF16Starts: inout [Int],
        primary: NSColor,
        accent: NSColor,
        soft: NSColor
    ) {
        let rows = blocks.compactMap { block -> [AttributedString]? in
            guard case let .table(cells) = block else { return nil }
            return cells
        }
        let columnCount = rows.map(\.count).max() ?? 0
        guard columnCount > 0 else {
            for _ in blocks { sourceLineUTF16Starts.append(output.length) }
            return
        }

        let table = NSTextTable()
        table.numberOfColumns = columnCount
        table.layoutAlgorithm = .fixedLayoutAlgorithm
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        table.setContentWidth(100, type: .percentageValueType)

        var tableRow = 0
        var sourceBlockOffset = 0
        let lastTableSourceOffset = blocks.indices.last { index in
            if case .table = blocks[index] { return true }
            return false
        }.map { blocks.distance(from: blocks.startIndex, to: $0) } ?? 0

        for block in blocks {
            sourceLineUTF16Starts.append(output.length)
            defer { sourceBlockOffset += 1 }
            guard case let .table(cells) = block else { continue }
            for column in 0..<columnCount {
                let tableBlock = NSTextTableBlock(
                    table: table,
                    startingRow: tableRow,
                    rowSpan: 1,
                    startingColumn: column,
                    columnSpan: 1
                )
                tableBlock.verticalAlignment = .topAlignment
                tableBlock.setWidth(5, type: .absoluteValueType, for: .padding)
                let paragraph = tableParagraphStyle(block: tableBlock)
                let content = column < cells.count ? cells[column] : AttributedString()
                output.append(inlineFragment(
                    content,
                    font: .systemFont(ofSize: 13),
                    color: primary,
                    accent: accent,
                    codeBackground: soft,
                    paragraph: paragraph
                ))
                let isFinalCell = isLastBlock
                    && sourceBlockOffset == lastTableSourceOffset
                    && column == columnCount - 1
                if !isFinalCell {
                    appendPlain(
                        "\n",
                        to: output,
                        font: .systemFont(ofSize: 13),
                        color: primary,
                        paragraph: paragraph
                    )
                }
            }
            tableRow += 1
        }
    }

    private static func inlineFragment(
        _ parsed: AttributedString,
        font: NSFont,
        color: NSColor,
        accent: NSColor,
        codeBackground: NSColor,
        paragraph: NSParagraphStyle
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(parsed)
        let full = NSRange(location: 0, length: result.length)
        result.addAttributes([
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ], range: full)
        result.enumerateAttribute(.inlinePresentationIntent, in: full) { value, range, _ in
            guard let raw = value as? NSNumber else { return }
            let intent = InlinePresentationIntent(rawValue: raw.uintValue)
            if intent.contains(.code) {
                result.addAttributes([
                    .font: NSFont.monospacedSystemFont(ofSize: max(11, font.pointSize - 1), weight: .regular),
                    .foregroundColor: accent,
                    .backgroundColor: codeBackground,
                ], range: range)
                return
            }
            var traits: NSFontTraitMask = []
            if intent.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
            if intent.contains(.emphasized) { traits.insert(.italicFontMask) }
            if !traits.isEmpty {
                result.addAttribute(
                    .font,
                    value: NSFontManager.shared.convert(font, toHaveTrait: traits),
                    range: range
                )
            }
        }
        result.enumerateAttribute(.link, in: full) { value, range, _ in
            guard value != nil else { return }
            result.addAttributes([
                .foregroundColor: accent,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ], range: range)
        }
        return result
    }

    private static func appendPlain(
        _ string: String,
        to output: NSMutableAttributedString,
        font: NSFont,
        color: NSColor,
        background: NSColor? = nil,
        paragraph: NSParagraphStyle
    ) {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        if let background { attributes[.backgroundColor] = background }
        output.append(NSAttributedString(string: string, attributes: attributes))
    }

    private static func paragraphStyle(
        spacingBefore: CGFloat = 0,
        spacingAfter: CGFloat = 0,
        headIndent: CGFloat = 0,
        firstLineHeadIndent: CGFloat = 0
    ) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacingBefore = spacingBefore
        paragraph.paragraphSpacing = spacingAfter
        paragraph.headIndent = headIndent
        paragraph.firstLineHeadIndent = firstLineHeadIndent
        return paragraph
    }

    private static func tableParagraphStyle(block: NSTextTableBlock) -> NSParagraphStyle {
        let paragraph = paragraphStyle(spacingAfter: 0) as! NSMutableParagraphStyle
        paragraph.lineBreakMode = .byCharWrapping
        paragraph.textBlocks = [block]
        return paragraph
    }

}
