#if LIGHTXT_STANDALONE_CSV_SESSION_QA
import AppKit
import Foundation

struct EditorLineLocation: Sendable {
    let lineNumber: Int64
    let lineStartByteOffset: Int64
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

@main
@MainActor
struct CSVSessionMutationRuntimeQA {
    static func main() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LighTxt-CSV-session-QA-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        try proveSuccessfulTransaction(in: directory)
        try proveStaleSnapshotIsRejected(in: directory)
        try proveLargeBatchCancellation(in: directory)
        try proveCloseDropsLateCompletion(in: directory)

        print(
            "CSV session mutation QA passed: dirty-at-start; edits/navigation/undo blocked; "
                + "cancel and stale snapshot publish nothing; success is one undo/redo step "
                + "with one final document event; close drops late completion"
        )
    }

    private static func proveSuccessfulTransaction(in directory: URL) throws {
        let original = Data("id,name\n1,A\n2,B\n".utf8)
        let url = directory.appendingPathComponent("success.csv")
        try original.write(to: url)
        let session = try LighTxtDocumentSession(opening: url)
        var documentEvents: [(Int64, Bool)] = []
        session.callbacks.documentChanged = { documentEvents.append(($0, $1)) }

        let snapshot = try session.editorSnapshot()
        let index = try completedIndex(for: snapshot)
        let edit = try CSVRowMutationPlanner.delete(
            record: 1,
            snapshot: snapshot,
            index: index
        )
        var completion: Result<Void, Error>?
        session.editorApplyCSVRowEdits([edit], replacing: snapshot) {
            completion = $0
        }

        guard session.isBulkEditing,
              session.isEdited,
              documentEvents.count == 1,
              documentEvents[0].1,
              !session.canUndo,
              !session.undo(),
              !session.beginDocumentNavigationReview() else {
            throw QAError.failed("CSV mutation did not enter prompt-safe blocked state")
        }
        do {
            try session.editorReplaceBytes(in: 0..<0, with: Data("x".utf8))
            throw QAError.failed("An ordinary edit was accepted during a CSV mutation")
        } catch LighTxtSessionError.bulkOperationInProgress {
            // Expected: this same state is the guard used by document Save.
        }

        try wait(until: { completion != nil }, failure: "Successful row mutation did not complete")
        try requireSuccess(completion)
        guard !session.isBulkEditing,
              session.isEdited,
              documentEvents.count == 2,
              documentEvents.last?.1 == true,
              try text(of: session.engine) == "id,name\n2,B\n" else {
            throw QAError.failed("Successful row mutation published an inconsistent final state")
        }

        guard session.undo(),
              try text(of: session.engine) == String(decoding: original, as: UTF8.self),
              !session.isEdited,
              session.redo(),
              try text(of: session.engine) == "id,name\n2,B\n" else {
            throw QAError.failed("CSV row mutation was not exactly one undo/redo step")
        }
        session.prepareForClose()
    }

    private static func proveStaleSnapshotIsRejected(in directory: URL) throws {
        let url = directory.appendingPathComponent("stale.csv")
        try Data("id,name\n1,A\n2,B\n".utf8).write(to: url)
        let session = try LighTxtDocumentSession(opening: url)
        let stale = try session.editorSnapshot()
        let index = try completedIndex(for: stale)
        let edit = try CSVRowMutationPlanner.delete(record: 1, snapshot: stale, index: index)
        try session.engine.insert(utf8: "X", at: session.engine.byteCount)
        let newer = try session.engine.snapshot()
        var events: [(Int64, Bool)] = []
        session.callbacks.documentChanged = { events.append(($0, $1)) }
        var completion: Result<Void, Error>?

        session.editorApplyCSVRowEdits([edit], replacing: stale) { completion = $0 }
        try wait(until: { completion != nil }, failure: "Stale row mutation did not complete")
        guard case .failure(let error)? = completion,
              case LighTxtCoreError.documentChangedDuringBulkOperation = error,
              try session.engine.snapshot().revision == newer.revision,
              try text(of: session.engine) == "id,name\n1,A\n2,B\nX",
              events.count == 2 else {
            throw QAError.failed("Stale row mutation changed or misreported the newer root")
        }
        session.prepareForClose()
    }

    private static func proveLargeBatchCancellation(in directory: URL) throws {
        let original = Data(repeating: 0x61, count: 100_000)
        let url = directory.appendingPathComponent("cancel.csv")
        try original.write(to: url)
        let session = try LighTxtDocumentSession(opening: url)
        let snapshot = try session.editorSnapshot()
        let edits = largeReplacementBatch()
        var events: [(Int64, Bool)] = []
        session.callbacks.documentChanged = { events.append(($0, $1)) }
        var completion: Result<Void, Error>?

        session.editorApplyCSVRowEdits(edits, replacing: snapshot) { completion = $0 }
        session.editorCancelCSVMutation()
        try wait(until: { completion != nil }, failure: "Cancelled row mutation did not finish")
        guard case .failure(let error)? = completion,
              error is CancellationError,
              !session.isBulkEditing,
              !session.isEdited,
              !session.engine.canUndo,
              !session.engine.canRedo,
              try session.engine.snapshot().revision == snapshot.revision,
              try session.engine.snapshot().data(in: 0..<snapshot.byteCount) == original,
              events.count == 2,
              events.first?.1 == true,
              events.last?.1 == false else {
            throw QAError.failed("Cancelling a large row batch published partial state")
        }
        session.prepareForClose()
    }

    private static func proveCloseDropsLateCompletion(in directory: URL) throws {
        let original = Data(repeating: 0x61, count: 100_000)
        let url = directory.appendingPathComponent("close.csv")
        try original.write(to: url)
        let session = try LighTxtDocumentSession(opening: url)
        let snapshot = try session.editorSnapshot()
        var completionCalled = false

        session.editorApplyCSVRowEdits(
            largeReplacementBatch(),
            replacing: snapshot
        ) { _ in
            completionCalled = true
        }
        guard session.isBulkEditing else {
            throw QAError.failed("Close test did not start a bulk operation")
        }
        session.prepareForClose()
        guard !session.isBulkEditing, !session.engine.isOpen else {
            throw QAError.failed("prepareForClose did not synchronously release the session")
        }
        runLoop(for: 0.25)
        guard !completionCalled,
              try Data(contentsOf: url) == original else {
            throw QAError.failed("A late CSV completion escaped after document close")
        }
    }

    private static func completedIndex(for snapshot: DocumentSnapshot) throws -> CSVRowIndex {
        let index = try CSVRowIndex(snapshot: snapshot)
        let result = try index.scanToEnd()
        guard result.stopReason == .completed else {
            throw QAError.failed("CSV fixture index did not complete")
        }
        return index
    }

    private static func largeReplacementBatch() -> [ByteEdit] {
        (0..<50_000).map { item in
            let offset = Int64(item * 2)
            return ByteEdit(
                byteRange: offset..<(offset + 1),
                replacement: Data([0x62])
            )
        }
    }

    private static func text(of engine: FileBackedPieceTable) throws -> String {
        let snapshot = try engine.snapshot()
        return try snapshot.utf8String(in: 0..<snapshot.byteCount)
    }

    private static func requireSuccess(_ result: Result<Void, Error>?) throws {
        guard case .success? = result else {
            if case .failure(let error)? = result { throw error }
            throw QAError.failed("Missing CSV mutation result")
        }
    }

    private static func wait(
        until condition: () -> Bool,
        timeout: TimeInterval = 5,
        failure: String
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        guard condition() else { throw QAError.failed(failure) }
    }

    private static func runLoop(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.005)))
        }
    }

    private enum QAError: Error, LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .failed(let message): message
            }
        }
    }
}
#endif
