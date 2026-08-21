import AppKit

struct EditorLineLocation: Sendable {
    let lineNumber: Int64
    let lineStartByteOffset: Int64
}

/// Immutable, bounded bytes currently materialized by the virtual editor.
/// Consumers may render this snapshot but must never treat it as an edit.
struct EditorViewportPresentationSnapshot: Sendable {
    let data: Data
    let byteRange: Range<Int64>
    let documentByteCount: Int64
    let leadingContext: Data
    let leadingContextStartByteOffset: Int64
}

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

private final class ViewportSyntaxCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

private enum ViewportDecorationKind: Sendable {
    case semantic(SyntaxSemanticKind)
    case diagnostic(message: String)
}

private struct ViewportDecoration: Sendable {
    let utf16Location: Int
    let utf16Length: Int
    let kind: ViewportDecorationKind
}

private struct ViewportSyntaxInput: Sendable {
    let generation: UInt64
    let data: Data
    let decoder: ViewportUTF8Map
    let snapshot: DocumentSnapshot
    let baseByteOffset: Int64
    let documentByteCount: Int64
    let fileType: SyntaxFileType
    let limits: SyntaxLimits
}

private struct ViewportSyntaxOutput: Sendable {
    let generation: UInt64
    let viewportData: Data
    let baseByteOffset: Int64
    let decorations: [ViewportDecoration]
    let folds: [SyntaxFoldRange]
}

/// Syntax parsing is intentionally serialized. Cancelling an obsolete token
/// makes queued work disappear immediately while bounding active CPU work to a
/// single 512 KiB viewport.
private enum ViewportSyntaxWorker {
    static let queue = DispatchQueue(
        label: "app.lightxt.viewport-syntax",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )

    static func analyze(
        _ input: ViewportSyntaxInput,
        cancellation: ViewportSyntaxCancellation
    ) -> ViewportSyntaxOutput? {
        guard !cancellation.isCancelled else { return nil }

        // A viewport can begin inside a string, comment, fenced block, XML
        // tag, CSV field, or YAML scalar. Derive bounded continuation state
        // from the immediately preceding file-backed bytes instead of
        // pretending every random viewport starts in neutral syntax.
        let contextByteCount = Int64(input.limits.maximumTokenBytes)
        let contextStart = max(0, input.baseByteOffset - contextByteCount)
        var initialState = SyntaxLexicalState.neutral
        if contextStart < input.baseByteOffset {
            guard let context = try? input.snapshot.data(in: contextStart..<input.baseByteOffset),
                  !cancellation.isCancelled else { return nil }
            let stateOnlyLimits = SyntaxLimits(
                maximumSpans: 0,
                maximumDiagnostics: 0,
                maximumFoldRanges: 0,
                maximumNestingDepth: input.limits.maximumNestingDepth,
                maximumTokenBytes: input.limits.maximumTokenBytes,
                minimumFoldByteCount: input.limits.minimumFoldByteCount,
                csvDelimiter: input.limits.csvDelimiter
            )
            initialState = ViewportSyntaxHighlighter.highlight(
                context,
                as: input.fileType,
                baseByteOffset: Int(clamping: contextStart),
                initialState: .neutral,
                limits: stateOnlyLimits
            ).endState
        }
        guard !cancellation.isCancelled else { return nil }

        let highlighted = ViewportSyntaxHighlighter.highlight(
            input.data,
            as: input.fileType,
            baseByteOffset: Int(clamping: input.baseByteOffset),
            initialState: initialState,
            limits: input.limits
        )
        guard !cancellation.isCancelled else { return nil }

        let absoluteBase = Int(clamping: input.baseByteOffset)
        var decorations: [ViewportDecoration] = []
        decorations.reserveCapacity(highlighted.spans.count + input.limits.maximumDiagnostics)
        for (index, span) in highlighted.spans.enumerated() {
            if index.isMultiple(of: 1_024), cancellation.isCancelled { return nil }
            let localStart = span.range.start - absoluteBase
            let localEnd = localStart + span.range.length
            guard localEnd > 0, localStart < input.data.count else { continue }
            let lower = input.decoder.utf16Offset(
                forByteOffset: max(0, localStart),
                bias: .leading
            )
            let upper = input.decoder.utf16Offset(
                forByteOffset: min(input.data.count, localEnd),
                bias: .trailing
            )
            guard upper > lower, upper <= input.decoder.utf16Count else { continue }
            decorations.append(ViewportDecoration(
                utf16Location: lower,
                utf16Length: upper - lower,
                kind: .semantic(span.kind)
            ))
        }

        if input.baseByteOffset == 0,
           Int64(input.data.count) == input.documentByteCount {
            let diagnostics = SyntaxDiagnostics.inspect(
                input.data,
                as: input.fileType,
                baseByteOffset: 0,
                limits: input.limits
            )
            guard !cancellation.isCancelled else { return nil }
            for diagnostic in diagnostics {
                let lower = input.decoder.utf16Offset(
                    forByteOffset: diagnostic.range.start,
                    bias: .leading
                )
                let upper = input.decoder.utf16Offset(
                    forByteOffset: diagnostic.range.end,
                    bias: .trailing
                )
                guard lower < input.decoder.utf16Count else { continue }
                decorations.append(ViewportDecoration(
                    utf16Location: lower,
                    utf16Length: max(1, upper - lower),
                    kind: .diagnostic(message: diagnostic.message)
                ))
            }
        }

        guard !cancellation.isCancelled else { return nil }
        let folds = SyntaxFoldDiscovery.discover(
            input.data,
            as: input.fileType,
            baseByteOffset: absoluteBase,
            limits: input.limits
        )
        guard !cancellation.isCancelled else { return nil }

        return ViewportSyntaxOutput(
            generation: input.generation,
            viewportData: input.data,
            baseByteOffset: input.baseByteOffset,
            decorations: decorations,
            folds: folds.ranges
        )
    }
}

/// A TextKit editing surface whose storage is always a bounded byte window.
/// The full document remains in the file-backed piece table owned by the
/// delegate. This prevents UTF-16, glyph, and attribute memory from scaling
/// with file size.
@MainActor
final class VirtualTextEditorView: NSView, NSTextViewDelegate {
    static let maximumViewportBytes = 512 * 1_024
    private static let maximumUnbrokenLineViewportBytes = 8 * 1_024
    private static let recenterThreshold = 0.13
    private static let decorationBatchSize = 1_024

    weak var editorDelegate: VirtualTextEditorDelegate? {
        didSet {
            if oldValue !== editorDelegate {
                rememberedHorizontalOffset = leadingHorizontalOrigin
                    ?? scrollView.contentView.bounds.minX
                loadViewport(centeredAt: 0, preferredSelection: nil)
            }
        }
    }

    private let scrollView = NSScrollView()
    private let textView = NSTextView(frame: .zero)
    private let virtualScroller = NSScroller()
    private lazy var rulerView = ViewportLineNumberRuler(scrollView: scrollView, orientation: .verticalRuler)

    private var sourceBytes = Data()
    private var decoder = ViewportUTF8Map(data: Data())
    private var viewportRange: Range<Int64> = 0..<0
    private var viewportFirstLine: Int64 = 1
    private var viewportFirstLineStart: Int64 = 0
    private var isApplyingSnapshot = false
    private var isCommittingEdit = false
    private var pendingReplacement: PendingReplacement?
    private var reloadWork: DispatchWorkItem?
    private var syntaxDebounceWork: DispatchWorkItem?
    private var syntaxCancellation: ViewportSyntaxCancellation?
    private var syntaxGeneration: UInt64 = 0
    private var fontSize: CGFloat = 13
    private var fontChoice = LighTxtEditorFontChoice.persisted()
    private var requestedSelectionAfterLoad: Range<Int64>?
    private var usesWrappedLongLineViewport = false
    private var appearanceTargetsConfigured = false
    private var isSynchronizingTextGeometry = false
    private var lastGeometryContentWidth: CGFloat = 0
    private var rememberedHorizontalOffset: CGFloat = 0
    private var leadingHorizontalOrigin: CGFloat?

    private struct PendingReplacement {
        let localByteRange: Range<Int>
        let globalByteRange: Range<Int64>
        let bytes: Data
    }

    private struct ViewportScrollAnchor {
        let byteOffset: Int64
        let screenOffset: CGFloat
        let horizontalOffset: CGFloat
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureTextSystem()
        configureLayout()
        appearanceTargetsConfigured = true
        applyResolvedAppearance(refreshSyntax: false)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(clipBoundsChanged(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(selectionChanged(_:)),
            name: NSTextView.didChangeSelectionNotification,
            object: textView
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(editorFontDidChange(_:)),
            name: .lighTxtEditorFontDidChange,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        reloadWork?.cancel()
        syntaxDebounceWork?.cancel()
        syntaxCancellation?.cancel()
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        applyResolvedAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyResolvedAppearance()
    }

    override func becomeFirstResponder() -> Bool {
        window?.makeFirstResponder(textView)
        return true
    }

    override func layout() {
        super.layout()
        if leadingHorizontalOrigin == nil, scrollView.contentSize.width > 0 {
            leadingHorizontalOrigin = scrollView.contentView.bounds.minX
            rememberedHorizontalOffset = scrollView.contentView.bounds.minX
        }
        guard abs(scrollView.contentSize.width - lastGeometryContentWidth) > 0.5 else { return }
        synchronizeTextViewGeometry()
    }

    var selectedGlobalByteRange: Range<Int64> {
        localUTF16RangeToGlobalBytes(textView.selectedRange()) ?? viewportRange.lowerBound..<viewportRange.lowerBound
    }

    var visibleGlobalByteRange: Range<Int64> {
        guard !sourceBytes.isEmpty,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return viewportRange }
        let visibleRect = scrollView.contentView.bounds.offsetBy(
            dx: -textView.textContainerOrigin.x,
            dy: -textView.textContainerOrigin.y
        )
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let lower = decoder.byteOffset(forUTF16Offset: characterRange.location, bias: .leading)
        let upper = decoder.byteOffset(forUTF16Offset: NSMaxRange(characterRange), bias: .trailing)
        return (viewportRange.lowerBound + Int64(lower))..<(viewportRange.lowerBound + Int64(upper))
    }

    func presentationSnapshot() throws -> EditorViewportPresentationSnapshot {
        let contextStart = max(
            0,
            viewportRange.lowerBound - Int64(Self.maximumViewportBytes)
        )
        let leadingContext: Data
        if contextStart < viewportRange.lowerBound, let editorDelegate {
            leadingContext = try editorDelegate.editorReadBytes(
                in: contextStart..<viewportRange.lowerBound
            )
        } else {
            leadingContext = Data()
        }
        return EditorViewportPresentationSnapshot(
            data: sourceBytes,
            byteRange: viewportRange,
            documentByteCount: editorDelegate?.editorDocumentByteCount ?? Int64(sourceBytes.count),
            leadingContext: leadingContext,
            leadingContextStartByteOffset: contextStart
        )
    }

    func reloadPreservingSelection() {
        let selection = selectedGlobalByteRange
        let visible = visibleGlobalByteRange
        let anchor = visible.lowerBound
        loadViewport(
            centeredAt: anchor,
            preferredSelection: selection,
            preserving: ViewportScrollAnchor(
                byteOffset: anchor,
                screenOffset: 0,
                horizontalOffset: rememberedHorizontalOffset
            )
        )
    }

    func scrollTo(byteRange: Range<Int64>, select: Bool = true) {
        guard let delegate = editorDelegate else { return }
        let total = delegate.editorDocumentByteCount
        let clampedLower = max(0, min(byteRange.lowerBound, total))
        let clampedUpper = max(clampedLower, min(byteRange.upperBound, total))
        let clamped = clampedLower..<clampedUpper

        if viewportRange.contains(clampedLower), clampedUpper <= viewportRange.upperBound {
            selectGlobalByteRange(clamped, scroll: true)
        } else {
            loadViewport(centeredAt: clampedLower, preferredSelection: select ? clamped : nil)
        }
    }

    func useSelectionForFind() -> String? {
        let range = textView.selectedRange()
        guard range.length > 0, range.length <= 16_384 else { return nil }
        return (textView.string as NSString).substring(with: range)
    }

    func setFontSize(_ size: CGFloat) {
        fontSize = min(30, max(9, size))
        applySelectedFont(refreshSyntax: true)
    }

    func changeFontSize(by delta: CGFloat) { setFontSize(fontSize + delta) }
    func resetFontSize() { setFontSize(13) }

    func undoCoreEdit() {
        // Routed by the owning document session, which has byte-coordinate
        // history independent of whichever viewport is currently materialized.
        nextResponder?.tryToPerform(
            #selector(LighTxtEditorViewController.undoDocumentEdit(_:)),
            with: self
        )
    }

    private func configureTextSystem() {
        let appearance = effectiveAppearance
        textView.delegate = self
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isIncrementalSearchingEnabled = false
        textView.usesFindBar = false
        textView.usesFindPanel = false
        textView.drawsBackground = true
        textView.backgroundColor = LighTxtTheme.resolved(LighTxtTheme.editorBackground, for: appearance)
        textView.textColor = LighTxtTheme.resolved(LighTxtTheme.primaryText, for: appearance)
        textView.insertionPointColor = LighTxtTheme.resolved(LighTxtTheme.accent, for: appearance)
        textView.selectedTextAttributes = [
            .backgroundColor: LighTxtTheme.resolved(LighTxtTheme.selection, for: appearance)
        ]
        textView.font = fontChoice.font(ofSize: fontSize)
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.setAccessibilityLabel("Document text")
    }

    private func configureLayout() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = textView
        // A single whole-document scroller sits above this clip view. Keeping
        // AppKit's viewport-only vertical scroller visible created a second,
        // contradictory thumb. Trackpad/wheel events still scroll the clip.
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = LighTxtTheme.resolved(
            LighTxtTheme.editorBackground,
            for: effectiveAppearance
        )
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        rulerView.font = fontChoice.font(ofSize: max(9, fontSize - 2))
        scrollView.verticalRulerView = rulerView
        // The clip view's true visual leading edge is one ruler width before
        // document x=0. Derive it from the ruler instead of sampling bounds
        // during layout: a newly attached, constraint-sized editor can report
        // x=0 for one pass and would then permanently clip the first 56 points.
        leadingHorizontalOrigin = -rulerView.ruleThickness
        rememberedHorizontalOffset = -rulerView.ruleThickness
        addSubview(scrollView)

        virtualScroller.translatesAutoresizingMaskIntoConstraints = false
        virtualScroller.scrollerStyle = .overlay
        virtualScroller.controlSize = .small
        virtualScroller.target = self
        virtualScroller.action = #selector(virtualScroll(_:))
        virtualScroller.setAccessibilityLabel("Document position")
        addSubview(virtualScroller)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            virtualScroller.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            virtualScroller.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            virtualScroller.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            virtualScroller.widthAnchor.constraint(equalToConstant: 12)
        ])
    }

    private func applyResolvedAppearance(refreshSyntax: Bool = true) {
        guard appearanceTargetsConfigured else { return }
        let appearance = effectiveAppearance
        let background = LighTxtTheme.resolved(LighTxtTheme.editorBackground, for: appearance)
        let primary = LighTxtTheme.resolved(LighTxtTheme.primaryText, for: appearance)
        textView.backgroundColor = background
        textView.textColor = primary
        textView.insertionPointColor = LighTxtTheme.resolved(LighTxtTheme.accent, for: appearance)
        textView.selectedTextAttributes = [
            .backgroundColor: LighTxtTheme.resolved(LighTxtTheme.selection, for: appearance)
        ]
        scrollView.backgroundColor = background
        applyPlainTextAppearance(appearance: appearance)
        rulerView.applyResolvedAppearance(appearance)
        textView.needsDisplay = true
        needsDisplay = true

        if refreshSyntax, !sourceBytes.isEmpty, editorDelegate != nil {
            requestSyntaxAnalysis(debounced: false)
        }
    }

    private func synchronizeTextViewGeometry() {
        guard !isSynchronizingTextGeometry else { return }
        isSynchronizingTextGeometry = true
        defer { isSynchronizingTextGeometry = false }
        let contentSize = scrollView.contentSize
        guard contentSize.width > 0, contentSize.height > 0 else { return }
        lastGeometryContentWidth = contentSize.width
        textView.minSize = contentSize
        if usesWrappedLongLineViewport {
            textView.maxSize = NSSize(
                width: contentSize.width,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.textContainer?.containerSize = NSSize(
                width: contentSize.width,
                height: CGFloat.greatestFiniteMagnitude
            )
        } else {
            textView.maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
        var provisional = textView.frame.size
        provisional.width = usesWrappedLongLineViewport
            ? contentSize.width
            : max(contentSize.width, provisional.width)
        provisional.height = max(contentSize.height, provisional.height)
        if provisional != textView.frame.size { textView.setFrameSize(provisional) }

        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let insets = textView.textContainerInset
        let width = usesWrappedLongLineViewport
            ? contentSize.width
            : max(contentSize.width, ceil(used.maxX + insets.width * 2))
        let height = max(contentSize.height, ceil(used.maxY + insets.height * 2))
        let target = NSSize(width: width, height: height)
        if target != textView.frame.size {
            textView.setFrameSize(target)
        }
    }

    private func resetTextViewGeometryForSnapshot() {
        let contentSize = scrollView.contentSize
        let width = max(1, contentSize.width)
        let height = max(1, contentSize.height)
        textView.minSize = NSSize(width: width, height: height)
        textView.setFrameSize(NSSize(width: width, height: height))
    }

    private func configureTextLayoutForViewport(wrappingLongLines: Bool) {
        usesWrappedLongLineViewport = wrappingLongLines
        scrollView.hasHorizontalScroller = !wrappingLongLines
        textView.isHorizontallyResizable = !wrappingLongLines
        textView.textContainer?.widthTracksTextView = wrappingLongLines
        textView.textContainer?.lineBreakMode = wrappingLongLines ? .byCharWrapping : .byWordWrapping

        if wrappingLongLines {
            rememberedHorizontalOffset = leadingHorizontalOrigin
                ?? scrollView.contentView.bounds.minX
            let width = max(1, scrollView.contentSize.width)
            textView.maxSize = NSSize(
                width: width,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.textContainer?.containerSize = NSSize(
                width: width,
                height: CGFloat.greatestFiniteMagnitude
            )
        } else {
            textView.maxSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
            textView.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
    }

    private func loadViewport(
        centeredAt requestedOffset: Int64,
        preferredSelection: Range<Int64>?,
        preserving anchor: ViewportScrollAnchor? = nil
    ) {
        reloadWork?.cancel()
        let generation = invalidateSyntaxAnalysis()
        guard let delegate = editorDelegate else { return }

        let total = max(0, delegate.editorDocumentByteCount)
        let center = min(max(0, requestedOffset), total)
        let capacity = Int64(Self.maximumViewportBytes)
        var lower = max(0, center - capacity / 2)
        var upper = min(total, lower + capacity)
        lower = max(0, upper - capacity)

        do {
            LighTxtSignpost.begin("ViewportRead", bytes: min(capacity, total))
            let aligned = try utf8AlignedViewportRange(
                lower..<upper,
                totalByteCount: total,
                maximumByteCount: capacity,
                delegate: delegate
            )
            lower = aligned.lowerBound
            upper = aligned.upperBound
            var bytes = try delegate.editorReadBytes(in: lower..<upper)

            // TextKit's no-wrap horizontal extent becomes a compositor surface.
            // A 512 KiB minified line is millions of pixels wide, and macOS can
            // retain one such graphics allocation after every virtual jump. Keep
            // the large viewport for normal line-oriented files, but page through
            // unusually long lines with a much smaller, still-editable window.
            let longLineCapacity = Int64(Self.maximumUnbrokenLineViewportBytes)
            var usesLongLineViewport = false
            if bytes.count > Self.maximumUnbrokenLineViewportBytes,
               Self.containsUnbrokenLineLonger(
                   than: Self.maximumUnbrokenLineViewportBytes,
                   in: bytes
               ) {
                var narrowLower = max(0, center - longLineCapacity / 2)
                let narrowUpper = min(total, narrowLower + longLineCapacity)
                narrowLower = max(0, narrowUpper - longLineCapacity)
                let narrow = try utf8AlignedViewportRange(
                    narrowLower..<narrowUpper,
                    totalByteCount: total,
                    maximumByteCount: longLineCapacity,
                    delegate: delegate
                )
                lower = narrow.lowerBound
                upper = narrow.upperBound
                bytes = try delegate.editorReadBytes(in: lower..<upper)
                usesLongLineViewport = true
            }
            LighTxtSignpost.end("ViewportRead", bytes: Int64(bytes.count))

            sourceBytes = bytes
            decoder = ViewportUTF8Map(data: bytes)
            viewportRange = lower..<(lower + Int64(bytes.count))
            let location = delegate.editorLineLocation(at: lower)
            viewportFirstLine = location.lineNumber
            viewportFirstLineStart = location.lineStartByteOffset
            requestedSelectionAfterLoad = preferredSelection

            isApplyingSnapshot = true
            configureTextLayoutForViewport(wrappingLongLines: usesLongLineViewport)
            resetTextViewGeometryForSnapshot()
            textView.string = decoder.text
            applyPlainTextAppearance()
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            synchronizeTextViewGeometry()

            rulerView.viewportStartLine = viewportFirstLine
            rulerView.viewportStartsAtLineBoundary = viewportFirstLineStart == lower
            rulerView.needsDisplay = true
            restoreRequestedSelectionOrCenter(center, preserving: anchor)
            isApplyingSnapshot = false
            updateVirtualScroller(visibleOffset: center)
            delegate.editorDidLoadViewport(byteRange: viewportRange)
            delegate.editorDidExpose(byteRange: viewportRange)
            startSyntaxAnalysis(generation: generation)
        } catch {
            LighTxtSignpost.end("ViewportRead", bytes: 0)
            editorDelegate?.editorDidFail(error)
        }
    }

    /// Moves viewport edges to UTF-8 scalar boundaries using two four-byte
    /// probes. The materialized text window itself never exceeds 512 KiB.
    private func utf8AlignedViewportRange(
        _ desired: Range<Int64>,
        totalByteCount: Int64,
        maximumByteCount: Int64,
        delegate: VirtualTextEditorDelegate
    ) throws -> Range<Int64> {
        guard !desired.isEmpty else { return desired }
        var lower = desired.lowerBound

        if lower > 0, lower < totalByteCount {
            let probeStart = max(0, lower - 3)
            let probe = try delegate.editorReadBytes(in: probeStart..<min(totalByteCount, lower + 1))
            var index = Int(lower - probeStart)
            while lower > probeStart,
                  index < probe.count,
                  Self.isUTF8Continuation(probe[index]) {
                lower -= 1
                index -= 1
            }
        }

        let capacity = max(0, maximumByteCount)
        var upper = min(totalByteCount, lower + capacity)
        if upper < totalByteCount {
            let probeStart = max(lower, upper - 3)
            let probe = try delegate.editorReadBytes(in: probeStart..<min(totalByteCount, upper + 1))
            var index = Int(upper - probeStart)
            while upper > probeStart,
                  index < probe.count,
                  Self.isUTF8Continuation(probe[index]) {
                upper -= 1
                index -= 1
            }
        }
        return lower..<max(lower, upper)
    }

    private static func containsUnbrokenLineLonger(
        than maximumByteCount: Int,
        in data: Data
    ) -> Bool {
        guard maximumByteCount >= 0 else { return true }
        var unbrokenByteCount = 0
        for byte in data {
            if byte == 0x0A || byte == 0x0D {
                unbrokenByteCount = 0
            } else {
                unbrokenByteCount += 1
                if unbrokenByteCount > maximumByteCount { return true }
            }
        }
        return false
    }

    private static func isUTF8Continuation(_ byte: UInt8) -> Bool {
        byte & 0xC0 == 0x80
    }

    private func restoreRequestedSelectionOrCenter(
        _ center: Int64,
        preserving anchor: ViewportScrollAnchor?
    ) {
        if let selection = requestedSelectionAfterLoad {
            requestedSelectionAfterLoad = nil
            let selectionIsVisible = viewportRange.lowerBound <= selection.lowerBound
                && selection.upperBound <= viewportRange.upperBound
            if selectionIsVisible {
                selectGlobalByteRange(selection, scroll: anchor == nil)
                if let anchor { restore(anchor) }
                return
            }
        }
        let target = anchor?.byteOffset ?? center
        let local = Int(max(0, min(Int64(sourceBytes.count), target - viewportRange.lowerBound)))
        let utf16 = decoder.utf16Offset(forByteOffset: local, bias: .leading)
        textView.setSelectedRange(NSRange(location: utf16, length: 0))
        if let anchor {
            restore(anchor)
        } else {
            scrollGlobalByteOffset(target, verticalFraction: 0.5)
        }
    }

    private func restore(_ anchor: ViewportScrollAnchor) {
        scrollGlobalByteOffset(
            anchor.byteOffset,
            screenOffset: anchor.screenOffset,
            horizontalOffset: anchor.horizontalOffset
        )
    }

    private func scrollGlobalByteOffset(_ offset: Int64, verticalFraction: CGFloat) {
        let clip = scrollView.contentView
        let position = verticalPosition(forGlobalByteOffset: offset)
        scrollClip(
            toY: position - clip.bounds.height * verticalFraction,
            horizontalOffset: rememberedHorizontalOffset
        )
    }

    private func scrollGlobalByteOffset(
        _ offset: Int64,
        screenOffset: CGFloat,
        horizontalOffset: CGFloat
    ) {
        scrollClip(
            toY: verticalPosition(forGlobalByteOffset: offset) - screenOffset,
            horizontalOffset: horizontalOffset
        )
    }

    private func verticalPosition(forGlobalByteOffset offset: Int64) -> CGFloat {
        guard let layoutManager = textView.layoutManager,
              layoutManager.numberOfGlyphs > 0 else { return 0 }
        let local = Int(max(0, min(Int64(sourceBytes.count), offset - viewportRange.lowerBound)))
        let utf16 = decoder.utf16Offset(forByteOffset: local, bias: .leading)
        let character = min(utf16, max(0, decoder.utf16Count - 1))
        let glyph = min(
            layoutManager.glyphIndexForCharacter(at: character),
            layoutManager.numberOfGlyphs - 1
        )
        let line = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        return line.minY + textView.textContainerOrigin.y
    }

    private func scrollClip(toY requestedY: CGFloat, horizontalOffset: CGFloat) {
        let clip = scrollView.contentView
        let maximumY = max(0, textView.frame.height - clip.bounds.height)
        let leadingX = leadingHorizontalOrigin ?? min(0, clip.bounds.minX)
        let maximumX = leadingX + max(0, textView.frame.width - clip.bounds.width)
        clip.scroll(to: NSPoint(
            x: min(max(leadingX, horizontalOffset), maximumX),
            y: min(max(0, requestedY), maximumY)
        ))
        scrollView.reflectScrolledClipView(clip)
    }

    private func selectGlobalByteRange(_ global: Range<Int64>, scroll: Bool) {
        let lowerByte = Int(max(0, global.lowerBound - viewportRange.lowerBound))
        let upperByte = Int(max(Int64(lowerByte), global.upperBound - viewportRange.lowerBound))
        let lowerUTF16 = decoder.utf16Offset(forByteOffset: lowerByte, bias: .leading)
        let upperUTF16 = decoder.utf16Offset(forByteOffset: upperByte, bias: .trailing)
        let range = NSRange(location: lowerUTF16, length: max(0, upperUTF16 - lowerUTF16))
        textView.setSelectedRange(range)
        if scroll { textView.scrollRangeToVisible(range) }
    }

    func textView(
        _ textView: NSTextView,
        shouldChangeTextIn affectedCharRange: NSRange,
        replacementString: String?
    ) -> Bool {
        guard !isApplyingSnapshot, !isCommittingEdit,
              let globalRange = localUTF16RangeToGlobalBytes(affectedCharRange) else { return isApplyingSnapshot }

        let replacement = replacementString ?? ""
        let replacementBytes = Data(replacement.utf8)
        let localLower = Int(globalRange.lowerBound - viewportRange.lowerBound)
        let localUpper = Int(globalRange.upperBound - viewportRange.lowerBound)
        let pending = PendingReplacement(
            localByteRange: localLower..<localUpper,
            globalByteRange: globalRange,
            bytes: replacementBytes
        )

        do {
            isCommittingEdit = true
            try editorDelegate?.editorReplaceBytes(in: globalRange, with: replacementBytes)

            let projectedViewportByteCount = sourceBytes.count
                - pending.localByteRange.count
                + replacementBytes.count
            if projectedViewportByteCount > Self.maximumViewportBytes {
                // A large paste belongs in the file-backed edit store, never
                // in TextKit. The core mutation is already complete; veto the
                // local insertion and repaint a bounded window around its end
                // on the next run-loop turn.
                let caret = globalRange.lowerBound + Int64(replacementBytes.count)
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isCommittingEdit = false
                    self.editorDelegate?.editorDidCommitEdit(
                        replaced: globalRange,
                        insertedByteCount: Int64(replacementBytes.count)
                    )
                    self.loadViewport(
                        centeredAt: caret,
                        preferredSelection: caret..<caret
                    )
                }
                return false
            }

            isCommittingEdit = false
            pendingReplacement = pending
            return true
        } catch {
            isCommittingEdit = false
            editorDelegate?.editorDidFail(error)
            NSSound.beep()
            return false
        }
    }

    func textDidChange(_ notification: Notification) {
        guard !isApplyingSnapshot, let replacement = pendingReplacement else { return }
        pendingReplacement = nil

        sourceBytes.replaceSubrange(replacement.localByteRange, with: replacement.bytes)
        viewportRange = viewportRange.lowerBound..<(
            viewportRange.upperBound
                - Int64(replacement.localByteRange.count)
                + Int64(replacement.bytes.count)
        )
        decoder = ViewportUTF8Map(data: sourceBytes)
        editorDelegate?.editorDidCommitEdit(
            replaced: replacement.globalByteRange,
            insertedByteCount: Int64(replacement.bytes.count)
        )
        editorDelegate?.editorDidLoadViewport(byteRange: viewportRange)
        rulerView.needsDisplay = true
        synchronizeTextViewGeometry()
        requestSyntaxAnalysis(debounced: true)
        scheduleRecenterIfNeeded(forceWhenOversized: sourceBytes.count > Self.maximumViewportBytes)
        updateSelectionStatus()
    }

    @objc private func editorFontDidChange(_ notification: Notification) {
        let rawValue = notification.userInfo?[LighTxtFontController.notificationChoiceKey] as? String
        let updatedChoice = rawValue.flatMap(LighTxtEditorFontChoice.init(rawValue:))
            ?? LighTxtEditorFontChoice.persisted()
        guard updatedChoice != fontChoice else { return }
        fontChoice = updatedChoice
        applySelectedFont(refreshSyntax: true)
    }

    private func applySelectedFont(refreshSyntax: Bool) {
        let editorFont = fontChoice.font(ofSize: fontSize)
        textView.font = editorFont
        textView.typingAttributes[.font] = editorFont
        rulerView.font = fontChoice.font(ofSize: max(9, fontSize - 2))

        if let storage = textView.textStorage, storage.length > 0 {
            let fullRange = NSRange(location: 0, length: storage.length)
            storage.addAttribute(.font, value: editorFont, range: fullRange)
            textView.layoutManager?.invalidateLayout(
                forCharacterRange: fullRange,
                actualCharacterRange: nil
            )
            textView.layoutManager?.invalidateDisplay(forCharacterRange: fullRange)
        }
        synchronizeTextViewGeometry()
        textView.needsDisplay = true
        rulerView.needsDisplay = true

        if refreshSyntax, !sourceBytes.isEmpty, editorDelegate != nil {
            requestSyntaxAnalysis(debounced: false)
        }
    }

    @objc private func selectionChanged(_ notification: Notification) {
        guard !isApplyingSnapshot else { return }
        textView.needsDisplay = true
        updateSelectionStatus()
    }

    private func updateSelectionStatus() {
        let range = selectedGlobalByteRange
        let caret = range.lowerBound
        let location = editorDelegate?.editorLineLocation(at: caret)
            ?? EditorLineLocation(lineNumber: viewportFirstLine, lineStartByteOffset: viewportFirstLineStart)
        let columnBytes = max(0, caret - location.lineStartByteOffset)
        editorDelegate?.editorSelectionDidChange(
            byteRange: range,
            line: location.lineNumber,
            column: Int(min(Int64(Int.max), columnBytes)) + 1
        )
    }

    private func localUTF16RangeToGlobalBytes(_ range: NSRange) -> Range<Int64>? {
        guard range.location != NSNotFound,
              range.location >= 0,
              NSMaxRange(range) <= decoder.utf16Count else { return nil }
        let localLower = decoder.byteOffset(forUTF16Offset: range.location, bias: .leading)
        let localUpper = decoder.byteOffset(forUTF16Offset: NSMaxRange(range), bias: .trailing)
        return (viewportRange.lowerBound + Int64(localLower))..<(viewportRange.lowerBound + Int64(localUpper))
    }

    @discardableResult
    private func invalidateSyntaxAnalysis() -> UInt64 {
        syntaxGeneration &+= 1
        syntaxDebounceWork?.cancel()
        syntaxDebounceWork = nil
        syntaxCancellation?.cancel()
        syntaxCancellation = nil
        return syntaxGeneration
    }

    private func requestSyntaxAnalysis(debounced: Bool) {
        let generation = invalidateSyntaxAnalysis()
        guard debounced else {
            startSyntaxAnalysis(generation: generation)
            return
        }

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.syntaxGeneration == generation else { return }
            self.syntaxDebounceWork = nil
            self.startSyntaxAnalysis(generation: generation)
        }
        syntaxDebounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    private func startSyntaxAnalysis(generation: UInt64) {
        guard generation == syntaxGeneration, let editorDelegate else { return }
        let snapshot: DocumentSnapshot
        do {
            snapshot = try editorDelegate.editorSnapshot()
        } catch {
            editorDelegate.editorDidFail(error)
            return
        }
        let cancellation = ViewportSyntaxCancellation()
        syntaxCancellation = cancellation
        let limits = SyntaxLimits(
            maximumSpans: 32_768,
            maximumDiagnostics: 128,
            maximumFoldRanges: 2_048,
            maximumNestingDepth: 512,
            maximumTokenBytes: Self.maximumViewportBytes,
            csvDelimiter: 0x2C
        )
        let input = ViewportSyntaxInput(
            generation: generation,
            data: sourceBytes,
            decoder: decoder,
            snapshot: snapshot,
            baseByteOffset: viewportRange.lowerBound,
            documentByteCount: editorDelegate.editorDocumentByteCount,
            fileType: editorDelegate.editorSyntaxFileType,
            limits: limits
        )
        ViewportSyntaxWorker.queue.async {
            guard let output = ViewportSyntaxWorker.analyze(input, cancellation: cancellation),
                  !cancellation.isCancelled else { return }
            DispatchQueue.main.async { [weak self] in
                self?.receiveSyntaxOutput(output, cancellation: cancellation)
            }
        }
    }

    private func receiveSyntaxOutput(
        _ output: ViewportSyntaxOutput,
        cancellation: ViewportSyntaxCancellation
    ) {
        guard !cancellation.isCancelled,
              output.generation == syntaxGeneration,
              output.baseByteOffset == viewportRange.lowerBound,
              output.viewportData.count == sourceBytes.count else { return }
        syntaxCancellation = nil
        editorDelegate?.editorDidDiscoverStructure(
            folds: output.folds,
            viewportData: output.viewportData,
            viewportBaseOffset: output.baseByteOffset
        )
        applyPlainTextAppearance()
        applyDecorationBatch(
            output.decorations,
            startingAt: 0,
            generation: output.generation
        )
    }

    private func applyPlainTextAppearance(appearance: NSAppearance? = nil) {
        guard let storage = textView.textStorage else { return }
        let appearance = appearance ?? effectiveAppearance
        let font = fontChoice.font(ofSize: fontSize)
        let primary = LighTxtTheme.resolved(LighTxtTheme.primaryText, for: appearance)
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: primary
        ]
        guard storage.length > 0 else {
            textView.needsDisplay = true
            return
        }
        let fullRange = NSRange(location: 0, length: storage.length)
        storage.setAttributes([
            .font: font,
            .foregroundColor: primary
        ], range: fullRange)
        textView.layoutManager?.invalidateDisplay(forCharacterRange: fullRange)
        textView.needsDisplay = true
    }

    private func applyDecorationBatch(
        _ decorations: [ViewportDecoration],
        startingAt start: Int,
        generation: UInt64
    ) {
        guard generation == syntaxGeneration,
              let storage = textView.textStorage,
              storage.length == decoder.utf16Count else { return }
        let end = min(decorations.count, start + Self.decorationBatchSize)
        guard start < end else { return }

        storage.beginEditing()
        for decoration in decorations[start..<end] {
            let location = decoration.utf16Location
            guard location >= 0, location < storage.length else { continue }
            let length = min(decoration.utf16Length, storage.length - location)
            guard length > 0 else { continue }
            let range = NSRange(location: location, length: length)
            switch decoration.kind {
            case .semantic(let kind):
                var attributes = SyntaxPalette.attributes(
                    for: kind,
                    appearance: effectiveAppearance
                )
                switch kind {
                case .heading, .keyword, .key, .tag:
                    attributes[.font] = fontChoice.font(ofSize: fontSize, emphasized: true)
                default:
                    break
                }
                storage.addAttributes(attributes, range: range)
            case .diagnostic(let message):
                storage.addAttributes([
                    .underlineStyle: NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.single.rawValue,
                    .underlineColor: LighTxtTheme.resolved(
                        LighTxtTheme.error,
                        for: effectiveAppearance
                    ),
                    .toolTip: message
                ], range: range)
            }
        }
        storage.endEditing()

        guard end < decorations.count else { return }
        DispatchQueue.main.async { [weak self] in
            self?.applyDecorationBatch(decorations, startingAt: end, generation: generation)
        }
    }

    @objc private func clipBoundsChanged(_ notification: Notification) {
        rulerView.needsDisplay = true
        if !isApplyingSnapshot, !isSynchronizingTextGeometry {
            if leadingHorizontalOrigin == nil {
                leadingHorizontalOrigin = scrollView.contentView.bounds.minX
            }
            rememberedHorizontalOffset = scrollView.contentView.bounds.minX
        }
        let visible = visibleGlobalByteRange
        updateVirtualScroller(visibleOffset: visible.lowerBound)
        editorDelegate?.editorDidExpose(byteRange: visible)
        scheduleRecenterIfNeeded(forceWhenOversized: false)
    }

    private func scheduleRecenterIfNeeded(forceWhenOversized: Bool) {
        guard !isApplyingSnapshot,
              !isSynchronizingTextGeometry,
              !viewportRange.isEmpty else { return }
        let total = editorDelegate?.editorDocumentByteCount ?? 0
        guard viewportRange.lowerBound > 0 || viewportRange.upperBound < total else { return }
        let visible = visibleGlobalByteRange
        let viewportBytes = max(1, viewportRange.count)
        let lowerFraction = Double(max(0, visible.lowerBound - viewportRange.lowerBound))
            / Double(viewportBytes)
        let upperFraction = Double(max(0, visible.upperBound - viewportRange.lowerBound))
            / Double(viewportBytes)
        let nearEdge = lowerFraction < Self.recenterThreshold
            || upperFraction > 1 - Self.recenterThreshold
        guard nearEdge || forceWhenOversized else { return }

        let current = visible.lowerBound
        if current <= viewportRange.lowerBound + 8, viewportRange.lowerBound == 0 { return }
        if current >= viewportRange.upperBound - 8,
           viewportRange.upperBound >= editorDelegate?.editorDocumentByteCount ?? 0 { return }

        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let selection = self.selectedGlobalByteRange
            self.loadViewport(
                centeredAt: current,
                preferredSelection: selection,
                preserving: ViewportScrollAnchor(
                    byteOffset: current,
                    screenOffset: 0,
                    horizontalOffset: rememberedHorizontalOffset
                )
            )
        }
        reloadWork = work
        let delay = usesWrappedLongLineViewport ? 0.15 : 0.04
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func updateVirtualScroller(visibleOffset: Int64) {
        let total = max(0, editorDelegate?.editorDocumentByteCount ?? 0)
        guard total > 0 else {
            virtualScroller.doubleValue = 0
            virtualScroller.knobProportion = 1
            virtualScroller.isEnabled = false
            return
        }
        virtualScroller.isEnabled = true
        virtualScroller.doubleValue = min(1, max(0, Double(visibleOffset) / Double(total)))
        let visibleBytes = max(1, visibleGlobalByteRange.count)
        virtualScroller.knobProportion = min(1, max(0.02, Double(visibleBytes) / Double(total)))
    }

    @objc private func virtualScroll(_ sender: NSScroller) {
        guard let delegate = editorDelegate else { return }
        let total = delegate.editorDocumentByteCount
        var value = sender.doubleValue
        switch sender.hitPart {
        case .decrementLine:
            value -= max(0.000_001, Double(Self.maximumViewportBytes / 8) / Double(max(1, total)))
        case .incrementLine:
            value += max(0.000_001, Double(Self.maximumViewportBytes / 8) / Double(max(1, total)))
        case .decrementPage:
            value -= max(0.000_01, Double(Self.maximumViewportBytes) / Double(max(1, total)))
        case .incrementPage:
            value += max(0.000_01, Double(Self.maximumViewportBytes) / Double(max(1, total)))
        default:
            break
        }
        let clampedValue = min(1, max(0, value))
        sender.doubleValue = clampedValue
        let offset = Int64(Double(total) * clampedValue)

        if viewportRange.lowerBound <= offset, offset <= viewportRange.upperBound {
            isApplyingSnapshot = true
            scrollGlobalByteOffset(offset, verticalFraction: 0.5)
            isApplyingSnapshot = false
            updateVirtualScroller(visibleOffset: visibleGlobalByteRange.lowerBound)
            return
        }

        guard usesWrappedLongLineViewport else {
            loadViewport(centeredAt: offset, preferredSelection: nil)
            return
        }

        // Dragging across a huge, unbroken line can otherwise create a fresh
        // wrapped TextKit/compositor surface for every input event faster than
        // WindowServer reclaims the prior one. Keep the thumb responsive while
        // materializing only the last requested destination.
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.loadViewport(centeredAt: offset, preferredSelection: nil)
        }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}

@MainActor
private final class ViewportLineNumberRuler: NSRulerView {
    var viewportStartLine: Int64 = 1
    var viewportStartsAtLineBoundary = true
    var font = LighTxtTheme.gutterFont

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        clientView = scrollView?.documentView
        ruleThickness = 56
        wantsLayer = true
        layer?.masksToBounds = true
        applyResolvedAppearance(effectiveAppearance)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyResolvedAppearance(effectiveAppearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyResolvedAppearance(effectiveAppearance)
    }

    func applyResolvedAppearance(_ appearance: NSAppearance) {
        layer?.backgroundColor = LighTxtTheme.resolved(
            LighTxtTheme.gutterBackground,
            for: appearance
        ).cgColor
        needsDisplay = true
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        let clippedRect = bounds.intersection(rect)
        guard !clippedRect.isEmpty else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: bounds).addClip()
        defer { NSGraphicsContext.restoreGraphicsState() }

        guard let textView = scrollView?.documentView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        let appearance = effectiveAppearance
        LighTxtTheme.resolved(LighTxtTheme.gutterBackground, for: appearance).setFill()
        clippedRect.fill()
        LighTxtTheme.resolved(LighTxtTheme.separator, for: appearance).setStroke()
        let border = NSBezierPath()
        border.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY))
        border.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        border.stroke()

        let visibleRect = scrollView?.contentView.bounds ?? .zero
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let string = textView.string as NSString
        var line = viewportStartLine
        if characterRange.location > 0 {
            let prefix = NSRange(location: 0, length: min(characterRange.location, string.length))
            string.enumerateSubstrings(in: prefix, options: [.byLines, .substringNotRequired]) { _, _, enclosing, _ in
                if NSMaxRange(enclosing) <= NSMaxRange(prefix) { line += 1 }
            }
        }

        var location = characterRange.location
        if location > 0 {
            location = string.lineRange(for: NSRange(location: location, length: 0)).location
        }
        let end = min(string.length, NSMaxRange(characterRange) + 1)
        while location <= end, location < string.length {
            let lineRange = string.lineRange(for: NSRange(location: location, length: 0))
            let glyph = layoutManager.glyphRange(forCharacterRange: NSRange(location: location, length: 0), actualCharacterRange: nil)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: min(glyph.location, max(0, layoutManager.numberOfGlyphs - 1)), effectiveRange: nil)
            let y = fragment.minY + textView.textContainerOrigin.y - visibleRect.minY
            let label = line.formatted() as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: LighTxtTheme.resolved(
                    LighTxtTheme.secondaryText,
                    for: appearance
                )
            ]
            let size = label.size(withAttributes: attributes)
            label.draw(at: NSPoint(x: bounds.width - size.width - 9, y: y + 1), withAttributes: attributes)
            line += 1
            let next = NSMaxRange(lineRange)
            guard next > location else { break }
            location = next
        }

        if !viewportStartsAtLineBoundary {
            let continuation = "·" as NSString
            continuation.draw(
                at: NSPoint(x: 7, y: 4),
                withAttributes: [
                    .font: font,
                    .foregroundColor: LighTxtTheme.resolved(
                        LighTxtTheme.accent,
                        for: appearance
                    )
                ]
            )
        }
    }
}

private struct ViewportUTF8Map: Sendable {
    enum Bias: Sendable { case leading, trailing }

    struct Checkpoint: Sendable {
        let byte: Int
        let utf16: Int
    }

    let data: Data
    let text: String
    let checkpoints: [Checkpoint]
    let utf16Count: Int

    init(data: Data) {
        self.data = data
        self.text = String(decoding: data, as: UTF8.self)
        var built: [Checkpoint] = [Checkpoint(byte: 0, utf16: 0)]
        built.reserveCapacity(max(1, data.count / 2_048))
        var byte = 0
        var utf16 = 0
        var nextCheckpoint = 2_048
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            while byte < bytes.count {
                let decoded = Self.decode(bytes, at: byte)
                byte += decoded.length
                utf16 += decoded.scalar > 0xFFFF ? 2 : 1
                if byte >= nextCheckpoint {
                    built.append(Checkpoint(byte: byte, utf16: utf16))
                    nextCheckpoint = byte + 2_048
                }
            }
        }
        if built.last?.byte != data.count {
            built.append(Checkpoint(byte: data.count, utf16: utf16))
        }
        self.checkpoints = built
        self.utf16Count = (text as NSString).length
    }

    func byteOffset(forUTF16Offset requested: Int, bias: Bias) -> Int {
        let target = min(max(0, requested), utf16Count)
        let checkpoint = checkpoint(atOrBeforeUTF16Offset: target)
        var byte = checkpoint.byte
        var utf16 = checkpoint.utf16
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            while byte < bytes.count, utf16 < target {
                let decoded = Self.decode(bytes, at: byte)
                let units = decoded.scalar > 0xFFFF ? 2 : 1
                if utf16 + units > target {
                    if bias == .trailing { byte += decoded.length }
                    utf16 = target
                    break
                }
                byte += decoded.length
                utf16 += units
            }
        }
        return min(data.count, byte)
    }

    func utf16Offset(forByteOffset requested: Int, bias: Bias) -> Int {
        let target = min(max(0, requested), data.count)
        let checkpoint = checkpoint(atOrBeforeByteOffset: target)
        var byte = checkpoint.byte
        var utf16 = checkpoint.utf16
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            while byte < bytes.count, byte < target {
                let decoded = Self.decode(bytes, at: byte)
                if byte + decoded.length > target {
                    if bias == .trailing { utf16 += decoded.scalar > 0xFFFF ? 2 : 1 }
                    byte = target
                    break
                }
                byte += decoded.length
                utf16 += decoded.scalar > 0xFFFF ? 2 : 1
            }
        }
        return min(utf16Count, utf16)
    }

    private func checkpoint(atOrBeforeUTF16Offset target: Int) -> Checkpoint {
        var lower = 0
        var upper = checkpoints.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if checkpoints[middle].utf16 <= target {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return checkpoints[max(0, lower - 1)]
    }

    private func checkpoint(atOrBeforeByteOffset target: Int) -> Checkpoint {
        var lower = 0
        var upper = checkpoints.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if checkpoints[middle].byte <= target {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return checkpoints[max(0, lower - 1)]
    }

    private static func decode(_ bytes: UnsafeBufferPointer<UInt8>, at index: Int) -> (scalar: UInt32, length: Int) {
        let first = bytes[index]
        if first < 0x80 { return (UInt32(first), 1) }
        let expectedLength: Int
        let accumulator: UInt32
        switch first {
        case 0xC2...0xDF: expectedLength = 2; accumulator = UInt32(first & 0x1F)
        case 0xE0...0xEF: expectedLength = 3; accumulator = UInt32(first & 0x0F)
        case 0xF0...0xF4: expectedLength = 4; accumulator = UInt32(first & 0x07)
        default: return (0xFFFD, 1)
        }

        // Match Swift's UTF-8 decoder's "maximal subpart" replacement
        // behavior exactly. A truncated but otherwise valid prefix becomes
        // one U+FFFD, so byte/UTF-16 coordinates remain aligned with the
        // String shown by TextKit even for malformed source files.
        guard index + 1 < bytes.count else { return (0xFFFD, 1) }
        let second = bytes[index + 1]
        let validSecond: Bool
        switch first {
        case 0xE0: validSecond = (0xA0...0xBF).contains(second)
        case 0xED: validSecond = (0x80...0x9F).contains(second)
        case 0xF0: validSecond = (0x90...0xBF).contains(second)
        case 0xF4: validSecond = (0x80...0x8F).contains(second)
        default: validSecond = (0x80...0xBF).contains(second)
        }
        guard validSecond else { return (0xFFFD, 1) }

        var scalar = accumulator
        scalar = (scalar << 6) | UInt32(second & 0x3F)
        if expectedLength == 2 { return (scalar, 2) }

        guard index + 2 < bytes.count else { return (0xFFFD, 2) }
        let third = bytes[index + 2]
        guard (0x80...0xBF).contains(third) else { return (0xFFFD, 2) }
        scalar = (scalar << 6) | UInt32(third & 0x3F)
        if expectedLength == 3 { return (scalar, 3) }

        guard index + 3 < bytes.count else { return (0xFFFD, 3) }
        let fourth = bytes[index + 3]
        guard (0x80...0xBF).contains(fourth) else { return (0xFFFD, 3) }
        scalar = (scalar << 6) | UInt32(fourth & 0x3F)
        return (scalar, 4)
    }
}

private extension Int {
    init(clamping value: Int64) {
        if value > Int64(Int.max) { self = Int.max }
        else if value < Int64(Int.min) { self = Int.min }
        else { self = Int(value) }
    }
}
