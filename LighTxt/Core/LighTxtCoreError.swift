import Foundation

/// Errors surfaced by the file-backed editing engine.
public nonisolated enum LighTxtCoreError: Error, LocalizedError, Equatable {
    case documentClosed
    case documentHasNoSaveDestination
    case fileTooLarge(Int64)
    case invalidByteRange(requested: Range<Int64>, byteCount: Int64)
    case invalidUTF8(range: Range<Int64>)
    case emptySearchPattern
    case invalidRegularExpression(String)
    case unsupportedRegularExpression(String)
    case regularExpressionRequiresExactSearch(
        documentByteCount: Int64,
        maximumExactByteCount: Int64,
        reason: String
    )
    case regularExpressionExceedsWindow(
        requiredByteCount: Int64,
        maximumByteCount: Int64
    )
    case regularExpressionMatchExceedsAnalyzedBound(
        matchByteCount: Int64,
        analyzedMaximumByteCount: Int64
    )
    case regularExpressionTimedOut(maximumDuration: TimeInterval)
    case requestedMaterializationTooLarge(requested: Int64, limit: Int64)
    case fileChangedExternally(path: String)
    case documentChangedDuringBulkOperation
    case overlappingByteEdits(first: Range<Int64>, second: Range<Int64>)
    case overlappingSearchMatches(previousEnd: Int64, next: Range<Int64>)
    case copyDestinationMatchesDocument
    case io(operation: String, path: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .documentClosed:
            return "The document is closed."
        case .documentHasNoSaveDestination:
            return "This untitled document has no current file location. Choose Save As to store it."
        case let .fileTooLarge(size):
            return "The file is too large to address on this system (\(size) bytes)."
        case let .invalidByteRange(range, byteCount):
            return "Byte range \(range) is outside the document's \(byteCount)-byte bounds."
        case let .invalidUTF8(range):
            return "The bytes in \(range) are not valid UTF-8."
        case .emptySearchPattern:
            return "The search pattern is empty."
        case let .invalidRegularExpression(message):
            return "Invalid regular expression: \(message)"
        case let .unsupportedRegularExpression(reason):
            return "LighTxt cannot search this regular expression safely in bounded memory: \(reason)"
        case let .regularExpressionRequiresExactSearch(documentBytes, maximumBytes, reason):
            let documentMiB = Double(documentBytes) / Double(1 << 20)
            let maximumMiB = Double(maximumBytes) / Double(1 << 20)
            return "This regex needs exact full-document context. The file is \(documentMiB.formatted(.number.precision(.fractionLength(1)))) MiB; exact regex is limited to \(maximumMiB.formatted(.number.precision(.fractionLength(0)))) MiB to protect memory. On larger files, avoid unbounded repetition, anchors, word boundaries, lookarounds, and backreferences, or use an explicit repetition bound. Detail: \(reason)"
        case let .regularExpressionExceedsWindow(required, maximum):
            return "A safe bounded search for this regular expression requires a \(required)-byte window, exceeding the \(maximum)-byte regex window limit. Reduce its repetition bounds or increase the regex window limit."
        case let .regularExpressionMatchExceedsAnalyzedBound(actual, analyzed):
            return "A regular-expression match used \(actual) UTF-8 bytes, exceeding its proven \(analyzed)-byte bound. Search stopped before returning that match."
        case let .regularExpressionTimedOut(maximumDuration):
            return "Regex search stopped after \(maximumDuration.formatted(.number.precision(.fractionLength(0...2)))) seconds to keep LighTxt responsive. Narrow the pattern or replace ambiguous repetition with an explicit bound."
        case let .requestedMaterializationTooLarge(requested, limit):
            return "The requested \(requested)-byte range exceeds the \(limit)-byte materialization limit."
        case let .fileChangedExternally(path):
            return "The file at \(path) changed outside LighTxt. Reload it or choose Save As to avoid overwriting those changes."
        case .documentChangedDuringBulkOperation:
            return "The document changed while the bulk operation was running. No bulk result was applied."
        case let .overlappingByteEdits(first, second):
            return "Atomic byte edits overlap (\(first) and \(second)). No edits were applied."
        case let .overlappingSearchMatches(previousEnd, next):
            return "Replace All cannot apply overlapping matches (previous end \(previousEnd), next \(next))."
        case .copyDestinationMatchesDocument:
            return "Save a Copy requires a destination different from the open document."
        case let .io(operation, path, code):
            return "Could not \(operation) \(path) (POSIX error \(code): \(String(cString: strerror(code))))."
        }
    }
}

@inline(__always)
nonisolated func checkedInt(_ value: Int64) throws -> Int {
    guard value >= 0, value <= Int64(Int.max) else {
        throw LighTxtCoreError.fileTooLarge(value)
    }
    return Int(value)
}

@inline(__always)
nonisolated func validateByteRange(_ range: Range<Int64>, byteCount: Int64) throws {
    guard range.lowerBound >= 0,
          range.upperBound >= range.lowerBound,
          range.upperBound <= byteCount else {
        throw LighTxtCoreError.invalidByteRange(requested: range, byteCount: byteCount)
    }
}
