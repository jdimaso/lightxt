import Darwin
import XCTest
@testable import LighTxt

final class RecoveryJournalTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var recoveryRoot: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecoveryJournalTests-\(UUID().uuidString)", isDirectory: true)
        recoveryRoot = temporaryDirectory.appendingPathComponent("Recovery", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testSequentialEditsAndMetadataRecoverWithoutChangingBase() throws {
        let original = Data("abcdef".utf8)
        let base = try makeFile(named: "source.txt", contents: original)
        let store = RecoveryStore(rootURL: recoveryRoot)
        let metadata = RecoveryMetadata(
            window: RecoveryWindowMetadata(
                frame: .init(x: 20, y: 40, width: 900, height: 700),
                selectionLowerByteOffset: 1,
                selectionUpperByteOffset: 3,
                viewportByteOffset: 1,
                presentationMode: "plain-text",
                structureSidebarVisible: true,
                structureSidebarWidth: 260
            ),
            task: RecoveryTaskMetadata(
                taskIdentifier: "window-7",
                displayName: "source.txt",
                fileType: "public.plain-text",
                values: ["encoding": "utf-8"]
            )
        )
        let journal = try store.createJournal(for: base, metadata: metadata)
        let originalFingerprint = journal.entry.baseFingerprint

        let entry = try journal.record([
            RecoveryPendingEdit(byteRange: 1..<3, replacement: Data("XY".utf8)),
            RecoveryPendingEdit(byteRange: 6..<6, replacement: Data("!".utf8)),
            RecoveryPendingEdit(byteRange: 0..<1, replacement: Data()),
        ])
        journal.close()

        XCTAssertEqual(try Data(contentsOf: base), original)
        XCTAssertEqual(entry.operationCount, 3)
        XCTAssertEqual(entry.insertedByteCount, 3)
        XCTAssertEqual(entry.resultingByteCount, 6)
        XCTAssertEqual(entry.metadata, metadata)
        XCTAssertEqual(entry.baseFingerprint, originalFingerprint)

        let inspections = try store.inspectEntries()
        XCTAssertEqual(inspections.count, 1)
        XCTAssertEqual(inspections[0].availability, .recoverable)
        XCTAssertEqual(inspections[0].entry, entry)

        let recovered = try store.recover(identifier: journal.identifier)
        defer { recovered.close() }
        let snapshot = try recovered.engine.snapshot()
        XCTAssertEqual(
            try snapshot.utf8String(in: 0..<snapshot.byteCount),
            "XYdef!"
        )
        XCTAssertEqual(recovered.entry.metadata, metadata)
        XCTAssertTrue(recovered.engine.hasUnsavedChanges)
        XCTAssertEqual(try Data(contentsOf: base), original)
    }

    func testHugeSparseBaseIsNotCopiedIntoRecoveryStorage() throws {
        let base = temporaryDirectory.appendingPathComponent("huge.txt", isDirectory: false)
        let descriptor = Darwin.open(
            base.path,
            O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC,
            mode_t(0o600)
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        let hugeByteCount: Int64 = 2 << 30
        XCTAssertEqual(ftruncate(descriptor, off_t(hugeByteCount)), 0)
        XCTAssertEqual(Darwin.close(descriptor), 0)

        let store = RecoveryStore(rootURL: recoveryRoot)
        let journal = try store.createJournal(for: base)
        try journal.record(RecoveryPendingEdit(
            byteRange: (1 << 30)..<(1 << 30),
            replacement: Data("tiny".utf8)
        ))

        let directory = entryDirectory(journal.identifier)
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(Set(children.map(\.lastPathComponent)), ["edits.blob", "manifest.json"])
        XCTAssertEqual(try fileSize(base), hugeByteCount)
        XCTAssertEqual(try fileSize(directory.appendingPathComponent("edits.blob")), 4)
        XCTAssertLessThan(try fileSize(directory.appendingPathComponent("manifest.json")), 32 << 10)
        XCTAssertEqual(journal.entry.insertedByteCount, 4)
        journal.close()
    }

    func testUntitledJournalRecoversAndDiscardRemovesItsPrivateBase() throws {
        let store = RecoveryStore(rootURL: recoveryRoot)
        let metadata = RecoveryMetadata(task: RecoveryTaskMetadata(
            displayName: "Untitled.txt",
            fileType: "txt",
            values: ["untitled": "true"]
        ))
        let journal = try store.createUntitledJournal(metadata: metadata)
        try journal.record(RecoveryPendingEdit(
            byteRange: 0..<0,
            replacement: Data("unsaved draft".utf8)
        ))
        let identifier = journal.identifier
        let privateBase = journal.entry.baseURL
        journal.close()

        XCTAssertTrue(FileManager.default.fileExists(atPath: privateBase.path))
        XCTAssertEqual(try store.recoveryCandidates().map(\.identifier), [identifier])
        let recovered = try store.recover(identifier: identifier)
        let snapshot = try recovered.engine.snapshot()
        XCTAssertEqual(
            try snapshot.utf8String(in: 0..<snapshot.byteCount),
            "unsaved draft"
        )
        XCTAssertEqual(recovered.entry.metadata, metadata)
        recovered.close()

        try store.discard(identifier: identifier)
        XCTAssertFalse(FileManager.default.fileExists(atPath: entryDirectory(identifier).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: privateBase.path))
        XCTAssertTrue(try store.recoveryCandidates().isEmpty)
    }

    func testChangedBaseIsInspectedButNeverRecovered() throws {
        let base = try makeFile(named: "changed.txt", contents: Data("original".utf8))
        let store = RecoveryStore(rootURL: recoveryRoot)
        let journal = try store.createJournal(for: base)
        try journal.record(RecoveryPendingEdit(
            byteRange: 8..<8,
            replacement: Data("!".utf8)
        ))
        journal.close()

        try Data("different".utf8).write(to: base, options: .atomic)

        let inspections = try store.inspectEntries()
        XCTAssertEqual(inspections.count, 1)
        XCTAssertEqual(inspections[0].availability, .baseChanged)
        XCTAssertEqual(try store.recoveryCandidates(), [])
        XCTAssertThrowsError(try store.recover(identifier: journal.identifier)) { error in
            XCTAssertEqual(error as? RecoveryJournalError, .baseFileChanged)
        }
    }

    func testJournalCreationRejectsBaseChangedSinceEngineOpened() throws {
        let store = RecoveryStore(rootURL: recoveryRoot)

        let mutated = try makeFile(
            named: "mutated-after-open.txt",
            contents: Data("original".utf8)
        )
        let mutationEngine = try FileBackedPieceTable(opening: mutated)
        let mutationFingerprint = try XCTUnwrap(mutationEngine.recoveryBaseFingerprint)
        let mutationDescriptor = Darwin.open(mutated.path, O_WRONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(mutationDescriptor, 0)
        guard mutationDescriptor >= 0 else { return }
        // Extend the same inode so the captured size differs deterministically,
        // independent of filesystem timestamp granularity.
        let changedBytes = Array("changed-content".utf8)
        let mutationResult = changedBytes.withUnsafeBytes {
            Darwin.pwrite(mutationDescriptor, $0.baseAddress, $0.count, 0)
        }
        XCTAssertEqual(mutationResult, changedBytes.count)
        XCTAssertEqual(Darwin.close(mutationDescriptor), 0)

        XCTAssertThrowsError(try store.createJournal(
            for: mutated,
            expectedBaseFingerprint: mutationFingerprint
        )) { error in
            XCTAssertEqual(error as? RecoveryJournalError, .baseFileChanged)
        }

        let replaced = try makeFile(
            named: "replaced-after-open.txt",
            contents: Data("original".utf8)
        )
        let replacementEngine = try FileBackedPieceTable(opening: replaced)
        let replacementFingerprint = try XCTUnwrap(replacementEngine.recoveryBaseFingerprint)
        try Data("replacement".utf8).write(to: replaced, options: .atomic)

        XCTAssertThrowsError(try store.createJournal(
            for: replaced,
            expectedBaseFingerprint: replacementFingerprint
        )) { error in
            XCTAssertEqual(error as? RecoveryJournalError, .baseFileChanged)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryRoot.path))
    }

    func testUncommittedBlobTailAndTemporaryManifestAreIgnored() throws {
        let base = try makeFile(named: "tail.txt", contents: Data("abc".utf8))
        let store = RecoveryStore(rootURL: recoveryRoot)
        let journal = try store.createJournal(for: base)
        try journal.record(RecoveryPendingEdit(
            byteRange: 3..<3,
            replacement: Data("!".utf8)
        ))
        journal.close()

        let directory = entryDirectory(journal.identifier)
        let blob = directory.appendingPathComponent("edits.blob")
        let handle = try FileHandle(forWritingTo: blob)
        handle.seekToEndOfFile()
        handle.write(Data("uncommitted-after-crash".utf8))
        handle.closeFile()
        try Data("{not-a-manifest".utf8).write(
            to: directory.appendingPathComponent("manifest.json.tmp.crash")
        )

        XCTAssertEqual(try store.recoveryCandidates().map(\.identifier), [journal.identifier])
        let recovered = try store.recover(identifier: journal.identifier)
        let snapshot = try recovered.engine.snapshot()
        XCTAssertEqual(try snapshot.utf8String(in: 0..<snapshot.byteCount), "abc!")
        XCTAssertGreaterThan(try fileSize(blob), recovered.entry.insertedByteCount)

        try recovered.journal.record(RecoveryPendingEdit(
            byteRange: 4..<4,
            replacement: Data("?".utf8)
        ))
        recovered.close()
        XCTAssertEqual(try fileSize(blob), 2, "The first resumed write truncates the crash tail")

        let recoveredAgain = try store.recover(identifier: journal.identifier)
        defer { recoveredAgain.close() }
        let resumedSnapshot = try recoveredAgain.engine.snapshot()
        XCTAssertEqual(
            try resumedSnapshot.utf8String(in: 0..<resumedSnapshot.byteCount),
            "abc!?"
        )
    }

    func testCommittedBlobCorruptionIsRejectedByChecksum() throws {
        let base = try makeFile(named: "corrupt.txt", contents: Data("abc".utf8))
        let store = RecoveryStore(rootURL: recoveryRoot)
        let journal = try store.createJournal(for: base)
        try journal.record(RecoveryPendingEdit(
            byteRange: 1..<2,
            replacement: Data("XYZ".utf8)
        ))
        journal.close()

        let blob = entryDirectory(journal.identifier).appendingPathComponent("edits.blob")
        let handle = try FileHandle(forWritingTo: blob)
        handle.seek(toFileOffset: 0)
        handle.write(Data("Q".utf8))
        handle.closeFile()

        XCTAssertThrowsError(try store.recover(identifier: journal.identifier)) { error in
            XCTAssertEqual(error as? RecoveryJournalError, .damagedBlob)
        }
    }

    func testInvalidBatchAndConfiguredBoundsPublishNothingPartial() throws {
        let base = try makeFile(named: "limits.txt", contents: Data("abc".utf8))
        let configuration = RecoveryJournalConfiguration(
            maximumOperationCount: 2,
            maximumInsertedBytesPerOperation: 3,
            maximumTotalInsertedBytes: 4,
            maximumMetadataUTF8Bytes: 8,
            maximumMetadataValueCount: 1
        )
        let store = RecoveryStore(rootURL: recoveryRoot, configuration: configuration)
        let journal = try store.createJournal(for: base)
        let blob = entryDirectory(journal.identifier).appendingPathComponent("edits.blob")

        XCTAssertThrowsError(try journal.record([
            RecoveryPendingEdit(byteRange: 3..<3, replacement: Data("x".utf8)),
            RecoveryPendingEdit(byteRange: 5..<5, replacement: Data("y".utf8)),
        ])) { error in
            XCTAssertEqual(
                error as? RecoveryJournalError,
                .invalidEditRange(requested: 5..<5, byteCount: 4)
            )
        }
        XCTAssertEqual(journal.entry.operationCount, 0)
        XCTAssertEqual(try fileSize(blob), 0)

        XCTAssertThrowsError(try journal.record(RecoveryPendingEdit(
            byteRange: 0..<0,
            replacement: Data("four".utf8)
        ))) { error in
            XCTAssertEqual(
                error as? RecoveryJournalError,
                .insertedOperationTooLarge(requested: 4, limit: 3)
            )
        }
        XCTAssertEqual(journal.entry.operationCount, 0)

        try journal.record(RecoveryPendingEdit(
            byteRange: 0..<0,
            replacement: Data("abc".utf8)
        ))
        XCTAssertThrowsError(try journal.record(RecoveryPendingEdit(
            byteRange: 3..<3,
            replacement: Data("de".utf8)
        ))) { error in
            XCTAssertEqual(
                error as? RecoveryJournalError,
                .insertedPayloadLimitExceeded(requested: 5, limit: 4)
            )
        }
        XCTAssertEqual(journal.entry.operationCount, 1)
        XCTAssertEqual(try fileSize(blob), 3)

        try journal.record(RecoveryPendingEdit(byteRange: 0..<1, replacement: Data()))
        XCTAssertThrowsError(try journal.record(RecoveryPendingEdit(
            byteRange: 0..<0,
            replacement: Data("x".utf8)
        ))) { error in
            XCTAssertEqual(error as? RecoveryJournalError, .operationLimitExceeded(limit: 2))
        }

        XCTAssertThrowsError(try journal.updateMetadata(RecoveryMetadata(
            task: RecoveryTaskMetadata(displayName: "123456789")
        ))) { error in
            XCTAssertEqual(error as? RecoveryJournalError, .metadataLimitExceeded)
        }
        XCTAssertNil(journal.entry.metadata.task)
    }

    func testPruneRemovesExpiredDamagedAndExcessEntriesOldestFirst() throws {
        let base = try makeFile(named: "prune.txt", contents: Data("abc".utf8))
        let store = RecoveryStore(rootURL: recoveryRoot)
        let now = Date()
        let expired = try store.createJournal(
            for: base,
            now: now.addingTimeInterval(-1_000)
        )
        let older = try store.createJournal(
            for: base,
            now: now.addingTimeInterval(-20)
        )
        let newest = try store.createJournal(
            for: base,
            now: now.addingTimeInterval(-10)
        )

        let damagedIdentifier = UUID()
        let damagedDirectory = entryDirectory(damagedIdentifier)
        try FileManager.default.createDirectory(
            at: damagedDirectory,
            withIntermediateDirectories: true
        )
        try Data("broken".utf8).write(
            to: damagedDirectory.appendingPathComponent("manifest.json")
        )

        let report = try store.prune(
            policy: RecoveryPrunePolicy(
                maximumAge: 100,
                maximumEntryCount: 1,
                maximumStoredBytes: .max,
                damagedEntryGracePeriod: 0
            ),
            now: now.addingTimeInterval(1)
        )
        let reasons = Dictionary(uniqueKeysWithValues: report.removed.map {
            ($0.identifier, $0.reason)
        })
        XCTAssertEqual(reasons[expired.identifier], .expired)
        XCTAssertEqual(reasons[older.identifier], .entryLimit)
        XCTAssertEqual(reasons[damagedIdentifier], .damaged)
        XCTAssertNil(reasons[newest.identifier])
        XCTAssertGreaterThan(report.reclaimedBytes, 0)
        XCTAssertEqual(try store.inspectEntries().compactMap(\.entry?.identifier), [newest.identifier])
    }

    func testPruneChangedBaseRequiresExplicitPolicy() throws {
        let base = try makeFile(named: "prune-changed.txt", contents: Data("abc".utf8))
        let store = RecoveryStore(rootURL: recoveryRoot)
        let journal = try store.createJournal(for: base)
        try Data("xyz".utf8).write(to: base, options: .atomic)

        let retained = try store.prune(policy: RecoveryPrunePolicy(
            maximumAge: 10_000,
            maximumEntryCount: 10,
            maximumStoredBytes: .max,
            damagedEntryGracePeriod: 0,
            removeEntriesWhoseBaseChanged: false
        ))
        XCTAssertTrue(retained.removed.isEmpty)
        XCTAssertEqual(try store.inspectEntries().first?.availability, .baseChanged)

        let removed = try store.prune(policy: RecoveryPrunePolicy(
            maximumAge: 10_000,
            maximumEntryCount: 10,
            maximumStoredBytes: .max,
            damagedEntryGracePeriod: 0,
            removeEntriesWhoseBaseChanged: true
        ))
        XCTAssertEqual(removed.removed.count, 1)
        XCTAssertEqual(removed.removed.first?.identifier, journal.identifier)
        XCTAssertEqual(removed.removed.first?.reason, .baseChanged)
        XCTAssertGreaterThan(removed.removed.first?.reclaimedBytes ?? 0, 0)
        XCTAssertTrue(try store.inspectEntries().isEmpty)
    }

    private func makeFile(named name: String, contents: Data) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name, isDirectory: false)
        try contents.write(to: url)
        return url
    }

    private func entryDirectory(_ identifier: UUID) -> URL {
        recoveryRoot.appendingPathComponent(identifier.uuidString, isDirectory: true)
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? -1
    }
}
