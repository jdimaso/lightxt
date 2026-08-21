import Foundation

/// Builds a small source-faithful line around each match off the main actor.
/// The three UTF-8 segments are decoded independently, so the highlighted
/// UTF-16 range always describes the displayed spelling of the matching bytes
/// (including JSON quotes and escapes), rather than a lossy decoded preview.
nonisolated enum StructureSearchResultBuilder {
    static func build(
        snapshot: DocumentSnapshot,
        matches: [SearchMatch],
        cancellation: CancellationToken? = nil
    ) -> [StructureSearchResult] {
        var results: [StructureSearchResult] = []
        results.reserveCapacity(matches.count)
        for match in matches {
            if cancellation?.isCancelled == true { break }
            results.append(
                (try? build(snapshot: snapshot, match: match)) ?? fallback(for: match)
            )
        }
        return results
    }

    private static func build(
        snapshot: DocumentSnapshot,
        match: SearchMatch
    ) throws -> StructureSearchResult {
        let validLower = min(max(0, match.byteRange.lowerBound), snapshot.byteCount)
        let validUpper = min(max(validLower, match.byteRange.upperBound), snapshot.byteCount)
        let beforeLimit: Int64 = 240
        let afterLimit: Int64 = 320
        let visibleMatchByteLimit: Int64 = 2 << 10
        let sourceStart = max(0, validLower - beforeLimit)
        let proposedVisibleMatchEnd = validLower > Int64.max - visibleMatchByteLimit
            ? Int64.max
            : validLower + visibleMatchByteLimit
        let visibleMatchEnd = min(validUpper, proposedVisibleMatchEnd)
        let sourceEnd = min(
            snapshot.byteCount,
            validUpper > Int64.max - afterLimit ? Int64.max : validUpper + afterLimit
        )
        let beforeData = try snapshot.data(in: sourceStart..<validLower)
        let matchData = try snapshot.data(in: validLower..<visibleMatchEnd)
        let afterData = try snapshot.data(in: validUpper..<sourceEnd)

        let lineStart = beforeData.lastIndex(where: { $0 == 0x0A || $0 == 0x0D })
            .map { $0 + 1 } ?? 0
        let lineEnd = afterData.firstIndex(where: { $0 == 0x0A || $0 == 0x0D })
            ?? afterData.endIndex

        var prefix = render(beforeData[lineStart...])
        var exactMatch = render(matchData[matchData.startIndex..<matchData.endIndex])
        var suffix = render(afterData[..<lineEnd])
        let prefixHadMore = lineStart == 0 && sourceStart > 0
        let suffixHadMore = lineEnd == afterData.endIndex && sourceEnd < snapshot.byteCount

        // Keep the exact match near the leading edge. Structure rows truncate
        // at the tail, so a long prefix could otherwise hide the only text the
        // user searched for at the app's 1000-point minimum width.
        if prefix.count > 48 { prefix = String(prefix.suffix(48)) }
        if suffix.count > 220 { suffix = String(suffix.prefix(220)) }
        let matchWasTruncated = visibleMatchEnd < validUpper || exactMatch.count > 320
        if matchWasTruncated { exactMatch = String(exactMatch.prefix(320)) }

        let renderedPrefix = (prefixHadMore || lineStart == 0 && prefix.count >= 48 ? "…" : "") + prefix
        let visibleMatch = exactMatch.isEmpty ? "▏" : exactMatch
        let renderedSuffix = suffix + (suffixHadMore || suffix.count >= 220 ? "…" : "")
        let text = renderedPrefix + visibleMatch + (matchWasTruncated ? "…" : "") + renderedSuffix
        let highlightStart = (renderedPrefix as NSString).length
        let highlightLength = (visibleMatch as NSString).length
        return StructureSearchResult(
            match: match,
            text: text.isEmpty ? "Match at byte \(validLower.formatted())" : text,
            highlightUTF16Range: highlightStart..<(highlightStart + highlightLength)
        )
    }

    private static func fallback(for match: SearchMatch) -> StructureSearchResult {
        let text = "Match at byte \(match.byteRange.lowerBound.formatted())"
        return StructureSearchResult(match: match, text: text, highlightUTF16Range: 0..<0)
    }

    private static func render(_ bytes: Data.SubSequence) -> String {
        String(decoding: bytes, as: UTF8.self)
            .replacingOccurrences(of: "\t", with: "⇥")
            .replacingOccurrences(of: "\r", with: "↵")
            .replacingOccurrences(of: "\n", with: "↵")
    }
}
