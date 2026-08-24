import XCTest
import Darwin
@testable import LighTxt

final class ExternalFileMonitorTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LighTxtExternalMonitorTests-\(UUID().uuidString)", isDirectory: true)
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

    func testClassifiesAppendTruncateModifyReplaceAndAvailability() {
        let firstIdentity = ExternalFileIdentity(device: 1, inode: 10)
        let secondIdentity = ExternalFileIdentity(device: 1, inode: 11)
        let timeOne = ExternalFileModificationTime(seconds: 10, nanoseconds: 1)
        let timeTwo = ExternalFileModificationTime(seconds: 10, nanoseconds: 2)
        let original = ExternalFileState(
            identity: firstIdentity,
            byteCount: 100,
            modificationTime: timeOne
        )

        let appended = ExternalFileState(
            identity: firstIdentity,
            byteCount: 140,
            modificationTime: timeTwo
        )
        XCTAssertEqual(
            ExternalFileChange.classify(
                previous: original,
                current: appended,
                documentWasClean: true
            )?.kind,
            .appended(range: 100..<140)
        )

        let truncated = ExternalFileState(
            identity: firstIdentity,
            byteCount: 25,
            modificationTime: timeTwo
        )
        XCTAssertEqual(
            ExternalFileChange.classify(
                previous: original,
                current: truncated,
                documentWasClean: true
            )?.kind,
            .truncated(fromByteCount: 100, toByteCount: 25)
        )

        let modified = ExternalFileState(
            identity: firstIdentity,
            byteCount: 100,
            modificationTime: timeTwo
        )
        XCTAssertEqual(
            ExternalFileChange.classify(
                previous: original,
                current: modified,
                documentWasClean: true
            )?.kind,
            .modified
        )

        let replacement = ExternalFileState(
            identity: secondIdentity,
            byteCount: 100,
            modificationTime: timeTwo
        )
        XCTAssertEqual(
            ExternalFileChange.classify(
                previous: original,
                current: replacement,
                documentWasClean: true
            )?.kind,
            .replaced
        )
        XCTAssertEqual(
            ExternalFileChange.classify(
                previous: nil,
                current: replacement,
                documentWasClean: true
            )?.kind,
            .appeared
        )
        XCTAssertEqual(
            ExternalFileChange.classify(
                previous: original,
                current: nil,
                documentWasClean: true
            )?.kind,
            .removed
        )
        XCTAssertNil(
            ExternalFileChange.classify(
                previous: original,
                current: original,
                documentWasClean: true
            )
        )
    }

    func testDecisionTrackerPresentsOncePerExactAvailableState() {
        let identity = ExternalFileIdentity(device: 7, inode: 42)
        let original = ExternalFileState(
            identity: identity,
            byteCount: 100,
            modificationTime: .init(seconds: 10, nanoseconds: 1)
        )
        let firstExternalVersion = ExternalFileState(
            identity: identity,
            byteCount: 100,
            modificationTime: .init(seconds: 11, nanoseconds: 1)
        )
        let laterExternalVersion = ExternalFileState(
            identity: identity,
            byteCount: 100,
            modificationTime: .init(seconds: 12, nanoseconds: 1)
        )
        let firstChange = try! XCTUnwrap(
            ExternalFileChange.classify(
                previous: original,
                current: firstExternalVersion,
                documentWasClean: false
            )
        )
        let duplicateSignal = try! XCTUnwrap(
            ExternalFileChange.classify(
                previous: nil,
                current: firstExternalVersion,
                documentWasClean: false
            )
        )
        let laterChange = try! XCTUnwrap(
            ExternalFileChange.classify(
                previous: firstExternalVersion,
                current: laterExternalVersion,
                documentWasClean: false
            )
        )

        var tracker = ExternalFileChangeDecisionTracker()
        XCTAssertTrue(tracker.beginDecision(for: firstChange))
        XCTAssertFalse(
            tracker.beginDecision(for: duplicateSignal),
            "The monitor and a failed editor read must share one prompt"
        )

        tracker.decline(firstChange)
        XCTAssertEqual(tracker.resolution, .declined)
        XCTAssertFalse(
            tracker.beginDecision(for: duplicateSignal),
            "Don't Reload must silence only the exact declined disk version"
        )
        XCTAssertTrue(
            tracker.beginDecision(for: laterChange),
            "A later external write must offer a fresh decision"
        )
        XCTAssertEqual(tracker.resolution, .awaitingDecision)
    }

    func testDecisionTrackerCoalescesMissingStateUntilFileReappears() {
        let identity = ExternalFileIdentity(device: 7, inode: 99)
        let available = ExternalFileState(
            identity: identity,
            byteCount: 20,
            modificationTime: .init(seconds: 20, nanoseconds: 1)
        )
        let removed = try! XCTUnwrap(
            ExternalFileChange.classify(
                previous: available,
                current: nil,
                documentWasClean: true
            )
        )
        let appeared = try! XCTUnwrap(
            ExternalFileChange.classify(
                previous: nil,
                current: available,
                documentWasClean: true
            )
        )

        var tracker = ExternalFileChangeDecisionTracker()
        XCTAssertTrue(tracker.beginDecision(for: removed))
        tracker.decline(removed)
        XCTAssertFalse(tracker.beginDecision(for: removed))
        XCTAssertTrue(tracker.beginDecision(for: appeared))
        tracker.accept(appeared)
        XCTAssertEqual(tracker.resolution, .accepted)
    }

    func testAutomaticVnodeObservationReportsAppendBeforeLongPollFallback() throws {
        let source = try makeFile(named: "automatic.txt", contents: Data("abc".utf8))
        let received = expectation(description: "vnode append")
        let recorder = ChangeRecorder()
        let callbackQueue = DispatchQueue(label: "app.lightext.tests.external-monitor-callback")
        let monitor = try ExternalFileMonitor(
            url: source,
            configuration: .init(
                coalescingInterval: 0.02,
                pollingInterval: 5,
                observationMode: .automatic
            ),
            deliveryQueue: callbackQueue
        ) { change in
            recorder.append(change)
            received.fulfill()
        }
        monitor.start()

        try append(Data("def".utf8), to: source)
        wait(for: [received], timeout: 1.5)
        monitor.stop()

        let changes = recorder.values
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].kind, .appended(range: 3..<6))
        XCTAssertEqual(changes[0].followEOFRange, 3..<6)
        XCTAssertTrue(changes[0].canFollowEOFWithoutConflict)
        XCTAssertFalse(changes[0].requiresFullReload)
    }

    func testPollingFallbackCoalescesRapidAppends() throws {
        let source = try makeFile(named: "poll.txt", contents: Data("0".utf8))
        let firstChange = expectation(description: "coalesced append")
        let unexpectedExtraChange = expectation(description: "no extra append event")
        unexpectedExtraChange.isInverted = true
        let recorder = ChangeRecorder()
        let callbackQueue = DispatchQueue(label: "app.lightext.tests.external-monitor-poll-callback")
        let monitor = try ExternalFileMonitor(
            url: source,
            configuration: .init(
                coalescingInterval: 0.08,
                pollingInterval: 0.05,
                observationMode: .pollingOnly
            ),
            deliveryQueue: callbackQueue
        ) { change in
            let count = recorder.append(change)
            if count == 1 {
                firstChange.fulfill()
            } else {
                unexpectedExtraChange.fulfill()
            }
        }
        monitor.start()

        try append(Data("1".utf8), to: source)
        try append(Data("23".utf8), to: source)
        wait(for: [firstChange], timeout: 2)
        wait(for: [unexpectedExtraChange], timeout: 0.25)
        monitor.stop()

        XCTAssertEqual(recorder.values.map(\.kind), [.appended(range: 1..<4)])
    }

    func testReplacementCarriesDirtyDocumentSignal() throws {
        let source = try makeFile(named: "replace.txt", contents: Data("old".utf8))
        let replacement = try makeFile(named: "incoming.txt", contents: Data("replacement".utf8))
        let received = expectation(description: "replacement")
        let recorder = ChangeRecorder()
        let callbackQueue = DispatchQueue(label: "app.lightext.tests.external-monitor-replace-callback")
        let monitor = try ExternalFileMonitor(
            url: source,
            configuration: .init(
                coalescingInterval: 0.02,
                pollingInterval: 0.05,
                observationMode: .pollingOnly
            ),
            deliveryQueue: callbackQueue
        ) { change in
            recorder.append(change)
            received.fulfill()
        }
        monitor.setDocumentIsClean(false)
        monitor.start()

        XCTAssertEqual(Darwin.rename(replacement.path, source.path), 0)
        wait(for: [received], timeout: 2)
        monitor.stop()

        let change = try XCTUnwrap(recorder.values.first)
        XCTAssertEqual(change.kind, .replaced)
        XCTAssertFalse(change.documentWasClean)
        XCTAssertFalse(change.isCleanChange)
        XCTAssertFalse(change.canFollowEOFWithoutConflict)
        XCTAssertTrue(change.requiresFullReload)
    }

    func testAcknowledgeRebasesWithoutEmittingSelfChange() throws {
        let source = try makeFile(named: "acknowledge.txt", contents: Data("a".utf8))
        let unexpectedChange = expectation(description: "acknowledged state is quiet")
        unexpectedChange.isInverted = true
        let monitor = try ExternalFileMonitor(
            url: source,
            configuration: .init(
                coalescingInterval: 0.03,
                pollingInterval: 0.05,
                observationMode: .pollingOnly
            )
        ) { _ in
            unexpectedChange.fulfill()
        }

        try append(Data("b".utf8), to: source)
        let acknowledged = try XCTUnwrap(monitor.acknowledgeCurrentFileState())
        XCTAssertEqual(acknowledged.byteCount, 2)
        monitor.start()
        wait(for: [unexpectedChange], timeout: 0.2)
        monitor.stop()
        XCTAssertEqual(monitor.baselineState, acknowledged)
    }

    func testConditionalAcknowledgeReportsRevisionThatArrivedAfterReaderPinned() throws {
        let source = try makeFile(named: "conditional-acknowledge.txt", contents: Data("old".utf8))
        let readerPinnedState = try XCTUnwrap(ExternalFileState.inspect(at: source))
        let received = expectation(description: "newer revision remains observable")
        let recorder = ChangeRecorder()
        let monitor = try ExternalFileMonitor(
            url: source,
            configuration: .init(
                coalescingInterval: 0.02,
                pollingInterval: 5,
                observationMode: .pollingOnly
            )
        ) { change in
            recorder.append(change)
            received.fulfill()
        }
        monitor.start()

        try Data("new revision".utf8).write(to: source, options: .atomic)
        XCTAssertFalse(
            try monitor.acknowledgeCurrentFileState(matching: readerPinnedState),
            "A reload must not acknowledge bytes newer than its pinned reader"
        )
        wait(for: [received], timeout: 1.5)
        monitor.stop()

        let current = try XCTUnwrap(ExternalFileState.inspect(at: source))
        XCTAssertEqual(recorder.values.count, 1)
        XCTAssertEqual(recorder.values[0].current, current)
        XCTAssertEqual(recorder.values[0].kind, .replaced)
        XCTAssertEqual(monitor.baselineState, current)
    }

    private func makeFile(named name: String, contents: Data) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try contents.write(to: url)
        return url
    }

    private func append(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }
}

private final class ChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ExternalFileChange] = []

    @discardableResult
    func append(_ change: ExternalFileChange) -> Int {
        lock.lock()
        defer { lock.unlock() }
        storage.append(change)
        return storage.count
    }

    var values: [ExternalFileChange] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
