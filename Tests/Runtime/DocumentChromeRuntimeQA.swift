#if LIGHTXT_STANDALONE_CHROME_QA
import AppKit
import Darwin
import Foundation

/// Standalone AppKit regression checks for contextual document-header actions.
/// This deliberately exercises the production view rather than a duplicate
/// layout so icon visibility, accessibility, hit targets, and callbacks cannot
/// drift unnoticed.
@main
@MainActor
struct DocumentChromeRuntimeQA {
    private static var failures: [String] = []
    private static var assertionCount = 0

    static func main() {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 64),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let header = DocumentHeaderView(
            frame: NSRect(x: 0, y: 0, width: 1_200, height: 64)
        )
        header.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(frame: window.contentLayoutRect)
        window.contentView = content
        content.addSubview(header)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            header.topAnchor.constraint(equalTo: content.topAnchor),
            header.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        content.layoutSubtreeIfNeeded()

        expect(!header.qaExportIsVisible, "Export is hidden outside table View mode")
        expect(!header.qaReloadIsVisible, "Reload is hidden outside Parquet View mode")

        header.setPresentationLabels(view: "Table")
        header.presentationMode = .view
        header.update(
            fileURL: nil, title: "Untitled", typeName: "CSV", typeAbbreviation: "CSV",
            byteCount: 4_294_967_296, edited: true, structureAvailable: false
        )
        header.setPresentationEditable(true)
        expect(header.qaPresentationLabels == ["Table", "Source"], "Table and source are named as presentations")
        expect(header.qaDetailText.contains("Editable"), "Table presentation can explicitly remain editable")
        expect(header.qaDetailText.contains("Unsaved changes"), "Unsaved changes have a visible text label")
        header.setPresentationLabels(view: "Tree")
        header.setPresentationEditable(false, reason: "Use Source to edit JSON.")
        expect(header.qaPresentationLabels == ["Tree", "Source"], "Tree representation is named contextually")
        expect(header.presentationMode == .view, "Renaming representations preserves the selected presentation")
        expect(header.qaDetailText.contains("Read-only"), "Read-only presentation is explicit")
        expect(header.qaDetailText.contains("Unsaved changes"), "Read-only presentation does not imply saved changes")
        header.setPresentationLabels(view: "Preview")
        expect(header.qaPresentationLabels == ["Preview", "Source"], "Preview representation is named contextually")
        header.setPresentationChoicesVisible(false)
        expect(!header.qaPresentationChoicesVisible, "Text formats without a distinct renderer hide redundant presentation choices")
        header.setPresentationChoicesVisible(true)
        expect(header.qaPresentationChoicesVisible, "Structured documents restore their presentation choices")

        header.setExportAvailable(
            false,
            visible: true,
            unavailableReason: "Filtering table"
        )
        content.layoutSubtreeIfNeeded()
        expect(header.qaExportIsVisible, "Export appears for a table")
        expect(!header.qaExportIsEnabled, "Busy tables keep Export disabled")
        expect(
            header.qaExportAccessibilityLabel == "Export table",
            "Export retains its accessibility label"
        )
        expect(
            header.qaExportAccessibilityHelp == "Filtering table",
            "The unavailable reason reaches accessibility help"
        )
        expect(
            abs(header.qaExportFrame.width - 32) < 0.01
                && abs(header.qaExportFrame.height - 32) < 0.01,
            "Export keeps its 32 by 32 point hit target"
        )

        var activations = 0
        header.onExport = { activations += 1 }
        header.qaActivateExport()
        expect(activations == 0, "Disabled Export cannot activate")

        header.setExportAvailable(true, visible: true)
        content.layoutSubtreeIfNeeded()
        expect(header.qaExportIsEnabled, "Export enables when the table is ready")
        expect(
            header.qaExportAccessibilityHelp == "Export the current table view",
            "Enabled Export exposes useful accessibility help"
        )
        header.qaActivateExport()
        expect(activations == 1, "Export invokes its callback exactly once")

        header.setReloadAvailable(
            false,
            visible: true,
            unavailableReason: "Export in progress"
        )
        content.layoutSubtreeIfNeeded()
        expect(header.qaReloadIsVisible, "Reload appears for a Parquet table")
        expect(!header.qaReloadIsEnabled, "Unavailable Parquet reload stays disabled")
        expect(
            header.qaReloadAccessibilityLabel == "Reload file",
            "Reload retains its accessibility label"
        )
        expect(
            header.qaReloadAccessibilityHelp == "Export in progress",
            "The Reload unavailable reason reaches accessibility help"
        )
        expect(
            abs(header.qaReloadFrame.width - 32) < 0.01
                && abs(header.qaReloadFrame.height - 32) < 0.01,
            "Reload keeps its 32 by 32 point hit target"
        )

        var reloadControlActivations = 0
        header.onReload = { reloadControlActivations += 1 }
        header.qaActivateReload()
        expect(reloadControlActivations == 0, "Disabled Reload cannot activate")

        header.setReloadAvailable(true, visible: true)
        content.layoutSubtreeIfNeeded()
        expect(header.qaReloadIsEnabled, "Reload enables when the Parquet file is ready")
        expect(
            header.qaReloadAccessibilityHelp == "Reload this Parquet file from disk",
            "Enabled Reload explains that it refreshes from disk"
        )
        header.qaActivateReload()
        expect(reloadControlActivations == 1, "Reload invokes its callback exactly once")

        let controls = allSubviews(of: header).compactMap { $0 as? HeaderIconButton }
        let export = controls.first { $0.accessibilityLabel() == "Export table" }
        let reload = controls.first { $0.accessibilityLabel() == "Reload file" }
        let structure = controls.first {
            $0.accessibilityLabel() == "Toggle structure sidebar"
        }
        let find = controls.first { $0.accessibilityLabel() == "Find" }
        if let export,
           let exportSuperview = export.superview {
            let exportFrame = header.convert(export.frame, from: exportSuperview)
            expect(header.bounds.contains(exportFrame), "Export remains inside the header")
            if let reload,
               let reloadSuperview = reload.superview {
                let reloadFrame = header.convert(reload.frame, from: reloadSuperview)
                expect(header.bounds.contains(reloadFrame), "Reload remains inside the header")
                expect(
                    exportFrame.maxX <= reloadFrame.minX,
                    "Reload is placed directly after Export"
                )
                if let structure,
                   let structureSuperview = structure.superview {
                    let structureFrame = header.convert(structure.frame, from: structureSuperview)
                    expect(
                        reloadFrame.maxX <= structureFrame.minX,
                        "Reload does not overlap Structure"
                    )
                } else {
                    fail("Structure control is missing")
                }
                if let find,
                   let findSuperview = find.superview {
                    let findFrame = header.convert(find.frame, from: findSuperview)
                    expect(reloadFrame.maxX <= findFrame.minX, "Reload does not overlap Find")
                } else {
                    fail("Find control is missing")
                }
            } else {
                fail("Reload control is missing")
            }
            if let structure,
               let structureSuperview = structure.superview {
                let structureFrame = header.convert(structure.frame, from: structureSuperview)
                expect(
                    exportFrame.maxX <= structureFrame.minX,
                    "Export does not overlap Structure"
                )
            } else {
                fail("Structure control is missing")
            }
            if let find,
               let findSuperview = find.superview {
                let findFrame = header.convert(find.frame, from: findSuperview)
                expect(exportFrame.maxX <= findFrame.minX, "Export does not overlap Find")
            } else {
                fail("Find control is missing")
            }
        } else {
            fail("Export control is missing")
        }

        header.setExportAvailable(false, visible: false)
        header.setReloadAvailable(false, visible: false)
        content.layoutSubtreeIfNeeded()
        expect(!header.qaExportIsVisible, "Export hides when leaving table View mode")
        expect(!header.qaExportIsEnabled, "Hidden Export is disabled")
        expect(!header.qaReloadIsVisible, "Reload hides when leaving Parquet View mode")
        expect(!header.qaReloadIsEnabled, "Hidden Reload is disabled")

        let statusBar = DocumentStatusBar()
        let multilineDiagnostic = "The Parquet query failed.\nOut of Memory Error:\nfailed to allocate a data chunk"
        statusBar.setState(multilineDiagnostic, busy: false, isError: true)
        expect(
            statusBar.qaStateText == "The Parquet query failed. Out of Memory Error: failed to allocate a data chunk",
            "Status diagnostics are flattened onto one line"
        )
        expect(
            statusBar.qaStateToolTip == multilineDiagnostic,
            "The full status diagnostic remains available in a tooltip"
        )
        expect(statusBar.qaStateIsError, "Status diagnostics retain their error state")
        expect(
            statusBar.qaStateIsStrictlySingleLine,
            "The status label enforces one-line middle truncation"
        )
        statusBar.setState("Ready")
        expect(!statusBar.qaStateIsError, "Ordinary status clears the prior error state")
        statusBar.setDocumentState(edited: true)
        statusBar.setState("Searching…", busy: true)
        expect(statusBar.qaDocumentStateText == "Unsaved changes", "Activity does not overwrite the save state")
        statusBar.setDocumentState(edited: false, readOnly: true)
        expect(statusBar.qaDocumentStateText == "Saved", "Clean documents show their saved state")
        statusBar.updateByteWindow(1_024..<2_048, totalByteCount: 8_589_934_592)
        expect(statusBar.qaInformationText.contains("1,024–2,048"), "Precise byte-window details remain in document information")
        expect(
            !allSubviews(of: statusBar).compactMap { ($0 as? NSTextField)?.stringValue }.contains(where: { $0.contains("BYTE WINDOW") }),
            "Storage implementation details do not compete with activity in the status bar"
        )
        statusBar.showMemoryBackedCSV(totalByteCount: 128)
        expect(statusBar.qaInformationText.contains("held in memory"), "Information explains table storage in plain language")

        var requestedPositions: [Int64] = []
        statusBar.onGoToLine = { value, completion in
            requestedPositions.append(value)
            completion(nil)
        }
        statusBar.configureLineNavigation(currentLine: 12, totalLines: 100, enabled: true)
        statusBar.updatePosition(line: 12, column: 3, selectionByteCount: 20)
        expect(statusBar.qaPositionEnabled, "Line position is actionable when navigation is available")
        expect(statusBar.qaPositionText.contains("Ln 12, Col 3"), "Source position names its line and column")
        expect(statusBar.qaPositionText.contains("selected"), "Source position retains selection feedback")
        for invalid in ["", "0", "-4", "1.5", "abc", "9223372036854775808"] {
            statusBar.qaSubmitJump(invalid)
            expect(statusBar.qaJumpError?.contains("positive whole line") == true, "Invalid line '\(invalid)' receives an inline explanation")
        }
        expect(requestedPositions.isEmpty, "Invalid input never invokes document navigation")
        statusBar.qaSubmitJump("101")
        expect(statusBar.qaJumpError == "This document has 100 lines.", "Out-of-range input states the available range")
        expect(requestedPositions.isEmpty, "Out-of-range input never invokes document navigation")
        statusBar.qaSubmitJump("42")
        expect(requestedPositions == [42], "A valid line reaches the document callback once")
        statusBar.configureLineNavigation(currentLine: nil, totalLines: nil, enabled: true)
        statusBar.qaSubmitJump("5000000000")
        expect(requestedPositions.last == 5_000_000_000, "Navigation preserves 64-bit positions before indexing completes")
        statusBar.onGoToLine = { _, completion in completion("That line no longer exists. Try a smaller number.") }
        statusBar.qaSubmitJump("42")
        expect(statusBar.qaJumpError == "That line no longer exists. Try a smaller number.", "Asynchronous lookup failures remain visible inline")
        statusBar.configureRowNavigation(currentRow: 2, totalRows: 4, enabled: true)
        statusBar.updateTablePosition(row: 2, selectedRowCount: 2, totalRows: 4)
        expect(statusBar.qaPositionText == "Row 2 of 4  ·  2 selected", "Table position reflects displayed rows and selection")
        statusBar.qaSubmitJump("5")
        expect(statusBar.qaJumpError == "This document has 4 rows.", "Table navigation validates against displayed rows")
        statusBar.updateTablePosition(row: 0, selectedRowCount: 0, totalRows: 0)
        expect(!statusBar.qaPositionEnabled, "Empty tables cannot offer a row jump")
        statusBar.configureLineNavigation(currentLine: nil, totalLines: nil, enabled: false)
        statusBar.setPositionSummary("JSON tree")
        expect(statusBar.qaPositionText == "JSON tree", "Structured presentations do not retain a stale source position")
        expect(!statusBar.qaPositionEnabled, "Structured presentation summaries are not misleading navigation actions")

        let diskState = ExternalFileState(
            identity: .init(device: 1, inode: 2),
            byteCount: 128,
            modificationTime: .init(seconds: 30, nanoseconds: 40)
        )
        let externalChange = ExternalFileChange.classify(
            previous: ExternalFileState(
                identity: diskState.identity,
                byteCount: diskState.byteCount,
                modificationTime: .init(seconds: 20, nanoseconds: 30)
            ),
            current: diskState,
            documentWasClean: false
        )!
        let banner = ExternalChangeBannerView()
        var reloadActivations = 0
        var keepActivations = 0
        banner.onReload = { reloadActivations += 1 }
        banner.onKeep = { keepActivations += 1 }
        banner.present(externalChange)
        expect(banner.qaReloadButtonTitle == "Reload", "External change offers Reload")
        expect(
            banner.qaKeepButtonTitle == "Don’t Reload",
            "External change offers an exact Don’t Reload action"
        )
        expect(banner.qaSaveAsButtonTitle == "Save As…", "Dirty-file Save As remains available")
        expect(banner.qaReloadIsEnabled, "Reload is enabled while the disk file exists")
        banner.qaActivateReload()
        expect(reloadActivations == 1, "Reload invokes its callback exactly once")
        banner.qaActivateKeep()
        expect(keepActivations == 1, "Don’t Reload invokes its callback exactly once")

        if failures.isEmpty {
            print("Document chrome QA passed: \(assertionCount) assertions")
            Darwin.exit(EXIT_SUCCESS)
        }
        failures.forEach { FileHandle.standardError.write(Data("FAIL: \($0)\n".utf8)) }
        Darwin.exit(EXIT_FAILURE)
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        assertionCount += 1
        if !condition() { fail(message) }
    }

    private static func fail(_ message: String) {
        failures.append(message)
    }

    private static func allSubviews(of root: NSView) -> [NSView] {
        root.subviews.flatMap { [$0] + allSubviews(of: $0) }
    }
}
#endif
