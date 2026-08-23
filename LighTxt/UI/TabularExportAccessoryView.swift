import AppKit

@MainActor
struct TabularExportRequest {
    enum Scope: String, CaseIterable {
        case currentView
        case selectedRows

        var title: String {
            switch self {
            case .currentView: "Current filtered/sorted view"
            case .selectedRows: "Selected rows"
            }
        }
    }

    let format: TabularExportFormat
    let scope: Scope
    let includesHeaders: Bool
}

/// Small shared save-panel accessory used by both virtual table modes. It owns
/// no data and starts no work until the user accepts the panel.
@MainActor
final class TabularExportAccessoryView: NSView {
    private let formatPopup = NSPopUpButton()
    private let scopePopup = NSPopUpButton()
    private let headerCheckbox = NSButton(
        checkboxWithTitle: "Include column names",
        target: nil,
        action: nil
    )
    private var selectedRowCount = 0

    var onFormatChange: ((TabularExportFormat) -> Void)?

    init(selectedRowCount: Int, hasHeaders: Bool) {
        self.selectedRowCount = max(0, selectedRowCount)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let formatLabel = NSTextField(labelWithString: "Format:")
        let scopeLabel = NSTextField(labelWithString: "Rows:")
        for format in TabularExportFormat.allCases {
            formatPopup.addItem(withTitle: format.displayName)
            formatPopup.lastItem?.representedObject = format.rawValue
        }
        formatPopup.target = self
        formatPopup.action = #selector(formatChanged(_:))

        for scope in TabularExportRequest.Scope.allCases {
            scopePopup.addItem(withTitle: scope.title)
            scopePopup.lastItem?.representedObject = scope.rawValue
        }
        if selectedRowCount > 0 {
            scopePopup.selectItem(at: 1)
            scopePopup.item(at: 1)?.title = "Selected rows (\(selectedRowCount.formatted()))"
        } else {
            scopePopup.item(at: 1)?.isEnabled = false
        }
        headerCheckbox.state = hasHeaders ? .on : .off

        let grid = NSGridView(views: [
            [formatLabel, formatPopup],
            [scopeLabel, scopePopup],
            [NSView(), headerCheckbox],
        ])
        grid.translatesAutoresizingMaskIntoConstraints = false
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        addSubview(grid)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: 360),
            grid.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            grid.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            grid.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            grid.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        setAccessibilityLabel("Table export options")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var request: TabularExportRequest {
        let formatRaw = formatPopup.selectedItem?.representedObject as? String
        let scopeRaw = scopePopup.selectedItem?.representedObject as? String
        let format = formatRaw.flatMap(TabularExportFormat.init(rawValue:)) ?? .csv
        let scope = scopeRaw.flatMap(TabularExportRequest.Scope.init(rawValue:)) ?? .currentView
        return TabularExportRequest(
            format: format,
            scope: scope,
            includesHeaders: headerCheckbox.state == .on
        )
    }

    @objc private func formatChanged(_ sender: Any?) {
        onFormatChange?(request.format)
    }
}
