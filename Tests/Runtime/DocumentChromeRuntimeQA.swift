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

        let controls = allSubviews(of: header).compactMap { $0 as? HeaderIconButton }
        let export = controls.first { $0.accessibilityLabel() == "Export table" }
        let structure = controls.first {
            $0.accessibilityLabel() == "Toggle structure sidebar"
        }
        let find = controls.first { $0.accessibilityLabel() == "Find" }
        if let export,
           let exportSuperview = export.superview {
            let exportFrame = header.convert(export.frame, from: exportSuperview)
            expect(header.bounds.contains(exportFrame), "Export remains inside the header")
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
        content.layoutSubtreeIfNeeded()
        expect(!header.qaExportIsVisible, "Export hides when leaving table View mode")
        expect(!header.qaExportIsEnabled, "Hidden Export is disabled")

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
            print("Document chrome QA passed: 21 assertions")
            Darwin.exit(EXIT_SUCCESS)
        }
        failures.forEach { FileHandle.standardError.write(Data("FAIL: \($0)\n".utf8)) }
        Darwin.exit(EXIT_FAILURE)
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
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
