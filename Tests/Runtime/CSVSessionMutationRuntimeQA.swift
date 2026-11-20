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

        let recoveryRoot = directory.appendingPathComponent("recovery", isDirectory: true)
        setenv("LIGHTXT_RUNTIME_QA_RECOVERY_ROOT", recoveryRoot.path, 1)
        guard try RecoveryStore.defaultRootURL().path == recoveryRoot.path else {
            throw QAError.failed("Session QA requires an isolated recovery store")
        }
        let store = RecoveryStore(rootURL: recoveryRoot)
        try proveFirstEditRecovery(file: nil, store: store)
        try proveFirstEditRecovery(file: directory.appendingPathComponent("saved.txt"), store: store)
        try proveAutomaticOpenResolution(in: directory)
        try proveConvertedAndSavedReopen(in: directory)
        try proveUntitledExtensionInference()
        try proveBulkCheckpointRecovery(in: directory, store: store)
        try proveBoundedRecoveryHistory(in: directory)
        try proveSuccessfulTransaction(in: directory)
        try proveStaleSnapshotIsRejected(in: directory)
        try proveLargeBatchCancellation(in: directory)
        try proveCloseDropsLateCompletion(in: directory)

        print(
            "CSV session mutation QA passed: dirty-at-start; edits/navigation/undo blocked; "
                + "cancel and stale snapshot publish nothing; success is one undo/redo step "
                + "with one final document event; close drops late completion; "
                + "first edits, caret, viewport and subsequent replacements survive recovery"
        )
    }

    private static func proveFirstEditRecovery(file: URL?, store: RecoveryStore) throws {
        let base = file == nil ? "" : "saved"
        if let file { try Data(base.utf8).write(to: file) }
        let contents = base + "ö!"
        let end = Int64(contents.utf8.count)
        let metadata = RecoveryMetadata(
            window: RecoveryWindowMetadata(
                selectionLowerByteOffset: end, selectionUpperByteOffset: end,
                viewportByteOffset: end - 1, presentationMode: "0"
            ),
            task: RecoveryTaskMetadata(displayName: file?.lastPathComponent, values: [
                "untitled": file == nil ? "true" : "false", "searchQuery": "ö"
            ])
        )
        do {
            let session = try file.map { try LighTxtDocumentSession(opening: $0) }
                ?? LighTxtDocumentSession(memoryOnlyEmptyDocument: ())
            let offset = session.byteCount
            try session.editorReplaceBytes(in: offset..<offset, with: Data("ö!".utf8))
            session.updateRecoveryMetadata(metadata)
            try wait(until: { try store.recoveryCandidates().first?.operationCount == 1 },
                     failure: "First edit did not reach the recovery journal")
            // Drop the writer without the explicit Save/Discard close that removes its journal.
            withExtendedLifetime(session) {}
        }
        guard let entry = try store.recoveryCandidates().first else {
            throw QAError.failed("Missing recovery entry")
        }
        do {
            let restored = try LighTxtDocumentSession(recovering: store.recover(identifier: entry.identifier))
            guard try text(of: restored.engine) == contents,
                  restored.takeRestoredRecoveryMetadata() == metadata,
                  restored.takeRestoredRecoveryMetadata() == nil else {
                throw QAError.failed("First edit did not restore its bytes and window metadata")
            }
            guard file != nil else {
                restored.prepareForClose()
                return
            }

            // The last known selection is past the new EOF. Its metadata-only timer
            // also runs after the edit debounce, before the user types again.
            restored.updateRecoveryMetadata(metadata)
            try restored.editorReplaceBytes(in: 0..<end, with: Data("ab".utf8))
            runLoop(for: 1.0)
            try restored.editorReplaceBytes(in: 2..<2, with: Data("c".utf8))
            try wait(until: { try store.recoveryCandidates().first?.operationCount == 3 },
                     failure: "An obsolete caret/viewport stopped recovery after a shortening edit")
            withExtendedLifetime(restored) {}
        }
        let final = try LighTxtDocumentSession(recovering: store.recover(identifier: entry.identifier))
        defer { final.prepareForClose() }
        let actual = final.takeRestoredRecoveryMetadata()
        guard try text(of: final.engine) == "abc", actual?.task == metadata.task,
              actual?.window?.selectionLowerByteOffset == 2,
              actual?.window?.selectionUpperByteOffset == 2,
              actual?.window?.viewportByteOffset == 2 else {
            throw QAError.failed("Shortening edit did not restore a valid caret, viewport and task")
        }
    }

    private static func proveBoundedRecoveryHistory(in directory: URL) throws {
        let url = directory.appendingPathComponent("history.csv")
        try Data().write(to: url)
        let session = try LighTxtDocumentSession(opening: url)
        defer { session.prepareForClose() }
        let block = 8 << 20
        for i in 0..<8 {
            let end = session.byteCount
            try session.editorReplaceBytes(in: end..<end, with: Data(repeating: UInt8(65 + i), count: block))
            let usage = session.qaRecoveryHistoryUsage
            guard usage.bytes == block, usage.transactions == 1, usage.references == 2 else {
                throw QAError.failed("A burst of eight 8 MiB edits retained excess recovery payload")
            }
        }
        for count in (0..<8).reversed() {
            guard session.undo(), session.byteCount == Int64(count * block),
                  session.qaRecoveryHistoryUsage.bytes <= block else {
                throw QAError.failed("Undo lost a revision outside the payload cache")
            }
            if count == 7 {
                try session.editorReplaceBytes(in: 0..<0, with: Data())
                guard session.canRedo, session.qaRecoveryHistoryUsage.bytes == block else {
                    throw QAError.failed("An empty edit disturbed the recovery redo stack")
                }
            }
            if count == 6 {
                // The second Undo crossed the evicted boundary. Reopen the
                // durable entry and check both its size and each segment.
                session.qaFlushRecovery()
                let store = RecoveryStore(rootURL: try RecoveryStore.defaultRootURL())
                guard let entry = try store.recoveryCandidates().first(where: {
                    $0.baseURL.resolvingSymlinksInPath() == url.resolvingSymlinksInPath()
                }) else { throw QAError.failed("Evicted Undo produced no recoverable revision") }
                let recovered = try store.recover(identifier: entry.identifier)
                defer { recovered.close() }
                let restored = try recovered.engine.snapshot()
                guard restored.byteCount == session.byteCount else {
                    throw QAError.failed("Evicted Undo journaled the wrong checkpoint length")
                }
                for i in 0..<count {
                    guard try restored.byte(at: Int64(i * block)) == UInt8(65 + i) else {
                        throw QAError.failed("Evicted Undo restored the wrong checkpoint bytes")
                    }
                }
            }
        }
        for count in 1...8 {
            guard session.redo(), session.byteCount == Int64(count * block),
                  try session.engine.snapshot().byte(at: session.byteCount - 1) == UInt8(64 + count),
                  session.qaRecoveryHistoryUsage.bytes <= block else {
                throw QAError.failed("Redo lost a revision outside the payload cache")
            }
        }

        // Tiny transactions and batch records also need a cardinality bound.
        for _ in 0..<520 { try session.editorReplaceBytes(in: 0..<0, with: Data([0x78])) }
        guard session.qaRecoveryHistoryUsage.transactions == 512 else {
            throw QAError.failed("Tiny recovery transactions exceeded their count budget")
        }
        let edits = (0..<1_024).map { i in ByteEdit(byteRange: Int64(i)..<Int64(i + 1), replacement: Data([65])) }
        for _ in 0..<3 {
            var outcome: Result<Void, Error>?
            session.editorApplyCSVRowEdits(edits, replacing: try session.engine.snapshot()) { outcome = $0 }
            try wait(until: { outcome != nil }, failure: "Recovery batch edit did not complete")
            try requireSuccess(outcome)
        }
        guard session.qaRecoveryHistoryUsage.references == 4_096 else {
            throw QAError.failed("Recovery edit references exceeded their combined forward/inverse budget")
        }
    }

    private static func proveBulkCheckpointRecovery(in directory: URL, store: RecoveryStore) throws {
        let url = directory.appendingPathComponent("checkpoint.csv")
        try Data("key,value\na,one\n".utf8).write(to: url)
        let session = try LighTxtDocumentSession(opening: url)
        defer { session.prepareForClose() }
        func verify(_ expected: String) throws {
            session.qaFlushRecovery()
            guard let entry = try store.recoveryCandidates().first(where: {
                $0.baseURL.resolvingSymlinksInPath() == url.resolvingSymlinksInPath()
            }) else { throw QAError.failed("Missing checkpoint for CSV") }
            let result = try store.recover(identifier: entry.identifier)
            defer { result.close() }
            guard try text(of: result.engine) == expected else {
                throw QAError.failed("Replayed a different checkpoint from the live document")
            }
        }
        var end = session.byteCount
        try session.editorReplaceBytes(in: end..<end, with: Data("b,two\n".utf8))
        session.configureSearch(query: "one", regularExpression: false, caseSensitive: true, wholeWords: false)
        var replace: Result<Int, Error>?
        session.replaceAll(with: "three") { replace = $0 }
        try wait(until: { replace != nil }, failure: "Replace All never finished")
        guard try replace?.get() == 1 else { throw QAError.failed("Expected one replacement") }
        try verify("key,value\na,three\nb,two\n")
        let snapshot = try session.engine.snapshot()
        var rewritten: Result<CSVColumnRewriteResult, Error>?
        session.editorApplyCSVColumnMutation(.delete(column: 1), snapshot: snapshot,
            index: try CSVRowIndex(snapshot: snapshot), progress: { _ in }, completion: { rewritten = $0 })
        try wait(until: { rewritten != nil }, failure: "Column deletion never finished")
        _ = try rewritten?.get()
        try verify("key\na\nb\n")

        // The writer has captured the old root by the first progress callback.
        // Apply a live edit before publication, then exercise the app's completion.
        var edit: Result<Void, Error>?
        try session.engine.save(progress: { _ in
            guard edit == nil else { return }
            end = session.byteCount
            edit = Result { try session.editorReplaceBytes(in: end..<end, with: Data("c\n".utf8)) }
        })
        _ = try edit?.get()
        session.didSaveInPlace()
        end = session.byteCount
        try session.editorReplaceBytes(in: end..<end, with: Data("d\n".utf8))
        try verify("key\na\nb\nc\nd\n")
        guard try String(contentsOf: url, encoding: .utf8) == "key\na\nb\n" else {
            throw QAError.failed("A newer edit leaked into the in-flight save")
        }
    }

    private static func proveAutomaticOpenResolution(in directory: URL) throws {
        let csvURL = directory.appendingPathComponent("yaml-like.CSV")
        let csv = [
            "name,description,network",
            "one,service: special,Clinic & Rehabilitation",
            "two,service: advanced,Research & Development",
            "three,service: routine,Hospital & Medical Center",
        ].joined(separator: "\n") + "\n"
        try Data(csv.utf8).write(to: csvURL)
        let csvSession = try LighTxtDocumentSession(opening: csvURL)
        guard csvSession.syntaxFileType == .csv,
              csvSession.delimitedTextDelimiter == .comma else {
            throw QAError.failed("Known CSV suffix did not survive YAML-like sampled content")
        }
        csvSession.prepareForClose()

        let tsvURL = directory.appendingPathComponent("comma-rich.tsv")
        let tsv = [
            "id\tLast, First, Credential",
            "1\tSmith, Ada, MD",
            "2\tJones, Grace, PhD",
            "3\tDoe, Lin, RN",
        ].joined(separator: "\n") + "\n"
        try Data(tsv.utf8).write(to: tsvURL)
        let tsvSession = try LighTxtDocumentSession(opening: tsvURL)
        guard tsvSession.syntaxFileType == .csv,
              tsvSession.delimitedTextDelimiter == .tab else {
            throw QAError.failed("Known TSV suffix did not preserve its tab dialect")
        }
        tsvSession.prepareForClose()
    }

    private static func proveConvertedAndSavedReopen(in directory: URL) throws {
        let original = directory.appendingPathComponent("source.tsv")
        let saved = directory.appendingPathComponent("saved.tsv")
        let value = String(repeating: "left\tright\n", count: 10_000)
        var utf16 = Data([0xff, 0xfe])
        utf16.append(value.data(using: .utf16LittleEndian)!)
        try utf16.write(to: original)

        let opened = try LighTxtDocumentSession(opening: original)
        defer { opened.prepareForClose() }
        guard opened.needsSaveAsDestination, opened.isSourceTextValidated,
              opened.sourceTextEncoding == .utf16LittleEndian else {
            throw QAError.failed("A completed automatic conversion is not immediately editable")
        }
        try opened.engine.saveAs(saved)
        opened.adoptSavedURL(saved)
        let reloaded = try LighTxtDocumentSession(opening: saved, openOptions: opened.reopenOptions)
        defer { reloaded.prepareForClose() }
        guard reloaded.sourceURL == saved, reloaded.delimitedTextDelimiter == .tab,
              !reloaded.isEdited, !reloaded.needsSaveAsDestination else {
            throw QAError.failed("Reload detached the saved UTF-8 file or changed its delimiter")
        }
        try wait(until: { reloaded.isSourceTextValidated }, failure: "Saved UTF-8 did not finish validation")
        try reloaded.editorReplaceBytes(in: 0..<4, with: Data("LEFT".utf8))
        try reloaded.engine.save(validatingCurrentDocumentURL: saved)
        guard try Data(contentsOf: saved).starts(with: "LEFT".utf8),
              try Data(contentsOf: original) == utf16 else {
            throw QAError.failed("The subsequent in-place save did not preserve its destination")
        }

        let token = CancellationToken()
        do {
            _ = try LighTxtDocumentSession.PreparedOpen(url: original, options: .init(), cancellation: token) { _ in
                token.cancel()
            }
            throw QAError.failed("Opening ignored cancellation during transcoding")
        } catch is CancellationError {}
        let explicit = try LighTxtDocumentSession(opening: saved, openOptions: .init(encoding: .explicit(.utf8)))
        defer { explicit.prepareForClose() }
        guard explicit.needsSaveAsDestination, explicit.sourceURL == nil, explicit.isSourceTextValidated else {
            throw QAError.failed("Explicit Open As UTF-8 must still produce a validated working copy")
        }
    }

    private static func proveUntitledExtensionInference() throws {
        let json = LighTxtDocumentSession(memoryOnlyEmptyDocument: ())
        try json.editorReplaceBytes(
            in: 0..<0,
            with: Data(#"{"name":"LighTxt","items":[1,2,3]}"#.utf8)
        )
        guard json.prepareUntitledSaveSuggestion() == "json" else {
            throw QAError.failed("Untitled JSON did not infer the .json extension")
        }
        json.prepareForClose()

        let pipe = LighTxtDocumentSession(memoryOnlyEmptyDocument: ())
        try pipe.editorReplaceBytes(
            in: 0..<0,
            with: Data("name|age\nAda|36\nLin|29\nGrace|85\n".utf8)
        )
        guard pipe.prepareUntitledSaveSuggestion() == "psv",
              pipe.delimitedTextDelimiter == .pipe else {
            throw QAError.failed("Untitled pipe-delimited data did not infer the .psv extension")
        }
        pipe.prepareForClose()

        let empty = LighTxtDocumentSession(memoryOnlyEmptyDocument: ())
        guard empty.prepareUntitledSaveSuggestion() == "txt" else {
            throw QAError.failed("Empty untitled documents no longer default to .txt")
        }
        empty.prepareForClose()
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
        try wait(
            until: { session.isSourceTextValidated },
            failure: "Large cancellation fixture did not finish UTF-8 validation"
        )
        let snapshot = try session.editorSnapshot()
        let edits = largeReplacementBatch()
        var events: [(Int64, Bool)] = []
        session.callbacks.documentChanged = { events.append(($0, $1)) }
        var completion: Result<Void, Error>?

        session.editorApplyCSVRowEdits(edits, replacing: snapshot) { completion = $0 }
        session.editorCancelCSVMutation()
        try wait(until: { completion != nil }, failure: "Cancelled row mutation did not finish")
        let finalSnapshot = try session.engine.snapshot()
        let finalData = try finalSnapshot.data(in: 0..<finalSnapshot.byteCount)
        let wasCancelled: Bool
        if case .failure(let error)? = completion {
            wasCancelled = error is CancellationError
        } else {
            wasCancelled = false
        }
        guard wasCancelled,
              !session.isBulkEditing,
              !session.isEdited,
              !session.engine.canUndo,
              !session.engine.canRedo,
              finalSnapshot.revision == snapshot.revision,
              finalData == original,
              events.count == 2,
              events.first?.1 == true,
              events.last?.1 == false else {
            throw QAError.failed(
                "Cancelling a large row batch published partial state: "
                    + "cancelled=\(wasCancelled), bulk=\(session.isBulkEditing), "
                    + "edited=\(session.isEdited), undo=\(session.engine.canUndo), "
                    + "redo=\(session.engine.canRedo), revision=\(finalSnapshot.revision)/\(snapshot.revision), "
                    + "bytesMatch=\(finalData == original), events=\(events)"
            )
        }
        session.prepareForClose()
    }

    private static func proveCloseDropsLateCompletion(in directory: URL) throws {
        let original = Data(repeating: 0x61, count: 100_000)
        let url = directory.appendingPathComponent("close.csv")
        try original.write(to: url)
        let session = try LighTxtDocumentSession(opening: url)
        try wait(
            until: { session.isSourceTextValidated },
            failure: "Large close fixture did not finish UTF-8 validation"
        )
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
        until condition: () throws -> Bool,
        timeout: TimeInterval = 5,
        failure: String
    ) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while try !condition(), Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
        }
        guard try condition() else { throw QAError.failed(failure) }
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
