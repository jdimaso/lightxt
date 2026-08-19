import AppKit
import Foundation

struct SearchSummary: Sendable {
    let totalMatches: Int
    let retainedMatches: [SearchMatch]
    let retainedLimitReached: Bool
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

    var isRunning: Bool { cancellation != nil }

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
                let start = min(max(0, byteOffset), snapshot.byteCount)
                let match: SearchMatch?
                if backwards {
                    match = try Self.previousMatch(
                        snapshot: snapshot,
                        pattern: pattern,
                        before: start,
                        options: options,
                        cancellation: token
                    ) ?? Self.previousMatch(
                        snapshot: snapshot,
                        pattern: pattern,
                        before: snapshot.byteCount,
                        options: options,
                        cancellation: token
                    )
                } else {
                    match = try snapshot.firstMatch(
                        for: pattern,
                        in: start..<snapshot.byteCount,
                        options: options,
                        cancellation: token
                    ) ?? snapshot.firstMatch(
                        for: pattern,
                        in: 0..<start,
                        options: options,
                        cancellation: token
                    )
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

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let started = CFAbsoluteTimeGetCurrent()
            let result: Result<SearchSummary, Error>
            do {
                let snapshot = try engine.snapshot()
                var retained: [SearchMatch] = []
                retained.reserveCapacity(min(safeLimit, 2_048))
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
                        if retained.count < safeLimit { retained.append(match) }
                        return true
                    }
                )
                if searchResult.stopReason == .cancelled { throw CancellationError() }
                result = .success(SearchSummary(
                    totalMatches: searchResult.matchesFound,
                    retainedMatches: retained,
                    retainedLimitReached: searchResult.matchesFound > retained.count,
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
        options: SearchOptions,
        cancellation: CancellationToken
    ) throws -> SearchMatch? {
        var primaryEnd = min(max(0, byteOffset), snapshot.byteCount)
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

        while primaryEnd > 0 {
            if cancellation.isCancelled { throw CancellationError() }
            let primaryStart = max(0, primaryEnd - primaryWindow)
            // Context-free regex and literal matches are owned by their start
            // offset. The preceding primary window owns any match that begins
            // before `primaryStart`; only right context is needed here.
            let scanStart = primaryStart
            let scanEnd = primaryEnd + min(overlap, snapshot.byteCount - primaryEnd)
            var last: SearchMatch?
            _ = try snapshot.search(
                pattern,
                in: scanStart..<scanEnd,
                options: options,
                cancellation: cancellation
            ) { match in
                if match.byteRange.lowerBound >= primaryStart,
                   match.byteRange.lowerBound < primaryEnd,
                   match.byteRange.upperBound <= byteOffset {
                    last = match
                }
                return true
            }
            if let last { return last }
            primaryEnd = primaryStart
        }
        return nil
    }
}
