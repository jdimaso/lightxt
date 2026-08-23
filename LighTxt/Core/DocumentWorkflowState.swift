import Foundation

/// Browser-style activation history that stores stable, non-retaining document
/// identifiers. It is intentionally independent of AppKit so the navigation
/// semantics used by the document controller stay exhaustively testable.
struct DocumentVisitHistory<Identifier: Hashable> {
    private(set) var entries: [Identifier] = []
    private(set) var currentIndex = -1

    var current: Identifier? {
        entries.indices.contains(currentIndex) ? entries[currentIndex] : nil
    }

    mutating func recordActivation(_ identifier: Identifier) {
        if current == identifier { return }
        if currentIndex + 1 < entries.count {
            entries.removeSubrange((currentIndex + 1)..<entries.count)
        }
        entries.append(identifier)
        currentIndex = entries.count - 1
    }

    func target(step: Int) -> Identifier? {
        guard step == -1 || step == 1 else { return nil }
        let targetIndex = currentIndex + step
        guard entries.indices.contains(targetIndex) else { return nil }
        return entries[targetIndex]
    }

    @discardableResult
    mutating func navigate(step: Int) -> Identifier? {
        guard let target = target(step: step) else { return nil }
        currentIndex += step
        return target
    }

    mutating func retainOnly(_ validIdentifiers: Set<Identifier>) {
        let previousEntries = entries
        let previousIndex = currentIndex
        var retained: [Identifier] = []
        retained.reserveCapacity(previousEntries.count)
        var retainedCurrentIndex: Int?
        var nearestPriorIndex: Int?
        var nearestFollowingIndex: Int?
        for (index, identifier) in previousEntries.enumerated()
        where validIdentifiers.contains(identifier) {
            let destinationIndex: Int
            if retained.last == identifier {
                destinationIndex = retained.count - 1
            } else {
                retained.append(identifier)
                destinationIndex = retained.count - 1
            }
            if index == previousIndex {
                retainedCurrentIndex = destinationIndex
            } else if index < previousIndex {
                nearestPriorIndex = destinationIndex
            } else if nearestFollowingIndex == nil {
                nearestFollowingIndex = destinationIndex
            }
        }
        entries = retained
        currentIndex = retainedCurrentIndex
            ?? nearestPriorIndex
            ?? nearestFollowingIndex
            ?? -1
    }
}

enum DocumentURLIdentity {
    static func canonicalURL(for url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func uniqueURLsPreservingOrder(_ urls: [URL]) -> [URL] {
        var seen = Set<URL>()
        return urls
            .map(\.standardizedFileURL)
            .filter { seen.insert(canonicalURL(for: $0)).inserted }
    }
}

/// Codable last-task representation. New captures require a durable bookmark
/// for every item and are all-or-nothing; the optional field and raw URL remain
/// solely to read manifests written by older versions.
struct DocumentTaskManifest: Codable, Equatable {
    struct Item: Codable, Equatable {
        let bookmark: Data?
        let fallbackURL: String
    }

    let items: [Item]

    init(
        urls: [URL],
        bookmarkData: (URL) throws -> Data
    ) throws {
        items = try DocumentURLIdentity.uniqueURLsPreservingOrder(urls).map { url in
            Item(
                bookmark: try bookmarkData(url),
                fallbackURL: url.absoluteString
            )
        }
    }

    init(items: [Item]) {
        self.items = items
    }

    func resolvedURLs(
        resolvingBookmark: (Data) throws -> URL?
    ) -> [URL] {
        let candidates = items.compactMap { item -> URL? in
            if let bookmark = item.bookmark,
               let resolved = try? resolvingBookmark(bookmark) {
                return resolved
            }
            guard let fallback = URL(string: item.fallbackURL), fallback.isFileURL else {
                return nil
            }
            return fallback
        }
        return DocumentURLIdentity.uniqueURLsPreservingOrder(candidates)
    }
}

struct InactiveDocumentPurgeConditions: Equatable {
    let isKeyWindow: Bool
    let hasAttachedSheet: Bool
    let hasPendingNavigation: Bool
    let isSaving: Bool
    let isBulkEditing: Bool
    let isExporting: Bool
}

enum InactiveDocumentPurgePolicy {
    static let minimumDocumentByteCount: Int64 = 64 << 20
    static let delay: TimeInterval = 30

    static func shouldSchedule(documentByteCount: Int64) -> Bool {
        documentByteCount >= minimumDocumentByteCount
    }

    static func canPurge(_ conditions: InactiveDocumentPurgeConditions) -> Bool {
        !conditions.isKeyWindow
            && !conditions.hasAttachedSheet
            && !conditions.hasPendingNavigation
            && !conditions.isSaving
            && !conditions.isBulkEditing
            && !conditions.isExporting
    }
}
