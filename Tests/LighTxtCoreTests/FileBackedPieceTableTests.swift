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
