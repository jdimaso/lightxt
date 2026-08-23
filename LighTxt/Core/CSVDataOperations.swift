import Darwin
import Foundation

public nonisolated enum CSVDataOperationError: Error, LocalizedError, Equatable {
    case invalidColumn(Int)
    case invalidRecord(Int64)
    case queryValueTooLarge(record: Int64, column: Int, limit: Int)
    case rowMapClosed
    case rowMapOutOfBounds(Int64)

    public var errorDescription: String? {
        switch self {
        case let .invalidColumn(column):
            return "CSV column indexes must be zero or greater (received \(column))."
        case let .invalidRecord(record):
            return "CSV record indexes must be zero or greater (received \(record))."
        case let .queryValueTooLarge(record, column, limit):
            return "CSV record \(record + 1), column \(column + 1) exceeds the exact query limit of \(limit.formatted()) bytes."
        case .rowMapClosed:
            return "This CSV query result has already been closed."
        case let .rowMapOutOfBounds(row):
            return "CSV result row \(row) is outside the available result."
        }
    }
}

public nonisolated enum CSVNumericComparison: Sendable, Equatable {
    case lessThan
    case lessThanOrEqual
    case equal
    case notEqual
    case greaterThanOrEqual
    case greaterThan
}

public nonisolated enum CSVFilterPredicate: Sendable, Equatable {
    case equals(String, caseSensitive: Bool)
    case notEquals(String, caseSensitive: Bool)
    case contains(String, caseSensitive: Bool)
    case beginsWith(String, caseSensitive: Bool)
    case endsWith(String, caseSensitive: Bool)
    case isEmpty
    case isNotEmpty
    case numeric(CSVNumericComparison, Double)
    /// The compact View-mode filter used by the CSV table. A nonempty text
    /// fragment and a nonempty selected-value set are independent constraints:
    /// both must match. Values within the selected set are alternatives (OR).
    /// An empty selected set means "all values" so clearing every checkbox
    /// clears that part of the filter instead of hiding every row.
    case containsAndSelectedValues(
        text: String,
        selectedValues: Set<String>,
        containsCaseSensitive: Bool,
        selectedValuesCaseSensitive: Bool
    )

    fileprivate func matches(_ value: String) -> Bool {
        switch self {
        case let .equals(expected, caseSensitive):
            return compare(value, expected, caseSensitive: caseSensitive) == .orderedSame
        case let .notEquals(expected, caseSensitive):
            return compare(value, expected, caseSensitive: caseSensitive) != .orderedSame
        case let .contains(fragment, caseSensitive):
            return value.range(
                of: fragment,
                options: caseSensitive ? [] : [.caseInsensitive]
            ) != nil
        case let .beginsWith(prefix, caseSensitive):
            return value.range(
                of: prefix,
                options: caseSensitive ? [.anchored] : [.anchored, .caseInsensitive]
            ) != nil
        case let .endsWith(suffix, caseSensitive):
            return value.range(
                of: suffix,
                options: caseSensitive
                    ? [.anchored, .backwards]
                    : [.anchored, .backwards, .caseInsensitive]
            ) != nil
        case .isEmpty:
            return value.isEmpty
        case .isNotEmpty:
            return !value.isEmpty
        case let .numeric(operation, expected):
            guard let actual = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)),
                  actual.isFinite else { return false }
            switch operation {
            case .lessThan: return actual < expected
            case .lessThanOrEqual: return actual <= expected
            case .equal: return actual == expected
            case .notEqual: return actual != expected
            case .greaterThanOrEqual: return actual >= expected
            case .greaterThan: return actual > expected
            }
        case let .containsAndSelectedValues(
            text,
            selectedValues,
            containsCaseSensitive,
            selectedValuesCaseSensitive
        ):
            if !text.isEmpty,
               value.range(
                   of: text,
                   options: containsCaseSensitive ? [] : [.caseInsensitive]
               ) == nil {
                return false
            }
            guard !selectedValues.isEmpty else { return true }
            if selectedValuesCaseSensitive { return selectedValues.contains(value) }
            return selectedValues.contains { expected in
                compare(value, expected, caseSensitive: false) == .orderedSame
            }
        }
    }

    private func compare(
        _ lhs: String,
        _ rhs: String,
        caseSensitive: Bool
    ) -> ComparisonResult {
        lhs.compare(rhs, options: caseSensitive ? [] : [.caseInsensitive])
    }
}

public nonisolated struct CSVColumnFilter: Sendable, Equatable {
    public let column: Int
    public let predicate: CSVFilterPredicate

    public init(column: Int, predicate: CSVFilterPredicate) {
        self.column = column
        self.predicate = predicate
    }

    /// Creates one column filter for the CSV View UI. The contains constraint
    /// and selected-value constraint are ANDed. Selected values are ORed.
    public init(
        column: Int,
        containsText: String,
        selectedValues: Set<String> = [],
        containsCaseSensitive: Bool = false,
        selectedValuesCaseSensitive: Bool = true
    ) {
        self.init(
            column: column,
            predicate: .containsAndSelectedValues(
                text: containsText,
                selectedValues: selectedValues,
                containsCaseSensitive: containsCaseSensitive,
                selectedValuesCaseSensitive: selectedValuesCaseSensitive
            )
        )
    }

    /// Compatibility shorthand for callers that intentionally want one
    /// comparison mode for both the text and checkbox constraints.
    public init(
        column: Int,
        containsText: String,
        selectedValues: Set<String>,
        caseSensitive: Bool
    ) {
        self.init(
            column: column,
            containsText: containsText,
            selectedValues: selectedValues,
            containsCaseSensitive: caseSensitive,
            selectedValuesCaseSensitive: caseSensitive
        )
    }
}

/// Query-time representation that folds one-of values once rather than doing
/// a linear scan of every selected checkbox for every source record.
private nonisolated struct CSVCompiledFilterPredicate {
    let predicate: CSVFilterPredicate
    let normalizedSelectedValues: Set<String>?

    init(_ predicate: CSVFilterPredicate) {
        self.predicate = predicate
        if case let .containsAndSelectedValues(
            _,
            values,
            _,
            selectedValuesCaseSensitive
        ) = predicate,
           !values.isEmpty,
           !selectedValuesCaseSensitive {
            self.normalizedSelectedValues = Set(values.map(csvCaseFold))
        } else {
            self.normalizedSelectedValues = nil
        }
    }

    func matches(_ value: String) -> Bool {
        guard case let .containsAndSelectedValues(
            text,
            selectedValues,
            containsCaseSensitive,
            selectedValuesCaseSensitive
        ) = predicate else {
            return predicate.matches(value)
        }
        if !text.isEmpty,
           value.range(
               of: text,
               options: containsCaseSensitive ? [] : [.caseInsensitive]
           ) == nil {
            return false
        }
        guard !selectedValues.isEmpty else { return true }
        if selectedValuesCaseSensitive { return selectedValues.contains(value) }
        return normalizedSelectedValues?.contains(csvCaseFold(value)) == true
    }
}

private nonisolated struct CSVCompiledColumnFilterGroup {
    let column: Int
    let predicates: [CSVCompiledFilterPredicate]

    func matches(_ value: String) -> Bool {
        predicates.allSatisfy { $0.matches(value) }
    }
}

private nonisolated func compileCSVColumnFilterGroups(
    _ filters: [CSVColumnFilter]
) -> [CSVCompiledColumnFilterGroup] {
    let grouped = Dictionary(grouping: filters, by: \.column)
    return grouped.keys
        .sorted()
        .map { column in
            CSVCompiledColumnFilterGroup(
                column: column,
                predicates: grouped[column, default: []]
                    .map { CSVCompiledFilterPredicate($0.predicate) }
            )
        }
}

private nonisolated func csvCaseFold(_ value: String) -> String {
    value.folding(
        options: [.caseInsensitive],
        locale: Locale(identifier: "en_US_POSIX")
    )
}

/// Per-record state shared by the completed-index projection scanner. It keeps
/// only requested logical values and their exact source ranges; unrequested
/// fields are scanned for RFC-4180 structure without being retained.
private nonisolated struct CSVProjectedFieldAccumulator {
    private let columns: Set<Int>
    private let perFieldLimit: Int
    private let aggregateLimit: Int
    private var selected: [Int: CSVFieldValue] = [:]
    private var fieldIndex = 0
    private var fieldStart: Int64
    private var current = Data()
    private var truncated = false
    private var retainedBytes = 0
    private var retainsCurrentField: Bool
    private var atFieldStart = true
    private var inQuotedField = false
    private var pendingQuote = false

    var canScanQuotedRun: Bool { inQuotedField && !pendingQuote }
    var canScanUnquotedRun: Bool { !inQuotedField && !atFieldStart }

    init(
        recordStart: Int64,
        columns: Set<Int>,
        maximumValueBytesPerField: Int,
        maximumRetainedValueBytes: Int
    ) {
        self.columns = columns
        self.perFieldLimit = max(0, maximumValueBytesPerField)
        self.aggregateLimit = max(0, maximumRetainedValueBytes)
        self.fieldStart = recordStart
        self.retainsCurrentField = columns.contains(0)
        selected.reserveCapacity(columns.count)
        current.reserveCapacity(min(256, perFieldLimit))
    }

    /// Returns true when `byte` is an unquoted record terminator. The caller
    /// owns CRLF coalescing and record emission so it can stop immediately when
    /// a bounded consumer has enough results.
    mutating func consume(
        _ byte: UInt8,
        at absoluteOffset: Int64,
        delimiter: UInt8
    ) -> Bool {
        if inQuotedField {
            if pendingQuote {
                if byte == 0x22 {
                    appendValueByte(0x22)
                    pendingQuote = false
                    return false
                }
                inQuotedField = false
                pendingQuote = false
                // This byte belongs to the unquoted delimiter/newline context.
            } else if byte == 0x22 {
                pendingQuote = true
                return false
            } else {
                appendValueByte(byte)
                return false
            }
        }

        if atFieldStart, byte == 0x22 {
            inQuotedField = true
            atFieldStart = false
        } else if byte == delimiter {
            finishField(at: absoluteOffset)
        } else if byte == 0x0A || byte == 0x0D {
            return true
        } else {
            appendValueByte(byte)
            atFieldStart = false
        }
        return false
    }

    mutating func finishRecord(at end: Int64) -> CSVSelectedFields {
        finishField(at: end)
        return CSVSelectedFields(fieldCount: fieldIndex, fields: selected)
    }

    mutating func consumeQuotedRun(_ bytes: UnsafeRawBufferPointer) {
        appendValueBytes(bytes)
    }

    mutating func consumeUnquotedRun(_ bytes: UnsafeRawBufferPointer) {
        guard !bytes.isEmpty else { return }
        appendValueBytes(bytes)
        atFieldStart = false
    }

    private mutating func appendValueByte(_ byte: UInt8) {
        guard retainsCurrentField else { return }
        if current.count < perFieldLimit, retainedBytes < aggregateLimit {
            current.append(byte)
            retainedBytes += 1
        } else {
            truncated = true
        }
    }

    private mutating func appendValueBytes(_ bytes: UnsafeRawBufferPointer) {
        guard retainsCurrentField, !bytes.isEmpty else { return }
        let fieldCapacity = max(0, perFieldLimit - current.count)
        let recordCapacity = max(0, aggregateLimit - retainedBytes)
        let retainedCount = min(bytes.count, fieldCapacity, recordCapacity)
        if retainedCount > 0, let baseAddress = bytes.baseAddress {
            current.append(
                baseAddress.assumingMemoryBound(to: UInt8.self),
                count: retainedCount
            )
            retainedBytes += retainedCount
        }
        if retainedCount < bytes.count { truncated = true }
    }

    private mutating func finishField(at end: Int64) {
        if retainsCurrentField {
            selected[fieldIndex] = CSVFieldValue(
                byteRange: fieldStart..<end,
                value: String(decoding: current, as: UTF8.self),
                wasTruncated: truncated
            )
        }
        fieldIndex += 1
        retainsCurrentField = columns.contains(fieldIndex)
        current.removeAll(keepingCapacity: true)
        truncated = false
        fieldStart = end + 1
        atFieldStart = true
        inQuotedField = false
        pendingQuote = false
    }
}

@inline(__always)
private nonisolated func csvProjectionWordContainsByte(_ word: UInt64, _ byte: UInt8) -> Bool {
    let ones: UInt64 = 0x0101_0101_0101_0101
    let highs: UInt64 = 0x8080_8080_8080_8080
    let repeated = UInt64(byte) &* ones
    let value = word ^ repeated
    return ((value &- ones) & ~value & highs) != 0
}

@inline(__always)
private nonisolated func csvProjectionScanUntilByte(
    _ base: UnsafeRawPointer,
    from start: Int,
    to end: Int,
    byte: UInt8
) -> Int {
    var cursor = start
    while cursor + MemoryLayout<UInt64>.size <= end {
        let word = base.loadUnaligned(fromByteOffset: cursor, as: UInt64.self)
        if csvProjectionWordContainsByte(word, byte) { break }
        cursor += MemoryLayout<UInt64>.size
    }
    while cursor < end,
          base.load(fromByteOffset: cursor, as: UInt8.self) != byte {
        cursor += 1
    }
    return cursor
}

@inline(__always)
private nonisolated func csvProjectionScanUntilUnquotedSpecial(
    _ base: UnsafeRawPointer,
    from start: Int,
    to end: Int,
    delimiter: UInt8
) -> Int {
    var cursor = start
    while cursor + MemoryLayout<UInt64>.size <= end {
        let word = base.loadUnaligned(fromByteOffset: cursor, as: UInt64.self)
        if csvProjectionWordContainsByte(word, delimiter)
            || csvProjectionWordContainsByte(word, 0x0A)
            || csvProjectionWordContainsByte(word, 0x0D) {
            break
        }
        cursor += MemoryLayout<UInt64>.size
    }
    while cursor < end {
        let byte = base.load(fromByteOffset: cursor, as: UInt8.self)
        if byte == delimiter || byte == 0x0A || byte == 0x0D { break }
        cursor += 1
    }
    return cursor
}

private nonisolated enum CSVProjectedRecordScannerStop: Error {
    case consumerFinished
}

/// Streams projected records in a single bounded pass once the sparse row
/// index is complete. The old page/location path remains the fallback while an
/// index is still growing because callers historically complete that index as
/// a side effect of a query.
private nonisolated enum CSVProjectedRecordScanner {
    /// Returns false only when `consume` asks to stop early. Backing reads stay
    /// capped by `DocumentSnapshot.forEachByteSlice` (currently one MiB), and no
    /// record-location or projected-row array is accumulated.
    static func scan(
        snapshot: DocumentSnapshot,
        index: CSVRowIndex,
        firstRecord: Int64,
        columns: Set<Int>,
        maximumValueBytesPerField: Int,
        maximumRetainedValueBytes: Int,
        cancellation: CSVRowIndex.CancellationCheck?,
        consume: (Int64, CSVSelectedFields) throws -> Bool
    ) throws -> Bool {
        let indexProgress = index.progress
        guard indexProgress.isComplete,
              let totalRecordCount = indexProgress.totalRecordCount else {
            return false
        }
        guard firstRecord < totalRecordCount else { return true }
        if cancellation?() == true { throw CancellationError() }

        guard let firstLocation = try index.recordLocation(
            forRecord: firstRecord,
            cancellation: cancellation
        ) else {
            throw CSVRowIndex.IndexError.inconsistentCheckpointData
        }
        var scanStart = firstLocation.contentRange.lowerBound
        if firstRecord == 0,
           scanStart == 0,
           snapshot.byteCount >= 3,
           try snapshot.data(in: 0..<3) == Data([0xEF, 0xBB, 0xBF]) {
            scanStart = 3
        }

        var record = firstRecord
        var pendingCarriageReturn = false
        var accumulator = CSVProjectedFieldAccumulator(
            recordStart: scanStart,
            columns: columns,
            maximumValueBytesPerField: maximumValueBytesPerField,
            maximumRetainedValueBytes: maximumRetainedValueBytes
        )
        var absoluteOffset = scanStart

        func emitRecord(endingAt end: Int64) throws {
            if cancellation?() == true { throw CancellationError() }
            let projected = accumulator.finishRecord(at: end)
            guard try consume(record, projected) else {
                throw CSVProjectedRecordScannerStop.consumerFinished
            }
            record += 1
        }

        do {
            try snapshot.forEachByteSlice(in: scanStart..<snapshot.byteCount) { bytes in
                if cancellation?() == true { throw CancellationError() }
                guard let baseAddress = bytes.baseAddress else { return }
                var cursor = 0
                var nextCancellationCheck = 0
                while cursor < bytes.count {
                    if cursor >= nextCancellationCheck {
                        if cancellation?() == true { throw CancellationError() }
                        nextCancellationCheck = cursor + (16 << 10)
                    }
                    if record >= totalRecordCount { return }
                    let scanLimit = min(bytes.count, nextCancellationCheck)
                    let byte = baseAddress.load(fromByteOffset: cursor, as: UInt8.self)

                    if pendingCarriageReturn {
                        pendingCarriageReturn = false
                        if byte == 0x0A {
                            cursor += 1
                            absoluteOffset += 1
                            accumulator = CSVProjectedFieldAccumulator(
                                recordStart: absoluteOffset,
                                columns: columns,
                                maximumValueBytesPerField: maximumValueBytesPerField,
                                maximumRetainedValueBytes: maximumRetainedValueBytes
                            )
                            continue
                        }
                    }

                    if accumulator.canScanQuotedRun {
                        let end = csvProjectionScanUntilByte(
                            baseAddress,
                            from: cursor,
                            to: scanLimit,
                            byte: 0x22
                        )
                        if end > cursor {
                            let count = end - cursor
                            accumulator.consumeQuotedRun(UnsafeRawBufferPointer(
                                start: baseAddress.advanced(by: cursor),
                                count: count
                            ))
                            cursor = end
                            absoluteOffset += Int64(count)
                            continue
                        }
                    } else if accumulator.canScanUnquotedRun {
                        let end = csvProjectionScanUntilUnquotedSpecial(
                            baseAddress,
                            from: cursor,
                            to: scanLimit,
                            delimiter: index.delimiter
                        )
                        if end > cursor {
                            let count = end - cursor
                            accumulator.consumeUnquotedRun(UnsafeRawBufferPointer(
                                start: baseAddress.advanced(by: cursor),
                                count: count
                            ))
                            cursor = end
                            absoluteOffset += Int64(count)
                            continue
                        }
                    }

                    if accumulator.consume(
                        byte,
                        at: absoluteOffset,
                        delimiter: index.delimiter
                    ) {
                        try emitRecord(endingAt: absoluteOffset)
                        pendingCarriageReturn = byte == 0x0D
                        accumulator = CSVProjectedFieldAccumulator(
                            recordStart: absoluteOffset + 1,
                            columns: columns,
                            maximumValueBytesPerField: maximumValueBytesPerField,
                            maximumRetainedValueBytes: maximumRetainedValueBytes
                        )
                    }
                    cursor += 1
                    absoluteOffset += 1
                }
            }

            if record < totalRecordCount {
                try emitRecord(endingAt: snapshot.byteCount)
            }
        } catch CSVProjectedRecordScannerStop.consumerFinished {
            return false
        }

        guard record == totalRecordCount else {
            throw CSVRowIndex.IndexError.inconsistentCheckpointData
        }
        return true
    }
}

public nonisolated enum CSVSortOrder: Sendable, Equatable {
    case ascending
    case descending
}

public nonisolated enum CSVSortValueKind: Sendable, Equatable {
    /// Empty values last; finite numbers numerically; remaining values with a
    /// case-insensitive, numeric-aware text comparison.
    case automatic
    case text
    case number
}

public nonisolated struct CSVSortDescriptor: Sendable, Equatable {
    public let column: Int
    public let order: CSVSortOrder
    public let valueKind: CSVSortValueKind
    public let caseSensitive: Bool

    public init(
        column: Int,
        order: CSVSortOrder = .ascending,
        valueKind: CSVSortValueKind = .automatic,
        caseSensitive: Bool = false
    ) {
        self.column = column
        self.order = order
        self.valueKind = valueKind
        self.caseSensitive = caseSensitive
    }
}

public nonisolated struct CSVRowQuery: Sendable, Equatable {
    /// The first source record included in the query. Set this to one when the
    /// first record is a header.
    public let firstRecord: Int64
    /// Every filter must match. Multiple filters may target the same column.
    public let filters: [CSVColumnFilter]
    /// Applied in order. Source record ordinal is the final tie-breaker, making
    /// sorting stable even when multiple logical values compare equally.
    public let sortDescriptors: [CSVSortDescriptor]

    public init(
        firstRecord: Int64 = 0,
        filters: [CSVColumnFilter] = [],
        sortDescriptors: [CSVSortDescriptor] = []
    ) {
        self.firstRecord = firstRecord
        self.filters = filters
        self.sortDescriptors = sortDescriptors
    }
}

public nonisolated struct CSVQueryProgress: Sendable, Equatable {
    public let indexedFractionCompleted: Double
    public let scannedRecordCount: Int64
    public let matchedRecordCount: Int64
    public let totalRecordCount: Int64?
}

/// Immutable, random-access mapping from a filtered table row to its source CSV
/// record. Ordinals live in one secure, unlinked temporary inode (eight bytes
/// per match), so result size never becomes heap growth.
public nonisolated final class CSVRowMap: @unchecked Sendable {
    private let store: CSVTemporaryOrdinalStore
    public let rowCount: Int64

    fileprivate init(store: CSVTemporaryOrdinalStore) throws {
        try store.finishWriting()
        self.store = store
        self.rowCount = store.count
    }

    public func record(at displayedRow: Int64) throws -> Int64 {
        guard displayedRow >= 0, displayedRow < rowCount else {
            throw CSVDataOperationError.rowMapOutOfBounds(displayedRow)
        }
        return try store.value(at: displayedRow)
    }

    /// Reads a bounded page of source record ordinals. Requests larger than
    /// 4,096 rows are intentionally capped for UI safety.
    public func records(in requestedRange: Range<Int64>) throws -> [Int64] {
        guard requestedRange.lowerBound >= 0,
              requestedRange.lowerBound <= requestedRange.upperBound,
              requestedRange.lowerBound <= rowCount else {
            throw CSVDataOperationError.rowMapOutOfBounds(requestedRange.lowerBound)
        }
        let upper = min(rowCount, requestedRange.upperBound)
        let cappedUpper = min(upper, requestedRange.lowerBound + 4_096)
        return try store.values(in: requestedRange.lowerBound..<cappedUpper)
    }

    /// Releases the temporary result immediately. It is also closed on deinit.
    public func close() {
        store.close()
    }
}

public nonisolated enum CSVRowQueryEngine {
    public struct Configuration: Sendable, Equatable {
        public let pageRecordCount: Int
        public let maximumValueBytesPerField: Int
        public let maximumRetainedValueBytesPerRecord: Int
        public let sortRunMemoryByteCount: Int
        public let mergeFanIn: Int

        public init(
            pageRecordCount: Int = 4_096,
            maximumValueBytesPerField: Int = 1 << 20,
            maximumRetainedValueBytesPerRecord: Int = 4 << 20,
            sortRunMemoryByteCount: Int = 16 << 20,
            mergeFanIn: Int = 16
        ) {
            self.pageRecordCount = min(4_096, max(1, pageRecordCount))
            self.maximumValueBytesPerField = max(0, maximumValueBytesPerField)
            self.maximumRetainedValueBytesPerRecord = max(
                0,
                maximumRetainedValueBytesPerRecord
            )
            self.sortRunMemoryByteCount = max(64 << 10, sortRunMemoryByteCount)
            self.mergeFanIn = min(64, max(2, mergeFanIn))
        }
    }

    public static func execute(
        snapshot: DocumentSnapshot,
        index: CSVRowIndex,
        query: CSVRowQuery,
        configuration: Configuration = .init(),
        cancellation: CSVRowIndex.CancellationCheck? = nil,
        progress: ((CSVQueryProgress) -> Void)? = nil
    ) throws -> CSVRowMap {
        guard query.firstRecord >= 0 else {
            throw CSVDataOperationError.invalidRecord(query.firstRecord)
        }
        for filter in query.filters where filter.column < 0 {
            throw CSVDataOperationError.invalidColumn(filter.column)
        }
        for descriptor in query.sortDescriptors where descriptor.column < 0 {
            throw CSVDataOperationError.invalidColumn(descriptor.column)
        }
        if cancellation?() == true { throw CancellationError() }

        let filterGroups = compileCSVColumnFilterGroups(query.filters)
        let columns = Set(
            filterGroups.map(\.column) + query.sortDescriptors.map(\.column)
        )
        let directStore = try CSVTemporaryOrdinalStore()
        var sortEntries: [CSVSortEntry] = []
        var sortEntryBytes = 0
        // Leveled external-sort compaction keeps the number of live temporary
        // descriptors bounded. Holding every initial run until the source scan
        // finishes can exhaust RLIMIT_NOFILE long before memory is pressured on
        // multi-gigabyte CSVs with long keys.
        var sortRunLevels: [[CSVTemporarySortRun]] = []
        var scanned: Int64 = 0
        var matched: Int64 = 0
        var pendingMatches: [Int64] = []
        pendingMatches.reserveCapacity(configuration.pageRecordCount)

        func report() {
            let indexProgress = index.progress
            progress?(CSVQueryProgress(
                indexedFractionCompleted: indexProgress.fractionCompleted,
                scannedRecordCount: scanned,
                matchedRecordCount: matched,
                totalRecordCount: indexProgress.totalRecordCount
            ))
        }

        func consume(record: Int64, selected: CSVSelectedFields) throws {
            if cancellation?() == true { throw CancellationError() }
            var matches = true
            for group in filterGroups {
                let field = selected.fields[group.column]
                if field?.wasTruncated == true {
                    throw CSVDataOperationError.queryValueTooLarge(
                        record: record,
                        column: group.column,
                        limit: configuration.maximumValueBytesPerField
                    )
                }
                if !group.matches(field?.value ?? "") {
                    matches = false
                    break
                }
            }
            scanned += 1
            guard matches else { return }

            if query.sortDescriptors.isEmpty {
                pendingMatches.append(record)
            } else {
                let entry = try makeSortEntry(
                    record: record,
                    selected: selected,
                    descriptors: query.sortDescriptors,
                    exactValueLimit: configuration.maximumValueBytesPerField
                )
                let estimatedBytes = entry.estimatedResidentByteCount
                let projected = sortEntryBytes.addingReportingOverflow(estimatedBytes)
                if !sortEntries.isEmpty,
                   projected.overflow
                    || projected.partialValue > configuration.sortRunMemoryByteCount {
                    let run = try spillSortedRun(
                        &sortEntries,
                        descriptors: query.sortDescriptors
                    )
                    try retainCompactedSortRun(
                        run,
                        levels: &sortRunLevels,
                        descriptors: query.sortDescriptors,
                        fanIn: configuration.mergeFanIn,
                        cancellation: cancellation
                    )
                    sortEntryBytes = 0
                }
                sortEntries.append(entry)
                let next = sortEntryBytes.addingReportingOverflow(estimatedBytes)
                sortEntryBytes = next.overflow ? Int.max : next.partialValue
            }
            matched += 1
        }

        func flushDirectMatches() throws {
            guard query.sortDescriptors.isEmpty, !pendingMatches.isEmpty else { return }
            try directStore.append(pendingMatches)
            pendingMatches.removeAll(keepingCapacity: true)
        }

        report()
        if index.progress.isComplete {
            _ = try CSVProjectedRecordScanner.scan(
                snapshot: snapshot,
                index: index,
                firstRecord: query.firstRecord,
                columns: columns,
                maximumValueBytesPerField: configuration.maximumValueBytesPerField,
                maximumRetainedValueBytes: configuration.maximumRetainedValueBytesPerRecord,
                cancellation: cancellation,
                consume: { record, selected in
                    try consume(record: record, selected: selected)
                    if scanned.isMultiple(of: Int64(configuration.pageRecordCount)) {
                        try flushDirectMatches()
                        report()
                    }
                    return true
                }
            )
        } else {
            var nextRecord = query.firstRecord
            while true {
                if cancellation?() == true { throw CancellationError() }
                let locations = try index.recordLocations(
                    startingAt: nextRecord,
                    limit: configuration.pageRecordCount,
                    cancellation: cancellation
                )
                guard !locations.isEmpty else { break }

                for location in locations {
                    if cancellation?() == true { throw CancellationError() }
                    let selected: CSVSelectedFields
                    if columns.isEmpty {
                        selected = CSVSelectedFields(fieldCount: 0, fields: [:])
                    } else {
                        selected = try CSVRecordParser.selectedFields(
                            snapshot: snapshot,
                            location: location,
                            columns: columns,
                            delimiter: index.delimiter,
                            maximumValueBytesPerField: configuration.maximumValueBytesPerField,
                            maximumRetainedValueBytes: configuration.maximumRetainedValueBytesPerRecord,
                            cancellation: cancellation
                        )
                    }
                    try consume(record: location.record, selected: selected)
                }
                try flushDirectMatches()
                nextRecord = locations[locations.count - 1].record + 1
                report()
                if locations.count < configuration.pageRecordCount, index.progress.isComplete {
                    break
                }
            }
        }
        try flushDirectMatches()
        report()
        if query.sortDescriptors.isEmpty {
            return try CSVRowMap(store: directStore)
        }
        if !sortEntries.isEmpty {
            let run = try spillSortedRun(
                &sortEntries,
                descriptors: query.sortDescriptors
            )
            try retainCompactedSortRun(
                run,
                levels: &sortRunLevels,
                descriptors: query.sortDescriptors,
                fanIn: configuration.mergeFanIn,
                cancellation: cancellation
            )
        }
        let sortRuns = sortRunLevels.flatMap { $0 }
        let sortedStore = try mergeSortedRuns(
            sortRuns,
            snapshot: snapshot,
            index: index,
            descriptors: query.sortDescriptors,
            configuration: configuration,
            cancellation: cancellation
        )
        return try CSVRowMap(store: sortedStore)
    }

    private static func makeSortEntry(
        record: Int64,
        selected: CSVSelectedFields,
        descriptors: [CSVSortDescriptor],
        exactValueLimit: Int
    ) throws -> CSVSortEntry {
        var values: [String] = []
        values.reserveCapacity(descriptors.count)
        for descriptor in descriptors {
            let field = selected.fields[descriptor.column]
            if field?.wasTruncated == true {
                throw CSVDataOperationError.queryValueTooLarge(
                    record: record,
                    column: descriptor.column,
                    limit: exactValueLimit
                )
            }
            values.append(field?.value ?? "")
        }
        return CSVSortEntry(record: record, values: values)
    }

    private static func spillSortedRun(
        _ entries: inout [CSVSortEntry],
        descriptors: [CSVSortDescriptor]
    ) throws -> CSVTemporarySortRun {
        entries.sort { compare($0, $1, descriptors: descriptors) == .orderedAscending }
        let store = try CSVTemporarySortRun()
        try store.append(entries)
        try store.finishWriting()
        entries.removeAll(keepingCapacity: true)
        return store
    }

    /// Adds one sorted run to a leveled fan-in accumulator. A level retains at
    /// most `fanIn - 1` runs; the next run merges that complete group and
    /// promotes one output to the following level. Live file descriptors are
    /// therefore O(fanIn × log(run count)) instead of O(run count), without the
    /// quadratic I/O of repeatedly merging the entire accumulated result.
    private static func retainCompactedSortRun(
        _ run: CSVTemporarySortRun,
        levels: inout [[CSVTemporarySortRun]],
        descriptors: [CSVSortDescriptor],
        fanIn: Int,
        cancellation: CSVRowIndex.CancellationCheck?
    ) throws {
        var promoted = run
        var level = 0
        while true {
            if cancellation?() == true { throw CancellationError() }
            if level == levels.count { levels.append([]) }
            levels[level].append(promoted)
            guard levels[level].count >= fanIn else { return }

            let group = levels[level]
            levels[level].removeAll(keepingCapacity: true)
            promoted = try mergeRunGroup(
                group,
                descriptors: descriptors,
                cancellation: cancellation
            )
            level += 1
        }
    }

    private static func mergeSortedRuns(
        _ initialRuns: [CSVTemporarySortRun],
        snapshot _: DocumentSnapshot,
        index _: CSVRowIndex,
        descriptors: [CSVSortDescriptor],
        configuration: Configuration,
        cancellation: CSVRowIndex.CancellationCheck?
    ) throws -> CSVTemporaryOrdinalStore {
        guard !initialRuns.isEmpty else {
            return try CSVTemporaryOrdinalStore()
        }
        var runs = initialRuns
        while runs.count > 1 {
            var merged: [CSVTemporarySortRun] = []
            merged.reserveCapacity((runs.count + configuration.mergeFanIn - 1) / configuration.mergeFanIn)
            var start = 0
            while start < runs.count {
                if cancellation?() == true { throw CancellationError() }
                let end = min(runs.count, start + configuration.mergeFanIn)
                if end - start == 1 {
                    merged.append(runs[start])
                } else {
                    merged.append(try mergeRunGroup(
                        Array(runs[start..<end]),
                        descriptors: descriptors,
                        cancellation: cancellation
                    ))
                }
                start = end
            }
            runs = merged
        }
        let output = try CSVTemporaryOrdinalStore()
        var offset: Int64 = 0
        var records: [Int64] = []
        records.reserveCapacity(4_096)
        while offset < runs[0].byteCount {
            if cancellation?() == true { throw CancellationError() }
            let decoded = try runs[0].entry(at: offset)
            records.append(decoded.entry.record)
            offset = decoded.nextOffset
            if records.count == 4_096 {
                try output.append(records)
                records.removeAll(keepingCapacity: true)
            }
        }
        try output.append(records)
        return output
    }

    private static func mergeRunGroup(
        _ runs: [CSVTemporarySortRun],
        descriptors: [CSVSortDescriptor],
        cancellation: CSVRowIndex.CancellationCheck?
    ) throws -> CSVTemporarySortRun {
        var cursors: [CSVSortRunCursor] = []
        cursors.reserveCapacity(runs.count)
        for run in runs where run.count > 0 {
            let decoded = try run.entry(at: 0)
            cursors.append(CSVSortRunCursor(
                store: run,
                nextOffset: decoded.nextOffset,
                entry: decoded.entry
            ))
        }

        let output = try CSVTemporarySortRun()
        var buffer: [CSVSortEntry] = []
        buffer.reserveCapacity(64)
        var bufferBytes = 0
        while !cursors.isEmpty {
            if cancellation?() == true { throw CancellationError() }
            var best = 0
            for candidate in cursors.indices.dropFirst() where compare(
                cursors[candidate].entry,
                cursors[best].entry,
                descriptors: descriptors
            ) == .orderedAscending {
                best = candidate
            }
            let entry = cursors[best].entry
            let projected = bufferBytes.addingReportingOverflow(entry.estimatedResidentByteCount)
            if !buffer.isEmpty, projected.overflow || projected.partialValue > (64 << 10) {
                try output.append(buffer)
                buffer.removeAll(keepingCapacity: true)
                bufferBytes = 0
            }
            buffer.append(entry)
            let nextBytes = bufferBytes.addingReportingOverflow(entry.estimatedResidentByteCount)
            bufferBytes = nextBytes.overflow ? Int.max : nextBytes.partialValue
            if cursors[best].nextOffset >= cursors[best].store.byteCount {
                cursors.remove(at: best)
            } else {
                let decoded = try cursors[best].store.entry(at: cursors[best].nextOffset)
                cursors[best].entry = decoded.entry
                cursors[best].nextOffset = decoded.nextOffset
            }
        }
        try output.append(buffer)
        try output.finishWriting()
        return output
    }

    private static func compare(
        _ lhs: CSVSortEntry,
        _ rhs: CSVSortEntry,
        descriptors: [CSVSortDescriptor]
    ) -> ComparisonResult {
        for (index, descriptor) in descriptors.enumerated() {
            let result = compareValue(
                lhs.values[index],
                rhs.values[index],
                descriptor: descriptor
            )
            if result != .orderedSame { return result }
        }
        if lhs.record < rhs.record { return .orderedAscending }
        if lhs.record > rhs.record { return .orderedDescending }
        return .orderedSame
    }

    /// A deterministic total order shared by in-memory runs and merge passes.
    /// Empty strings are always last. Automatic/number mode put finite numeric
    /// values before text ascending; direction reversal puts them after text.
    private static func compareValue(
        _ lhs: String,
        _ rhs: String,
        descriptor: CSVSortDescriptor
    ) -> ComparisonResult {
        if lhs.isEmpty || rhs.isEmpty {
            if lhs.isEmpty, rhs.isEmpty { return .orderedSame }
            return lhs.isEmpty ? .orderedDescending : .orderedAscending
        }

        let base: ComparisonResult
        switch descriptor.valueKind {
        case .text:
            var options: String.CompareOptions = [.numeric]
            if !descriptor.caseSensitive { options.insert(.caseInsensitive) }
            base = lhs.compare(rhs, options: options)
        case .automatic, .number:
            let lhsNumber = finiteNumber(lhs)
            let rhsNumber = finiteNumber(rhs)
            switch (lhsNumber, rhsNumber) {
            case let (left?, right?):
                if left < right { base = .orderedAscending }
                else if left > right { base = .orderedDescending }
                else { base = .orderedSame }
            case (_?, nil):
                base = .orderedAscending
            case (nil, _?):
                base = .orderedDescending
            case (nil, nil):
                var options: String.CompareOptions = [.numeric]
                if !descriptor.caseSensitive { options.insert(.caseInsensitive) }
                base = lhs.compare(rhs, options: options)
            }
        }
        guard descriptor.order == .descending else { return base }
        switch base {
        case .orderedAscending: return .orderedDescending
        case .orderedDescending: return .orderedAscending
        case .orderedSame: return .orderedSame
        }
    }

    private static func finiteNumber(_ value: String) -> Double? {
        guard let number = Double(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              number.isFinite else { return nil }
        return number
    }
}

public nonisolated struct CSVUniqueValuesProgress: Sendable, Equatable {
    public let indexedFractionCompleted: Double
    public let scannedRecordCount: Int64
    /// Records that matched every supplied filter on other columns.
    public let eligibleRecordCount: Int64
    public let uniqueValueCount: Int
    /// Candidate records at or after `firstRecord`, once the sparse index has
    /// reached EOF. This remains nil while the total is not yet known.
    public let totalRecordCount: Int64?

    public var scannedFractionCompleted: Double? {
        guard let totalRecordCount, totalRecordCount > 0 else { return nil }
        return min(1, Double(scannedRecordCount) / Double(totalRecordCount))
    }
}

public nonisolated enum CSVUniqueValuesTruncationReason: Sendable, Equatable {
    /// More distinct values exist than the picker is configured to retain.
    case uniqueValueCountLimit
    /// Retaining another distinct string would exceed the aggregate heap cap.
    case retainedValueBytesLimit
    /// A logical value is too large to be an exact, selectable picker item.
    case valueByteLimit
}

public nonisolated struct CSVUniqueValuesResult: Sendable, Equatable {
    public let column: Int
    /// Exact, unmodified logical CSV values in deterministic display order.
    /// The empty string is retained as an ordinary selectable value.
    public let values: [String]
    public let scannedRecordCount: Int64
    public let eligibleRecordCount: Int64
    /// Candidate records at or after `firstRecord`, if EOF was observed.
    public let totalRecordCount: Int64?
    /// True only when every candidate record was inspected and `values`
    /// contains the complete distinct set.
    public let isCompleteDataset: Bool
    /// Explains why discovery returned an explicitly incomplete value set.
    /// Every returned string is exact; an overlong partial preview is never
    /// exposed as a selectable value.
    public let truncationReason: CSVUniqueValuesTruncationReason?
    public let maximumUniqueValueCount: Int
    public let maximumRetainedValueBytes: Int

    public var isTruncated: Bool { truncationReason != nil }
}

/// Exact unique-value discovery for a CSV filter picker. Heap use is bounded
/// by both a value-count cap and an aggregate byte cap: discovery stops as soon
/// as it proves the column has more data than the UI can safely show.
/// No row-map or temporary file is created by this operation.
public nonisolated enum CSVUniqueValueProvider {
    public struct Configuration: Sendable, Equatable {
        public let pageRecordCount: Int
        public let maximumUniqueValueCount: Int
        public let maximumValueBytes: Int
        public let maximumRetainedValueBytes: Int
        public let maximumFilterValueBytesPerField: Int
        public let maximumRetainedValueBytesPerRecord: Int

        public init(
            pageRecordCount: Int = 4_096,
            maximumUniqueValueCount: Int = 500,
            maximumValueBytes: Int = 64 << 10,
            maximumRetainedValueBytes: Int = 4 << 20,
            maximumFilterValueBytesPerField: Int = 1 << 20,
            maximumRetainedValueBytesPerRecord: Int = 4 << 20
        ) {
            self.pageRecordCount = min(4_096, max(1, pageRecordCount))
            self.maximumUniqueValueCount = min(10_000, max(1, maximumUniqueValueCount))
            self.maximumValueBytes = min(1 << 20, max(0, maximumValueBytes))
            self.maximumRetainedValueBytes = min(64 << 20, max(0, maximumRetainedValueBytes))
            self.maximumFilterValueBytesPerField = min(
                4 << 20,
                max(0, maximumFilterValueBytesPerField)
            )
            self.maximumRetainedValueBytesPerRecord = min(
                64 << 20,
                max(0, maximumRetainedValueBytesPerRecord)
            )
        }
    }

    /// Runs discovery away from the caller's actor. Cancelling the surrounding
    /// Task is observed between records and while parsing unusually long rows.
    public static func values(
        snapshot: DocumentSnapshot,
        index: CSVRowIndex,
        column: Int,
        firstRecord: Int64 = 0,
        baseFilters: [CSVColumnFilter] = [],
        configuration: Configuration = .init(),
        progress: (@Sendable (CSVUniqueValuesProgress) -> Void)? = nil
    ) async throws -> CSVUniqueValuesResult {
        let worker = Task.detached(priority: .userInitiated) {
            try collect(
                snapshot: snapshot,
                index: index,
                column: column,
                firstRecord: firstRecord,
                baseFilters: baseFilters,
                configuration: configuration,
                cancellation: { Task.isCancelled },
                progress: progress
            )
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// Synchronous engine for deterministic tests and callers already running
    /// on a background executor. Cancellation never returns a partial result.
    public static func collect(
        snapshot: DocumentSnapshot,
        index: CSVRowIndex,
        column: Int,
        firstRecord: Int64 = 0,
        baseFilters: [CSVColumnFilter] = [],
        configuration: Configuration = .init(),
        cancellation: CSVRowIndex.CancellationCheck? = nil,
        progress: (@Sendable (CSVUniqueValuesProgress) -> Void)? = nil
    ) throws -> CSVUniqueValuesResult {
        guard column >= 0 else { throw CSVDataOperationError.invalidColumn(column) }
        guard firstRecord >= 0 else { throw CSVDataOperationError.invalidRecord(firstRecord) }
        for filter in baseFilters where filter.column < 0 {
            throw CSVDataOperationError.invalidColumn(filter.column)
        }
        if cancellation?() == true { throw CancellationError() }

        // Faceting intentionally ignores the target column's own committed
        // filter, while honoring all other columns. This lets a reopened chip
        // offer alternatives instead of only its current selection.
        let filterGroups = compileCSVColumnFilterGroups(
            baseFilters.filter { $0.column != column }
        )
        let selectedColumns = Set([column] + filterGroups.map(\.column))
        var uniqueValues = Set<String>()
        uniqueValues.reserveCapacity(configuration.maximumUniqueValueCount)
        var retainedUniqueValueBytes = 0
        var nextRecord = firstRecord
        var scannedRecordCount: Int64 = 0
        var eligibleRecordCount: Int64 = 0
        var lastProgressUpdate: ContinuousClock.Instant?

        func candidateTotal(_ indexProgress: CSVRowIndex.Progress) -> Int64? {
            guard let sourceTotal = indexProgress.totalRecordCount else { return nil }
            return max(0, sourceTotal - firstRecord)
        }

        /// Multi-gigabyte, low-cardinality columns may require tens of
        /// thousands of pages. Coalescing intermediate reports prevents those
        /// pages from becoming tens of thousands of queued main-thread blocks.
        /// Initial and terminal states are always delivered exactly.
        func report(force: Bool = false) {
            guard progress != nil else { return }
            let now = ContinuousClock.now
            if !force,
               let lastProgressUpdate,
               lastProgressUpdate.duration(to: now) < .milliseconds(125) {
                return
            }
            lastProgressUpdate = now
            let indexProgress = index.progress
            progress?(CSVUniqueValuesProgress(
                indexedFractionCompleted: indexProgress.fractionCompleted,
                scannedRecordCount: scannedRecordCount,
                eligibleRecordCount: eligibleRecordCount,
                uniqueValueCount: uniqueValues.count,
                totalRecordCount: candidateTotal(indexProgress)
            ))
        }

        func makeResult(
            isCompleteDataset: Bool,
            truncationReason: CSVUniqueValuesTruncationReason?
        ) -> CSVUniqueValuesResult {
            CSVUniqueValuesResult(
                column: column,
                values: uniqueValues.sorted(by: uniqueValueDisplayOrder),
                scannedRecordCount: scannedRecordCount,
                eligibleRecordCount: eligibleRecordCount,
                totalRecordCount: candidateTotal(index.progress),
                isCompleteDataset: isCompleteDataset,
                truncationReason: truncationReason,
                maximumUniqueValueCount: configuration.maximumUniqueValueCount,
                maximumRetainedValueBytes: configuration.maximumRetainedValueBytes
            )
        }

        func consume(
            record: Int64,
            selected: CSVSelectedFields
        ) throws -> CSVUniqueValuesTruncationReason? {
            if cancellation?() == true { throw CancellationError() }
            scannedRecordCount += 1
            nextRecord = record + 1

            for group in filterGroups {
                let field = selected.fields[group.column]
                if field?.wasTruncated == true
                    || (field?.value.utf8.count ?? 0)
                        > configuration.maximumFilterValueBytesPerField {
                    throw CSVDataOperationError.queryValueTooLarge(
                        record: record,
                        column: group.column,
                        limit: configuration.maximumFilterValueBytesPerField
                    )
                }
                if !group.matches(field?.value ?? "") { return nil }
            }

            eligibleRecordCount += 1
            let field = selected.fields[column]
            guard field?.wasTruncated != true else { return .valueByteLimit }
            let value = field?.value ?? ""
            let valueByteCount = value.utf8.count
            guard valueByteCount <= configuration.maximumValueBytes else {
                return .valueByteLimit
            }
            guard !uniqueValues.contains(value) else { return nil }
            guard uniqueValues.count < configuration.maximumUniqueValueCount else {
                return .uniqueValueCountLimit
            }
            let projectedBytes = retainedUniqueValueBytes.addingReportingOverflow(valueByteCount)
            guard !projectedBytes.overflow,
                  projectedBytes.partialValue <= configuration.maximumRetainedValueBytes else {
                return .retainedValueBytesLimit
            }
            uniqueValues.insert(value)
            retainedUniqueValueBytes = projectedBytes.partialValue
            return nil
        }

        report(force: true)
        if index.progress.isComplete {
            var truncationReason: CSVUniqueValuesTruncationReason?
            _ = try CSVProjectedRecordScanner.scan(
                snapshot: snapshot,
                index: index,
                firstRecord: firstRecord,
                columns: selectedColumns,
                maximumValueBytesPerField: max(
                    configuration.maximumValueBytes,
                    configuration.maximumFilterValueBytesPerField
                ),
                maximumRetainedValueBytes: configuration.maximumRetainedValueBytesPerRecord,
                cancellation: cancellation,
                consume: { record, selected in
                    truncationReason = try consume(record: record, selected: selected)
                    if truncationReason != nil {
                        report(force: true)
                        return false
                    }
                    if scannedRecordCount.isMultiple(of: Int64(configuration.pageRecordCount)) {
                        report()
                    }
                    return true
                }
            )
            if let truncationReason {
                return makeResult(
                    isCompleteDataset: false,
                    truncationReason: truncationReason
                )
            }
        } else {
            while true {
                if cancellation?() == true { throw CancellationError() }
                let locations = try index.recordLocations(
                    startingAt: nextRecord,
                    limit: configuration.pageRecordCount,
                    cancellation: cancellation
                )
                guard !locations.isEmpty else { break }

                for location in locations {
                    if cancellation?() == true { throw CancellationError() }
                    let selected = try CSVRecordParser.selectedFields(
                        snapshot: snapshot,
                        location: location,
                        columns: selectedColumns,
                        delimiter: index.delimiter,
                        maximumValueBytesPerField: max(
                            configuration.maximumValueBytes,
                            configuration.maximumFilterValueBytesPerField
                        ),
                        maximumRetainedValueBytes: configuration.maximumRetainedValueBytesPerRecord,
                        cancellation: cancellation
                    )
                    if let truncationReason = try consume(
                        record: location.record,
                        selected: selected
                    ) {
                        report(force: true)
                        return makeResult(
                            isCompleteDataset: false,
                            truncationReason: truncationReason
                        )
                    }
                }
                report()
                if locations.count < configuration.pageRecordCount, index.progress.isComplete {
                    break
                }
            }
        }

        let indexProgress = index.progress
        let isComplete = indexProgress.isComplete
            && nextRecord >= (indexProgress.totalRecordCount ?? nextRecord)
        report(force: true)
        return makeResult(isCompleteDataset: isComplete, truncationReason: nil)
    }

    /// POSIX-locale, case-insensitive/numeric ordering is pleasant for a value
    /// picker and stable across machines. A literal comparison breaks folds
    /// such as `A`/`a` deterministically. Empty sorts first.
    private static func uniqueValueDisplayOrder(_ lhs: String, _ rhs: String) -> Bool {
        if lhs.isEmpty || rhs.isEmpty {
            if lhs.isEmpty, rhs.isEmpty { return false }
            return lhs.isEmpty
        }
        let comparison = lhs.compare(
            rhs,
            options: [.caseInsensitive, .numeric],
            range: nil,
            locale: Locale(identifier: "en_US_POSIX")
        )
        if comparison != .orderedSame { return comparison == .orderedAscending }
        return lhs < rhs
    }
}

public nonisolated enum CSVInferredColumnKind: String, Sendable, Equatable {
    case empty
    case boolean
    case integer
    case decimal
    case text
    case mixed
}

public nonisolated enum CSVProfileSamplingStrategy: Sendable, Equatable {
    case complete
    case prefix
    case stratified
}

public nonisolated struct CSVTopValue: Sendable, Equatable {
    public let value: String
    public let estimatedCount: Int64
    /// Space-Saving guarantees the true count is no lower than
    /// `estimatedCount - maximumError` within the scanned sample.
    public let maximumError: Int64
}

public nonisolated struct CSVColumnProfile: Sendable, Equatable {
    public let column: Int
    public let sampledRecordCount: Int64
    public let totalRecordCount: Int64?
    public let isCompleteDataset: Bool
    public let samplingStrategy: CSVProfileSamplingStrategy
    public let missingValueCount: Int64
    public let emptyValueCount: Int64
    public let booleanValueCount: Int64
    public let integerValueCount: Int64
    public let decimalValueCount: Int64
    public let textValueCount: Int64
    public let truncatedValueCount: Int64
    public let inferredKind: CSVInferredColumnKind
    public let approximateDistinctValueCount: Int64
    public let minimumNumericValue: Double?
    public let maximumNumericValue: Double?
    public let meanNumericValue: Double?
    public let minimumUTF8Length: Int?
    public let maximumUTF8Length: Int?
    public let topValues: [CSVTopValue]
}

public nonisolated enum CSVColumnProfiler {
    public struct Configuration: Sendable, Equatable {
        public let pageRecordCount: Int
        public let maximumRecords: Int64
        public let maximumPreviewBytesPerValue: Int
        public let topValueCapacity: Int

        public init(
            pageRecordCount: Int = 4_096,
            maximumRecords: Int64 = 50_000,
            maximumPreviewBytesPerValue: Int = 4_096,
            topValueCapacity: Int = 12
        ) {
            self.pageRecordCount = min(4_096, max(1, pageRecordCount))
            self.maximumRecords = max(1, maximumRecords)
            self.maximumPreviewBytesPerValue = max(0, maximumPreviewBytesPerValue)
            self.topValueCapacity = min(64, max(1, topValueCapacity))
        }
    }

    public static func profile(
        snapshot: DocumentSnapshot,
        index: CSVRowIndex,
        column: Int,
        firstRecord: Int64 = 0,
        configuration: Configuration = .init(),
        cancellation: CSVRowIndex.CancellationCheck? = nil,
        progress: ((CSVQueryProgress) -> Void)? = nil
    ) throws -> CSVColumnProfile {
        guard column >= 0 else { throw CSVDataOperationError.invalidColumn(column) }
        guard firstRecord >= 0 else { throw CSVDataOperationError.invalidRecord(firstRecord) }
        var accumulator = CSVProfileAccumulator(
            column: column,
            topValueCapacity: configuration.topValueCapacity
        )
        var nextRecord = firstRecord

        func consume(_ locations: [CSVRowIndex.RecordLocation]) throws {
            for location in locations {
                if cancellation?() == true { throw CancellationError() }
                let selected = try CSVRecordParser.selectedFields(
                    snapshot: snapshot,
                    location: location,
                    columns: [column],
                    delimiter: index.delimiter,
                    maximumValueBytesPerField: configuration.maximumPreviewBytesPerValue,
                    maximumRetainedValueBytes: configuration.maximumPreviewBytesPerValue,
                    cancellation: cancellation
                )
                accumulator.add(selected.fields[column])
            }
            let indexProgress = index.progress
            progress?(CSVQueryProgress(
                indexedFractionCompleted: indexProgress.fractionCompleted,
                scannedRecordCount: accumulator.sampledRecordCount,
                matchedRecordCount: accumulator.sampledRecordCount,
                totalRecordCount: indexProgress.totalRecordCount
            ))
        }

        let initialProgress = index.progress
        if let total = initialProgress.totalRecordCount,
           total > firstRecord,
           total - firstRecord > configuration.maximumRecords {
            // At most 128 contiguous windows keep sparse-index seeks bounded
            // while making grouped and time-series CSVs representative.
            let available = total - firstRecord
            let windowCount = Int(min(128, configuration.maximumRecords))
            let baseWindowSize = configuration.maximumRecords / Int64(windowCount)
            let extraWindows = configuration.maximumRecords % Int64(windowCount)
            for window in 0..<windowCount {
                if cancellation?() == true { throw CancellationError() }
                let lower = firstRecord
                    + available * Int64(window) / Int64(windowCount)
                let upper = firstRecord
                    + available * Int64(window + 1) / Int64(windowCount)
                let desired = baseWindowSize + (Int64(window) < extraWindows ? 1 : 0)
                let count = min(desired, upper - lower)
                let start = lower + (upper - lower - count) / 2
                let locations = try index.recordLocations(
                    startingAt: start,
                    limit: Int(clamping: count),
                    cancellation: cancellation
                )
                try consume(locations)
            }
            return accumulator.result(
                totalRecordCount: total,
                isCompleteDataset: false,
                samplingStrategy: .stratified
            )
        }

        while accumulator.sampledRecordCount < configuration.maximumRecords {
            if cancellation?() == true { throw CancellationError() }
            let remaining = configuration.maximumRecords - accumulator.sampledRecordCount
            let pageSize = min(configuration.pageRecordCount, Int(clamping: remaining))
            let locations = try index.recordLocations(
                startingAt: nextRecord,
                limit: pageSize,
                cancellation: cancellation
            )
            guard !locations.isEmpty else { break }
            try consume(locations)
            nextRecord = locations[locations.count - 1].record + 1
            if locations.count < pageSize, index.progress.isComplete { break }
        }

        let indexProgress = index.progress
        let complete = indexProgress.isComplete
            && nextRecord >= (indexProgress.totalRecordCount ?? nextRecord)
        return accumulator.result(
            totalRecordCount: indexProgress.totalRecordCount,
            isCompleteDataset: complete,
            samplingStrategy: complete ? .complete : .prefix
        )
    }
}

public nonisolated enum CSVLineEnding: Sendable, Equatable {
    case lineFeed
    case carriageReturnLineFeed
    case carriageReturn

    fileprivate var bytes: Data {
        switch self {
        case .lineFeed: return Data([0x0A])
        case .carriageReturnLineFeed: return Data([0x0D, 0x0A])
        case .carriageReturn: return Data([0x0D])
        }
    }
}

private nonisolated func csvContentStartPreservingUTF8BOM(
    snapshot: DocumentSnapshot,
    location: CSVRowIndex.RecordLocation
) throws -> Int64 {
    guard location.record == 0,
          location.contentRange.lowerBound == 0,
          snapshot.byteCount >= 3,
          try snapshot.data(in: 0..<3) == Data([0xEF, 0xBB, 0xBF]) else {
        return location.contentRange.lowerBound
    }
    return 3
}

public nonisolated enum CSVRowMutationPlanner {
    /// Plans one source-coordinate insertion. Inserting in the middle includes
    /// one inferred record terminator; appending preserves whether the source
    /// ended with a terminator.
    public static func insert(
        values: [String],
        beforeRecord: Int64,
        snapshot: DocumentSnapshot,
        index: CSVRowIndex,
        delimiter: UInt8 = 0x2C,
        lineEnding requestedLineEnding: CSVLineEnding? = nil
    ) throws -> ByteEdit {
        guard beforeRecord >= 0 else {
            throw CSVDataOperationError.invalidRecord(beforeRecord)
        }
        let lineEnding = try requestedLineEnding ?? inferredLineEnding(
            snapshot: snapshot,
            index: index
        )
        let encoded = CSVRecordParser.encodedRecord(values, delimiter: delimiter)
        if let location = try index.recordLocation(forRecord: beforeRecord) {
            var replacement = encoded
            replacement.append(lineEnding.bytes)
            let insertionOffset = try csvContentStartPreservingUTF8BOM(
                snapshot: snapshot,
                location: location
            )
            return ByteEdit(
                byteRange: insertionOffset..<insertionOffset,
                replacement: replacement
            )
        }

        let completed = try index.scanToEnd()
        guard completed.progress.totalRecordCount == beforeRecord else {
            throw CSVDataOperationError.invalidRecord(beforeRecord)
        }
        guard snapshot.byteCount > 0 else {
            return ByteEdit(byteRange: 0..<0, replacement: encoded)
        }
        let last = try snapshot.byte(at: snapshot.byteCount - 1)
        var replacement = Data()
        if last == 0x0A || last == 0x0D {
            replacement.append(encoded)
            replacement.append(lineEnding.bytes)
        } else {
            replacement.append(lineEnding.bytes)
            replacement.append(encoded)
        }
        return ByteEdit(
            byteRange: snapshot.byteCount..<snapshot.byteCount,
            replacement: replacement
        )
    }

    public static func delete(
        record: Int64,
        snapshot: DocumentSnapshot,
        index: CSVRowIndex
    ) throws -> ByteEdit {
        guard record >= 0,
              let location = try index.recordLocation(forRecord: record) else {
            throw CSVDataOperationError.invalidRecord(record)
        }
        let deletionStart = try csvContentStartPreservingUTF8BOM(
            snapshot: snapshot,
            location: location
        )
        return ByteEdit(
            byteRange: deletionStart..<location.completeRange.upperBound,
            replacement: Data()
        )
    }

    private static func inferredLineEnding(
        snapshot: DocumentSnapshot,
        index: CSVRowIndex
    ) throws -> CSVLineEnding {
        let locations = try index.recordLocations(startingAt: 0, limit: 32)
        for location in locations {
            let terminator = location.contentRange.upperBound..<location.completeRange.upperBound
            guard !terminator.isEmpty else { continue }
            let bytes = try snapshot.data(in: terminator)
            if bytes == Data([0x0D, 0x0A]) { return .carriageReturnLineFeed }
            if bytes == Data([0x0D]) { return .carriageReturn }
            if bytes == Data([0x0A]) { return .lineFeed }
        }
        return .lineFeed
    }
}

public nonisolated struct CSVColumnInsertion: Sendable, Equatable {
    public let column: Int
    public let headerRecord: Int64?
    public let headerValue: String
    public let defaultValue: String

    public init(
        column: Int,
        headerRecord: Int64? = nil,
        headerValue: String = "",
        defaultValue: String = ""
    ) {
        self.column = column
        self.headerRecord = headerRecord
        self.headerValue = headerValue
        self.defaultValue = defaultValue
    }
}

public nonisolated enum CSVColumnMutation: Sendable, Equatable {
    case insert(CSVColumnInsertion)
    case delete(column: Int)

    fileprivate var column: Int {
        switch self {
        case let .insert(insertion): return insertion.column
        case let .delete(column): return column
        }
    }
}

public nonisolated enum CSVColumnMutationPlanner {
    /// Plans the exact edit for one record. A missing deleted field returns nil,
    /// leaving that ragged row byte-identical. Insertions pad missing trailing
    /// fields with delimiters so the new value lands at the requested ordinal.
    public static func byteEdit(
        for mutation: CSVColumnMutation,
        snapshot: DocumentSnapshot,
        location: CSVRowIndex.RecordLocation,
        delimiter: UInt8 = 0x2C,
        cancellation: CSVRowIndex.CancellationCheck? = nil
    ) throws -> ByteEdit? {
        guard mutation.column >= 0 else {
            throw CSVDataOperationError.invalidColumn(mutation.column)
        }
        let requested: Set<Int>
        switch mutation {
        case let .insert(insertion):
            requested = [insertion.column]
        case let .delete(column):
            requested = column > 0 ? [column - 1, column] : [column]
        }
        let layout = try CSVRecordParser.selectedFields(
            snapshot: snapshot,
            location: location,
            columns: requested,
            delimiter: delimiter,
            maximumValueBytesPerField: 0,
            maximumRetainedValueBytes: 0,
            cancellation: cancellation
        )

        // A UTF-8 BOM is a file prefix, not part of the first CSV value. The
        // parser deliberately keeps raw byte ranges exact, so protect that
        // prefix when a structural edit targets column zero of record zero.
        // This is common in CSVs exported by Excel.
        let protectedPrefixEnd = mutation.column == 0
            ? try csvContentStartPreservingUTF8BOM(snapshot: snapshot, location: location)
            : location.contentRange.lowerBound

        switch mutation {
        case let .insert(insertion):
            let logicalValue = location.record == insertion.headerRecord
                ? insertion.headerValue
                : insertion.defaultValue
            let value = CSVRecordParser.encodedField(logicalValue, delimiter: delimiter)
            if insertion.column < layout.fieldCount,
               let target = layout.fields[insertion.column] {
                var replacement = value
                replacement.append(delimiter)
                let insertionOffset = insertion.column == 0
                    ? max(target.byteRange.lowerBound, protectedPrefixEnd)
                    : target.byteRange.lowerBound
                return ByteEdit(
                    byteRange: insertionOffset..<insertionOffset,
                    replacement: replacement
                )
            }
            var replacement = Data(
                repeating: delimiter,
                count: insertion.column - layout.fieldCount + 1
            )
            replacement.append(value)
            return ByteEdit(
                byteRange: location.contentRange.upperBound..<location.contentRange.upperBound,
                replacement: replacement
            )

        case let .delete(column):
            guard column < layout.fieldCount,
                  let target = layout.fields[column] else { return nil }
            let range: Range<Int64>
            if layout.fieldCount == 1 {
                range = max(target.byteRange.lowerBound, protectedPrefixEnd)..<target.byteRange.upperBound
            } else if column == 0 {
                range = max(target.byteRange.lowerBound, protectedPrefixEnd)..<(target.byteRange.upperBound + 1)
            } else {
                guard let previous = layout.fields[column - 1] else {
                    throw CSVRowIndex.IndexError.inconsistentCheckpointData
                }
                range = previous.byteRange.upperBound..<target.byteRange.upperBound
            }
            return ByteEdit(byteRange: range, replacement: Data())
        }
    }
}

public nonisolated struct CSVColumnRewriteProgress: Sendable, Equatable {
    public let processedRecordCount: Int64
    public let totalRecordCount: Int64
    public let changedRecordCount: Int64

    public var fractionCompleted: Double {
        guard totalRecordCount > 0 else { return 1 }
        return min(1, Double(processedRecordCount) / Double(totalRecordCount))
    }
}

public nonisolated struct CSVColumnRewriteResult: Sendable, Equatable {
    public let processedRecordCount: Int64
    public let changedRecordCount: Int64
    public let sourceByteCount: Int64
    public let resultByteCount: Int64

    public var didChange: Bool { changedRecordCount > 0 }
}

extension FileBackedPieceTable {
    /// Transactional, bounded-memory whole-column mutation. Every record is
    /// streamed into one secure temporary inode, then installed as one undoable
    /// root only if `snapshot` is still current. No per-row edit collection is
    /// retained, even for CSVs containing billions of rows.
    @discardableResult
    public func applyCSVColumnMutation(
        _ mutation: CSVColumnMutation,
        snapshot: DocumentSnapshot,
        index: CSVRowIndex,
        delimiter: UInt8 = 0x2C,
        cancellation: CSVRowIndex.CancellationCheck? = nil,
        progress: ((CSVColumnRewriteProgress) -> Void)? = nil
    ) throws -> CSVColumnRewriteResult {
        guard mutation.column >= 0 else {
            throw CSVDataOperationError.invalidColumn(mutation.column)
        }
        if cancellation?() == true { throw CancellationError() }
        let scan = try index.scanToEnd(cancellation: cancellation)
        guard scan.stopReason != .cancelled,
              let totalRecords = scan.progress.totalRecordCount else {
            throw CancellationError()
        }

        let output = try CSVTemporaryRewriteOutput()
        var nextRecord: Int64 = 0
        var sourceCursor: Int64 = 0
        var changed: Int64 = 0

        func report() {
            progress?(CSVColumnRewriteProgress(
                processedRecordCount: nextRecord,
                totalRecordCount: totalRecords,
                changedRecordCount: changed
            ))
        }
        report()
        while nextRecord < totalRecords {
            if cancellation?() == true { throw CancellationError() }
            let locations = try index.recordLocations(
                startingAt: nextRecord,
                limit: 512,
                cancellation: cancellation
            )
            guard !locations.isEmpty else {
                throw CSVRowIndex.IndexError.inconsistentCheckpointData
            }
            for location in locations {
                if cancellation?() == true { throw CancellationError() }
                try output.append(
                    snapshot: snapshot,
                    range: sourceCursor..<location.completeRange.lowerBound,
                    cancellation: cancellation
                )
                if let edit = try CSVColumnMutationPlanner.byteEdit(
                    for: mutation,
                    snapshot: snapshot,
                    location: location,
                    delimiter: delimiter,
                    cancellation: cancellation
                ) {
                    try output.append(
                        snapshot: snapshot,
                        range: location.completeRange.lowerBound..<edit.byteRange.lowerBound,
                        cancellation: cancellation
                    )
                    try output.append(edit.replacement, cancellation: cancellation)
                    try output.append(
                        snapshot: snapshot,
                        range: edit.byteRange.upperBound..<location.completeRange.upperBound,
                        cancellation: cancellation
                    )
                    changed += 1
                } else {
                    try output.append(
                        snapshot: snapshot,
                        range: location.completeRange,
                        cancellation: cancellation
                    )
                }
                sourceCursor = location.completeRange.upperBound
                nextRecord = location.record + 1
            }
            report()
        }
        try output.append(
            snapshot: snapshot,
            range: sourceCursor..<snapshot.byteCount,
            cancellation: cancellation
        )
        guard changed > 0 else {
            return CSVColumnRewriteResult(
                processedRecordCount: nextRecord,
                changedRecordCount: 0,
                sourceByteCount: snapshot.byteCount,
                resultByteCount: snapshot.byteCount
            )
        }
        if cancellation?() == true { throw CancellationError() }
        let mapping = try output.finishAndMap()
        if cancellation?() == true { throw CancellationError() }
        try installBulkRewrite(
            mapping,
            replacing: snapshot,
            cancellation: cancellation
        )
        report()
        return CSVColumnRewriteResult(
            processedRecordCount: nextRecord,
            changedRecordCount: changed,
            sourceByteCount: snapshot.byteCount,
            resultByteCount: mapping.byteCount
        )
    }
}

private nonisolated struct CSVSortEntry {
    let record: Int64
    let values: [String]

    var estimatedResidentByteCount: Int {
        values.reduce(32) { partial, value in
            let (next, overflow) = partial.addingReportingOverflow(value.utf8.count + 16)
            return overflow ? Int.max : next
        }
    }
}

private nonisolated struct CSVSortRunCursor {
    let store: CSVTemporarySortRun
    var nextOffset: Int64
    var entry: CSVSortEntry
}

private nonisolated final class CSVTemporaryRewriteOutput {
    private static let bufferByteCount = 256 << 10

    private var descriptor: Int32
    private var path: String?
    private var buffer = Data()
    private(set) var byteCount: Int64 = 0

    init() throws {
        let templateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LighTxt-csv-rewrite-XXXXXX")
        var template = Array(templateURL.path.utf8CString)
        descriptor = mkstemp(&template)
        guard descriptor >= 0 else {
            throw LighTxtCoreError.io(
                operation: "create CSV rewrite",
                path: templateURL.path,
                code: errno
            )
        }
        let createdPath = String(
            decoding: template.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        guard fchmod(descriptor, 0o600) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            unlink(createdPath)
            throw LighTxtCoreError.io(
                operation: "secure CSV rewrite",
                path: createdPath,
                code: code
            )
        }
        path = createdPath
        buffer.reserveCapacity(Self.bufferByteCount)
    }

    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
        if let path { unlink(path) }
    }

    func append(
        snapshot: DocumentSnapshot,
        range: Range<Int64>,
        cancellation: CSVRowIndex.CancellationCheck?
    ) throws {
        try snapshot.forEachByteSlice(in: range) { bytes in
            try append(bytes, cancellation: cancellation)
        }
    }

    func append(
        _ data: Data,
        cancellation: CSVRowIndex.CancellationCheck?
    ) throws {
        try data.withUnsafeBytes { bytes in
            try append(bytes, cancellation: cancellation)
        }
    }

    func finishAndMap() throws -> MemoryMappedFile {
        guard descriptor >= 0, let path else {
            throw LighTxtCoreError.io(
                operation: "finalize CSV rewrite",
                path: self.path ?? "(unavailable)",
                code: EBADF
            )
        }
        try flush()
        let closeResult = Darwin.close(descriptor)
        descriptor = -1
        guard closeResult == 0 else {
            throw LighTxtCoreError.io(
                operation: "close CSV rewrite",
                path: path,
                code: errno
            )
        }
        let mapping = try MemoryMappedFile(url: URL(fileURLWithPath: path))
        guard unlink(path) == 0 else {
            throw LighTxtCoreError.io(
                operation: "unlink CSV rewrite",
                path: path,
                code: errno
            )
        }
        self.path = nil
        return mapping
    }

    private func append(
        _ bytes: UnsafeRawBufferPointer,
        cancellation: CSVRowIndex.CancellationCheck?
    ) throws {
        guard descriptor >= 0 else {
            throw LighTxtCoreError.io(
                operation: "write CSV rewrite",
                path: path ?? "(unavailable)",
                code: EBADF
            )
        }
        guard Int64(bytes.count) <= Int64.max - byteCount else {
            throw LighTxtCoreError.fileTooLarge(Int64.max)
        }
        var offset = 0
        while offset < bytes.count {
            if cancellation?() == true { throw CancellationError() }
            let copied = min(Self.bufferByteCount - buffer.count, bytes.count - offset)
            buffer.append(contentsOf: UnsafeRawBufferPointer(
                start: bytes.baseAddress!.advanced(by: offset),
                count: copied
            ))
            offset += copied
            byteCount += Int64(copied)
            if buffer.count == Self.bufferByteCount { try flush() }
        }
    }

    private func flush() throws {
        guard !buffer.isEmpty else { return }
        try buffer.withUnsafeBytes { bytes in
            var completed = 0
            while completed < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: completed),
                    bytes.count - completed
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw LighTxtCoreError.io(
                        operation: "write CSV rewrite",
                        path: path ?? "(unavailable)",
                        code: errno
                    )
                }
                guard result > 0 else {
                    throw LighTxtCoreError.io(
                        operation: "write CSV rewrite",
                        path: path ?? "(unavailable)",
                        code: EIO
                    )
                }
                completed += result
            }
        }
        buffer.removeAll(keepingCapacity: true)
    }
}

/// Variable-record sorted run. Every frame persists the source ordinal and all
/// comparison keys, so external merge passes never revisit sparse CSV rows.
private nonisolated final class CSVTemporarySortRun: @unchecked Sendable {
    private static let bufferByteCount = 256 << 10

    private let lock = NSLock()
    private var descriptor: Int32
    private let diagnosticPath: String
    private var buffer = Data()
    private var storedByteCount: Int64 = 0
    private var storedCount: Int64 = 0
    private var isFinished = false

    var count: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return storedCount
    }

    var byteCount: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return storedByteCount
    }

    init() throws {
        let templateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LighTxt-csv-sort-XXXXXX")
        var template = Array(templateURL.path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else {
            throw LighTxtCoreError.io(
                operation: "create CSV sort run",
                path: templateURL.path,
                code: errno
            )
        }
        let path = String(
            decoding: template.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        guard fchmod(descriptor, 0o600) == 0, unlink(path) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            unlink(path)
            throw LighTxtCoreError.io(
                operation: "secure CSV sort run",
                path: path,
                code: code
            )
        }
        self.descriptor = descriptor
        self.diagnosticPath = path
        buffer.reserveCapacity(Self.bufferByteCount)
    }

    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    func append(_ entries: [CSVSortEntry]) throws {
        guard !entries.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0, !isFinished else {
            throw CSVDataOperationError.rowMapClosed
        }
        for entry in entries {
            var payload = Data()
            payload.reserveCapacity(entry.estimatedResidentByteCount)
            var record = entry.record.littleEndian
            withUnsafeBytes(of: &record) { payload.append(contentsOf: $0) }
            var keyCount = UInt32(entry.values.count).littleEndian
            withUnsafeBytes(of: &keyCount) { payload.append(contentsOf: $0) }
            for value in entry.values {
                let bytes = Data(value.utf8)
                guard bytes.count <= Int(UInt32.max) else {
                    throw LighTxtCoreError.fileTooLarge(Int64(bytes.count))
                }
                var length = UInt32(bytes.count).littleEndian
                withUnsafeBytes(of: &length) { payload.append(contentsOf: $0) }
                payload.append(bytes)
            }
            guard payload.count <= Int(UInt32.max) else {
                throw LighTxtCoreError.fileTooLarge(Int64(payload.count))
            }
            var frameLength = UInt32(payload.count).littleEndian
            var frame = Data()
            frame.reserveCapacity(MemoryLayout<UInt32>.size + payload.count)
            withUnsafeBytes(of: &frameLength) { frame.append(contentsOf: $0) }
            frame.append(payload)
            try appendBytes(frame)
            storedCount += 1
        }
    }

    func finishWriting() throws {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { throw CSVDataOperationError.rowMapClosed }
        guard !isFinished else { return }
        try flush()
        isFinished = true
    }

    func entry(at offset: Int64) throws -> (entry: CSVSortEntry, nextOffset: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0, isFinished else { throw CSVDataOperationError.rowMapClosed }
        guard offset >= 0, offset + 4 <= storedByteCount else {
            throw CSVDataOperationError.rowMapOutOfBounds(offset)
        }
        let header = try readData(at: offset, count: 4)
        let payloadCount = header.withUnsafeBytes { bytes in
            Int(UInt32(littleEndian: bytes.loadUnaligned(as: UInt32.self)))
        }
        let nextOffset = offset + 4 + Int64(payloadCount)
        guard payloadCount >= 12, nextOffset <= storedByteCount else {
            throw CSVRowIndex.IndexError.inconsistentCheckpointData
        }
        let payload = try readData(at: offset + 4, count: payloadCount)
        let decoded: CSVSortEntry = try payload.withUnsafeBytes { bytes in
            let record = Int64(littleEndian: bytes.loadUnaligned(as: Int64.self))
            let keyCount = Int(UInt32(littleEndian: bytes.loadUnaligned(
                fromByteOffset: 8,
                as: UInt32.self
            )))
            var cursor = 12
            var values: [String] = []
            values.reserveCapacity(keyCount)
            for _ in 0..<keyCount {
                guard cursor + 4 <= bytes.count else {
                    throw CSVRowIndex.IndexError.inconsistentCheckpointData
                }
                let length = Int(UInt32(littleEndian: bytes.loadUnaligned(
                    fromByteOffset: cursor,
                    as: UInt32.self
                )))
                cursor += 4
                guard length <= bytes.count - cursor else {
                    throw CSVRowIndex.IndexError.inconsistentCheckpointData
                }
                values.append(String(decoding: bytes[cursor..<(cursor + length)], as: UTF8.self))
                cursor += length
            }
            guard cursor == bytes.count else {
                throw CSVRowIndex.IndexError.inconsistentCheckpointData
            }
            return CSVSortEntry(record: record, values: values)
        }
        return (decoded, nextOffset)
    }

    private func appendBytes(_ data: Data) throws {
        guard Int64(data.count) <= Int64.max - storedByteCount else {
            throw LighTxtCoreError.fileTooLarge(Int64.max)
        }
        if data.count > Self.bufferByteCount {
            try flush()
            try writeAll(data)
        } else {
            if buffer.count + data.count > Self.bufferByteCount { try flush() }
            buffer.append(data)
        }
        storedByteCount += Int64(data.count)
    }

    private func flush() throws {
        guard !buffer.isEmpty else { return }
        try writeAll(buffer)
        buffer.removeAll(keepingCapacity: true)
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var completed = 0
            while completed < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: completed),
                    bytes.count - completed
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw LighTxtCoreError.io(
                        operation: "write CSV sort run",
                        path: diagnosticPath,
                        code: errno
                    )
                }
                guard result > 0 else {
                    throw LighTxtCoreError.io(
                        operation: "write CSV sort run",
                        path: diagnosticPath,
                        code: EIO
                    )
                }
                completed += result
            }
        }
    }

    private func readData(at offset: Int64, count: Int) throws -> Data {
        var data = Data(count: count)
        try data.withUnsafeMutableBytes { bytes in
            var completed = 0
            while completed < count {
                let result = Darwin.pread(
                    descriptor,
                    bytes.baseAddress!.advanced(by: completed),
                    count - completed,
                    off_t(offset + Int64(completed))
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw LighTxtCoreError.io(
                        operation: "read CSV sort run",
                        path: diagnosticPath,
                        code: errno
                    )
                }
                guard result > 0 else {
                    throw LighTxtCoreError.io(
                        operation: "read CSV sort run",
                        path: diagnosticPath,
                        code: EIO
                    )
                }
                completed += result
            }
        }
        return data
    }
}

private nonisolated final class CSVTemporaryOrdinalStore: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    private let diagnosticPath: String
    private var storedCount: Int64 = 0
    private var isFinished = false

    var count: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return storedCount
    }

    init() throws {
        let templateURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("LighTxt-csv-rows-XXXXXX")
        var template = Array(templateURL.path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else {
            throw LighTxtCoreError.io(
                operation: "create CSV row map",
                path: templateURL.path,
                code: errno
            )
        }
        let path = String(
            decoding: template.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        guard fchmod(descriptor, 0o600) == 0, unlink(path) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            unlink(path)
            throw LighTxtCoreError.io(operation: "secure CSV row map", path: path, code: code)
        }
        self.descriptor = descriptor
        self.diagnosticPath = path
    }

    deinit { close() }

    func append(_ values: [Int64]) throws {
        guard !values.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0, !isFinished else { throw CSVDataOperationError.rowMapClosed }
        var data = Data()
        data.reserveCapacity(values.count * MemoryLayout<Int64>.size)
        for value in values {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
        }
        try writeAll(data)
        storedCount += Int64(values.count)
    }

    func finishWriting() throws {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { throw CSVDataOperationError.rowMapClosed }
        guard !isFinished else { return }
        isFinished = true
    }

    func value(at position: Int64) throws -> Int64 {
        try values(in: position..<(position + 1))[0]
    }

    func values(in range: Range<Int64>) throws -> [Int64] {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0, isFinished else { throw CSVDataOperationError.rowMapClosed }
        guard range.lowerBound >= 0, range.upperBound <= storedCount else {
            throw CSVDataOperationError.rowMapOutOfBounds(range.lowerBound)
        }
        let count = Int(range.count)
        guard count > 0 else { return [] }
        var data = Data(count: count * MemoryLayout<Int64>.size)
        try data.withUnsafeMutableBytes { bytes in
            var completed = 0
            while completed < bytes.count {
                let result = Darwin.pread(
                    descriptor,
                    bytes.baseAddress!.advanced(by: completed),
                    bytes.count - completed,
                    off_t(range.lowerBound * Int64(MemoryLayout<Int64>.size) + Int64(completed))
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw LighTxtCoreError.io(
                        operation: "read CSV row map",
                        path: diagnosticPath,
                        code: errno
                    )
                }
                guard result > 0 else {
                    throw LighTxtCoreError.io(
                        operation: "read CSV row map",
                        path: diagnosticPath,
                        code: EIO
                    )
                }
                completed += result
            }
        }
        return data.withUnsafeBytes { bytes in
            (0..<count).map { index in
                Int64(littleEndian: bytes.loadUnaligned(
                    fromByteOffset: index * MemoryLayout<Int64>.size,
                    as: Int64.self
                ))
            }
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
    }

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var completed = 0
            while completed < bytes.count {
                let result = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: completed),
                    bytes.count - completed
                )
                if result < 0 {
                    if errno == EINTR { continue }
                    throw LighTxtCoreError.io(
                        operation: "write CSV row map",
                        path: diagnosticPath,
                        code: errno
                    )
                }
                guard result > 0 else {
                    throw LighTxtCoreError.io(
                        operation: "write CSV row map",
                        path: diagnosticPath,
                        code: EIO
                    )
                }
                completed += result
            }
        }
    }
}

private nonisolated struct CSVProfileAccumulator {
    let column: Int
    private(set) var sampledRecordCount: Int64 = 0
    private var missingValueCount: Int64 = 0
    private var emptyValueCount: Int64 = 0
    private var booleanValueCount: Int64 = 0
    private var integerValueCount: Int64 = 0
    private var decimalValueCount: Int64 = 0
    private var textValueCount: Int64 = 0
    private var truncatedValueCount: Int64 = 0
    private var minimumNumericValue: Double?
    private var maximumNumericValue: Double?
    private var numericMean = 0.0
    private var numericCount: Int64 = 0
    private var minimumUTF8Length: Int?
    private var maximumUTF8Length: Int?
    private var distinct = CSVHyperLogLog()
    private var heavyHitters: CSVSpaceSaving

    init(column: Int, topValueCapacity: Int) {
        self.column = column
        self.heavyHitters = CSVSpaceSaving(capacity: topValueCapacity)
    }

    mutating func add(_ field: CSVFieldValue?) {
        sampledRecordCount += 1
        guard let field else {
            missingValueCount += 1
            return
        }
        let value = field.value
        if field.wasTruncated { truncatedValueCount += 1 }
        let length = field.wasTruncated ? Int(clamping: field.byteRange.count) : value.utf8.count
        minimumUTF8Length = min(minimumUTF8Length ?? length, length)
        maximumUTF8Length = max(maximumUTF8Length ?? length, length)
        // A prefix is useful for display and type hints, but never claim that
        // it is the complete value in cardinality or frequency metrics.
        if !field.wasTruncated {
            distinct.add(value)
            heavyHitters.add(value)
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            emptyValueCount += 1
        } else if ["true", "false", "yes", "no"].contains(trimmed.lowercased()) {
            booleanValueCount += 1
        } else if Int64(trimmed) != nil {
            integerValueCount += 1
            addNumeric(Double(trimmed))
        } else if let number = Double(trimmed), number.isFinite {
            decimalValueCount += 1
            addNumeric(number)
        } else {
            textValueCount += 1
        }
    }

    func result(
        totalRecordCount: Int64?,
        isCompleteDataset: Bool,
        samplingStrategy: CSVProfileSamplingStrategy
    ) -> CSVColumnProfile {
        CSVColumnProfile(
            column: column,
            sampledRecordCount: sampledRecordCount,
            totalRecordCount: totalRecordCount,
            isCompleteDataset: isCompleteDataset,
            samplingStrategy: samplingStrategy,
            missingValueCount: missingValueCount,
            emptyValueCount: emptyValueCount,
            booleanValueCount: booleanValueCount,
            integerValueCount: integerValueCount,
            decimalValueCount: decimalValueCount,
            textValueCount: textValueCount,
            truncatedValueCount: truncatedValueCount,
            inferredKind: inferredKind,
            approximateDistinctValueCount: distinct.estimate,
            minimumNumericValue: minimumNumericValue,
            maximumNumericValue: maximumNumericValue,
            meanNumericValue: numericCount > 0 ? numericMean : nil,
            minimumUTF8Length: minimumUTF8Length,
            maximumUTF8Length: maximumUTF8Length,
            topValues: heavyHitters.results
        )
    }

    private var inferredKind: CSVInferredColumnKind {
        let kinds = [
            booleanValueCount > 0,
            integerValueCount > 0,
            decimalValueCount > 0,
            textValueCount > 0,
        ].filter { $0 }.count
        if kinds == 0 { return .empty }
        if textValueCount > 0, kinds > 1 { return .mixed }
        if textValueCount > 0 { return .text }
        if booleanValueCount > 0, kinds > 1 { return .mixed }
        if booleanValueCount > 0 { return .boolean }
        if decimalValueCount > 0 { return .decimal }
        return .integer
    }

    private mutating func addNumeric(_ number: Double?) {
        guard let number, number.isFinite else { return }
        minimumNumericValue = min(minimumNumericValue ?? number, number)
        maximumNumericValue = max(maximumNumericValue ?? number, number)
        numericCount += 1
        numericMean += (number - numericMean) / Double(numericCount)
    }
}

private nonisolated struct CSVSpaceSaving {
    private struct Counter {
        var count: Int64
        var error: Int64
    }

    let capacity: Int
    private var counters: [String: Counter] = [:]

    init(capacity: Int) {
        self.capacity = capacity
        counters.reserveCapacity(capacity)
    }

    mutating func add(_ value: String) {
        if var existing = counters[value] {
            existing.count += 1
            counters[value] = existing
            return
        }
        if counters.count < capacity {
            counters[value] = Counter(count: 1, error: 0)
            return
        }
        guard let minimum = counters.min(by: { lhs, rhs in
            lhs.value.count == rhs.value.count
                ? lhs.key > rhs.key
                : lhs.value.count < rhs.value.count
        }) else { return }
        counters.removeValue(forKey: minimum.key)
        counters[value] = Counter(count: minimum.value.count + 1, error: minimum.value.count)
    }

    var results: [CSVTopValue] {
        counters.map { value, counter in
            CSVTopValue(
                value: value,
                estimatedCount: counter.count,
                maximumError: counter.error
            )
        }.sorted { lhs, rhs in
            lhs.estimatedCount == rhs.estimatedCount
                ? lhs.value < rhs.value
                : lhs.estimatedCount > rhs.estimatedCount
        }
    }
}

private nonisolated struct CSVHyperLogLog {
    private static let registerCount = 64
    private var registers = [UInt8](repeating: 0, count: registerCount)

    mutating func add(_ value: String) {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        // Avalanche FNV's correlated low bits before splitting bucket/rank;
        // sequential identifiers otherwise cluster badly in 64 registers.
        hash = (hash ^ (hash >> 30)) &* 0xbf58_476d_1ce4_e5b9
        hash = (hash ^ (hash >> 27)) &* 0x94d0_49bb_1331_11eb
        hash ^= hash >> 31
        let bucket = Int(hash & UInt64(Self.registerCount - 1))
        let remainder = hash >> 6
        // Shifting the six bucket bits out introduces six leading zero bits in
        // UInt64. Exclude those from rho so cardinalities are not inflated.
        let rank = UInt8(min(59, max(1, remainder.leadingZeroBitCount - 6 + 1)))
        registers[bucket] = max(registers[bucket], rank)
    }

    var estimate: Int64 {
        let m = Double(Self.registerCount)
        let harmonic = registers.reduce(0.0) { partial, register in
            partial + pow(2.0, -Double(register))
        }
        var estimate = 0.709 * m * m / harmonic
        let zeroes = registers.filter { $0 == 0 }.count
        if estimate <= 2.5 * m, zeroes > 0 {
            estimate = m * log(m / Double(zeroes))
        }
        return Int64(max(0, estimate.rounded()))
    }
}
