import AppKit

@MainActor
protocol FindBarViewDelegate: AnyObject {
    func findBar(
        _ findBar: FindBarView,
        queryDidChange query: String,
        regularExpression: Bool,
        caseSensitive: Bool,
        wholeWords: Bool
    )
    func findBarFindNext(_ findBar: FindBarView, backwards: Bool)
    func findBarFindAll(_ findBar: FindBarView)
    func findBarReplaceCurrent(_ findBar: FindBarView, replacement: String)
    func findBarReplaceAll(_ findBar: FindBarView, replacement: String)
    func findBarDidRequestClose(_ findBar: FindBarView)
}

@MainActor
final class FindBarView: NSVisualEffectView, NSSearchFieldDelegate, NSTextFieldDelegate {
    weak var findDelegate: FindBarViewDelegate?

    let searchField = NSSearchField()
    private let replaceField = NSTextField()
    private let regexButton = NSButton(checkboxWithTitle: "Regex", target: nil, action: nil)
    private let caseButton = NSButton(checkboxWithTitle: "Match case", target: nil, action: nil)
    private let wholeWordButton = NSButton(checkboxWithTitle: "Whole word", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "Search this document")
    private var pendingChange: DispatchWorkItem?
    private var statusIsError = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .headerView
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.borderWidth = 0.5
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Find and replace")
        configureControls()
        applyResolvedAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyResolvedAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyResolvedAppearance()
    }

    var query: String {
        get { searchField.stringValue }
        set {
            searchField.stringValue = newValue
            notifyQueryChanged(immediately: true)
        }
    }

    var replacement: String { replaceField.stringValue }
    var usesRegularExpression: Bool { regexButton.state == .on }
    var isCaseSensitive: Bool { caseButton.state == .on }
    var matchesWholeWords: Bool { wholeWordButton.state == .on }

    func focus(selectAll: Bool = false) {
        window?.makeFirstResponder(searchField)
        if selectAll {
            searchField.currentEditor()?.selectAll(nil)
        }
    }

    func setStatus(_ text: String, isError: Bool = false) {
        statusLabel.stringValue = text
        statusIsError = isError
        applyResolvedAppearance()
        statusLabel.toolTip = text
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === searchField else { return }
        notifyQueryChanged(immediately: false)
    }

    func control(
        _ control: NSControl,
        textView: NSTextView,
        doCommandBy commandSelector: Selector
    ) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            findDelegate?.findBarDidRequestClose(self)
            return true
        }
        guard control === searchField,
              commandSelector == #selector(NSResponder.insertNewline(_:)) else {
            return false
        }
        let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
        findDelegate?.findBarFindNext(self, backwards: backwards)
        return true
    }

    private func configureControls() {
        searchField.placeholderString = "Search this document"
        searchField.delegate = self
        searchField.sendsSearchStringImmediately = true
        searchField.maximumRecents = 8
        searchField.recentsAutosaveName = "LighTxt.find.recent"
        searchField.setAccessibilityLabel("Find")
        searchField.controlSize = .regular
        searchField.font = NSFont.systemFont(ofSize: 13)
        searchField.toolTip = "Find text in the current document. Return finds next; Shift-Return finds previous."

        replaceField.placeholderString = "Replacement text"
        replaceField.delegate = self
        replaceField.focusRingType = .exterior
        replaceField.setAccessibilityLabel("Replace with")
        replaceField.controlSize = .regular
        replaceField.font = NSFont.systemFont(ofSize: 13)
        replaceField.toolTip = "Text used by Replace and Replace All. Regex captures use $1, $2, and so on."

        regexButton.target = self
        regexButton.action = #selector(searchOptionChanged(_:))
        regexButton.toolTip = "Treat the search as a regular expression (for example: \\bword\\b or ^name:)"
        regexButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        regexButton.controlSize = .regular
        regexButton.setAccessibilityLabel("Use regular expression")

        caseButton.target = self
        caseButton.action = #selector(searchOptionChanged(_:))
        caseButton.toolTip = "Match uppercase and lowercase letters exactly"
        caseButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        caseButton.controlSize = .regular
        caseButton.setAccessibilityLabel("Match case")

        wholeWordButton.target = self
        wholeWordButton.action = #selector(searchOptionChanged(_:))
        wholeWordButton.toolTip = "Match complete words only. Regular expressions can use \\b explicitly."
        wholeWordButton.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        wholeWordButton.controlSize = .regular
        wholeWordButton.setAccessibilityLabel("Match whole word")

        statusLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = LighTxtTheme.secondaryText
        statusLabel.lineBreakMode = .byTruncatingMiddle
        statusLabel.alignment = .right
        statusLabel.setAccessibilityLabel("Find status")

        let previous = actionButton(
            title: "Previous",
            symbolName: "chevron.up",
            action: #selector(previousMatch(_:))
        )
        previous.toolTip = "Find previous (⇧⌘G)"
        let next = actionButton(
            title: "Next",
            symbolName: "chevron.down",
            action: #selector(nextMatch(_:))
        )
        next.toolTip = "Find next (⌘G)"
        let all = actionButton(title: "Find All", action: #selector(findAll(_:)))
        all.toolTip = "List all matches in the results pane"
        let replace = actionButton(title: "Replace", action: #selector(replaceCurrent(_:)))
        replace.toolTip = "Replace the selected match"
        let replaceAll = actionButton(title: "Replace All", action: #selector(replaceAll(_:)))
        replaceAll.toolTip = "Replace every match as one undoable edit"
        let close = actionButton(title: "", symbolName: "xmark", action: #selector(close(_:)))
        close.toolTip = "Close find and replace"
        close.setAccessibilityLabel("Close find and replace")

        let findLabel = fieldLabel("Find")
        let replaceLabel = fieldLabel("Replace")

        let firstRow = NSStackView(views: [
            findLabel,
            searchField,
            caseButton,
            wholeWordButton,
            regexButton,
            statusLabel,
            close,
        ])
        firstRow.orientation = .horizontal
        firstRow.alignment = .centerY
        firstRow.spacing = 8
        searchField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        firstRow.setHuggingPriority(.defaultLow, for: .horizontal)

        let replacementSpacer = NSView()
        replacementSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        replacementSpacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let secondRow = NSStackView(views: [
            replaceLabel,
            replaceField,
            replacementSpacer,
            previous,
            next,
            all,
            replace,
            replaceAll,
        ])
        secondRow.orientation = .horizontal
        secondRow.alignment = .centerY
        secondRow.spacing = 8
        replaceField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let rows = NSStackView(views: [firstRow, secondRow])
        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 10
        rows.distribution = .fillEqually
        addSubview(rows)

        let trailing = rows.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        trailing.priority = .defaultHigh
        let bottom = rows.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11)
        bottom.priority = .defaultHigh
        let minimumSearchWidth = searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 190)
        minimumSearchWidth.priority = .defaultHigh
        let preferredStatusWidth = statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 116)
        preferredStatusWidth.priority = .defaultLow

        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            trailing,
            rows.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            bottom,
            firstRow.widthAnchor.constraint(equalTo: rows.widthAnchor),
            secondRow.widthAnchor.constraint(equalTo: rows.widthAnchor),
            minimumSearchWidth,
            replaceField.widthAnchor.constraint(equalTo: searchField.widthAnchor),
            findLabel.widthAnchor.constraint(equalToConstant: 54),
            replaceLabel.widthAnchor.constraint(equalTo: findLabel.widthAnchor),
            searchField.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
            replaceField.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
            caseButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
            wholeWordButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
            regexButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
            close.widthAnchor.constraint(greaterThanOrEqualToConstant: 30),
            close.heightAnchor.constraint(greaterThanOrEqualToConstant: 30),
            preferredStatusWidth,
        ])

        searchField.nextKeyView = replaceField
        replaceField.nextKeyView = searchField
    }

    private func fieldLabel(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = LighTxtTheme.primaryText
        label.alignment = .right
        return label
    }

    private func actionButton(
        title: String,
        symbolName: String? = nil,
        action: Selector
    ) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .regular
        button.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        if let symbolName,
           let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: title) {
            button.image = symbol
            button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        }
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true
        return button
    }

    private func applyResolvedAppearance() {
        let appearance = effectiveAppearance
        layer?.borderColor = LighTxtTheme.resolved(
            LighTxtTheme.separator,
            for: appearance
        ).cgColor
        statusLabel.textColor = LighTxtTheme.resolved(
            statusIsError ? LighTxtTheme.error : LighTxtTheme.secondaryText,
            for: appearance
        )
    }

    private func notifyQueryChanged(immediately: Bool) {
        pendingChange?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.findDelegate?.findBar(
                self,
                queryDidChange: self.query,
                regularExpression: self.usesRegularExpression,
                caseSensitive: self.isCaseSensitive,
                wholeWords: self.matchesWholeWords
            )
        }
        pendingChange = work
        if immediately {
            work.perform()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
    }

    @objc private func searchOptionChanged(_ sender: Any?) {
        if sender as AnyObject? === regexButton, usesRegularExpression {
            wholeWordButton.state = .off
            wholeWordButton.isEnabled = false
        } else if !usesRegularExpression {
            wholeWordButton.isEnabled = true
        }
        notifyQueryChanged(immediately: true)
        focus(selectAll: false)
    }

    @objc private func previousMatch(_ sender: Any?) {
        findDelegate?.findBarFindNext(self, backwards: true)
    }

    @objc private func nextMatch(_ sender: Any?) {
        findDelegate?.findBarFindNext(self, backwards: false)
    }

    @objc private func findAll(_ sender: Any?) {
        findDelegate?.findBarFindAll(self)
    }

    @objc private func replaceCurrent(_ sender: Any?) {
        findDelegate?.findBarReplaceCurrent(self, replacement: replacement)
    }

    @objc private func replaceAll(_ sender: Any?) {
        findDelegate?.findBarReplaceAll(self, replacement: replacement)
    }

    @objc private func close(_ sender: Any?) {
        findDelegate?.findBarDidRequestClose(self)
    }
}
