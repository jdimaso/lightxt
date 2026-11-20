import XCTest
import Darwin
@testable import LighTxt

final class FileBackedPieceTableTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LighTxtCoreTests-\(UUID().uuidString)", isDirectory: true)
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

    func testEditsSnapshotsAndClose() throws {
        let source = try makeFile(named: "sample.txt", contents: Data("hello world".utf8))
        let table = try FileBackedPieceTable(opening: source)
        let originalSnapshot = try table.snapshot()

        try table.insert(utf8: ",", at: 5)
        try table.replace(byteRange: 7..<12, withUTF8: "LighTxt")
        try table.delete(byteRange: 0..<1)

        XCTAssertEqual(try text(of: table), "ello, LighTxt")
        XCTAssertEqual(
            try originalSnapshot.utf8String(in: 0..<originalSnapshot.byteCount),
            "hello world"
        )
        XCTAssertTrue(table.hasUnsavedChanges)

        let editedSnapshot = try table.snapshot()
        table.close()
        XCTAssertFalse(table.isOpen)
        XCTAssertThrowsError(try table.snapshot())
        XCTAssertEqual(
            try editedSnapshot.utf8String(in: 0..<editedSnapshot.byteCount),
            "ello, LighTxt"
        )
    }

    func testUndoRedoAndDirtyState() throws {
        let source = try makeFile(named: "undo.txt", contents: Data("abc".utf8))
        let table = try FileBackedPieceTable(opening: source)

        try table.insert(utf8: "1", at: 1)
        try table.insert(utf8: "2", at: 2)
        XCTAssertEqual(try text(of: table), "a12bc")
        XCTAssertTrue(table.canUndo)

        XCTAssertTrue(table.undo())
        XCTAssertEqual(try text(of: table), "a1bc")
        XCTAssertTrue(table.undo())
        XCTAssertEqual(try text(of: table), "abc")
        XCTAssertFalse(table.hasUnsavedChanges)

        XCTAssertTrue(table.redo())
        XCTAssertTrue(table.redo())
        XCTAssertEqual(try text(of: table), "a12bc")
        XCTAssertFalse(table.redo())
    }

    func testAtomicByteEditsUseSourceCoordinatesAndOneUndoRevision() throws {
        let source = try makeFile(named: "atomic.txt", contents: Data("0123456789".utf8))
        let table = try FileBackedPieceTable(opening: source)
        let revisionBefore = try table.snapshot().revision

        try table.replaceAtomically(edits: [
            ByteEdit(byteRange: 2..<4, replacement: Data("AB".utf8)),
            ByteEdit(byteRange: 10..<10, replacement: Data("!".utf8)),
            ByteEdit(byteRange: 6..<8, replacement: Data()),
        ])

        XCTAssertEqual(try text(of: table), "01AB4589!")
        XCTAssertEqual(try table.snapshot().revision, revisionBefore + 1)
        XCTAssertTrue(table.hasUnsavedChanges)
        XCTAssertTrue(table.undo())
        XCTAssertEqual(try text(of: table), "0123456789")
        XCTAssertFalse(table.hasUnsavedChanges)
        XCTAssertFalse(table.canUndo, "The complete batch must consume one undo level")
        XCTAssertTrue(table.redo())
        XCTAssertEqual(try text(of: table), "01AB4589!")
    }

    func testAtomicByteEditValidationNeverPublishesAPartialBatch() throws {
        let source = try makeFile(named: "atomic-invalid.txt", contents: Data("abcdefghij".utf8))
        let table = try FileBackedPieceTable(opening: source)
        let revisionBefore = try table.snapshot().revision

        XCTAssertThrowsError(try table.replaceAtomically(edits: [
            ByteEdit(byteRange: 7..<9, replacement: Data("valid".utf8)),
            ByteEdit(byteRange: 4..<8, replacement: Data()),
        ])) { error in
            guard case LighTxtCoreError.overlappingByteEdits = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try text(of: table), "abcdefghij")
        XCTAssertEqual(try table.snapshot().revision, revisionBefore)
        XCTAssertFalse(table.hasUnsavedChanges)
        XCTAssertFalse(table.canUndo)

        XCTAssertThrowsError(try table.replaceAtomically(edits: [
            ByteEdit(byteRange: 2..<3, replacement: Data("x".utf8)),
            ByteEdit(byteRange: 9..<11, replacement: Data()),
        ]))
        XCTAssertEqual(try text(of: table), "abcdefghij")
        XCTAssertEqual(try table.snapshot().revision, revisionBefore)
        XCTAssertFalse(table.canUndo)
    }

    func testAtomicSameOffsetInsertionsPreserveCallerOrder() throws {
        let source = try makeFile(named: "atomic-insert-order.txt", contents: Data("ac".utf8))
        let table = try FileBackedPieceTable(opening: source)

        try table.replaceAtomically(edits: [
            ByteEdit(byteRange: 1..<1, replacement: Data("1".utf8)),
            ByteEdit(byteRange: 1..<1, replacement: Data("2".utf8)),
            ByteEdit(byteRange: 1..<1, replacement: Data("3".utf8)),
        ])

        XCTAssertEqual(try text(of: table), "a123c")
        XCTAssertTrue(table.undo())
        XCTAssertEqual(try text(of: table), "ac")
        XCTAssertFalse(table.canUndo)
    }

    func testAtomicByteEditsRejectAStaleSnapshotWithoutChangingNewerEdit() throws {
        let source = try makeFile(named: "atomic-stale.txt", contents: Data("abcdef".utf8))
        let table = try FileBackedPieceTable(opening: source)
        let stale = try table.snapshot()
        try table.insert(utf8: "!", at: table.byteCount)
        let revisionAfterNewerEdit = try table.snapshot().revision

        XCTAssertThrowsError(try table.replaceAtomically(
            edits: [ByteEdit(byteRange: 0..<1, replacement: Data("A".utf8))],
            replacing: stale
        )) { error in
            guard case LighTxtCoreError.documentChangedDuringBulkOperation = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try text(of: table), "abcdef!")
        XCTAssertEqual(try table.snapshot().revision, revisionAfterNewerEdit)
        XCTAssertTrue(table.undo())
        XCTAssertEqual(try text(of: table), "abcdef")
        XCTAssertFalse(table.canUndo, "The rejected batch must not add undo state")
    }

    func testAtomicByteEditCancellationDuringPreparationPublishesNothing() throws {
        let source = try makeFile(
            named: "atomic-cancel.txt",
            contents: Data("0123456789".utf8)
        )
        let table = try FileBackedPieceTable(opening: source)
        let snapshot = try table.snapshot()
        // This fires after at least one replacement root has been prepared in
        // local state, proving cancellation still wins before publication.
        let cancellation = AtomicEditCancellationProbe(cancelAfterChecks: 17)

        XCTAssertThrowsError(try table.replaceAtomically(
            edits: [
                ByteEdit(byteRange: 0..<1, replacement: Data("A".utf8)),
                ByteEdit(byteRange: 2..<3, replacement: Data("B".utf8)),
                ByteEdit(byteRange: 4..<5, replacement: Data("C".utf8)),
                ByteEdit(byteRange: 6..<7, replacement: Data("D".utf8)),
            ],
            replacing: snapshot,
            cancellation: { cancellation.shouldCancel() }
        )) { error in
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }

        XCTAssertGreaterThanOrEqual(cancellation.checkCount, 17)
        XCTAssertEqual(try text(of: table), "0123456789")
        XCTAssertEqual(try table.snapshot().revision, snapshot.revision)
        XCTAssertFalse(table.hasUnsavedChanges)
        XCTAssertFalse(table.canUndo)
        XCTAssertFalse(table.canRedo)
    }

    func testBulkRewriteCancellationAtCommitPublishesNothing() throws {
        let source = try makeFile(
            named: "bulk-cancel-source.txt",
            contents: Data("original".utf8)
        )
        let rewrite = try makeFile(
            named: "bulk-cancel-rewrite.txt",
            contents: Data("replacement".utf8)
        )
        let table = try FileBackedPieceTable(opening: source)
        let snapshot = try table.snapshot()
        let mapping = try MemoryMappedFile(url: rewrite)
        // The fourth check occurs after the replacement root is prepared but
        // while the document lock still protects the publication boundary.
        let cancellation = AtomicEditCancellationProbe(cancelAfterChecks: 4)

        XCTAssertThrowsError(try table.installBulkRewrite(
            mapping,
            replacing: snapshot,
            cancellation: { cancellation.shouldCancel() }
        )) { error in
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }

        XCTAssertEqual(cancellation.checkCount, 4)
        XCTAssertEqual(try text(of: table), "original")
        XCTAssertEqual(try table.snapshot().revision, snapshot.revision)
        XCTAssertFalse(table.hasUnsavedChanges)
        XCTAssertFalse(table.canUndo)
        XCTAssertFalse(table.canRedo)
    }

    func testRandomizedEditsMatchContiguousReference() throws {
        var reference = Data((0..<512).map { UInt8($0 & 0xff) })
        let source = try makeFile(named: "random.bin", contents: reference)
        let table = try FileBackedPieceTable(opening: source)
        var random = TestRandom(seed: 0xfeed_face_cafe_beef)

        for operation in 0..<2_000 {
            let count = reference.count
            let lower = count == 0 ? 0 : random.int(through: count)
            let maximumRemoval = count - lower
            let removal = maximumRemoval == 0
                ? 0
                : random.int(through: min(24, maximumRemoval))
            let insertedCount = random.int(through: 24)
            let inserted = Data((0..<insertedCount).map { _ in random.byte() })

            try table.replace(
                byteRange: Int64(lower)..<Int64(lower + removal),
                with: inserted
            )
            reference.replaceSubrange(lower..<(lower + removal), with: inserted)

            if operation.isMultiple(of: 41) {
                let actual = try table.snapshot().data(in: 0..<table.byteCount)
                XCTAssertEqual(actual, reference, "Diverged after operation \(operation)")
            }
        }

        XCTAssertEqual(try table.snapshot().data(in: 0..<table.byteCount), reference)
        XCTAssertLessThanOrEqual(table.pieceCount, 4_001)
    }

    func testResidentEditBudgetSpillsWithoutChangingSemantics() throws {
        let source = try makeFile(named: "spill.txt", contents: Data("base".utf8))
        let configuration = FileBackedPieceTable.Configuration(
            maximumResidentEditBytes: 0,
            individualEditSpillThresholdBytes: 0
        )
        let table = try FileBackedPieceTable(opening: source, configuration: configuration)
        let addition = Data(repeating: 0x78, count: 2 << 20)

        try table.insert(addition, at: 2)
        let snapshot = try table.snapshot()
        XCTAssertEqual(snapshot.byteCount, Int64(addition.count + 4))
        XCTAssertEqual(try snapshot.data(in: 0..<4), Data("baxx".utf8))
        XCTAssertEqual(
            try snapshot.data(in: (snapshot.byteCount - 4)..<snapshot.byteCount),
            Data("xxse".utf8)
        )
    }

    func testThousandsOfSpilledEditsRemainReadable() throws {
        let source = try makeFile(named: "many-spills.txt", contents: Data())
        let configuration = FileBackedPieceTable.Configuration(
            maximumResidentEditBytes: 0,
            individualEditSpillThresholdBytes: 0
        )
        let table = try FileBackedPieceTable(opening: source, configuration: configuration)

        for offset in 0..<2_000 {
            try table.insert(Data([UInt8(offset & 0xff)]), at: Int64(offset))
        }

        let snapshot = try table.snapshot()
        XCTAssertEqual(snapshot.byteCount, 2_000)
        XCTAssertEqual(try snapshot.data(in: 0..<4), Data([0, 1, 2, 3]))
        XCTAssertEqual(
            try snapshot.data(in: 1_996..<2_000),
            Data((1_996..<2_000).map { UInt8($0 & 0xff) })
        )
    }

    func testMaterializationRequiresExplicitBound() throws {
        let source = try makeFile(
            named: "bounded.txt",
            contents: Data(repeating: 1, count: 1_024)
        )
        let snapshot = try FileBackedPieceTable(opening: source).snapshot()
        XCTAssertThrowsError(try snapshot.materializedData(maximumByteCount: 100))
        XCTAssertEqual(try snapshot.materializedData(maximumByteCount: 1_024).count, 1_024)
    }

    func testAtomicSaveSaveAsAndSaveCopy() throws {
        let source = try makeFile(named: "save.txt", contents: Data("before".utf8))
        let table = try FileBackedPieceTable(opening: source)
        try table.replace(byteRange: 0..<6, withUTF8: "after")
        try table.save()

        XCTAssertEqual(try Data(contentsOf: source), Data("after".utf8))
        XCTAssertFalse(table.hasUnsavedChanges)
        XCTAssertEqual(table.pieceCount, 1)
        XCTAssertFalse(table.canUndo, "A memory-reclaiming rebase clears history")

        try table.insert(utf8: "!", at: table.byteCount)
        let copy = temporaryDirectory.appendingPathComponent("copy.txt")
        try table.saveCopy(to: copy)
        XCTAssertEqual(try Data(contentsOf: copy), Data("after!".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("after".utf8))
        XCTAssertTrue(table.hasUnsavedChanges)

        let renamed = temporaryDirectory.appendingPathComponent("renamed.txt")
        try table.saveAs(renamed)
        XCTAssertEqual(table.documentURL, renamed.resolvingSymlinksInPath())
        XCTAssertEqual(try Data(contentsOf: renamed), Data("after!".utf8))
        XCTAssertFalse(table.hasUnsavedChanges)
    }

    func testExternalAppendExportsRecoverableLocalBytesAndOriginalRanges() throws {
        let original = Data("first/middle/last".utf8)
        let source = try makeFile(named: "source.txt", contents: original)
        let table = try FileBackedPieceTable(opening: source,
                                             configuration: .init(maximumResidentEditBytes: 0))
        try table.replace(byteRange: 6..<12, withUTF8: "雪")
        try table.delete(byteRange: 0..<2)
        try table.insert(Data([0, 255]), at: table.byteCount)
        let snapshot = try table.snapshot()
        let exact = try snapshot.materializedData()
        let handle = try FileHandle(forWritingTo: source)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("external".utf8))
        try handle.close()
        XCTAssertTrue(snapshot.originalFileIsUnavailable)
        let target = temporaryDirectory.appendingPathComponent("copy.txt")
        XCTAssertThrowsError(try table.saveAs(target))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))

        let rescue = temporaryDirectory.appendingPathComponent("edits.jsonl")
        try LocalEditExport.write(snapshot: snapshot, sourceURL: source, to: rescue, expectedDestination: nil)
        let records = try Data(contentsOf: rescue).split(separator: 0x0A).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
        XCTAssertEqual(records.first?["format"] as? String, "LighTxt local edits")
        let base = try XCTUnwrap(records.first?["original"] as? [String: Any])
        XCTAssertEqual(base["filename"] as? String, "source.txt")
        XCTAssertEqual(base["byteCount"] as? Int, original.count)
        var rebuilt = Data()
        for record in records.dropFirst() {
            switch record["op"] as? String {
            case "copyOriginal":
                let start = try XCTUnwrap(record["byteOffset"] as? Int)
                let count = try XCTUnwrap(record["byteCount"] as? Int)
                rebuilt.append(original[start..<(start + count)])
            case "insertUTF8":
                rebuilt.append(contentsOf: try XCTUnwrap(record["text"] as? String).utf8)
            case "insertBase64":
                rebuilt.append(try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(record["base64"] as? String))))
            default: XCTFail("Unexpected rescue operation")
            }
        }
        XCTAssertEqual(rebuilt, exact)
        XCTAssertEqual(try Data(contentsOf: source), original + Data("external".utf8))
        XCTAssertTrue(table.hasUnsavedChanges)
        let fingerprint = try FileFingerprint.atPath(source.path)
        XCTAssertThrowsError(try LocalEditExport.write(snapshot: snapshot, sourceURL: source, to: source,
                                                       expectedDestination: fingerprint))
    }

    func testExternalAtomicReplacementKeepsFullSaveAsAvailable() throws {
        let source = try makeFile(named: "replaced.txt", contents: Data("original".utf8))
        let table = try FileBackedPieceTable(opening: source)
        try table.insert(utf8: " local", at: table.byteCount)
        try Data("changed externally".utf8).write(to: source, options: .atomic)
        XCTAssertFalse(try table.snapshot().originalFileIsUnavailable)
        let target = temporaryDirectory.appendingPathComponent("rescued.txt")
        try table.saveAs(target)
        XCTAssertEqual(try Data(contentsOf: target), Data("original local".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("changed externally".utf8))
    }

    func testSaveRefusesToOverwriteExternalChange() throws {
        let source = try makeFile(named: "conflict.txt", contents: Data("one".utf8))
        let table = try FileBackedPieceTable(opening: source)
        try table.replace(byteRange: 0..<3, withUTF8: "local")
        try Data("external-longer".utf8).write(to: source)

        XCTAssertThrowsError(try table.save()) { error in
            guard case LighTxtCoreError.fileChangedExternally = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: source), Data("external-longer".utf8))
    }

    func testInPlaceTruncateReturnsRecoverableErrorForExistingSnapshot() throws {
        let source = try makeFile(
            named: "truncate.txt",
            contents: Data(repeating: 0x61, count: 2 << 20)
        )
        let table = try FileBackedPieceTable(opening: source)
        let snapshot = try table.snapshot()

        let descriptor = Darwin.open(source.path, O_WRONLY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        XCTAssertEqual(Darwin.ftruncate(descriptor, 17), 0)
        XCTAssertEqual(Darwin.close(descriptor), 0)

        XCTAssertThrowsError(try snapshot.data(in: 0..<snapshot.byteCount)) { error in
            guard case LighTxtCoreError.fileChangedExternally = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertTrue(table.isOpen, "An external truncate is an error, not a process crash")
    }

    func testFileBackedSliceCallbacksHaveAHardMemoryBound() throws {
        let source = try makeFile(
            named: "bounded-slices.txt",
            contents: Data(repeating: 0x62, count: (3 << 20) + 17)
        )
        let snapshot = try FileBackedPieceTable(opening: source).snapshot()
        var callbackCount = 0
        var total = 0

        try snapshot.forEachByteSlice { bytes in
            callbackCount += 1
            total += bytes.count
            XCTAssertLessThanOrEqual(bytes.count, MemoryMappedFile.maximumReadByteCount)
        }

        XCTAssertGreaterThan(callbackCount, 1)
        XCTAssertEqual(total, Int(snapshot.byteCount))
    }

    func testPostRenameSubstitutionNeverRebasesOntoForeignInode() throws {
        let source = try makeFile(named: "rename-race.txt", contents: Data("base".utf8))
        let intruder = temporaryDirectory.appendingPathComponent("foreign-inode.txt")
        var configuration = FileBackedPieceTable.Configuration()
        configuration._afterSaveRenameForTesting = { target in
            try Data("foreign".utf8).write(to: intruder)
            guard Darwin.rename(intruder.path, target.path) == 0 else {
                throw LighTxtCoreError.io(
                    operation: "inject post-rename substitution",
                    path: target.path,
                    code: errno
                )
            }
        }
        let table = try FileBackedPieceTable(opening: source, configuration: configuration)
        try table.replace(byteRange: 0..<4, withUTF8: "local")

        XCTAssertThrowsError(try table.save()) { error in
            guard case LighTxtCoreError.fileChangedExternally = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: source), Data("foreign".utf8))
        XCTAssertEqual(try text(of: table), "local")
        XCTAssertTrue(table.hasUnsavedChanges)
        XCTAssertTrue(table.canUndo, "A raced pathname must not clear edit history")
        XCTAssertTrue(table.undo())
        XCTAssertEqual(try text(of: table), "base")
    }

    func testOrdinarySaveRejectsRetargetedSymlinkWithoutTouchingEitherFile() throws {
        let original = try makeFile(named: "symlink-original.txt", contents: Data("original".utf8))
        let foreign = try makeFile(named: "symlink-foreign.txt", contents: Data("foreign".utf8))
        let link = temporaryDirectory.appendingPathComponent("document-link.txt")
        XCTAssertEqual(Darwin.symlink(original.path, link.path), 0)

        let table = try FileBackedPieceTable(opening: link)
        try table.replace(byteRange: 0..<8, withUTF8: "local")

        XCTAssertEqual(Darwin.unlink(link.path), 0)
        XCTAssertEqual(Darwin.symlink(foreign.path, link.path), 0)

        XCTAssertThrowsError(
            try table.save(validatingCurrentDocumentURL: link)
        ) { error in
            guard case LighTxtCoreError.fileChangedExternally = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: foreign), Data("foreign".utf8))
        XCTAssertEqual(try text(of: table), "local")
        XCTAssertTrue(table.hasUnsavedChanges)
    }

    func testMemoryOnlyEmptyDocumentEditsAndPersistsOnlyThroughSaveAs() throws {
        let table = FileBackedPieceTable(empty: .init())
        XCTAssertNil(table.documentURL)
        XCTAssertEqual(table.byteCount, 0)

        try table.insert(utf8: "memory only", at: 0)
        XCTAssertEqual(try text(of: table), "memory only")
        XCTAssertTrue(table.hasUnsavedChanges)

        XCTAssertThrowsError(try table.save()) { error in
            guard case LighTxtCoreError.documentHasNoSaveDestination = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }

        let destination = temporaryDirectory.appendingPathComponent("memory-only-saved.txt")
        try table.saveAs(destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("memory only".utf8))
        XCTAssertEqual(table.documentURL, destination.standardizedFileURL.resolvingSymlinksInPath())
        XCTAssertFalse(table.hasUnsavedChanges)
    }

    func testCancelledSaveLeavesDestinationUntouched() throws {
        let source = try makeFile(
            named: "cancel-source.txt",
            contents: Data(repeating: 0x61, count: 2 << 20)
        )
        let destination = try makeFile(named: "cancel-target.txt", contents: Data("safe".utf8))
        let table = try FileBackedPieceTable(opening: source)
        let cancellation = CancellationToken()
        cancellation.cancel()

        XCTAssertThrowsError(try table.saveCopy(to: destination, cancellation: cancellation))
        XCTAssertEqual(try Data(contentsOf: destination), Data("safe".utf8))
    }

    func testSaveStagingRequestsTheDestinationVolumeForNewAndExistingFiles() throws {
        let existing = try makeFile(named: "existing.txt", contents: Data("previous".utf8))
        let new = temporaryDirectory.appendingPathComponent("new.txt")
        for (target, exists) in [(existing, true), (new, false)] {
            let manager = SaveStagingFileManager()
            let area = try StreamingFileWriter.makeStagingArea(appropriateFor: target, targetExists: exists, fileManager: manager)
            defer { try? FileManager.default.removeItem(at: area.directoryURL) }
            let anchor = exists ? existing : temporaryDirectory!
            XCTAssertEqual(manager.replacementRequest?.standardizedFileURL.path, anchor.standardizedFileURL.path)
            let anchorDevice = try XCTUnwrap(FileFingerprint.atPath(anchor.path)).device
            XCTAssertEqual(try FileFingerprint.atPath(area.directoryURL.path)?.device, anchorDevice)
            XCTAssertFalse(FileManager.default.fileExists(atPath: area.fileURL.path))
        }
    }

    func testSaveStagingFallbackRejectsAnotherDeviceBeforeWriting() throws {
        let target = temporaryDirectory.appendingPathComponent("new.txt")
        let expectedDevice = try XCTUnwrap(FileFingerprint.atPath(temporaryDirectory.path)).device
        let manager = SaveStagingFileManager()
        manager.failReplacementRequest = true
        manager.fallbackDirectory = temporaryDirectory
        let fallback = try StreamingFileWriter.makeStagingArea(appropriateFor: target, targetExists: false, fileManager: manager)
        defer { try? FileManager.default.removeItem(at: fallback.directoryURL) }
        XCTAssertEqual(try FileFingerprint.atPath(fallback.directoryURL.path)?.device, expectedDevice)
        let differentDevice = URL(fileURLWithPath: "/dev", isDirectory: true)
        try XCTSkipIf(try FileFingerprint.atPath(differentDevice.path)?.device == expectedDevice)
        manager.fallbackDirectory = differentDevice
        manager.rejectDirectoryCreation = true
        XCTAssertThrowsError(try StreamingFileWriter.makeStagingArea(appropriateFor: target, targetExists: false, fileManager: manager)) { error in
            guard case LighTxtCoreError.io(_, _, EXDEV) = error else { return XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertFalse(manager.attemptedRejectedCreation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testSaveAsRejectsUnsupportedDestinationBeforeStreamingAndKeepsEdits() throws {
        let table = FileBackedPieceTable(empty: .init())
        try table.insert(utf8: "unsaved", at: 0)
        let folder = temporaryDirectory.appendingPathComponent("existing-directory", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let marker = folder.appendingPathComponent("preserved.txt")
        try Data("original".utf8).write(to: marker)
        let missingParent = temporaryDirectory.appendingPathComponent("absent/target.txt")
        for destination in [folder, missingParent] {
            var beganStreaming = false
            XCTAssertThrowsError(try table.saveAs(destination, progress: { _ in beganStreaming = true }))
            XCTAssertFalse(beganStreaming)
            XCTAssertTrue(table.hasUnsavedChanges)
            XCTAssertNil(table.documentURL)
        }
        XCTAssertEqual(try Data(contentsOf: marker), Data("original".utf8))
        XCTAssertEqual(try text(of: table), "unsaved")
    }

    /// Supply a writable test directory on another volume. Only this test's
    /// unique child directory is created or removed.
    func testSaveAsAndSaveCopyToAnotherVolumeWhenAvailable() throws {
        guard let path = ProcessInfo.processInfo.environment["LIGHTXT_CROSS_VOLUME_SAVE_DIRECTORY"] else {
            throw XCTSkip("Set LIGHTXT_CROSS_VOLUME_SAVE_DIRECTORY to a writable directory on another volume")
        }
        let volume = URL(fileURLWithPath: path, isDirectory: true)
        let device = try XCTUnwrap(FileFingerprint.atPath(volume.path)).device
        XCTAssertNotEqual(device, try XCTUnwrap(FileFingerprint.atPath(temporaryDirectory.path)).device)
        let directory = volume.appendingPathComponent("LighTxtSaveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = try makeFile(named: "source.txt", contents: Data("source".utf8))
        let table = try FileBackedPieceTable(opening: source)
        let copy = directory.appendingPathComponent("copy.txt")
        try table.saveCopy(to: copy)
        XCTAssertEqual(try Data(contentsOf: copy), Data("source".utf8))
        let destination = directory.appendingPathComponent("new.txt")
        try table.insert(utf8: "-new", at: table.byteCount)
        try table.saveAs(destination)
        XCTAssertEqual(try FileFingerprint.atPath(destination.path)?.device, device)
        XCTAssertFalse(table.hasUnsavedChanges)
        try table.insert(utf8: "-existing", at: table.byteCount)
        try table.save()
        XCTAssertEqual(try Data(contentsOf: destination), Data("source-new-existing".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("source".utf8))
        XCTAssertFalse(table.hasUnsavedChanges)
    }

    func testCleanSaveCopyStreamsFromAnotherSystemVolume() throws {
        let source = URL(fileURLWithPath: "/System/Volumes/Preboot/Cryptexes/OS/System/Library/CoreServices/SystemVersion.plist")
        guard FileManager.default.isReadableFile(atPath: source.path),
              let sourceDevice = try FileFingerprint.atPath(source.path)?.device else {
            throw XCTSkip("No readable system version fixture on the Preboot volume")
        }
        let targetDevice = try XCTUnwrap(FileFingerprint.atPath(temporaryDirectory.path)).device
        try XCTSkipIf(sourceDevice == targetDevice, "System and temporary directories share one volume")
        let destination = temporaryDirectory.appendingPathComponent("system-version-copy.plist")
        let table = try FileBackedPieceTable(opening: source)
        try table.saveCopy(to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), try Data(contentsOf: source))
        XCTAssertEqual(try FileFingerprint.atPath(destination.path)?.device, targetDevice)
        XCTAssertEqual(table.documentURL, source.standardizedFileURL.resolvingSymlinksInPath())
    }

    /// Run separately under a sandbox profile that grants write access to the
    /// destination file itself while denying writes to its parent directory.
    /// This mirrors the Powerbox authority returned by NSSavePanel and guards
    /// against reintroducing arbitrary same-directory staging files.
    func testSaveAsAndInPlaceSaveWithFileOnlyWriteAuthority() throws {
        guard let path = ProcessInfo.processInfo.environment["LIGHTXT_EXACT_SAVE_TARGET"] else {
            throw XCTSkip("Exact-path sandbox regression is run by release QA")
        }
        let destination = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: destination)
        defer { try? FileManager.default.removeItem(at: destination) }

        let table = FileBackedPieceTable(empty: .init())
        try table.insert(utf8: "first", at: 0)
        try table.saveAs(destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("first".utf8))

        try table.insert(utf8: " second", at: table.byteCount)
        try table.save()
        XCTAssertEqual(try Data(contentsOf: destination), Data("first second".utf8))
        XCTAssertFalse(table.hasUnsavedChanges)
    }

    private func makeFile(named name: String, contents: Data) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    private func text(of table: FileBackedPieceTable) throws -> String {
        let snapshot = try table.snapshot()
        return try snapshot.utf8String(in: 0..<snapshot.byteCount)
    }
}

private final class SaveStagingFileManager: FileManager, @unchecked Sendable {
    var failReplacementRequest = false
    var rejectDirectoryCreation = false
    var attemptedRejectedCreation = false
    var fallbackDirectory: URL?
    var replacementRequest: URL?

    override var temporaryDirectory: URL { fallbackDirectory ?? super.temporaryDirectory }

    override func url(
        for directory: FileManager.SearchPathDirectory,
        in domain: FileManager.SearchPathDomainMask,
        appropriateFor url: URL?,
        create shouldCreate: Bool
    ) throws -> URL {
        replacementRequest = url
        if failReplacementRequest { throw CocoaError(.fileWriteNoPermission) }
        return try super.url(for: directory, in: domain, appropriateFor: url, create: shouldCreate)
    }

    override func createDirectory(
        at url: URL,
        withIntermediateDirectories createIntermediates: Bool,
        attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        if rejectDirectoryCreation {
            attemptedRejectedCreation = true
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.createDirectory(at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
    }
}

private final class AtomicEditCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelAfterChecks: Int
    private var checks = 0

    init(cancelAfterChecks: Int) {
        self.cancelAfterChecks = cancelAfterChecks
    }

    var checkCount: Int {
        lock.withLock { checks }
    }

    func shouldCancel() -> Bool {
        lock.withLock {
            checks += 1
            return checks >= cancelAfterChecks
        }
    }
}

private struct TestRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }

    mutating func int(through upperBound: Int) -> Int {
        guard upperBound > 0 else { return 0 }
        return Int(next() % UInt64(upperBound + 1))
    }

    mutating func byte() -> UInt8 {
        UInt8(truncatingIfNeeded: next() >> 24)
    }
}
