import AppKit

@MainActor
final class DocumentOpenAsAccessoryView: NSView {
    private enum FormatChoice: Int, CaseIterable {
        case automatic
        case plainText
        case json
        case markdown
        case sql
        case xml
        case yaml
        case comma
        case tab
        case semicolon
        case pipe

        var title: String {
            switch self {
            case .automatic: "Automatic (sample content)"
            case .plainText: "Plain text"
            case .json: "JSON"
            case .markdown: "Markdown"
            case .sql: "SQL"
            case .xml: "XML"
            case .yaml: "YAML"
            case .comma: "Delimited table — comma"
            case .tab: "Delimited table — tab"
            case .semicolon: "Delimited table — semicolon"
            case .pipe: "Delimited table — pipe"
            }
        }

        var format: DocumentOpenAsFormat {
            switch self {
            case .automatic: .automatic
            case .plainText: .plainText
            case .json: .json
            case .markdown: .markdown
            case .sql: .sql
            case .xml: .xml
            case .yaml: .yaml
            case .comma: .delimitedText(.comma)
            case .tab: .delimitedText(.tab)
            case .semicolon: .delimitedText(.semicolon)
            case .pipe: .delimitedText(.pipe)
            }
        }
    }

    private let formatPopup = NSPopUpButton()
    private let encodingPopup = NSPopUpButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        for choice in FormatChoice.allCases {
            formatPopup.addItem(withTitle: choice.title)
            formatPopup.lastItem?.tag = choice.rawValue
        }
        encodingPopup.addItem(withTitle: "Automatic (BOM/sample)")
        encodingPopup.lastItem?.tag = -1
        for (index, encoding) in DocumentTextEncoding.allCases.enumerated() {
            encodingPopup.addItem(withTitle: encoding.rawValue)
            encodingPopup.lastItem?.tag = index
        }

        let note = NSTextField(wrappingLabelWithString:
            "Detection reads at most 64 KB. UTF-16/32 files open as a safe UTF-8 working copy; the original is not overwritten."
        )
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 2

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Content:"), formatPopup],
            [NSTextField(labelWithString: "Encoding:"), encodingPopup],
            [NSView(), note],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        addSubview(grid)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 430),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        setAccessibilityLabel("Open As options")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var options: DocumentOpenOptions {
        let formatChoice = FormatChoice(rawValue: formatPopup.selectedItem?.tag ?? 0) ?? .automatic
        let encoding: DocumentEncodingSelection
        if encodingPopup.selectedItem?.tag == -1 {
            encoding = .automatic
        } else {
            let index = encodingPopup.selectedItem?.tag ?? 0
            encoding = DocumentTextEncoding.allCases.indices.contains(index)
                ? .explicit(DocumentTextEncoding.allCases[index])
                : .automatic
        }
        return DocumentOpenOptions(format: formatChoice.format, encoding: encoding)
    }
}
