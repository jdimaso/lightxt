import Foundation
import Darwin
#if SWIFT_PACKAGE
import LighTxtJSONAccelerator
#endif

// MARK: - Public structure model

/// A stable identity within one immutable JSON structure index. Source byte
/// offsets are unique for JSON values, so primitive rows do not need a retained
/// object or an on-disk record merely to have an identity.
public nonisolated struct JSONStructureNodeID: Hashable, Sendable {
    fileprivate let byteOffset: Int64

    private static let documentOffset = Int64.min

    fileprivate static var document: JSONStructureNodeID {
        JSONStructureNodeID(byteOffset: documentOffset)
    }
}

public nonisolated enum JSONStructureNodeKind: UInt8, Sendable, Equatable {
    case document = 0
    case object = 1
    case array = 2
    case string = 3
    case number = 4
    case boolean = 5
    case null = 6
    case invalid = 7

    public var isContainer: Bool {
        self == .document || self == .object || self == .array
    }
}

public nonisolated struct JSONStructureNode: Sendable, Equatable {
    public let id: JSONStructureNodeID
    public let kind: JSONStructureNodeKind
    public let byteRange: Range<Int64>
    public let keyByteRange: Range<Int64>?
    public let depth: Int64
    /// Includes direct primitive values as well as direct object/array values.
    /// It is nil only for primitive rows decoded lazily from a malformed span.
    public let childCount: Int64?
    public let isComplete: Bool
    public let containsErrors: Bool

    fileprivate let indexIdentifier: UUID
}

public nonisolated struct JSONStructureNodePreview: Sendable, Equatable {
    public let key: String?
    public let value: String
    public let keyWasTruncated: Bool
    public let valueWasTruncated: Bool
}

/// Bounded text prepared for a pasteboard operation. JSON copying deliberately
/// has a second byte ceiling in addition to its visible-character ceiling: one
/// pathological grapheme or escape run must never turn a context-menu click
/// into a whole-value read.
nonisolated struct JSONStructureCopyText: Sendable, Equatable {
    let text: String
    let wasTruncated: Bool
    let sourceByteCount: Int64
}

nonisolated enum JSONStructureCopyKind: Sendable, Equatable {
    case scalarValue
    case containerJSON
}

/// The UI retains only the real member node or array ordinal for each visible
/// row. The index resolves member keys from their immutable source ranges when
/// Copy Path is requested, so display-label truncation can never leak into a
/// copied JSONPath.
nonisolated enum JSONStructurePathSegment: Sendable, Equatable {
    case member(JSONStructureNode)
    case index(Int64)
}

/// Opaque continuation state. It records the next source byte and child ordinal,
/// so requesting page N+1 never rescans the first N pages of a million-row array.
public nonisolated struct JSONStructureChildrenCursor: Sendable, Equatable {
    fileprivate let indexIdentifier: UUID
    fileprivate let parentID: JSONStructureNodeID
    fileprivate let nextByteOffset: Int64
    fileprivate let nextChildOrdinal: Int64
}

public nonisolated struct JSONStructureChildrenPage: Sendable, Equatable {
    public let nodes: [JSONStructureNode]
    public let firstChildOrdinal: Int64
    public let nextCursor: JSONStructureChildrenCursor?
}

public nonisolated enum JSONStructureDiagnosticKind: UInt8, Sendable, Equatable {
    case unexpectedByte = 1
    case unexpectedToken = 2
    case malformedNumber = 3
    case malformedLiteral = 4
    case malformedStringEscape = 5
    case unescapedControlCharacter = 6
    case invalidUTF8 = 7
    case expectedObjectKey = 8
    case expectedColon = 9
    case expectedValue = 10
    case expectedCommaOrEnd = 11
    case mismatchedClosingDelimiter = 12
    case trailingContent = 13
    case unexpectedEndOfFile = 14

    public var message: String {
        switch self {
        case .unexpectedByte: return "Unexpected byte in JSON."
        case .unexpectedToken: return "Unexpected token in this JSON context."
        case .malformedNumber: return "Malformed JSON number."
        case .malformedLiteral: return "Expected true, false, or null."
        case .malformedStringEscape: return "Malformed escape in JSON string."
        case .unescapedControlCharacter: return "Unescaped control character in JSON string."
        case .invalidUTF8: return "Invalid UTF-8 sequence in JSON string."
        case .expectedObjectKey: return "Expected a quoted object key."
        case .expectedColon: return "Expected ':' after the object key."
        case .expectedValue: return "Expected a JSON value."
        case .expectedCommaOrEnd: return "Expected ',' or the container's closing delimiter."
        case .mismatchedClosingDelimiter: return "Closing delimiter does not match the open container."
        case .trailingContent: return "JSON content follows the root value."
        case .unexpectedEndOfFile: return "The JSON document ends before this value is complete."
        }
    }
}

public nonisolated struct JSONStructureDiagnostic: Sendable, Equatable {
    public let kind: JSONStructureDiagnosticKind
    public let byteRange: Range<Int64>
    public var message: String { kind.message }
}

public nonisolated struct JSONStructureDiagnosticsCursor: Sendable, Equatable {
    fileprivate let indexIdentifier: UUID
    fileprivate let nextOrdinal: Int64
}

public nonisolated struct JSONStructureDiagnosticsPage: Sendable, Equatable {
    public let diagnostics: [JSONStructureDiagnostic]
    public let nextCursor: JSONStructureDiagnosticsCursor?
}

public nonisolated struct JSONStructureIndexProgress: Sendable, Equatable {
    public let processedBytes: Int64
    public let totalBytes: Int64
    public let indexedContainerCount: Int64
    public let parsedValueCount: Int64
    public let diagnosticCount: Int64

    public var fractionCompleted: Double {
        guard totalBytes > 0 else { return 1 }
        return min(1, Double(processedBytes) / Double(totalBytes))
    }
}

public nonisolated struct JSONStructureIndexConfiguration: Sendable, Equatable {
    /// Progress and cancellation are checked independently of source slice size.
    public var progressIntervalByteCount: Int64
    /// The number of diagnostics retained on disk. The full count is still
    /// reported after this limit, preventing adversarial input from filling disk.
    public var maximumStoredDiagnosticCount: Int64
    /// A caller cannot accidentally turn one outline request into an unbounded
    /// allocation; larger requested page sizes are clamped to this value.
    public var maximumChildrenPerPage: Int
    /// Bounded reads used by lazy child decoding.
    public var lazyReadByteCount: Int
    /// `nil` selects an automatic, physical-memory-aware owned source copy.
    /// Zero always streams from the immutable snapshot; a positive value is the
    /// largest document eligible for the anonymous-RAM source path.
    public var maximumResidentSourceByteCount: Int64?
    /// `nil` selects an automatic resident container-index ceiling. Records
    /// beyond this ceiling spill to private, immediately-unlinked storage.
    public var maximumResidentIndexByteCount: Int64?
    /// Valid resident documents use the bundled native record builder. Through
    /// 4 GiB it runs alongside a full simdjson traversal; larger files use the
    /// exact 64-bit grammar emitter plus SIMD UTF-8 validation. Rejected input
    /// always falls back to the Swift diagnostics parser.
    public var allowsAcceleratedValidJSON: Bool
    public var maximumAcceleratedNestingDepth: Int

    public init(
        progressIntervalByteCount: Int64 = 8 << 20,
        maximumStoredDiagnosticCount: Int64 = 10_000,
        maximumChildrenPerPage: Int = 1_024,
        lazyReadByteCount: Int = 64 << 10,
        maximumResidentSourceByteCount: Int64? = nil,
        maximumResidentIndexByteCount: Int64? = nil,
        allowsAcceleratedValidJSON: Bool = true,
        maximumAcceleratedNestingDepth: Int = 1_024
    ) {
        self.progressIntervalByteCount = max(64 << 10, progressIntervalByteCount)
        self.maximumStoredDiagnosticCount = max(0, maximumStoredDiagnosticCount)
        self.maximumChildrenPerPage = min(16_384, max(1, maximumChildrenPerPage))
        self.lazyReadByteCount = min(1 << 20, max(4 << 10, lazyReadByteCount))
        self.maximumResidentSourceByteCount = maximumResidentSourceByteCount.map { max(0, $0) }
        self.maximumResidentIndexByteCount = maximumResidentIndexByteCount.map { max(0, $0) }
        self.allowsAcceleratedValidJSON = allowsAcceleratedValidJSON
        // The SIMD builder itself is iterative, but its independent semantic
        // validation walk is recursive. Keep that walk at simdjson's documented
        // default depth and route deeper valid documents to the spill-stack
        // Swift parser instead of risking the process stack.
        self.maximumAcceleratedNestingDepth = min(1_024, max(1, maximumAcceleratedNestingDepth))
    }

    public static let `default` = JSONStructureIndexConfiguration()
}

public nonisolated enum JSONStructureIndexError: Error, LocalizedError, Equatable {
    case closed
    case nodeBelongsToDifferentIndex
    case cursorBelongsToDifferentIndex
    case nodeIsNotContainer
    case copyUnavailable
    case copyLimitExceeded
    case corruptIndex

    public var errorDescription: String? {
        switch self {
        case .closed: return "The JSON structure index is closed."
        case .nodeBelongsToDifferentIndex: return "This JSON row belongs to an older document index."
        case .cursorBelongsToDifferentIndex: return "This JSON page cursor belongs to an older document index."
        case .nodeIsNotContainer: return "Only JSON objects and arrays have child rows."
        case .copyUnavailable: return "This JSON row does not have a copyable value or exact path."
        case .copyLimitExceeded: return "The JSON path exceeds LighTxt's bounded copy limit."
        case .corruptIndex: return "The temporary JSON structure index could not be read."
        }
    }
}

// MARK: - Immutable disk records

private nonisolated struct JSONContainerRecord {
    var start: Int64
    var end: Int64
    var firstChildStart: Int64
    var childCount: Int64
    var metadata: Int64

    static let byteCount = 40

    var kind: JSONStructureNodeKind {
        JSONStructureNodeKind(rawValue: UInt8(metadata & 0xff)) ?? .invalid
    }

    var isComplete: Bool { metadata & (1 << 8) != 0 }
    var containsErrors: Bool { metadata & (1 << 9) != 0 }
    var depth: Int64 { metadata >> 16 }

    mutating func setComplete(_ complete: Bool) {
        if complete { metadata |= 1 << 8 } else { metadata &= ~(1 << 8) }
    }

    mutating func setContainsErrors(_ errors: Bool) {
        if errors { metadata |= 1 << 9 } else { metadata &= ~(1 << 9) }
    }
}

private nonisolated struct JSONDiagnosticRecord {
    var start: Int64
    var end: Int64
    var kind: Int64
    var reserved: Int64 = 0

    static let byteCount = 32
}

/// A RAM-first container store with a deterministic disk overflow path.
///
/// The old implementation updated every container through an LRU dictionary
/// backed by `pwrite`. That kept RSS tiny, but made the temporary index the
/// dominant cost on object-dense JSON. This store reserves one anonymous region
/// and faults in only the pages actually written. Records beyond the configured
/// resident ceiling continue through the bounded disk cache. The resident
/// prefix can also be flushed to the already-open private temporary file and
/// unmapped on memory pressure without invalidating the completed index.
private nonisolated final class JSONContainerRecordStore: @unchecked Sendable {
    private final class Page {
        var data: Data
        var dirty = false
        var lastUse: UInt64

        init(data: Data, lastUse: UInt64) {
            self.data = data
            self.lastUse = lastUse
        }
    }

    private let lock = NSLock()
    private let disk: JSONTemporaryRecordFile
    /// 26,214 40-byte records; deliberately divisible by the record size so a
    /// record never straddles two cached pages.
    private let pageByteCount = 1_048_560
    private let maximumResidentPages = 16
    private var diskPages: [Int64: Page] = [:]
    private var clock: UInt64 = 0
    private var memory: UnsafeMutableRawPointer?
    private var memoryByteCapacity: Int64
    private var touchedMemoryPages: [Bool]
    private var isFinished = false
    private var isClosed = false

    init(disk: JSONTemporaryRecordFile, maximumResidentByteCount: Int64) {
        self.disk = disk
        let pageCount = max(0, maximumResidentByteCount / Int64(pageByteCount))
        let capacity = pageCount * Int64(pageByteCount)
        var mapping: UnsafeMutableRawPointer?
        if capacity > 0, capacity <= Int64(Int.max) {
            let result = Darwin.mmap(
                nil,
                Int(capacity),
                PROT_READ | PROT_WRITE,
                MAP_PRIVATE | MAP_ANON,
                -1,
                0
            )
            if result != MAP_FAILED {
                mapping = result
                _ = Darwin.madvise(result, Int(capacity), MADV_SEQUENTIAL)
            }
        }
        self.memory = mapping
        self.memoryByteCapacity = mapping == nil ? 0 : capacity
        self.touchedMemoryPages = Array(repeating: false, count: mapping == nil ? 0 : Int(pageCount))
    }

    deinit { close() }

    func write(_ record: inout JSONContainerRecord, at ordinal: Int64) throws {
        guard ordinal >= 0 else { throw JSONStructureIndexError.corruptIndex }
        let recordOffset = ordinal * Int64(JSONContainerRecord.byteCount)
        if let memory,
           recordOffset >= 0,
           recordOffset <= memoryByteCapacity - Int64(JSONContainerRecord.byteCount) {
            withUnsafeBytes(of: &record) { bytes in
                memory.advanced(by: Int(recordOffset)).copyMemory(
                    from: bytes.baseAddress!,
                    byteCount: bytes.count
                )
            }
            touchedMemoryPages[Int(recordOffset / Int64(pageByteCount))] = true
            return
        }
        let pageOrdinal = recordOffset / Int64(pageByteCount)
        let offsetInPage = Int(recordOffset % Int64(pageByteCount))
        let page = try page(for: pageOrdinal)
        try withUnsafeBytes(of: &record) { recordBytes in
            try page.data.withUnsafeMutableBytes { pageBytes in
                guard offsetInPage + recordBytes.count <= pageBytes.count else {
                    throw JSONStructureIndexError.corruptIndex
                }
                pageBytes.baseAddress!.advanced(by: offsetInPage).copyMemory(
                    from: recordBytes.baseAddress!,
                    byteCount: recordBytes.count
                )
            }
        }
        page.dirty = true
    }

    func finish() throws {
        for pageOrdinal in diskPages.keys.sorted() {
            guard let page = diskPages[pageOrdinal] else { continue }
            try flush(page, ordinal: pageOrdinal)
        }
        diskPages.removeAll(keepingCapacity: false)
        isFinished = true
        if let memory, memoryByteCapacity > 0 {
            _ = Darwin.madvise(memory, Int(memoryByteCapacity), MADV_RANDOM)
        }
    }

    func withUnsafeAcceleratorRecords<R>(
        _ body: (UnsafeMutablePointer<LighTxtJSONContainerRecord>, UInt64) throws -> R
    ) rethrows -> R? {
        guard let memory else { return nil }
        let capacity = UInt64(memoryByteCapacity / Int64(JSONContainerRecord.byteCount))
        return try body(
            memory.assumingMemoryBound(to: LighTxtJSONContainerRecord.self),
            capacity
        )
    }

    func finishAccelerated(recordCount: Int64) throws {
        guard recordCount >= 0,
              recordCount <= memoryByteCapacity / Int64(JSONContainerRecord.byteCount) else {
            throw JSONStructureIndexError.corruptIndex
        }
        let writtenBytes = recordCount * Int64(JSONContainerRecord.byteCount)
        let touchedCount = writtenBytes == 0
            ? 0
            : Int((writtenBytes + Int64(pageByteCount) - 1) / Int64(pageByteCount))
        for index in 0..<min(touchedCount, touchedMemoryPages.count) {
            touchedMemoryPages[index] = true
        }
        try finish()
    }

    func read(at ordinal: Int64) throws -> JSONContainerRecord {
        guard ordinal >= 0,
              ordinal <= Int64.max / Int64(JSONContainerRecord.byteCount) else {
            throw JSONStructureIndexError.corruptIndex
        }
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { throw JSONStructureIndexError.closed }
        let offset = ordinal * Int64(JSONContainerRecord.byteCount)
        if let memory,
           offset <= memoryByteCapacity - Int64(JSONContainerRecord.byteCount) {
            return memory.advanced(by: Int(offset)).loadUnaligned(as: JSONContainerRecord.self)
        }
        return try disk.read(at: ordinal, as: JSONContainerRecord.self)
    }

    var residentByteCount: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return memory == nil
            ? 0
            : Int64(touchedMemoryPages.lazy.filter { $0 }.count) * Int64(pageByteCount)
    }

    var hasDiskOverflow: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isFinished && memoryByteCapacity == 0 || !diskPages.isEmpty
    }

    /// Makes the anonymous prefix recoverable from the existing unlinked file,
    /// then immediately returns all of its pages to the OS. Completed readers
    /// seamlessly continue through positional I/O.
    @discardableResult
    func purgeResidentMemory() throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, isFinished, let memory else { return 0 }
        let reclaimed = Int64(touchedMemoryPages.lazy.filter { $0 }.count) * Int64(pageByteCount)
        for (pageOrdinal, touched) in touchedMemoryPages.enumerated() where touched {
            let byteOffset = Int64(pageOrdinal) * Int64(pageByteCount)
            let count = min(Int64(pageByteCount), memoryByteCapacity - byteOffset)
            let bytes = Data(
                bytes: memory.advanced(by: Int(byteOffset)),
                count: Int(count)
            )
            try disk.writePage(bytes, atByteOffset: byteOffset)
        }
        releaseMemory(mapping: memory, byteCount: memoryByteCapacity)
        self.memory = nil
        memoryByteCapacity = 0
        touchedMemoryPages.removeAll(keepingCapacity: false)
        return reclaimed
    }

    func close() {
        lock.lock()
        guard !isClosed else {
            lock.unlock()
            return
        }
        isClosed = true
        let closingMemory = memory
        let closingCapacity = memoryByteCapacity
        memory = nil
        memoryByteCapacity = 0
        touchedMemoryPages.removeAll(keepingCapacity: false)
        diskPages.removeAll(keepingCapacity: false)
        lock.unlock()
        if let closingMemory { releaseMemory(mapping: closingMemory, byteCount: closingCapacity) }
        disk.close()
    }

    private func page(for ordinal: Int64) throws -> Page {
        clock &+= 1
        if let existing = diskPages[ordinal] {
            existing.lastUse = clock
            return existing
        }
        if diskPages.count >= maximumResidentPages,
           let victim = diskPages.min(by: { $0.value.lastUse < $1.value.lastUse }) {
            try flush(victim.value, ordinal: victim.key)
            diskPages.removeValue(forKey: victim.key)
        }
        let offset = ordinal * Int64(pageByteCount)
        let data = try disk.readZeroFilledPage(byteCount: pageByteCount, atByteOffset: offset)
        let created = Page(data: data, lastUse: clock)
        diskPages[ordinal] = created
        return created
    }

    private func flush(_ page: Page, ordinal: Int64) throws {
        guard page.dirty else { return }
        try disk.writePage(page.data, atByteOffset: ordinal * Int64(pageByteCount))
        page.dirty = false
    }

    private func releaseMemory(mapping: UnsafeMutableRawPointer, byteCount: Int64) {
        guard byteCount > 0 else { return }
        _ = Darwin.madvise(mapping, Int(byteCount), MADV_DONTNEED)
        _ = Darwin.munmap(mapping, Int(byteCount))
    }
}

/// A descriptor-backed, immediately unlinked temporary store. Each operation
/// holds the lock through positional I/O, so explicit close safely waits for an
/// in-flight UI/background read and no descriptor can be reused underneath it.
private nonisolated final class JSONTemporaryRecordFile: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32
    private let recordByteCount: Int

    init(prefix: String, recordByteCount: Int) throws {
        precondition(recordByteCount > 0)
        let directory = FileManager.default.temporaryDirectory.path
        var template = Array("\(directory)/\(prefix)-XXXXXX".utf8CString)
        let opened = template.withUnsafeMutableBufferPointer { buffer in
            Darwin.mkstemp(buffer.baseAddress!)
        }
        guard opened >= 0 else {
            throw LighTxtCoreError.io(operation: "create JSON index", path: directory, code: errno)
        }
        _ = template.withUnsafeBufferPointer { buffer in Darwin.unlink(buffer.baseAddress!) }
        _ = Darwin.fcntl(opened, F_SETFD, FD_CLOEXEC)
        self.descriptor = opened
        self.recordByteCount = recordByteCount
    }

    deinit { close() }

    func close() {
        lock.lock()
        let closing = descriptor
        descriptor = -1
        if closing >= 0 { Darwin.close(closing) }
        lock.unlock()
    }

    func write<T>(_ value: inout T, at ordinal: Int64) throws {
        guard ordinal >= 0,
              MemoryLayout<T>.size == recordByteCount,
              ordinal <= (Int64.max / Int64(recordByteCount)) else {
            throw JSONStructureIndexError.corruptIndex
        }
        try withUnsafeBytes(of: &value) { bytes in
            try writeBytes(bytes, atByteOffset: ordinal * Int64(recordByteCount))
        }
    }

    func read<T>(at ordinal: Int64, as type: T.Type) throws -> T {
        guard ordinal >= 0,
              MemoryLayout<T>.size == recordByteCount,
              ordinal <= (Int64.max / Int64(recordByteCount)) else {
            throw JSONStructureIndexError.corruptIndex
        }
        // Initialize raw storage and load only after a complete positional read.
        return try withUnsafeTemporaryAllocation(byteCount: recordByteCount, alignment: 8) { buffer in
            try readBytes(buffer, atByteOffset: ordinal * Int64(recordByteCount))
            return buffer.load(as: T.self)
        }
    }

    func writePage(_ data: Data, atByteOffset offset: Int64) throws {
        try data.withUnsafeBytes { bytes in try writeBytes(bytes, atByteOffset: offset) }
    }

    /// Reads an index page while treating unwritten sparse/EOF bytes as zero.
    /// The build-time page cache uses this when revisiting a partially flushed
    /// page; completed indexes continue to use strict fixed-record reads.
    func readZeroFilledPage(byteCount: Int, atByteOffset offset: Int64) throws -> Data {
        guard byteCount >= 0, offset >= 0 else { throw JSONStructureIndexError.corruptIndex }
        var result = Data(count: byteCount)
        try result.withUnsafeMutableBytes { bytes in
            lock.lock()
            defer { lock.unlock() }
            guard descriptor >= 0 else { throw JSONStructureIndexError.closed }
            var completed = 0
            while completed < byteCount {
                let amount = Darwin.pread(
                    descriptor,
                    bytes.baseAddress!.advanced(by: completed),
                    byteCount - completed,
                    off_t(offset + Int64(completed))
                )
                if amount < 0 {
                    if errno == EINTR { continue }
                    throw LighTxtCoreError.io(
                        operation: "read JSON index page",
                        path: "private temporary storage",
                        code: errno
                    )
                }
                if amount == 0 { break }
                completed += amount
            }
        }
        return result
    }

    private func writeBytes(_ bytes: UnsafeRawBufferPointer, atByteOffset offset: Int64) throws {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { throw JSONStructureIndexError.closed }
        var completed = 0
        while completed < bytes.count {
            let result = Darwin.pwrite(
                descriptor,
                bytes.baseAddress!.advanced(by: completed),
                bytes.count - completed,
                off_t(offset + Int64(completed))
            )
            if result < 0 {
                if errno == EINTR { continue }
                throw LighTxtCoreError.io(operation: "write JSON index", path: "private temporary storage", code: errno)
            }
            guard result > 0 else {
                throw LighTxtCoreError.io(operation: "write JSON index", path: "private temporary storage", code: EIO)
            }
            completed += result
        }
    }

    private func readBytes(_ bytes: UnsafeMutableRawBufferPointer, atByteOffset offset: Int64) throws {
        lock.lock()
        defer { lock.unlock() }
        guard descriptor >= 0 else { throw JSONStructureIndexError.closed }
        var completed = 0
        while completed < bytes.count {
            let result = Darwin.pread(
                descriptor,
                bytes.baseAddress!.advanced(by: completed),
                bytes.count - completed,
                off_t(offset + Int64(completed))
            )
            if result < 0 {
                if errno == EINTR { continue }
                throw LighTxtCoreError.io(operation: "read JSON index", path: "private temporary storage", code: errno)
            }
            guard result > 0 else { throw JSONStructureIndexError.corruptIndex }
            completed += result
        }
    }
}

// MARK: - Bounded source abstraction

nonisolated enum JSONIndexInputSegment {
    case bytes(UnsafeRawBufferPointer)
    case repeatedASCII(byte: UInt8, count: Int64)
}

nonisolated protocol JSONStructureSource: AnyObject, Sendable {
    var byteCount: Int64 { get }
    var revision: UInt64 { get }
    var residentByteCount: Int64 { get }
    var preparationSeconds: Double { get }
    func forEachSegment(_ body: (JSONIndexInputSegment) throws -> Void) throws
    func data(in range: Range<Int64>) throws -> Data
    @discardableResult func purgeResidentMemory() -> Int64
}

extension JSONStructureSource {
    var residentByteCount: Int64 { 0 }
    var preparationSeconds: Double { 0 }
    @discardableResult func purgeResidentMemory() -> Int64 { 0 }
}

private nonisolated final class JSONSnapshotSource: JSONStructureSource, @unchecked Sendable {
    let snapshot: DocumentSnapshot

    init(_ snapshot: DocumentSnapshot) { self.snapshot = snapshot }

    var byteCount: Int64 { snapshot.byteCount }
    var revision: UInt64 { snapshot.revision }

    func forEachSegment(_ body: (JSONIndexInputSegment) throws -> Void) throws {
        try snapshot.forEachByteSlice { bytes in try body(.bytes(bytes)) }
    }

    func data(in range: Range<Int64>) throws -> Data { try snapshot.data(in: range) }
}

/// An independent anonymous copy of one immutable snapshot. Unlike a mapping
/// of the user-controlled inode, an external truncate cannot fault this region.
/// The snapshot remains as a safe positional-I/O fallback if memory pressure
/// asks the completed index to discard the resident copy.
private nonisolated final class JSONOwnedMemorySource: JSONStructureSource, @unchecked Sendable {
    private let lock = NSLock()
    private let snapshot: DocumentSnapshot
    private var mapping: UnsafeMutableRawPointer?
    private let mappingByteCount: Int64

    let byteCount: Int64
    let revision: UInt64
    let preparationSeconds: Double

    init?(
        snapshot: DocumentSnapshot,
        maximumEligibleByteCount: Int64,
        cancellation: CancellationToken?
    ) throws {
        guard snapshot.byteCount > 0,
              snapshot.byteCount <= maximumEligibleByteCount,
              snapshot.byteCount <= Int64(Int.max) else { return nil }
        let padding = Int64(LighTxtJSONAcceleratorRequiredPadding())
        guard snapshot.byteCount <= Int64(Int.max) - padding else { return nil }
        let allocationByteCount = snapshot.byteCount + padding
        let started = ProcessInfo.processInfo.systemUptime
        let pointer = Darwin.mmap(
            nil,
            Int(allocationByteCount),
            PROT_READ | PROT_WRITE,
            MAP_PRIVATE | MAP_ANON,
            -1,
            0
        )
        guard pointer != MAP_FAILED else { return nil }
        _ = Darwin.madvise(pointer, Int(allocationByteCount), MADV_SEQUENTIAL)

        var copied: Int64 = 0
        do {
            try snapshot.forEachByteSlice { bytes in
                if cancellation?.isCancelled == true { throw CancellationError() }
                guard copied <= snapshot.byteCount - Int64(bytes.count) else {
                    throw JSONStructureIndexError.corruptIndex
                }
                if !bytes.isEmpty {
                    pointer!.advanced(by: Int(copied)).copyMemory(
                        from: bytes.baseAddress!,
                        byteCount: bytes.count
                    )
                }
                copied += Int64(bytes.count)
            }
            guard copied == snapshot.byteCount else { throw JSONStructureIndexError.corruptIndex }
        } catch {
            _ = Darwin.madvise(pointer, Int(allocationByteCount), MADV_DONTNEED)
            _ = Darwin.munmap(pointer, Int(allocationByteCount))
            throw error
        }
        self.snapshot = snapshot
        self.mapping = pointer
        self.mappingByteCount = allocationByteCount
        self.byteCount = snapshot.byteCount
        self.revision = snapshot.revision
        self.preparationSeconds = ProcessInfo.processInfo.systemUptime - started
    }

    deinit { releaseMapping() }

    var residentByteCount: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return mapping == nil ? 0 : mappingByteCount
    }

    func forEachSegment(_ body: (JSONIndexInputSegment) throws -> Void) throws {
        lock.lock()
        if let mapping {
            defer { lock.unlock() }
            try body(.bytes(UnsafeRawBufferPointer(start: mapping, count: Int(byteCount))))
            return
        }
        lock.unlock()
        try snapshot.forEachByteSlice { bytes in try body(.bytes(bytes)) }
    }

    func data(in range: Range<Int64>) throws -> Data {
        try validateByteRange(range, byteCount: byteCount)
        lock.lock()
        if let mapping {
            defer { lock.unlock() }
            return Data(
                bytes: mapping.advanced(by: Int(range.lowerBound)),
                count: Int(range.count)
            )
        }
        lock.unlock()
        return try snapshot.data(in: range)
    }

    func withUnsafePaddedBytes<R>(
        _ body: (UnsafeRawPointer, Int64) throws -> R
    ) rethrows -> R? {
        lock.lock()
        guard let mapping else {
            lock.unlock()
            return nil
        }
        defer { lock.unlock() }
        return try body(UnsafeRawPointer(mapping), mappingByteCount)
    }

    @discardableResult
    func purgeResidentMemory() -> Int64 {
        lock.lock()
        guard let mapping else {
            lock.unlock()
            return 0
        }
        self.mapping = nil
        lock.unlock()
        _ = Darwin.madvise(mapping, Int(mappingByteCount), MADV_DONTNEED)
        _ = Darwin.munmap(mapping, Int(mappingByteCount))
        return mappingByteCount
    }

    private func releaseMapping() {
        _ = purgeResidentMemory()
    }
}

nonisolated enum JSONAutomaticMemoryBudget {
    static func maximumSourceBytes(
        for sourceByteCount: Int64,
        physicalMemory: UInt64 = ProcessInfo.processInfo.physicalMemory,
        availableMemory: Int64? = nil
    ) -> Int64 {
        let physical = min(UInt64(Int64.max), physicalMemory)
        let usesNative64 = sourceByteCount
            > Int64(LighTxtJSONAcceleratorMaximumSIMDDocumentLength())
        // Copying the source is worthwhile only when it leaves ample room for
        // AppKit, the container index, and another active application.
        // Documents through 4 GiB briefly need simdjson's source-sized structural
        // buffer in addition to the owned source and container records. The
        // native 64-bit path avoids that scratch allocation and therefore uses
        // the separately measured, still conservative threshold below.
        // Native64 has no source-sized simdjson structural workspace. Its
        // resident record region is independently capped at half the source,
        // so admitting at one sixth of physical memory keeps the worst-case
        // source+records footprint near one quarter. This admits 16–24 GiB
        // documents on roomy 128+ GiB Macs, but intentionally not on 64 GiB.
        let physicalShare = Int64(physical / (usesNative64 ? 6 : 10))
        // The <=4 GiB path budgets its measured ~2.5x transient; Native64
        // budgets the source plus the independently capped record region.
        let observedAvailable = availableMemory ?? availableMemoryByteCount()
        let availableShare = observedAvailable.map {
            usesNative64 ? $0 / 5 : ($0 / 15) * 2
        } ?? physicalShare
        return min(32 << 30, max(0, min(physicalShare, availableShare)))
    }

    static func maximumIndexBytes(for sourceByteCount: Int64) -> Int64 {
        let physical = min(UInt64(Int64.max), ProcessInfo.processInfo.physicalMemory)
        let physicalShare = Int64(physical / 16)
        let sourceShare = max(64 << 20, sourceByteCount / 2)
        return min(8 << 30, max(0, min(physicalShare, sourceShare)))
    }

    private static func availableMemoryByteCount() -> Int64? {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        var pageSize: vm_size_t = 0
        guard host_page_size(mach_host_self(), &pageSize) == KERN_SUCCESS else { return nil }
        let pages = UInt64(statistics.free_count)
            + UInt64(statistics.inactive_count)
            + UInt64(statistics.purgeable_count)
        let (bytes, overflow) = pages.multipliedReportingOverflow(by: UInt64(pageSize))
        return overflow ? nil : Int64(min(bytes, UInt64(Int64.max)))
    }
}

// MARK: - Completed immutable index

public nonisolated final class JSONStructureIndex: @unchecked Sendable {
    private struct OpenState {
        let source: any JSONStructureSource
        let containers: JSONContainerRecordStore
        let diagnostics: JSONTemporaryRecordFile
    }

    private let stateLock = NSLock()
    private var openState: OpenState?
    private let identifier = UUID()
    private let configuration: JSONStructureIndexConfiguration

    public let sourceRevision: UInt64
    public let sourceByteCount: Int64
    public let generation: UInt64
    public let indexedContainerCount: Int64
    /// Time spent creating an independent anonymous source copy. Zero means the
    /// index streamed directly from its immutable piece-table snapshot.
    public let sourcePreparationSeconds: Double
    /// Full structural validation and container-record construction time.
    public let parserSeconds: Double
    /// Native structural-record emission time for performance QA. Zero on the
    /// bounded Swift fallback path.
    public let nativeRecordBuildSeconds: Double
    /// Native semantic-validation time for performance QA. Zero on the bounded
    /// Swift fallback path.
    public let nativeValidationSeconds: Double
    /// Time required to publish the native record region to the immutable store.
    public let indexPublicationSeconds: Double
    public let usedAcceleratedParser: Bool
    /// Logical bytes retained in unlinked temporary record files. The parser's
    /// short-lived stack store is closed before the completed index is returned.
    public let temporaryIndexByteCount: Int64
    public let parsedValueCount: Int64
    public let diagnosticCount: Int64
    public let storedDiagnosticCount: Int64
    public let diagnosticsWereTruncated: Bool
    public let maximumNestingDepth: Int64
    public let isComplete: Bool
    public let containsErrors: Bool
    public let documentRoot: JSONStructureNode

    fileprivate init(
        source: any JSONStructureSource,
        containers: JSONContainerRecordStore,
        diagnostics: JSONTemporaryRecordFile,
        configuration: JSONStructureIndexConfiguration,
        generation: UInt64,
        parserSeconds: Double,
        nativeRecordBuildSeconds: Double,
        nativeValidationSeconds: Double,
        indexPublicationSeconds: Double,
        usedAcceleratedParser: Bool,
        indexedContainerCount: Int64,
        parsedValueCount: Int64,
        diagnosticCount: Int64,
        storedDiagnosticCount: Int64,
        maximumNestingDepth: Int64,
        rootChildCount: Int64,
        isComplete: Bool,
        containsErrors: Bool
    ) {
        self.openState = OpenState(
            source: source,
            containers: containers,
            diagnostics: diagnostics
        )
        self.configuration = configuration
        self.sourceRevision = source.revision
        self.sourceByteCount = source.byteCount
        self.generation = generation
        self.sourcePreparationSeconds = source.preparationSeconds
        self.parserSeconds = parserSeconds
        self.nativeRecordBuildSeconds = nativeRecordBuildSeconds
        self.nativeValidationSeconds = nativeValidationSeconds
        self.indexPublicationSeconds = indexPublicationSeconds
        self.usedAcceleratedParser = usedAcceleratedParser
        self.indexedContainerCount = indexedContainerCount
        let (containerBytes, containerOverflow) = indexedContainerCount.multipliedReportingOverflow(
            by: Int64(JSONContainerRecord.byteCount)
        )
        let (diagnosticBytes, diagnosticOverflow) = storedDiagnosticCount.multipliedReportingOverflow(
            by: Int64(JSONDiagnosticRecord.byteCount)
        )
        let (combinedBytes, additionOverflow) = containerBytes.addingReportingOverflow(diagnosticBytes)
        self.temporaryIndexByteCount = containerOverflow || diagnosticOverflow || additionOverflow
            ? Int64.max
            : combinedBytes
        self.parsedValueCount = parsedValueCount
        self.diagnosticCount = diagnosticCount
        self.storedDiagnosticCount = storedDiagnosticCount
        self.diagnosticsWereTruncated = storedDiagnosticCount < diagnosticCount
        self.maximumNestingDepth = maximumNestingDepth
        self.isComplete = isComplete
        self.containsErrors = containsErrors
        self.documentRoot = JSONStructureNode(
            id: .document,
            kind: .document,
            byteRange: 0..<source.byteCount,
            keyByteRange: nil,
            depth: -1,
            childCount: rootChildCount,
            isComplete: isComplete,
            containsErrors: containsErrors,
            indexIdentifier: identifier
        )
    }

    deinit { close() }

    public var isOpen: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return openState != nil
    }

    public var residentSourceByteCount: Int64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return openState?.source.residentByteCount ?? 0
    }

    public var residentIndexByteCount: Int64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return openState?.containers.residentByteCount ?? 0
    }

    /// Returns anonymous source and index pages to the OS while preserving a
    /// readable disk-backed index/snapshot fallback.
    @discardableResult
    public func purgeResidentMemory() throws -> Int64 {
        let state = try capturedOpenState()
        let sourceBytes = state.source.purgeResidentMemory()
        let indexBytes = try state.containers.purgeResidentMemory()
        return sourceBytes + indexBytes
    }

    /// Releases the snapshot and all unlinked temporary descriptors. Calls
    /// already performing a positional read finish safely before close returns.
    public func close() {
        stateLock.lock()
        let closing = openState
        openState = nil
        stateLock.unlock()
        closing?.containers.close()
        closing?.diagnostics.close()
    }

    public func isCurrent(revision: UInt64, generation: UInt64) -> Bool {
        sourceRevision == revision && self.generation == generation && isOpen
    }

    public func children(
        of parent: JSONStructureNode,
        cursor: JSONStructureChildrenCursor? = nil,
        limit requestedLimit: Int = 256,
        cancellation: CancellationToken? = nil
    ) throws -> JSONStructureChildrenPage {
        guard parent.indexIdentifier == identifier else {
            throw JSONStructureIndexError.nodeBelongsToDifferentIndex
        }
        guard parent.kind.isContainer else {
            throw JSONStructureIndexError.nodeIsNotContainer
        }
        if let cursor,
           (cursor.indexIdentifier != identifier || cursor.parentID != parent.id) {
            throw JSONStructureIndexError.cursorBelongsToDifferentIndex
        }
        let state = try capturedOpenState()
        let limit = min(configuration.maximumChildrenPerPage, max(1, requestedLimit))
        var scanner = JSONLazyChildrenScanner(
            source: state.source,
            containers: state.containers,
            containerCount: indexedContainerCount,
            indexIdentifier: identifier,
            parent: parent,
            cursor: cursor,
            readByteCount: configuration.lazyReadByteCount,
            cancellation: cancellation
        )
        return try scanner.page(limit: limit)
    }

    public func preview(
        for node: JSONStructureNode,
        maximumByteCount: Int = 512
    ) throws -> JSONStructureNodePreview {
        guard node.indexIdentifier == identifier else {
            throw JSONStructureIndexError.nodeBelongsToDifferentIndex
        }
        let state = try capturedOpenState()
        let maximum = min(16 << 10, max(16, maximumByteCount))
        let keyResult: (String, Bool)?
        if let keyRange = node.keyByteRange {
            keyResult = try Self.decodedString(
                in: keyRange,
                source: state.source,
                maximumSourceByteCount: maximum
            )
        } else {
            keyResult = nil
        }

        let value: String
        let valueWasTruncated: Bool
        switch node.kind {
        case .document:
            value = "Document · \((node.childCount ?? 0).formatted()) root value\((node.childCount ?? 0) == 1 ? "" : "s")"
            valueWasTruncated = false
        case .object:
            value = "Object · \((node.childCount ?? 0).formatted()) member\((node.childCount ?? 0) == 1 ? "" : "s")"
            valueWasTruncated = false
        case .array:
            value = "Array · \((node.childCount ?? 0).formatted()) item\((node.childCount ?? 0) == 1 ? "" : "s")"
            valueWasTruncated = false
        case .string:
            (value, valueWasTruncated) = try Self.decodedString(
                in: node.byteRange,
                source: state.source,
                maximumSourceByteCount: maximum
            )
        case .number, .boolean, .null, .invalid:
            let length = node.byteRange.upperBound - node.byteRange.lowerBound
            let readCount = min(length, Int64(maximum))
            let data = try state.source.data(
                in: node.byteRange.lowerBound..<(node.byteRange.lowerBound + readCount)
            )
            value = String(decoding: data, as: UTF8.self)
            valueWasTruncated = readCount < length
        }
        return JSONStructureNodePreview(
            key: keyResult?.0,
            value: value,
            keyWasTruncated: keyResult?.1 ?? false,
            valueWasTruncated: valueWasTruncated
        )
    }

    /// Returns either a decoded scalar value or the raw JSON for one object or
    /// array. Both limits are hard-capped even for internal callers. The byte
    /// cap keeps work independent of the selected value's total size; the
    /// character cap is measured with Swift `Character` so the pasteboard text
    /// contains at most 10,000 user-visible characters including the ellipsis.
    func copyText(
        for node: JSONStructureNode,
        kind: JSONStructureCopyKind,
        maximumCharacterCount requestedCharacterCount: Int = 10_000,
        maximumSourceByteCount requestedSourceByteCount: Int = 64 << 10
    ) throws -> JSONStructureCopyText {
        guard node.indexIdentifier == identifier else {
            throw JSONStructureIndexError.nodeBelongsToDifferentIndex
        }
        switch kind {
        case .scalarValue:
            guard node.kind == .string || node.kind == .number
                    || node.kind == .boolean || node.kind == .null else {
                throw JSONStructureIndexError.copyUnavailable
            }
        case .containerJSON:
            guard node.kind == .object || node.kind == .array else {
                throw JSONStructureIndexError.copyUnavailable
            }
        }

        let state = try capturedOpenState()
        let characterLimit = min(10_000, max(1, requestedCharacterCount))
        let sourceByteLimit = min(64 << 10, max(16, requestedSourceByteCount))
        let sourceLength = node.byteRange.upperBound - node.byteRange.lowerBound
        guard sourceLength >= 0 else { throw JSONStructureIndexError.corruptIndex }
        let readCount = min(sourceLength, Int64(sourceByteLimit))
        let data = try state.source.data(
            in: node.byteRange.lowerBound..<(node.byteRange.lowerBound + readCount)
        )
        let sourceWasTruncated = readCount < sourceLength
        let text: String
        if kind == .scalarValue, node.kind == .string {
            text = decodeJSONStringPrefix(data, sourceWasTruncated: sourceWasTruncated)
        } else {
            text = String(decoding: data, as: UTF8.self)
        }
        let bounded = Self.boundedCopyText(
            text,
            sourceWasTruncated: sourceWasTruncated,
            maximumCharacterCount: characterLimit
        )
        return JSONStructureCopyText(
            text: bounded.text,
            wasTruncated: bounded.wasTruncated,
            sourceByteCount: readCount
        )
    }

    /// Resolves a normalized JSONPath from exact immutable key ranges and array
    /// ordinals. A copied path is always exact: if a pathological key/path would
    /// exceed either bounded budget, the operation fails instead of publishing
    /// a display-truncated or ambiguous path.
    func jsonPath(
        for segments: [JSONStructurePathSegment],
        maximumCharacterCount requestedCharacterCount: Int = 10_000,
        maximumSourceByteCount requestedSourceByteCount: Int = 64 << 10
    ) throws -> String {
        let state = try capturedOpenState()
        let characterLimit = min(10_000, max(1, requestedCharacterCount))
        var sourceByteBudget = min(64 << 10, max(16, requestedSourceByteCount))
        guard segments.count <= 4_096 else {
            throw JSONStructureIndexError.copyLimitExceeded
        }

        var result = "$"
        for segment in segments {
            let token: String
            switch segment {
            case let .index(ordinal):
                guard ordinal >= 0 else { throw JSONStructureIndexError.copyUnavailable }
                token = "[\(ordinal)]"
            case let .member(node):
                guard node.indexIdentifier == identifier else {
                    throw JSONStructureIndexError.nodeBelongsToDifferentIndex
                }
                guard let range = node.keyByteRange else {
                    throw JSONStructureIndexError.copyUnavailable
                }
                let length = range.upperBound - range.lowerBound
                guard length > 0, length <= Int64(sourceByteBudget) else {
                    throw JSONStructureIndexError.copyLimitExceeded
                }
                let data = try state.source.data(in: range)
                sourceByteBudget -= Int(length)
                let decoded: Any
                do {
                    decoded = try JSONSerialization.jsonObject(
                        with: data,
                        options: [.fragmentsAllowed]
                    )
                } catch {
                    throw JSONStructureIndexError.copyUnavailable
                }
                guard let key = decoded as? String else {
                    throw JSONStructureIndexError.copyUnavailable
                }
                token = Self.jsonPathToken(for: key)
            }
            guard result.count <= characterLimit,
                  token.count <= characterLimit - result.count else {
                throw JSONStructureIndexError.copyLimitExceeded
            }
            result += token
        }
        return result
    }

    public func diagnostics(
        cursor: JSONStructureDiagnosticsCursor? = nil,
        limit requestedLimit: Int = 256
    ) throws -> JSONStructureDiagnosticsPage {
        if let cursor, cursor.indexIdentifier != identifier {
            throw JSONStructureIndexError.cursorBelongsToDifferentIndex
        }
        let state = try capturedOpenState()
        let start = cursor?.nextOrdinal ?? 0
        guard start >= 0, start <= storedDiagnosticCount else {
            throw JSONStructureIndexError.cursorBelongsToDifferentIndex
        }
        let limit = min(4_096, max(1, requestedLimit))
        let end = min(storedDiagnosticCount, start + Int64(limit))
        var result: [JSONStructureDiagnostic] = []
        result.reserveCapacity(Int(end - start))
        for ordinal in start..<end {
            let record = try state.diagnostics.read(at: ordinal, as: JSONDiagnosticRecord.self)
            guard let kind = JSONStructureDiagnosticKind(rawValue: UInt8(record.kind)) else {
                throw JSONStructureIndexError.corruptIndex
            }
            result.append(
                JSONStructureDiagnostic(
                    kind: kind,
                    byteRange: record.start..<record.end
                )
            )
        }
        let next = end < storedDiagnosticCount
            ? JSONStructureDiagnosticsCursor(indexIdentifier: identifier, nextOrdinal: end)
            : nil
        return JSONStructureDiagnosticsPage(diagnostics: result, nextCursor: next)
    }

    private func capturedOpenState() throws -> OpenState {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let openState else { throw JSONStructureIndexError.closed }
        return openState
    }

    private static func decodedString(
        in range: Range<Int64>,
        source: any JSONStructureSource,
        maximumSourceByteCount: Int
    ) throws -> (String, Bool) {
        let length = range.upperBound - range.lowerBound
        let readCount = min(length, Int64(maximumSourceByteCount))
        let data = try source.data(in: range.lowerBound..<(range.lowerBound + readCount))
        let wasTruncated = readCount < length
        return (decodeJSONStringPrefix(data, sourceWasTruncated: wasTruncated), wasTruncated)
    }

    private static func boundedCopyText(
        _ text: String,
        sourceWasTruncated: Bool,
        maximumCharacterCount: Int
    ) -> (text: String, wasTruncated: Bool) {
        guard sourceWasTruncated || text.count > maximumCharacterCount else {
            return (text, false)
        }
        let prefixCount = max(0, maximumCharacterCount - 1)
        return (String(text.prefix(prefixCount)) + "…", true)
    }

    private static func jsonPathToken(for key: String) -> String {
        let bytes = Array(key.utf8)
        let isIdentifier = !bytes.isEmpty
            && (isASCIIIdentifierStart(bytes[0]))
            && bytes.dropFirst().allSatisfy(isASCIIIdentifierContinuation)
        if isIdentifier { return ".\(key)" }

        var escaped = ""
        escaped.reserveCapacity(key.utf8.count + 4)
        for scalar in key.unicodeScalars {
            switch scalar.value {
            case 0x08: escaped += "\\b"
            case 0x09: escaped += "\\t"
            case 0x0a: escaped += "\\n"
            case 0x0c: escaped += "\\f"
            case 0x0d: escaped += "\\r"
            case 0x22: escaped += "\\\""
            case 0x5c: escaped += "\\\\"
            case 0x00...0x1f:
                escaped += String(format: "\\u%04X", scalar.value)
            default:
                escaped.unicodeScalars.append(scalar)
            }
        }
        return "[\"\(escaped)\"]"
    }

    private static func isASCIIIdentifierStart(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5a)
            || (byte >= 0x61 && byte <= 0x7a)
            || byte == 0x5f || byte == 0x24
    }

    private static func isASCIIIdentifierContinuation(_ byte: UInt8) -> Bool {
        isASCIIIdentifierStart(byte) || (byte >= 0x30 && byte <= 0x39)
    }
}

private nonisolated func decodeJSONStringPrefix(
    _ data: Data,
    sourceWasTruncated: Bool
) -> String {
    let bytes = [UInt8](data)
    var lower = 0
    var upper = bytes.count
    if lower < upper, bytes[lower] == 0x22 { lower += 1 }
    if !sourceWasTruncated, lower < upper, bytes[upper - 1] == 0x22 { upper -= 1 }
    var output = ""
    output.reserveCapacity(max(0, upper - lower))
    var runStart = lower
    var index = lower

    func appendRun(_ end: Int) {
        guard end > runStart else { return }
        output += String(decoding: bytes[runStart..<end], as: UTF8.self)
    }

    while index < upper {
        guard bytes[index] == 0x5c else { index += 1; continue }
        appendRun(index)
        index += 1
        guard index < upper else { output += "�"; runStart = index; break }
        switch bytes[index] {
        case 0x22: output += "\""; index += 1
        case 0x5c: output += "\\"; index += 1
        case 0x2f: output += "/"; index += 1
        case 0x62: output += "\u{8}"; index += 1
        case 0x66: output += "\u{c}"; index += 1
        case 0x6e: output += "\n"; index += 1
        case 0x72: output += "\r"; index += 1
        case 0x74: output += "\t"; index += 1
        case 0x75:
            guard index + 4 < upper,
                  let first = jsonHexQuad(bytes, at: index + 1) else {
                output += "�"
                index = min(upper, index + 1)
                runStart = index
                continue
            }
            index += 5
            var scalarValue = UInt32(first)
            if (0xd800...0xdbff).contains(first),
               index + 5 < upper,
               bytes[index] == 0x5c,
               bytes[index + 1] == 0x75,
               let second = jsonHexQuad(bytes, at: index + 2),
               (0xdc00...0xdfff).contains(second) {
                scalarValue = 0x10000
                    + (UInt32(first - 0xd800) << 10)
                    + UInt32(second - 0xdc00)
                index += 6
            }
            if let scalar = Unicode.Scalar(scalarValue) { output.unicodeScalars.append(scalar) }
            else { output += "�" }
        default:
            output += "�"
            index += 1
        }
        runStart = index
    }
    appendRun(upper)
    return output
}

private nonisolated func jsonHexQuad(_ bytes: [UInt8], at start: Int) -> UInt16? {
    guard start >= 0, start + 4 <= bytes.count else { return nil }
    var result: UInt16 = 0
    for index in start..<(start + 4) {
        let value: UInt16
        switch bytes[index] {
        case 0x30...0x39: value = UInt16(bytes[index] - 0x30)
        case 0x41...0x46: value = UInt16(bytes[index] - 0x41 + 10)
        case 0x61...0x66: value = UInt16(bytes[index] - 0x61 + 10)
        default: return nil
        }
        result = (result << 4) | value
    }
    return result
}

// MARK: - Full-document streaming parser

public nonisolated enum StreamingJSONStructureIndexer {
    public static var maximumAcceleratedSourceByteCount: Int64 {
        Int64(LighTxtJSONAcceleratorMaximumSourceLength())
    }

    public static var maximumSIMDDocumentValidationByteCount: Int64 {
        Int64(LighTxtJSONAcceleratorMaximumSIMDDocumentLength())
    }

    public static var acceleratedSourcePaddingByteCount: Int64 {
        Int64(LighTxtJSONAcceleratorRequiredPadding())
    }

    public static var acceleratedContainerRecordByteCount: Int {
        MemoryLayout<LighTxtJSONContainerRecord>.stride
    }

    public static var acceleratedContainerRecordAlignment: Int {
        MemoryLayout<LighTxtJSONContainerRecord>.alignment
    }

    /// Scans the complete captured revision. Input callbacks are capped by
    /// `DocumentSnapshot` at one MiB and the parser never concatenates slices.
    public static func build(
        snapshot: DocumentSnapshot,
        generation: UInt64,
        configuration: JSONStructureIndexConfiguration = .default,
        cancellation: CancellationToken? = nil,
        progress: ((JSONStructureIndexProgress) -> Void)? = nil
    ) throws -> JSONStructureIndex {
        let automaticLimit = JSONAutomaticMemoryBudget.maximumSourceBytes(
            for: snapshot.byteCount
        )
        let maximumSourceBytes = configuration.maximumResidentSourceByteCount
            ?? automaticLimit
        let source: any JSONStructureSource
        if let resident = try JSONOwnedMemorySource(
            snapshot: snapshot,
            maximumEligibleByteCount: maximumSourceBytes,
            cancellation: cancellation
        ) {
            source = resident
        } else {
            source = JSONSnapshotSource(snapshot)
        }
        LighTxtSignpost.jsonParserAdmission(
            bytes: snapshot.byteCount,
            maximumResidentBytes: maximumSourceBytes,
            residentSource: source is JSONOwnedMemorySource
        )
        return try build(
            source: source,
            generation: generation,
            configuration: configuration,
            cancellation: cancellation,
            progress: progress
        )
    }

    /// Internal source seam permits fast virtual-offset tests without allocating
    /// or reading four GiB. Production callers always enter through a snapshot.
    static func build(
        source: any JSONStructureSource,
        generation: UInt64,
        configuration: JSONStructureIndexConfiguration = .default,
        cancellation: CancellationToken? = nil,
        progress: ((JSONStructureIndexProgress) -> Void)? = nil
    ) throws -> JSONStructureIndex {
        let containerDisk = try JSONTemporaryRecordFile(
            prefix: "LighTxt-json-containers",
            recordByteCount: JSONContainerRecord.byteCount
        )
        let residentIndexLimit = configuration.maximumResidentIndexByteCount
            ?? JSONAutomaticMemoryBudget.maximumIndexBytes(for: source.byteCount)
        let containers = JSONContainerRecordStore(
            disk: containerDisk,
            maximumResidentByteCount: residentIndexLimit
        )
        let diagnostics = try JSONTemporaryRecordFile(
            prefix: "LighTxt-json-diagnostics",
            recordByteCount: JSONDiagnosticRecord.byteCount
        )
        let stack = try JSONTemporaryRecordFile(
            prefix: "LighTxt-json-stack",
            recordByteCount: JSONParserFrame.byteCount
        )
        defer { stack.close() }
        do {
            let parserStarted = ProcessInfo.processInfo.systemUptime
            let accelerated = try acceleratedOutcome(
                source: source,
                containers: containers,
                configuration: configuration,
                cancellation: cancellation,
                progress: progress
            )
            let outcome: JSONParserOutcome
            let usedAcceleratedParser: Bool
            if let accelerated {
                outcome = accelerated
                usedAcceleratedParser = true
            } else {
                var parser = JSONStreamingStructureParser(
                    source: source,
                    containers: containers,
                    diagnostics: diagnostics,
                    stack: stack,
                    configuration: configuration,
                    cancellation: cancellation,
                    progress: progress
                )
                outcome = try parser.run()
                try containers.finish()
                usedAcceleratedParser = false
            }
            let parserSeconds = ProcessInfo.processInfo.systemUptime - parserStarted
            let index = JSONStructureIndex(
                source: source,
                containers: containers,
                diagnostics: diagnostics,
                configuration: configuration,
                generation: generation,
                parserSeconds: parserSeconds,
                nativeRecordBuildSeconds: outcome.nativeRecordBuildSeconds,
                nativeValidationSeconds: outcome.nativeValidationSeconds,
                indexPublicationSeconds: outcome.indexPublicationSeconds,
                usedAcceleratedParser: usedAcceleratedParser,
                indexedContainerCount: outcome.containerCount,
                parsedValueCount: outcome.valueCount,
                diagnosticCount: outcome.diagnosticCount,
                storedDiagnosticCount: outcome.storedDiagnosticCount,
                maximumNestingDepth: outcome.maximumDepth,
                rootChildCount: outcome.rootChildCount,
                isComplete: true,
                containsErrors: outcome.containsErrors
            )
            LighTxtSignpost.jsonIndexReady(
                bytes: source.byteCount,
                accelerated: usedAcceleratedParser,
                sourceSeconds: index.sourcePreparationSeconds,
                parserSeconds: parserSeconds,
                nativeBuildSeconds: outcome.nativeRecordBuildSeconds,
                validationSeconds: outcome.nativeValidationSeconds,
                publicationSeconds: outcome.indexPublicationSeconds
            )
            return index
        } catch {
            containers.close()
            diagnostics.close()
            throw error
        }
    }
}

private nonisolated final class JSONAcceleratorCallbackContext: @unchecked Sendable {
    let sourceByteCount: Int64
    let cancellation: CancellationToken?
    let progress: ((JSONStructureIndexProgress) -> Void)?
    private var maximumContainerCount: UInt64 = 0
    private var maximumValueCount: UInt64 = 0

    init(
        sourceByteCount: Int64,
        cancellation: CancellationToken?,
        progress: ((JSONStructureIndexProgress) -> Void)?
    ) {
        self.sourceByteCount = sourceByteCount
        self.cancellation = cancellation
        self.progress = progress
    }

    func update(
        completedWork: UInt64,
        totalWork: UInt64,
        containerCount: UInt64,
        valueCount: UInt64
    ) -> Bool {
        guard cancellation?.isCancelled != true else { return false }
        maximumContainerCount = max(maximumContainerCount, containerCount)
        maximumValueCount = max(maximumValueCount, valueCount)
        let fraction = totalWork == 0
            ? 1
            : min(1, Double(completedWork) / Double(totalWork))
        progress?(
            JSONStructureIndexProgress(
                processedBytes: Int64(Double(sourceByteCount) * fraction),
                totalBytes: sourceByteCount,
                indexedContainerCount: Int64(clamping: maximumContainerCount),
                parsedValueCount: Int64(clamping: maximumValueCount),
                diagnosticCount: 0
            )
        )
        return cancellation?.isCancelled != true
    }
}

private nonisolated let jsonAcceleratorProgressCallback: LighTxtJSONAcceleratorProgress = {
    context,
    completedWork,
    totalWork,
    containerCount,
    valueCount in
    guard let context else { return true }
    return Unmanaged<JSONAcceleratorCallbackContext>
        .fromOpaque(context)
        .takeUnretainedValue()
        .update(
            completedWork: completedWork,
            totalWork: totalWork,
            containerCount: containerCount,
            valueCount: valueCount
        )
}

private nonisolated func acceleratedOutcome(
    source: any JSONStructureSource,
    containers: JSONContainerRecordStore,
    configuration: JSONStructureIndexConfiguration,
    cancellation: CancellationToken?,
    progress: ((JSONStructureIndexProgress) -> Void)?
) throws -> JSONParserOutcome? {
    guard configuration.allowsAcceleratedValidJSON,
          MemoryLayout<LighTxtJSONContainerRecord>.size == JSONContainerRecord.byteCount,
          MemoryLayout<LighTxtJSONContainerRecord>.stride == JSONContainerRecord.byteCount,
          MemoryLayout<LighTxtJSONContainerRecord>.alignment
            == MemoryLayout<JSONContainerRecord>.alignment,
          source.byteCount >= 0,
          source.byteCount <= StreamingJSONStructureIndexer.maximumAcceleratedSourceByteCount,
          let residentSource = source as? JSONOwnedMemorySource else { return nil }

    let callbackContext = JSONAcceleratorCallbackContext(
        sourceByteCount: source.byteCount,
        cancellation: cancellation,
        progress: progress
    )
    let opaqueContext = Unmanaged.passUnretained(callbackContext).toOpaque()
    let nested = residentSource.withUnsafePaddedBytes { sourceBytes, sourceCapacity in
        containers.withUnsafeAcceleratorRecords { records, recordCapacity in
            LighTxtBuildJSONContainerIndex(
                sourceBytes.assumingMemoryBound(to: UInt8.self),
                UInt64(source.byteCount),
                UInt64(sourceCapacity),
                records,
                recordCapacity,
                UInt64(configuration.maximumAcceleratedNestingDepth),
                jsonAcceleratorProgressCallback,
                opaqueContext
            )
        }
    }
    guard let result = nested ?? nil else { return nil }
    switch result.status {
    case UInt32(LighTxtJSONAcceleratorSuccess):
        let publicationStarted = ProcessInfo.processInfo.systemUptime
        try containers.finishAccelerated(recordCount: Int64(clamping: result.containerCount))
        progress?(
            JSONStructureIndexProgress(
                processedBytes: source.byteCount,
                totalBytes: source.byteCount,
                indexedContainerCount: Int64(clamping: result.containerCount),
                parsedValueCount: Int64(clamping: result.valueCount),
                diagnosticCount: 0
            )
        )
        return JSONParserOutcome(
            containerCount: Int64(clamping: result.containerCount),
            valueCount: Int64(clamping: result.valueCount),
            diagnosticCount: 0,
            storedDiagnosticCount: 0,
            maximumDepth: Int64(clamping: result.maximumDepth),
            rootChildCount: Int64(clamping: result.rootChildCount),
            containsErrors: false,
            nativeRecordBuildSeconds: Double(result.recordBuildNanoseconds) / 1_000_000_000,
            nativeValidationSeconds: Double(result.validationNanoseconds) / 1_000_000_000,
            indexPublicationSeconds: ProcessInfo.processInfo.systemUptime - publicationStarted
        )
    case UInt32(LighTxtJSONAcceleratorCancelled):
        throw CancellationError()
    case UInt32(LighTxtJSONAcceleratorInvalidJSON),
         UInt32(LighTxtJSONAcceleratorInsufficientRecordCapacity),
         UInt32(LighTxtJSONAcceleratorUnsupportedSize),
         UInt32(LighTxtJSONAcceleratorInternalError):
        return nil
    default:
        return nil
    }
}

private nonisolated struct JSONParserOutcome {
    let containerCount: Int64
    let valueCount: Int64
    let diagnosticCount: Int64
    let storedDiagnosticCount: Int64
    let maximumDepth: Int64
    let rootChildCount: Int64
    let containsErrors: Bool
    let nativeRecordBuildSeconds: Double
    let nativeValidationSeconds: Double
    let indexPublicationSeconds: Double
}

private nonisolated enum JSONFrameState: Int64 {
    case documentExpectValue = 0
    case documentAfterValue = 1
    case arrayExpectValueOrEnd = 2
    case arrayExpectCommaOrEnd = 3
    case objectExpectKeyOrEnd = 4
    case objectExpectColon = 5
    case objectExpectValue = 6
    case objectExpectCommaOrEnd = 7
}

private nonisolated struct JSONParserFrame {
    var recordOrdinal: Int64
    var start: Int64
    var pendingKeyStart: Int64
    var pendingKeyEnd: Int64
    var childCount: Int64
    var depth: Int64
    var packed: Int64
    var reserved: Int64 = 0

    static let byteCount = 64

    var kind: JSONStructureNodeKind {
        get { JSONStructureNodeKind(rawValue: UInt8(packed & 0xff)) ?? .invalid }
        set { packed = (packed & ~0xff) | Int64(newValue.rawValue) }
    }

    var state: JSONFrameState {
        get { JSONFrameState(rawValue: (packed >> 8) & 0xff) ?? .documentExpectValue }
        set { packed = (packed & ~(0xff << 8)) | (newValue.rawValue << 8) }
    }

    var containsErrors: Bool {
        get { packed & (1 << 16) != 0 }
        set {
            if newValue { packed |= 1 << 16 } else { packed &= ~(1 << 16) }
        }
    }

    var followsComma: Bool {
        get { packed & (1 << 17) != 0 }
        set {
            if newValue { packed |= 1 << 17 } else { packed &= ~(1 << 17) }
        }
    }

    static func document() -> JSONParserFrame {
        var frame = JSONParserFrame(
            recordOrdinal: -1,
            start: Int64.min,
            pendingKeyStart: -1,
            pendingKeyEnd: -1,
            childCount: 0,
            depth: -1,
            packed: 0
        )
        frame.kind = .document
        frame.state = .documentExpectValue
        return frame
    }
}

private nonisolated struct JSONParserFrameStack {
    let store: JSONTemporaryRecordFile
    private let maximumResidentFrameCount = 1_024
    private var resident: [JSONParserFrame] = []
    private var spilledCount: Int64 = 0

    init(store: JSONTemporaryRecordFile) { self.store = store }

    mutating func push(_ frame: JSONParserFrame) throws {
        if spilledCount == 0, resident.count < maximumResidentFrameCount {
            resident.append(frame)
        } else {
            var value = frame
            try store.write(&value, at: spilledCount)
            spilledCount += 1
        }
    }

    mutating func pop() throws -> JSONParserFrame? {
        if spilledCount > 0 {
            spilledCount -= 1
            return try store.read(at: spilledCount, as: JSONParserFrame.self)
        }
        return resident.popLast()
    }
}

private nonisolated enum JSONNumberState: UInt8 {
    case minus
    case zero
    case integer
    case dot
    case fraction
    case exponent
    case exponentSign
    case exponentDigits

    mutating func consume(_ byte: UInt8) -> Bool {
        switch self {
        case .minus:
            if byte == 0x30 { self = .zero; return true }
            if (0x31...0x39).contains(byte) { self = .integer; return true }
        case .zero:
            if byte == 0x2e { self = .dot; return true }
            if byte == 0x65 || byte == 0x45 { self = .exponent; return true }
        case .integer:
            if (0x30...0x39).contains(byte) { return true }
            if byte == 0x2e { self = .dot; return true }
            if byte == 0x65 || byte == 0x45 { self = .exponent; return true }
        case .dot:
            if (0x30...0x39).contains(byte) { self = .fraction; return true }
        case .fraction:
            if (0x30...0x39).contains(byte) { return true }
            if byte == 0x65 || byte == 0x45 { self = .exponent; return true }
        case .exponent:
            if byte == 0x2b || byte == 0x2d { self = .exponentSign; return true }
            if (0x30...0x39).contains(byte) { self = .exponentDigits; return true }
        case .exponentSign:
            if (0x30...0x39).contains(byte) { self = .exponentDigits; return true }
        case .exponentDigits:
            if (0x30...0x39).contains(byte) { return true }
        }
        return false
    }

    var mayTerminate: Bool {
        self == .zero || self == .integer || self == .fraction || self == .exponentDigits
    }
}

private nonisolated struct JSONBareLexeme {
    let start: Int64
    var kind: JSONStructureNodeKind
    var numberState: JSONNumberState?
    var literal: [UInt8]
    var literalPosition: Int
    var invalid: Bool

    init(start: Int64, firstByte: UInt8) {
        self.start = start
        self.literalPosition = 0
        self.invalid = false
        switch firstByte {
        case 0x2d:
            kind = .number
            numberState = .minus
            literal = []
        case 0x30:
            kind = .number
            numberState = .zero
            literal = []
        case 0x31...0x39:
            kind = .number
            numberState = .integer
            literal = []
        case 0x74:
            kind = .boolean
            numberState = nil
            literal = Array("true".utf8)
            literalPosition = 1
        case 0x66:
            kind = .boolean
            numberState = nil
            literal = Array("false".utf8)
            literalPosition = 1
        case 0x6e:
            kind = .null
            numberState = nil
            literal = Array("null".utf8)
            literalPosition = 1
        default:
            kind = .invalid
            numberState = nil
            literal = []
            invalid = true
        }
    }

    mutating func consume(_ byte: UInt8) {
        if var numberState {
            if !numberState.consume(byte) { invalid = true }
            self.numberState = numberState
        } else if !literal.isEmpty {
            if literalPosition >= literal.count || byte != literal[literalPosition] {
                invalid = true
            }
            literalPosition += 1
        } else {
            invalid = true
        }
    }

    var isValid: Bool {
        guard !invalid else { return false }
        if let numberState { return numberState.mayTerminate }
        if !literal.isEmpty { return literalPosition == literal.count }
        return false
    }
}

private nonisolated struct JSONStringLexeme {
    let start: Int64
    var afterBackslash = false
    var unicodeDigitsRemaining = 0
    var utf8ContinuationRemaining = 0
    var nextContinuationMinimum: UInt8 = 0x80
    var nextContinuationMaximum: UInt8 = 0xbf
    var invalid = false
}

private nonisolated enum JSONLexMode {
    case normal
    case string(JSONStringLexeme)
    case bare(JSONBareLexeme)
}

private nonisolated struct JSONStreamingStructureParser {
    let source: any JSONStructureSource
    let containers: JSONContainerRecordStore
    let diagnostics: JSONTemporaryRecordFile
    let configuration: JSONStructureIndexConfiguration
    let cancellation: CancellationToken?
    let progress: ((JSONStructureIndexProgress) -> Void)?

    private var stack: JSONParserFrameStack
    private var current = JSONParserFrame.document()
    private var lexMode = JSONLexMode.normal
    private var offset: Int64 = 0
    private var containerCount: Int64 = 0
    private var valueCount: Int64 = 0
    private var diagnosticCount: Int64 = 0
    private var storedDiagnosticCount: Int64 = 0
    private var maximumDepth: Int64 = 0
    private var nextProgressOffset: Int64

    init(
        source: any JSONStructureSource,
        containers: JSONContainerRecordStore,
        diagnostics: JSONTemporaryRecordFile,
        stack: JSONTemporaryRecordFile,
        configuration: JSONStructureIndexConfiguration,
        cancellation: CancellationToken?,
        progress: ((JSONStructureIndexProgress) -> Void)?
    ) {
        self.source = source
        self.containers = containers
        self.diagnostics = diagnostics
        self.stack = JSONParserFrameStack(store: stack)
        self.configuration = configuration
        self.cancellation = cancellation
        self.progress = progress
        self.nextProgressOffset = configuration.progressIntervalByteCount
    }

    mutating func run() throws -> JSONParserOutcome {
        reportProgress()
        let input = source
        try input.forEachSegment { segment in
            try consume(segment)
        }
        try finishLexemeAtEOF()
        try finishOpenContainersAtEOF()
        if current.state == .documentExpectValue, current.childCount == 0 {
            try addDiagnostic(.expectedValue, range: source.byteCount..<source.byteCount)
            current.containsErrors = true
        }
        offset = source.byteCount
        try checkCancellation()
        reportProgress()
        return JSONParserOutcome(
            containerCount: containerCount,
            valueCount: valueCount,
            diagnosticCount: diagnosticCount,
            storedDiagnosticCount: storedDiagnosticCount,
            maximumDepth: maximumDepth,
            rootChildCount: current.childCount,
            containsErrors: current.containsErrors || diagnosticCount > 0,
            nativeRecordBuildSeconds: 0,
            nativeValidationSeconds: 0,
            indexPublicationSeconds: 0
        )
    }

    private mutating func consume(_ segment: JSONIndexInputSegment) throws {
        switch segment {
        case let .bytes(bytes):
            try consumeBytes(bytes)
        case let .repeatedASCII(byte, count):
            guard count >= 0, offset <= Int64.max - count else {
                throw LighTxtCoreError.fileTooLarge(Int64.max)
            }
            if case .normal = lexMode, isJSONWhitespace(byte) {
                offset += count
                try checkCancellation()
                reportProgress()
                nextProgressOffset = offset + configuration.progressIntervalByteCount
            } else {
                var remaining = count
                while remaining > 0 {
                    try consumeByte(byte)
                    offset += 1
                    remaining -= 1
                    if offset >= nextProgressOffset {
                        try checkCancellation()
                        reportProgress()
                        nextProgressOffset = offset + configuration.progressIntervalByteCount
                    }
                }
            }
        }
    }

    /// Runs of ordinary ASCII inside JSON strings account for most bytes in
    /// real data exports. Handling those runs here avoids an enum switch and a
    /// throwing function call per character. Eight-byte probes quickly skip
    /// spans that cannot contain a quote, escape, control byte, or UTF-8 lead.
    private mutating func consumeBytes(_ bytes: UnsafeRawBufferPointer) throws {
        guard let base = bytes.baseAddress else { return }
        var index = 0
        while index < bytes.count {
            if case let .string(token) = lexMode,
               !token.afterBackslash,
               token.unicodeDigitsRemaining == 0,
               token.utf8ContinuationRemaining == 0 {
                var end = index
                while end + MemoryLayout<UInt64>.size <= bytes.count {
                    let word = base.loadUnaligned(fromByteOffset: end, as: UInt64.self)
                    if jsonStringWordContainsSpecialByte(word) { break }
                    end += MemoryLayout<UInt64>.size
                }
                while end < bytes.count, isOrdinaryJSONStringASCIIByte(base.load(fromByteOffset: end, as: UInt8.self)) {
                    end += 1
                }
                if end > index {
                    offset += Int64(end - index)
                    index = end
                    try reportProgressIfNeeded()
                    if index == bytes.count { continue }
                }
            } else if case .normal = lexMode {
                var end = index
                while end < bytes.count,
                      isJSONWhitespace(base.load(fromByteOffset: end, as: UInt8.self)) {
                    end += 1
                }
                if end > index {
                    offset += Int64(end - index)
                    index = end
                    try reportProgressIfNeeded()
                    if index == bytes.count { continue }
                }
            }

            try consumeByte(base.load(fromByteOffset: index, as: UInt8.self))
            offset += 1
            index += 1
            try reportProgressIfNeeded()
        }
    }

    @inline(__always)
    private mutating func reportProgressIfNeeded() throws {
        guard offset >= nextProgressOffset else { return }
        try checkCancellation()
        reportProgress()
        nextProgressOffset = offset + configuration.progressIntervalByteCount
    }

    private mutating func consumeByte(_ byte: UInt8) throws {
        var shouldReprocess = true
        while shouldReprocess {
            shouldReprocess = false
            switch lexMode {
            case .normal:
                try consumeNormal(byte)
            case var .bare(token):
                if isJSONTokenDelimiter(byte) {
                    try finishBare(token, end: offset)
                    lexMode = .normal
                    shouldReprocess = true
                } else {
                    token.consume(byte)
                    lexMode = .bare(token)
                }
            case var .string(token):
                if token.unicodeDigitsRemaining > 0 {
                    if !isJSONHex(byte) {
                        token.invalid = true
                        try addDiagnostic(.malformedStringEscape, range: offset..<(offset + 1))
                    }
                    token.unicodeDigitsRemaining -= 1
                    lexMode = .string(token)
                } else if token.afterBackslash {
                    token.afterBackslash = false
                    if byte == 0x75 {
                        token.unicodeDigitsRemaining = 4
                    } else if ![0x22, 0x5c, 0x2f, 0x62, 0x66, 0x6e, 0x72, 0x74].contains(byte) {
                        token.invalid = true
                        try addDiagnostic(.malformedStringEscape, range: offset..<(offset + 1))
                    }
                    lexMode = .string(token)
                } else if token.utf8ContinuationRemaining > 0 {
                    if byte < token.nextContinuationMinimum || byte > token.nextContinuationMaximum {
                        token.invalid = true
                        token.utf8ContinuationRemaining = 0
                        try addDiagnostic(.invalidUTF8, range: offset..<(offset + 1))
                        lexMode = .string(token)
                        shouldReprocess = true
                    } else {
                        token.utf8ContinuationRemaining -= 1
                        token.nextContinuationMinimum = 0x80
                        token.nextContinuationMaximum = 0xbf
                        lexMode = .string(token)
                    }
                } else if byte == 0x22 {
                    try finishString(token, end: offset + 1, complete: true)
                    lexMode = .normal
                } else if byte == 0x5c {
                    token.afterBackslash = true
                    lexMode = .string(token)
                } else if byte < 0x20 {
                    token.invalid = true
                    try addDiagnostic(.unescapedControlCharacter, range: offset..<(offset + 1))
                    lexMode = .string(token)
                } else if byte < 0x80 {
                    lexMode = .string(token)
                } else {
                    switch byte {
                    case 0xc2...0xdf:
                        token.utf8ContinuationRemaining = 1
                    case 0xe0:
                        token.utf8ContinuationRemaining = 2
                        token.nextContinuationMinimum = 0xa0
                    case 0xe1...0xec, 0xee...0xef:
                        token.utf8ContinuationRemaining = 2
                    case 0xed:
                        token.utf8ContinuationRemaining = 2
                        token.nextContinuationMaximum = 0x9f
                    case 0xf0:
                        token.utf8ContinuationRemaining = 3
                        token.nextContinuationMinimum = 0x90
                    case 0xf1...0xf3:
                        token.utf8ContinuationRemaining = 3
                    case 0xf4:
                        token.utf8ContinuationRemaining = 3
                        token.nextContinuationMaximum = 0x8f
                    default:
                        token.invalid = true
                        try addDiagnostic(.invalidUTF8, range: offset..<(offset + 1))
                    }
                    lexMode = .string(token)
                }
            }
        }
    }

    private mutating func consumeNormal(_ byte: UInt8) throws {
        if isJSONWhitespace(byte) { return }
        switch byte {
        case 0x22:
            lexMode = .string(JSONStringLexeme(start: offset))
        case 0x7b:
            try beginContainer(kind: .object, at: offset)
        case 0x5b:
            try beginContainer(kind: .array, at: offset)
        case 0x7d:
            try closeContainer(kind: .object, closingOffset: offset)
        case 0x5d:
            try closeContainer(kind: .array, closingOffset: offset)
        case 0x3a:
            try consumeColon()
        case 0x2c:
            try consumeComma()
        default:
            lexMode = .bare(JSONBareLexeme(start: offset, firstByte: byte))
        }
    }

    private mutating func finishString(
        _ token: JSONStringLexeme,
        end: Int64,
        complete: Bool
    ) throws {
        var invalid = token.invalid
        if token.afterBackslash || token.unicodeDigitsRemaining > 0 || token.utf8ContinuationRemaining > 0 {
            invalid = true
            try addDiagnostic(.malformedStringEscape, range: token.start..<end)
        }
        let range = token.start..<end
        if current.kind == .object, current.state == .objectExpectKeyOrEnd {
            current.pendingKeyStart = range.lowerBound
            current.pendingKeyEnd = range.upperBound
            current.state = .objectExpectColon
            current.followsComma = false
            if invalid { current.containsErrors = true }
        } else {
            try acceptPrimitive(kind: invalid ? .invalid : .string, range: range)
        }
        if !complete {
            try addDiagnostic(.unexpectedEndOfFile, range: range)
            current.containsErrors = true
        }
    }

    private mutating func finishBare(_ token: JSONBareLexeme, end: Int64) throws {
        let valid = token.isValid
        if !valid {
            try addDiagnostic(
                token.kind == .number ? .malformedNumber : .malformedLiteral,
                range: token.start..<end
            )
        }
        try acceptPrimitive(
            kind: valid ? token.kind : .invalid,
            range: token.start..<end
        )
    }

    private mutating func acceptPrimitive(
        kind: JSONStructureNodeKind,
        range: Range<Int64>
    ) throws {
        _ = try prepareParentForValue(at: range.lowerBound)
        valueCount += 1
        if kind == .invalid { current.containsErrors = true }
    }

    private mutating func beginContainer(
        kind: JSONStructureNodeKind,
        at start: Int64
    ) throws {
        _ = try prepareParentForValue(at: start)
        valueCount += 1
        let depth = current.depth + 1
        maximumDepth = max(maximumDepth, depth)
        try stack.push(current)
        var child = JSONParserFrame(
            recordOrdinal: containerCount,
            start: start,
            pendingKeyStart: -1,
            pendingKeyEnd: -1,
            childCount: 0,
            depth: depth,
            packed: 0
        )
        child.kind = kind
        child.state = kind == .object ? .objectExpectKeyOrEnd : .arrayExpectValueOrEnd
        containerCount += 1
        current = child
    }

    private mutating func prepareParentForValue(at start: Int64) throws -> Range<Int64>? {
        var keyRange: Range<Int64>?
        switch current.state {
        case .documentExpectValue:
            current.state = .documentAfterValue
        case .documentAfterValue:
            try addDiagnostic(.trailingContent, range: start..<(start + 1))
            current.containsErrors = true
        case .arrayExpectValueOrEnd:
            current.state = .arrayExpectCommaOrEnd
            current.followsComma = false
        case .arrayExpectCommaOrEnd:
            try addDiagnostic(.expectedCommaOrEnd, range: start..<(start + 1))
            current.containsErrors = true
        case .objectExpectValue:
            if current.pendingKeyStart >= 0 {
                keyRange = current.pendingKeyStart..<current.pendingKeyEnd
            }
            current.pendingKeyStart = -1
            current.pendingKeyEnd = -1
            current.state = .objectExpectCommaOrEnd
            current.followsComma = false
        case .objectExpectKeyOrEnd:
            try addDiagnostic(.expectedObjectKey, range: start..<(start + 1))
            current.state = .objectExpectCommaOrEnd
            current.containsErrors = true
        case .objectExpectColon:
            try addDiagnostic(.expectedColon, range: start..<(start + 1))
            if current.pendingKeyStart >= 0 {
                keyRange = current.pendingKeyStart..<current.pendingKeyEnd
            }
            current.pendingKeyStart = -1
            current.pendingKeyEnd = -1
            current.state = .objectExpectCommaOrEnd
            current.containsErrors = true
        case .objectExpectCommaOrEnd:
            try addDiagnostic(.expectedCommaOrEnd, range: start..<(start + 1))
            current.containsErrors = true
        }
        if current.childCount == 0 {
            // Object pages must resume at the key, not at the value. Arrays and
            // the synthetic document root have no key prefix.
            current.reserved = keyRange?.lowerBound ?? start
        }
        current.childCount += 1
        return keyRange
    }

    private mutating func consumeColon() throws {
        if current.kind == .object, current.state == .objectExpectColon {
            current.state = .objectExpectValue
        } else {
            try addDiagnostic(.unexpectedByte, range: offset..<(offset + 1))
            current.containsErrors = true
        }
    }

    private mutating func consumeComma() throws {
        switch current.state {
        case .arrayExpectCommaOrEnd:
            current.state = .arrayExpectValueOrEnd
            current.followsComma = true
        case .objectExpectCommaOrEnd:
            current.state = .objectExpectKeyOrEnd
            current.followsComma = true
        default:
            try addDiagnostic(.unexpectedByte, range: offset..<(offset + 1))
            current.containsErrors = true
        }
    }

    private mutating func closeContainer(
        kind: JSONStructureNodeKind,
        closingOffset: Int64
    ) throws {
        while current.kind != .document, current.kind != kind {
            try addDiagnostic(.mismatchedClosingDelimiter, range: closingOffset..<(closingOffset + 1))
            current.containsErrors = true
            try finalizeCurrentContainer(end: closingOffset, complete: false)
        }
        guard current.kind != .document else {
            try addDiagnostic(.mismatchedClosingDelimiter, range: closingOffset..<(closingOffset + 1))
            current.containsErrors = true
            return
        }

        switch current.state {
        case .arrayExpectValueOrEnd where current.followsComma,
             .objectExpectKeyOrEnd where current.followsComma:
            try addDiagnostic(.expectedValue, range: closingOffset..<(closingOffset + 1))
            current.containsErrors = true
        case .objectExpectColon:
            try addDiagnostic(.expectedColon, range: closingOffset..<(closingOffset + 1))
            current.containsErrors = true
        case .objectExpectValue:
            try addDiagnostic(.expectedValue, range: closingOffset..<(closingOffset + 1))
            current.containsErrors = true
        default:
            break
        }
        try finalizeCurrentContainer(end: closingOffset + 1, complete: true)
    }

    private mutating func finalizeCurrentContainer(end: Int64, complete: Bool) throws {
        var record = JSONContainerRecord(
            start: current.start,
            end: max(current.start + 1, end),
            firstChildStart: current.childCount > 0 ? current.reserved : -1,
            childCount: current.childCount,
            metadata: Int64(current.kind.rawValue) | (current.depth << 16)
        )
        record.setComplete(complete)
        record.setContainsErrors(current.containsErrors || !complete)
        try containers.write(&record, at: current.recordOrdinal)
        let childHadErrors = record.containsErrors
        guard var parent = try stack.pop() else {
            throw JSONStructureIndexError.corruptIndex
        }
        if childHadErrors { parent.containsErrors = true }
        current = parent
    }

    private mutating func finishLexemeAtEOF() throws {
        switch lexMode {
        case .normal:
            break
        case let .bare(token):
            try finishBare(token, end: source.byteCount)
        case let .string(token):
            try finishString(token, end: source.byteCount, complete: false)
        }
        lexMode = .normal
    }

    private mutating func finishOpenContainersAtEOF() throws {
        while current.kind != .document {
            try addDiagnostic(.unexpectedEndOfFile, range: current.start..<source.byteCount)
            current.containsErrors = true
            try finalizeCurrentContainer(end: source.byteCount, complete: false)
        }
    }

    private mutating func addDiagnostic(
        _ kind: JSONStructureDiagnosticKind,
        range: Range<Int64>
    ) throws {
        diagnosticCount += 1
        guard storedDiagnosticCount < configuration.maximumStoredDiagnosticCount else { return }
        var record = JSONDiagnosticRecord(
            start: max(0, min(source.byteCount, range.lowerBound)),
            end: max(0, min(source.byteCount, range.upperBound)),
            kind: Int64(kind.rawValue)
        )
        try diagnostics.write(&record, at: storedDiagnosticCount)
        storedDiagnosticCount += 1
    }

    private func checkCancellation() throws {
        if cancellation?.isCancelled == true { throw CancellationError() }
    }

    private func reportProgress() {
        progress?(
            JSONStructureIndexProgress(
                processedBytes: min(offset, source.byteCount),
                totalBytes: source.byteCount,
                indexedContainerCount: containerCount,
                parsedValueCount: valueCount,
                diagnosticCount: diagnosticCount
            )
        )
    }
}

@inline(__always)
private nonisolated func isJSONWhitespace(_ byte: UInt8) -> Bool {
    byte == 0x20 || byte == 0x09 || byte == 0x0a || byte == 0x0d
}

@inline(__always)
private nonisolated func isOrdinaryJSONStringASCIIByte(_ byte: UInt8) -> Bool {
    byte >= 0x20 && byte < 0x80 && byte != 0x22 && byte != 0x5c
}

@inline(__always)
private nonisolated func jsonStringWordContainsSpecialByte(_ word: UInt64) -> Bool {
    let ones: UInt64 = 0x0101_0101_0101_0101
    let highBits: UInt64 = 0x8080_8080_8080_8080
    let quoteBytes: UInt64 = 0x2222_2222_2222_2222
    let slashBytes: UInt64 = 0x5c5c_5c5c_5c5c_5c5c
    let controlThreshold: UInt64 = 0x2020_2020_2020_2020

    @inline(__always)
    func containsZeroByte(_ value: UInt64) -> Bool {
        ((value &- ones) & ~value & highBits) != 0
    }

    if word & highBits != 0 { return true }
    if containsZeroByte(word ^ quoteBytes) || containsZeroByte(word ^ slashBytes) { return true }
    // The standard per-byte less-than test can report an adjacent-byte false
    // positive because of subtraction borrow, but never a false negative. A
    // false positive merely falls back to the scalar correctness path.
    return ((word &- controlThreshold) & ~word & highBits) != 0
}

@inline(__always)
private nonisolated func isJSONTokenDelimiter(_ byte: UInt8) -> Bool {
    isJSONWhitespace(byte)
        || byte == 0x2c || byte == 0x3a
        || byte == 0x5b || byte == 0x5d
        || byte == 0x7b || byte == 0x7d
}

@inline(__always)
private nonisolated func isJSONHex(_ byte: UInt8) -> Bool {
    (0x30...0x39).contains(byte)
        || (0x41...0x46).contains(byte)
        || (0x61...0x66).contains(byte)
}

// MARK: - Lazy bounded child paging

private nonisolated struct JSONBoundedByteReader {
    let source: any JSONStructureSource
    let chunkByteCount: Int64
    private var windowStart: Int64 = -1
    private var window = Data()

    init(source: any JSONStructureSource, chunkByteCount: Int) {
        self.source = source
        self.chunkByteCount = Int64(chunkByteCount)
    }

    mutating func byte(at offset: Int64) throws -> UInt8 {
        guard offset >= 0, offset < source.byteCount else {
            throw LighTxtCoreError.invalidByteRange(
                requested: offset..<offset,
                byteCount: source.byteCount
            )
        }
        if windowStart < 0
            || offset < windowStart
            || offset >= windowStart + Int64(window.count) {
            windowStart = (offset / chunkByteCount) * chunkByteCount
            let end = min(source.byteCount, windowStart + chunkByteCount)
            window = try source.data(in: windowStart..<end)
        }
        return window[Int(offset - windowStart)]
    }
}

private nonisolated struct JSONLazyChildrenScanner {
    let source: any JSONStructureSource
    let containers: JSONContainerRecordStore
    let containerCount: Int64
    let indexIdentifier: UUID
    let parent: JSONStructureNode
    let cancellation: CancellationToken?

    private var reader: JSONBoundedByteReader
    private var position: Int64
    private var childOrdinal: Int64
    private let contentEnd: Int64
    private var bytesSinceCancellationCheck: Int64 = 0

    init(
        source: any JSONStructureSource,
        containers: JSONContainerRecordStore,
        containerCount: Int64,
        indexIdentifier: UUID,
        parent: JSONStructureNode,
        cursor: JSONStructureChildrenCursor?,
        readByteCount: Int,
        cancellation: CancellationToken?
    ) {
        self.source = source
        self.containers = containers
        self.containerCount = containerCount
        self.indexIdentifier = indexIdentifier
        self.parent = parent
        self.cancellation = cancellation
        self.reader = JSONBoundedByteReader(source: source, chunkByteCount: readByteCount)
        if let cursor {
            self.position = cursor.nextByteOffset
            self.childOrdinal = cursor.nextChildOrdinal
        } else {
            self.position = parent.kind == .document
                ? parent.byteRange.lowerBound
                : min(parent.byteRange.upperBound, parent.byteRange.lowerBound + 1)
            self.childOrdinal = 0
        }
        if parent.kind == .document || !parent.isComplete {
            self.contentEnd = parent.byteRange.upperBound
        } else {
            self.contentEnd = max(parent.byteRange.lowerBound, parent.byteRange.upperBound - 1)
        }
    }

    mutating func page(limit: Int) throws -> JSONStructureChildrenPage {
        if cancellation?.isCancelled == true { throw CancellationError() }
        if childOrdinal == 0,
           parent.kind != .document,
           let parentRecord = try containerRecord(startingAt: parent.byteRange.lowerBound),
           parentRecord.firstChildStart >= position,
           parentRecord.firstChildStart < contentEnd {
            position = parentRecord.firstChildStart
        }
        let firstOrdinal = childOrdinal
        var nodes: [JSONStructureNode] = []
        nodes.reserveCapacity(limit)
        let knownChildCount = parent.childCount ?? Int64.max

        while nodes.count < limit,
              childOrdinal < knownChildCount,
              position < contentEnd {
            try skipWhitespaceAndCommas()
            guard position < contentEnd else { break }

            var keyRange: Range<Int64>?
            if parent.kind == .object {
                guard try reader.byte(at: position) == 0x22 else {
                    // A malformed object can still expose its remaining span as
                    // an invalid row without trapping the outline pager.
                    let invalidStart = position
                    try scanBareValue()
                    let invalidEnd = max(invalidStart + 1, position)
                    nodes.append(makePrimitiveNode(
                        kind: .invalid,
                        range: invalidStart..<min(contentEnd, invalidEnd),
                        keyRange: nil,
                        containsErrors: true
                    ))
                    childOrdinal += 1
                    continue
                }
                let keyStart = position
                let keyEnd = try scanString()
                keyRange = keyStart..<keyEnd
                try skipWhitespace()
                if position < contentEnd, try reader.byte(at: position) == 0x3a {
                    try advance()
                }
                try skipWhitespace()
                guard position < contentEnd else { break }
            }

            let valueStart = position
            let byte = try reader.byte(at: position)
            let node: JSONStructureNode
            if byte == 0x7b || byte == 0x5b,
               let record = try containerRecord(startingAt: valueStart) {
                node = makeContainerNode(from: record, keyRangeOverride: keyRange)
                position = min(contentEnd, max(position + 1, record.end))
                try didAdvance(by: max(1, record.end - valueStart))
            } else if byte == 0x22 {
                let end = try scanString()
                node = makePrimitiveNode(
                    kind: .string,
                    range: valueStart..<end,
                    keyRange: keyRange,
                    containsErrors: end >= contentEnd && (try? reader.byte(at: max(valueStart, end - 1))) != 0x22
                )
            } else {
                let kind = primitiveKind(firstByte: byte)
                try scanBareValue()
                let end = max(valueStart + 1, position)
                node = makePrimitiveNode(
                    kind: kind,
                    range: valueStart..<min(contentEnd, end),
                    keyRange: keyRange,
                    containsErrors: kind == .invalid
                )
            }
            nodes.append(node)
            childOrdinal += 1
        }

        let hasMore = childOrdinal < knownChildCount && position < contentEnd
        let cursor = hasMore
            ? JSONStructureChildrenCursor(
                indexIdentifier: indexIdentifier,
                parentID: parent.id,
                nextByteOffset: position,
                nextChildOrdinal: childOrdinal
            )
            : nil
        return JSONStructureChildrenPage(
            nodes: nodes,
            firstChildOrdinal: firstOrdinal,
            nextCursor: cursor
        )
    }

    private mutating func skipWhitespaceAndCommas() throws {
        while position < contentEnd {
            let byte = try reader.byte(at: position)
            guard isJSONWhitespace(byte) || byte == 0x2c else { return }
            try advance()
        }
    }

    private mutating func skipWhitespace() throws {
        while position < contentEnd, isJSONWhitespace(try reader.byte(at: position)) {
            try advance()
        }
    }

    @discardableResult
    private mutating func scanString() throws -> Int64 {
        guard position < contentEnd, try reader.byte(at: position) == 0x22 else {
            return position
        }
        try advance()
        var escaped = false
        while position < contentEnd {
            let byte = try reader.byte(at: position)
            try advance()
            if escaped {
                escaped = false
            } else if byte == 0x5c {
                escaped = true
            } else if byte == 0x22 {
                break
            }
        }
        return position
    }

    private mutating func scanBareValue() throws {
        while position < contentEnd {
            let byte = try reader.byte(at: position)
            if isJSONWhitespace(byte) || byte == 0x2c || byte == 0x5d || byte == 0x7d {
                return
            }
            try advance()
        }
    }

    private mutating func advance() throws {
        position += 1
        try didAdvance(by: 1)
    }

    private mutating func didAdvance(by count: Int64) throws {
        bytesSinceCancellationCheck += count
        if bytesSinceCancellationCheck >= 64 << 10 {
            bytesSinceCancellationCheck = 0
            if cancellation?.isCancelled == true { throw CancellationError() }
        }
    }

    private func primitiveKind(firstByte: UInt8) -> JSONStructureNodeKind {
        switch firstByte {
        case 0x2d, 0x30...0x39: return .number
        case 0x74, 0x66: return .boolean
        case 0x6e: return .null
        default: return .invalid
        }
    }

    private func makePrimitiveNode(
        kind: JSONStructureNodeKind,
        range: Range<Int64>,
        keyRange: Range<Int64>?,
        containsErrors: Bool
    ) -> JSONStructureNode {
        JSONStructureNode(
            id: JSONStructureNodeID(byteOffset: range.lowerBound),
            kind: kind,
            byteRange: range,
            keyByteRange: keyRange,
            depth: parent.depth + 1,
            childCount: kind == .invalid ? nil : 0,
            isComplete: !containsErrors,
            containsErrors: containsErrors,
            indexIdentifier: indexIdentifier
        )
    }

    private func makeContainerNode(
        from record: JSONContainerRecord,
        keyRangeOverride: Range<Int64>?
    ) -> JSONStructureNode {
        return JSONStructureNode(
            id: JSONStructureNodeID(byteOffset: record.start),
            kind: record.kind,
            byteRange: record.start..<record.end,
            keyByteRange: keyRangeOverride,
            depth: record.depth,
            childCount: record.childCount,
            isComplete: record.isComplete,
            containsErrors: record.containsErrors,
            indexIdentifier: indexIdentifier
        )
    }

    /// Container records are appended at opening delimiters, hence strictly
    /// sorted by source offset and searchable without an in-memory dictionary.
    private func containerRecord(startingAt start: Int64) throws -> JSONContainerRecord? {
        var lower: Int64 = 0
        var upper = containerCount
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            let record = try containers.read(at: middle)
            if record.start < start { lower = middle + 1 }
            else { upper = middle }
        }
        guard lower < containerCount else { return nil }
        let result = try containers.read(at: lower)
        return result.start == start ? result : nil
    }
}
