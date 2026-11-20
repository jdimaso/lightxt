import AppKit
import Foundation

struct SearchSummary: Sendable {
    let totalMatches: Int
    let retainedMatches: [SearchMatch]
    let retainedLimitReached: Bool
    /// False when an intentionally bounded interactive search stopped before
    /// EOF. In that case `totalMatches` is the number found so far, not a file
    /// total.
    let isComplete: Bool
    let elapsed: TimeInterval
}

@MainActor
final class DocumentSearchController {
    typealias ProgressHandler = @MainActor (SearchProgress) -> Void
    typealias MatchHandler = @MainActor (Result<SearchMatch?, Error>) -> Void
    typealias SummaryHandler = @MainActor (Result<SearchSummary, Error>) -> Void

    private let engineProvider: @MainActor () -> FileBackedPieceTable
    private var cancellation: CancellationToken?
    private var generation: UInt64 = 0

    init(engineProvider: @escaping @MainActor () -> FileBackedPieceTable) {
        self.engineProvider = engineProvider
    }

    func cancel() {
        generation &+= 1
        cancellation?.cancel()
        cancellation = nil
    }

    func findOne(
        query: String,
        regularExpression: Bool,
        from byteOffset: Int64,
        backwards: Bool,
        skippingEmptyMatchAtOrigin: Bool = false,
        options: SearchOptions = .init(),
        completion: @escaping MatchHandler
    ) {
        cancel()
        guard !query.isEmpty else {
            completion(.success(nil))
            return
        }

        let engine = engineProvider()
        let token = CancellationToken()
        cancellation = token
        generation &+= 1
        let operationGeneration = generation
        let pattern: SearchPattern = regularExpression
            ? .regularExpression(query)
            : .literal(query)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<SearchMatch?, Error>
            do {
                let snapshot = try engine.snapshot()
                var start = min(max(0, byteOffset), snapshot.byteCount)
                let match: SearchMatch?
                if backwards {
                    let previous = try Self.previousMatch(
                        snapshot: snapshot,
                        pattern: pattern,
                        before: start,
                        includeEmptyAtOrigin: !skippingEmptyMatchAtOrigin,
                        options: options,
                        cancellation: token
                    )
                    if previous == nil, start < snapshot.byteCount || skippingEmptyMatchAtOrigin {
                        match = try Self.previousMatch(
                            snapshot: snapshot,
                            pattern: pattern,
                            before: snapshot.byteCount,
                            includeEmptyAtOrigin: true,
                            options: options,
                            cancellation: token
                        )
                    } else {
                        match = previous
                    }
                } else {
                    if regularExpression {
                        if skippingEmptyMatchAtOrigin {
                            start = start == snapshot.byteCount ? 0 : start + 1
                        }
                        start = try snapshot.utf8BoundaryAtOrAfter(start, limitedBy: snapshot.byteCount)
                    }
                    let next = try snapshot.firstMatch(
                        for: pattern,
                        in: start..<snapshot.byteCount,
                        options: options,
                        cancellation: token
                    )
                    if next == nil, start > 0 {
                        // A match that starts before the caret may end after it.
                        // Exact regexes can have arbitrary width and context.
                        let end: Int64
                        switch pattern {
                        case let .literal(bytes):
                            end = start + min(Int64(bytes.count - 1), snapshot.byteCount - start)
                        case .regularExpression where snapshot.byteCount <= Int64(options.maximumExactRegexDocumentByteCount):
                            end = snapshot.byteCount
                        case .regularExpression:
                            let context = min(Int64(options.maximumRegexWindowByteCount), snapshot.byteCount - start)
                            end = try snapshot.utf8BoundaryAtOrAfter(start + context, limitedBy: snapshot.byteCount)
                        }
                        match = try snapshot.firstMatch(
                            for: pattern,
                            in: 0..<end,
                            options: options,
                            cancellation: token
                        )
                    } else {
                        match = next
                    }
                }
                result = .success(match)
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                guard let self, self.generation == operationGeneration else { return }
                self.cancellation = nil
                switch result {
                case let .success(match): completion(.success(match))
                case .failure(let error as CancellationError):
                    _ = error
                    completion(.success(nil))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }

    func findAll(
        query: String,
        regularExpression: Bool,
        options: SearchOptions = .init(),
        retainedLimit: Int = 20_000,
        scanMatchLimit: Int? = nil,
        progress: ProgressHandler? = nil,
        completion: @escaping SummaryHandler
    ) {
        cancel()
        guard !query.isEmpty else {
            completion(.failure(LighTxtCoreError.emptySearchPattern))
            return
        }

        let engine = engineProvider()
        let token = CancellationToken()
        cancellation = token
        generation &+= 1
        let operationGeneration = generation
        let pattern: SearchPattern = regularExpression
            ? .regularExpression(query)
            : .literal(query)
        let safeLimit = min(100_000, max(0, retainedLimit))
        let safeScanLimit = scanMatchLimit.map { min(100_000, max(1, $0)) }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let started = CFAbsoluteTimeGetCurrent()
            let result: Result<SearchSummary, Error>
            do {
                let snapshot = try engine.snapshot()
                var retained: [SearchMatch] = []
                retained.reserveCapacity(min(safeLimit, 2_048))
                var observedMatches = 0
                var lastProgressUpdate = CFAbsoluteTimeGetCurrent()
                let searchResult = try snapshot.search(
                    pattern,
                    options: options,
                    cancellation: token,
                    progress: { update in
                        let now = CFAbsoluteTimeGetCurrent()
                        guard now - lastProgressUpdate >= 0.10 || update.processedBytes == update.totalBytes else { return }
                        lastProgressUpdate = now
                        DispatchQueue.main.async {
                            guard let self, self.generation == operationGeneration else { return }
                            progress?(update)
                        }
                    },
                    matchHandler: { match in
                        observedMatches += 1
                        if retained.count < safeLimit { retained.append(match) }
                        return safeScanLimit.map { observedMatches < $0 } ?? true
                    }
                )
                if searchResult.stopReason == .cancelled { throw CancellationError() }
                result = .success(SearchSummary(
                    totalMatches: searchResult.matchesFound,
                    retainedMatches: retained,
                    retainedLimitReached: searchResult.stopReason != .completed
                        || searchResult.matchesFound > retained.count,
                    isComplete: searchResult.stopReason == .completed,
                    elapsed: CFAbsoluteTimeGetCurrent() - started
                ))
            } catch {
                result = .failure(error)
            }

            DispatchQueue.main.async {
                guard let self, self.generation == operationGeneration else { return }
                self.cancellation = nil
                completion(result)
            }
        }
    }

    private nonisolated static func previousMatch(
        snapshot: DocumentSnapshot,
        pattern: SearchPattern,
        before byteOffset: Int64,
        includeEmptyAtOrigin: Bool,
        options: SearchOptions,
        cancellation: CancellationToken
    ) throws -> SearchMatch? {
        var primaryEnd = min(max(0, byteOffset), snapshot.byteCount)
        if primaryEnd == 0, !includeEmptyAtOrigin { return nil }
        let primaryWindow: Int64
        let overlap: Int64
        switch pattern {
        case let .literal(bytes):
            primaryWindow = 4 << 20
            overlap = Int64(max(0, bytes.count - 1))
        case .regularExpression:
            // The core proves each accepted regex fits this hard window. Use
            // that same conservative bound around reverse-search ownership
            // windows so a long finite match cannot disappear at a 4 MiB
            // boundary merely because its explicit preferred context is small.
            let maximumWindow = Int64(options.maximumRegexWindowByteCount)
            primaryWindow = max(
                4 << 20,
                maximumWindow <= Int64.max / 2 ? maximumWindow * 2 : Int64.max
            )
            overlap = maximumWindow
        }

        repeat {
            if cancellation.isCancelled { throw CancellationError() }
            var primaryStart = max(0, primaryEnd - primaryWindow)
            // Context-free regex and literal matches are owned by their start
            // offset. The preceding primary window owns any match that begins
            // before `primaryStart`; only right context is needed here.
            var scanEnd = primaryEnd + min(overlap, snapshot.byteCount - primaryEnd)
            if case .regularExpression = pattern {
                primaryStart = try snapshot.utf8BoundaryAtOrBefore(primaryStart, limitedBy: 0)
                scanEnd = try snapshot.utf8BoundaryAtOrAfter(scanEnd, limitedBy: snapshot.byteCount)
            }
            var last: SearchMatch?
            _ = try snapshot.search(
                pattern,
                in: primaryStart..<scanEnd,
                options: options,
                cancellation: cancellation
            ) { match in
                let range = match.byteRange
                let includesOrigin = includeEmptyAtOrigin && range.isEmpty && range.lowerBound == byteOffset
                if range.lowerBound >= primaryEnd, !includesOrigin { return false }
                if range.lowerBound >= primaryStart,
                   range.upperBound <= byteOffset {
                    last = match
                }
                return !includesOrigin
            }
            if let last { return last }
            primaryEnd = primaryStart
        } while primaryEnd > 0
        return nil
    }
}
