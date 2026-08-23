import Foundation
import XCTest
@testable import LighTxt

final class DocumentWorkflowStateTests: XCTestCase {
    func testVisitHistoryNavigatesBackAndForward() {
        var history = DocumentVisitHistory<String>()
        history.recordActivation("A")
        history.recordActivation("B")
        history.recordActivation("C")

        XCTAssertEqual(history.navigate(step: -1), "B")
        XCTAssertEqual(history.navigate(step: -1), "A")
        XCTAssertNil(history.navigate(step: -1))
        XCTAssertEqual(history.navigate(step: 1), "B")
        XCTAssertEqual(history.navigate(step: 1), "C")
        XCTAssertNil(history.navigate(step: 1))
    }

    func testNewActivationAfterBackDropsForwardHistory() {
        var history = DocumentVisitHistory<String>()
        ["A", "B", "C"].forEach { history.recordActivation($0) }
        XCTAssertEqual(history.navigate(step: -1), "B")

        history.recordActivation("D")

        XCTAssertEqual(history.entries, ["A", "B", "D"])
        XCTAssertNil(history.target(step: 1))
        XCTAssertEqual(history.navigate(step: -1), "B")
    }

    func testRepeatedCurrentActivationDoesNotDuplicateHistory() {
        var history = DocumentVisitHistory<String>()
        history.recordActivation("A")
        history.recordActivation("A")
        history.recordActivation("B")
        history.recordActivation("A")

        XCTAssertEqual(history.entries, ["A", "B", "A"])
        XCTAssertEqual(history.navigate(step: -1), "B")
    }

    func testClosedDocumentsArePrunedWithoutMovingAValidCursor() {
        var history = DocumentVisitHistory<String>()
        ["A", "B", "C", "D"].forEach { history.recordActivation($0) }
        XCTAssertEqual(history.navigate(step: -1), "C")

        history.retainOnly(["A", "C", "D"])

        XCTAssertEqual(history.current, "C")
        XCTAssertEqual(history.target(step: -1), "A")
        XCTAssertEqual(history.target(step: 1), "D")
    }

    func testPruningCollapsesDuplicatesSeparatedByAClosedDocument() {
        var history = DocumentVisitHistory<String>()
        ["A", "B", "A"].forEach { history.recordActivation($0) }

        history.retainOnly(["A"])

        XCTAssertEqual(history.entries, ["A"])
        XCTAssertEqual(history.current, "A")
        XCTAssertNil(history.target(step: -1))
        XCTAssertNil(history.target(step: 1))
    }

    func testPruningRemovedCurrentUsesNearestPriorDocument() {
        var history = DocumentVisitHistory<String>()
        ["A", "B", "C", "D"].forEach { history.recordActivation($0) }
        XCTAssertEqual(history.navigate(step: -1), "C")
        XCTAssertEqual(history.navigate(step: -1), "B")

        history.retainOnly(["A", "C", "D"])

        XCTAssertEqual(history.current, "A")
        XCTAssertNil(history.target(step: -1))
        XCTAssertEqual(history.target(step: 1), "C")
    }

    func testCanonicalIdentityDeduplicatesSymlinkAndRealPathInOrder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LighTxt-workflow-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("source.csv")
        let alias = directory.appendingPathComponent("alias.csv")
        let other = directory.appendingPathComponent("other.csv")
        try Data("a,b\n1,2\n".utf8).write(to: original)
        try Data("x,y\n3,4\n".utf8).write(to: other)
        try FileManager.default.createSymbolicLink(
            atPath: alias.path,
            withDestinationPath: original.path
        )

        let unique = DocumentURLIdentity.uniqueURLsPreservingOrder([
            alias,
            original,
            other,
            alias,
        ])

        XCTAssertEqual(unique, [alias.standardizedFileURL, other.standardizedFileURL])
        XCTAssertEqual(
            DocumentURLIdentity.canonicalURL(for: alias),
            DocumentURLIdentity.canonicalURL(for: original)
        )
    }

    func testTaskManifestCaptureIsAllOrNothing() throws {
        let first = URL(fileURLWithPath: "/tmp/first.csv")
        let second = URL(fileURLWithPath: "/tmp/second.csv")
        var attempted: [URL] = []

        XCTAssertThrowsError(
            try DocumentTaskManifest(urls: [first, second]) { url in
                attempted.append(url)
                if url == second { throw TestFailure.bookmark }
                return Data("bookmark".utf8)
            }
        )
        XCTAssertEqual(attempted, [first, second])
    }

    func testTaskManifestPrefersBookmarksAndSupportsLegacyFallbacks() throws {
        let bookmarked = URL(fileURLWithPath: "/tmp/bookmarked.csv")
        let fallback = URL(fileURLWithPath: "/tmp/fallback.csv")
        let duplicate = URL(fileURLWithPath: "/tmp/../tmp/bookmarked.csv")
        let manifest = DocumentTaskManifest(items: [
            .init(bookmark: Data([1]), fallbackURL: "/not-used"),
            .init(bookmark: nil, fallbackURL: fallback.absoluteString),
            .init(bookmark: Data([2]), fallbackURL: "/not-used-either"),
        ])

        let resolved = manifest.resolvedURLs { data in
            data == Data([1]) ? bookmarked : duplicate
        }

        XCTAssertEqual(resolved, [bookmarked, fallback])
    }

    func testTaskManifestCodableRoundTripAndLegacyPayload() throws {
        let manifest = DocumentTaskManifest(items: [
            .init(
                bookmark: Data([0x01, 0x02, 0x03]),
                fallbackURL: URL(fileURLWithPath: "/tmp/current.csv").absoluteString
            ),
        ])
        let encoded = try JSONEncoder().encode(manifest)
        XCTAssertEqual(try JSONDecoder().decode(DocumentTaskManifest.self, from: encoded), manifest)

        // Version-one manifests sometimes omitted the optional bookmark key.
        // Keep this literal independent of the encoder so a schema/key change
        // cannot make both sides of the round-trip fail in the same way.
        let legacy = Data(
            #"{"items":[{"fallbackURL":"file:\/\/\/tmp\/legacy.csv"}]}"#.utf8
        )
        let decoded = try JSONDecoder().decode(DocumentTaskManifest.self, from: legacy)
        XCTAssertEqual(
            decoded.resolvedURLs { _ in nil },
            [URL(fileURLWithPath: "/tmp/legacy.csv")]
        )
    }

    func testInactivePurgePolicyProtectsSmallAndBusyDocuments() {
        XCTAssertFalse(
            InactiveDocumentPurgePolicy.shouldSchedule(
                documentByteCount: InactiveDocumentPurgePolicy.minimumDocumentByteCount - 1
            )
        )
        XCTAssertTrue(
            InactiveDocumentPurgePolicy.shouldSchedule(
                documentByteCount: InactiveDocumentPurgePolicy.minimumDocumentByteCount
            )
        )

        let ready = InactiveDocumentPurgeConditions(
            isKeyWindow: false,
            hasAttachedSheet: false,
            hasPendingNavigation: false,
            isSaving: false,
            isBulkEditing: false,
            isExporting: false
        )
        XCTAssertTrue(InactiveDocumentPurgePolicy.canPurge(ready))

        for blocked in [
            InactiveDocumentPurgeConditions(
                isKeyWindow: true,
                hasAttachedSheet: false,
                hasPendingNavigation: false,
                isSaving: false,
                isBulkEditing: false,
                isExporting: false
            ),
            InactiveDocumentPurgeConditions(
                isKeyWindow: false,
                hasAttachedSheet: true,
                hasPendingNavigation: false,
                isSaving: false,
                isBulkEditing: false,
                isExporting: false
            ),
            InactiveDocumentPurgeConditions(
                isKeyWindow: false,
                hasAttachedSheet: false,
                hasPendingNavigation: true,
                isSaving: false,
                isBulkEditing: false,
                isExporting: false
            ),
            InactiveDocumentPurgeConditions(
                isKeyWindow: false,
                hasAttachedSheet: false,
                hasPendingNavigation: false,
                isSaving: true,
                isBulkEditing: false,
                isExporting: false
            ),
            InactiveDocumentPurgeConditions(
                isKeyWindow: false,
                hasAttachedSheet: false,
                hasPendingNavigation: false,
                isSaving: false,
                isBulkEditing: true,
                isExporting: false
            ),
            InactiveDocumentPurgeConditions(
                isKeyWindow: false,
                hasAttachedSheet: false,
                hasPendingNavigation: false,
                isSaving: false,
                isBulkEditing: false,
                isExporting: true
            ),
        ] {
            XCTAssertFalse(InactiveDocumentPurgePolicy.canPurge(blocked))
        }
        XCTAssertEqual(InactiveDocumentPurgePolicy.delay, 30)
    }

    private enum TestFailure: Error {
        case bookmark
    }
}
