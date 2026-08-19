#if LIGHTXT_STANDALONE_CSV_QA
import AppKit
import Foundation

enum SyntaxFileType { case csv }
struct EditorLineLocation: Sendable {
    let lineNumber: Int64
    let lineStartByteOffset: Int64
}
struct SyntaxFoldRange: Sendable {}

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

@main
@MainActor
struct CSVTableRuntimeQA {
    static func main() throws {
        guard CommandLine.arguments.count >= 3 else { throw QAError.usage }
        _ = NSApplication.shared
        let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )

        let fixtureDelegate = try QACSVDelegate(url: fixtureURL)
        let fixtureView = CSVTableView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 720))
        let fixtureWindow = makeWindow(containing: fixtureView, appearance: .aqua)
        var fixtureComplete = false
        fixtureView.onStatusChange = { _, busy in fixtureComplete = !busy }
        fixtureView.editorDelegate = fixtureDelegate
        try wait(until: { fixtureComplete }, timeout: 5, failure: "Small CSV fixture did not finish indexing")
        guard let fixtureTable = descendant(of: fixtureView, as: NSTableView.self),
              fixtureTable.numberOfRows == 4,
              fixtureTable.numberOfColumns == 5 else {
            throw QAError.failed("CSV table did not detect a four-row/four-column fixture with fixed header")
        }
        fixtureWindow.appearance = NSAppearance(named: .aqua)
        fixtureView.layoutSubtreeIfNeeded()
        try render(fixtureView, to: outputDirectory.appendingPathComponent("csv-light.png"))
        fixtureWindow.appearance = NSAppearance(named: .darkAqua)
        fixtureView.layoutSubtreeIfNeeded()
        try render(fixtureView, to: outputDirectory.appendingPathComponent("csv-dark.png"))

        let stressURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LighTxt-CSV-page-QA-\(UUID().uuidString).csv"
        )
        defer { try? FileManager.default.removeItem(at: stressURL) }
        try writeStressCSV(to: stressURL)
        let stressDelegate = try QACSVDelegate(url: stressURL)
        let stressView = CSVTableView(frame: NSRect(x: 0, y: 0, width: 1_000, height: 720))
        let stressWindow = makeWindow(containing: stressView, appearance: .aqua)
        _ = stressWindow
        var stressComplete = false
        var observeEdit = false
        var editRestartedIndexing = false
        var registrationStates: [Bool] = []
        var registrationStateObservedAtCommit: Bool?
        stressView.onStatusChange = { _, busy in
            stressComplete = !busy
            if observeEdit, busy { editRestartedIndexing = true }
        }
        stressView.onEditingRegistrationChange = { editing in
            registrationStates.append(editing)
        }
        stressDelegate.onCommit = {
            registrationStateObservedAtCommit = registrationStates.last
        }
        stressView.editorDelegate = stressDelegate
        try wait(until: { stressComplete }, timeout: 15, failure: "Stress CSV did not finish indexing")
        guard let stressTable = descendant(of: stressView, as: NSTableView.self),
              stressTable.numberOfRows == 96 else {
            throw QAError.failed("Stress CSV row count was not available")
        }

        // Row 63 maps to record 64 after the fixed header. Its page is not in
        // the 32-record initial cache; requesting it exercises the random page
        // miss path with 32 records near the 256 KiB presentation bound.
        let clock = ContinuousClock()
        let start = clock.now
        let initialCell = stressTable.view(atColumn: 2, row: 63, makeIfNecessary: true) as? NSTextField
        let enqueueElapsed = start.duration(to: clock.now)
        let enqueueMilliseconds = milliseconds(enqueueElapsed)
        guard enqueueMilliseconds < 20 else {
            throw QAError.failed("Random page request blocked main for \(enqueueMilliseconds) ms")
        }
        guard initialCell?.stringValue.isEmpty == true else {
            throw QAError.failed("Random page unexpectedly decoded synchronously")
        }

        var heartbeatObserved = false
        let heartbeatStart = clock.now
        DispatchQueue.main.async { heartbeatObserved = true }
        try wait(until: { heartbeatObserved }, timeout: 0.1, failure: "Main queue stalled during CSV page decode")
        let heartbeatMilliseconds = milliseconds(heartbeatStart.duration(to: clock.now))

        try wait(
            until: {
                let cell = stressTable.view(atColumn: 2, row: 63, makeIfNecessary: true) as? NSTextField
                return cell?.stringValue == "person-64"
            },
            timeout: 5,
            failure: "Background CSV page did not populate the requested row"
        )

        guard let editableCell = stressTable.view(
            atColumn: 2,
            row: 63,
            makeIfNecessary: true
        ) as? NSTextField else {
            throw QAError.failed("Could not resolve the random row's editable cell")
        }
        observeEdit = true
        stressView.controlTextDidBeginEditing(Notification(
            name: NSControl.textDidBeginEditingNotification,
            object: editableCell
        ))
        guard registrationStates.last == true else {
            throw QAError.failed("CSV editor did not register before a pending cell edit")
        }
        editableCell.stringValue = "person 64, edited"
        let editStart = clock.now
        stressView.controlTextDidEndEditing(Notification(
            name: NSControl.textDidEndEditingNotification,
            object: editableCell
        ))
        let editMilliseconds = milliseconds(editStart.duration(to: clock.now))
        guard editMilliseconds < 20, !editRestartedIndexing else {
            throw QAError.failed(
                "Middle-row edit discarded the completed sparse index (\(editMilliseconds) ms)"
            )
        }
        guard registrationStates.suffix(2).elementsEqual([true, false]),
              registrationStateObservedAtCommit == false else {
            throw QAError.failed(
                "CSV NSEditor registration was not transferred to the document change count"
            )
        }
        try wait(
            until: {
                let cell = stressTable.view(atColumn: 2, row: 63, makeIfNecessary: true) as? NSTextField
                return cell?.stringValue == "person 64, edited"
            },
            timeout: 5,
            failure: "Rebased index did not repopulate the edited middle row"
        )

        // A discarded active field must unregister and must not publish a
        // piece-table edit. This mirrors Cancel from the unsaved-changes sheet.
        guard let discardedCell = stressTable.view(
            atColumn: 2,
            row: 62,
            makeIfNecessary: true
        ) as? NSTextField else {
            throw QAError.failed("Could not resolve the discard-test cell")
        }
        let commitsBeforeDiscard = stressDelegate.commitCount
        stressView.controlTextDidBeginEditing(Notification(
            name: NSControl.textDidBeginEditingNotification,
            object: discardedCell
        ))
        discardedCell.stringValue = "must not persist"
        stressView.discardEditing()
        guard discardedCell.stringValue == "person-63",
              stressDelegate.commitCount == commitsBeforeDiscard,
              registrationStates.last == false else {
            throw QAError.failed("Discarding a pending CSV cell changed the document")
        }
        print(
            "CSV table QA passed: 4 fixture rows, 5 visible columns; random 8 MiB-bounded page "
                + "enqueued in \(String(format: "%.3f", enqueueMilliseconds)) ms, main heartbeat "
                + "\(String(format: "%.3f", heartbeatMilliseconds)) ms; middle-row index rebase "
                + "\(String(format: "%.3f", editMilliseconds)) ms; light/dark captures rendered"
        )
    }

    private static func makeWindow(
        containing view: NSView,
        appearance: NSAppearance.Name
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: view.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        window.layoutIfNeeded()
        return window
    }

    private static func writeStressCSV(to url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.write(contentsOf: Data("id,name,payload\n".utf8))
        let payload = Data(repeating: 0x61, count: (256 << 10) - 64)
        for row in 1...96 {
            try handle.write(contentsOf: Data("\(row),person-\(row),".utf8))
            try handle.write(contentsOf: payload)
            try handle.write(contentsOf: Data("\n".utf8))
        }
    }

    private static func render(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw QAError.failed("Could not create CSV capture buffer")
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw QAError.failed("Could not encode CSV capture")
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

    private static func wait(
        until condition: () -> Bool,
        timeout: TimeInterval,
        failure: String
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        guard condition() else { throw QAError.failed(failure) }
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    private enum QAError: Error, LocalizedError {
        case usage
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .usage:
                return "Usage: csv-table-qa <small-fixture.csv> <capture-directory>"
            case let .failed(message):
                return message
            }
        }
    }
}

@MainActor
private final class QACSVDelegate: VirtualTextEditorDelegate {
    let engine: FileBackedPieceTable
    private(set) var lastError: Error?
    private(set) var commitCount = 0
    var onCommit: (() -> Void)?

    init(url: URL) throws { engine = try FileBackedPieceTable(opening: url) }

    var editorDocumentByteCount: Int64 { engine.byteCount }
    var editorSyntaxFileType: SyntaxFileType { .csv }
    func editorSnapshot() throws -> DocumentSnapshot { try engine.snapshot() }
    func editorReadBytes(in range: Range<Int64>) throws -> Data {
        try engine.snapshot().data(in: range)
    }
    func editorReplaceBytes(in range: Range<Int64>, with bytes: Data) throws {
        try engine.replace(byteRange: range, with: bytes)
    }
    func editorLineLocation(at byteOffset: Int64) -> EditorLineLocation {
        EditorLineLocation(lineNumber: 1, lineStartByteOffset: 0)
    }
    func editorDidCommitEdit(replaced range: Range<Int64>, insertedByteCount: Int64) {
        commitCount += 1
        onCommit?()
    }
    func editorSelectionDidChange(byteRange: Range<Int64>, line: Int64, column: Int) {}
    func editorDidLoadViewport(byteRange: Range<Int64>) {}
    func editorDidExpose(byteRange: Range<Int64>) {}
    func editorDidDiscoverStructure(
        folds: [SyntaxFoldRange],
        viewportData: Data,
        viewportBaseOffset: Int64
    ) {}
    func editorDidFail(_ error: Error) { lastError = error }
}
#endif
