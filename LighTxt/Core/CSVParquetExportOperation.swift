import Darwin
import Foundation

/// Errors emitted while materializing an exact CSV table view as Parquet.
nonisolated enum CSVParquetExportError: Error, LocalizedError, Equatable {
    case noColumns
    case tooManyColumns(actual: Int, maximum: Int)
    case columnNameTooLarge(column: Int)
    case aggregateColumnNamesTooLarge
    case invalidRowWidth(row: Int64, expected: Int, actual: Int)
    case fieldTooLarge(row: Int64, column: Int, byteCount: Int, maximum: Int)
    case rowTooLarge(row: Int64, byteCount: Int, maximum: Int)
    case alreadyFinished
    case malformedOutput(String)
    case rowCountMismatch(expected: Int64, actual: Int64)

    var errorDescription: String? {
        switch self {
        case .noColumns:
            return "Parquet export requires at least one column."
        case let .tooManyColumns(actual, maximum):
            return "Parquet export received \(actual.formatted()) columns; the safety limit is \(maximum.formatted())."
        case let .columnNameTooLarge(column):
            return "Column \(column + 1) has a name that is too large to export safely."
        case .aggregateColumnNamesTooLarge:
            return "The combined column names are too large to export safely."
        case let .invalidRowWidth(row, expected, actual):
            return "Row \(row + 1) has \(actual.formatted()) fields; \(expected.formatted()) were expected."
        case let .fieldTooLarge(row, column, byteCount, maximum):
            return "Row \(row + 1), column \(column + 1) is \(byteCount.formatted()) bytes; exact Parquet export is limited to \(maximum.formatted()) bytes per field."
        case let .rowTooLarge(row, byteCount, maximum):
            return "Row \(row + 1) contains \(byteCount.formatted()) bytes; exact Parquet export is limited to \(maximum.formatted()) bytes per row."
        case .alreadyFinished:
            return "This Parquet export has already finished."
        case let .malformedOutput(reason):
            return "DuckDB did not produce a valid Parquet file. \(reason)"
        case let .rowCountMismatch(expected, actual):
            return "DuckDB wrote \(actual.formatted()) rows, but \(expected.formatted()) rows were staged."
        }
    }
}

/// A bounded, one-shot CSV-view-to-Parquet pipeline. Callers stream the exact
/// rows already selected by the CSV table into this object, then call `finish`.
/// DuckDB only sees a private normalized CSV and a same-volume staging path;
/// the selected destination is replaced after the completed inode is validated.
nonisolated final class CSVParquetExportOperation: @unchecked Sendable {
    static let maximumColumns = ParquetQueryService.Limits.maximumPhysicalColumns
    static let maximumFieldUTF8Bytes = 4 << 20
    static let maximumRowUTF8Bytes = 16 << 20

    // Quote doubling can expand the 16 MiB retained row to just over 32 MiB.
    // DuckDB requires its CSV buffer to hold at least four maximum-size lines.
    private static let maximumNormalizedLineBytes = 40 << 20
    private static let duckDBBufferBytes = 4 * maximumNormalizedLineBytes

    let outputColumnNames: [String]

    private let runtime: DuckDBDynamicAPI
    private let interruptHandle: ParquetInterruptHandle
    private let connectionStorage: DuckDBConnectionStorage
    private let securityScope: SecurityScopedAccess
    private let temporaryDirectory: URL
    private let spillDirectory: URL
    private let inputURL: URL
    private let writer: NormalizedCSVStageWriter
    private let publication: AtomicParquetPublication
    private let cancellation: CancellationToken?
    /// Serializes the streamed producer with `finish`. Cancellation remains
    /// independent so it can interrupt a blocked DuckDB COPY immediately.
    private let producerLock = NSLock()
    private let lock = NSLock()
    private var rowCount: Int64 = 0
    private var isFinishing = false
    private var isTerminal = false
    private var wasCancelled = false
    private var hasBegunPublication = false

    #if DEBUG || LIGHTXT_PACKAGE_TESTING
    /// Deterministic probes for the two sides of the cancellation/publication
    /// linearization point. Shipping Release builds contain neither hook.
    private var testingBeforePublicationDecision: (() throws -> Void)?
    private var testingAfterPublicationDecision: (() throws -> Void)?
    private var testingAfterFailureDecision: (() -> Void)?

    nonisolated static var testingDatabaseOptionNames: Set<String> {
        Set(databaseOptions(spillDirectory: URL(fileURLWithPath: "/private/tmp")).map(\.0))
    }
    #endif

    init(
        targetURL: URL,
        columnNames: [String],
        expectedDestination: FileFingerprint?,
        cancellation: CancellationToken? = nil,
        libraryURL: URL? = nil
    ) throws {
        let outputColumnNames = try Self.validatedColumnNames(columnNames)
        let runtime = try DuckDBDynamicAPI(libraryURL: libraryURL)
        let securityScope = SecurityScopedAccess(url: targetURL.standardizedFileURL)
        let temporaryDirectory = try Self.makeTemporaryDirectory()
        do {
            let spillDirectory = temporaryDirectory.appendingPathComponent("spill", isDirectory: true)
            try FileManager.default.createDirectory(
                at: spillDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let inputURL = temporaryDirectory.appendingPathComponent("rows.csv")
            let writer = try NormalizedCSVStageWriter(url: inputURL)
            let publication = try AtomicParquetPublication(
                targetURL: targetURL,
                expectedDestination: expectedDestination
            )

            self.outputColumnNames = outputColumnNames
            self.runtime = runtime
            self.interruptHandle = ParquetInterruptHandle(runtime: runtime)
            self.connectionStorage = DuckDBConnectionStorage(runtime: runtime)
            self.securityScope = securityScope
            self.temporaryDirectory = temporaryDirectory
            self.spillDirectory = spillDirectory
            self.inputURL = inputURL
            self.writer = writer
            self.publication = publication
            self.cancellation = cancellation
        } catch {
            securityScope.stop()
            try? FileManager.default.removeItem(at: temporaryDirectory)
            throw error
        }
    }

    deinit {
        interruptHandle.interrupt()
        interruptHandle.setConnection(nil)
        connectionStorage.close()
        writer.cancel()
        publication.cancel()
        securityScope.stop()
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    static func expectedDestination(at url: URL) throws -> FileFingerprint? {
        try FileFingerprint.atPath(url.standardizedFileURL.path)
    }

    func append(row: [String?]) throws {
        producerLock.lock()
        defer { producerLock.unlock() }
        let currentRow = try lock.withLock { () throws -> Int64 in
            guard !isFinishing, !isTerminal else { throw CSVParquetExportError.alreadyFinished }
            return rowCount
        }
        try throwIfCancelled()
        try writer.append(
            row: row,
            expectedColumnCount: outputColumnNames.count,
            rowNumber: currentRow,
            maximumFieldBytes: Self.maximumFieldUTF8Bytes,
            maximumRowBytes: Self.maximumRowUTF8Bytes,
            isCancelled: { [weak self] in self?.isCancelled ?? true }
        )
        try throwIfCancelled()
        lock.withLock { rowCount += 1 }
    }

    @discardableResult
    func finish() throws -> Int64 {
        producerLock.lock()
        defer { producerLock.unlock() }
        let expectedRows = try lock.withLock { () throws -> Int64 in
            guard !isFinishing, !isTerminal else { throw CSVParquetExportError.alreadyFinished }
            isFinishing = true
            return rowCount
        }

        do {
            try throwIfCancelled()
            try writer.finish()
            try throwIfCancelled()
            try convert(expectedRows: expectedRows)
            try throwIfCancelled()
            #if DEBUG || LIGHTXT_PACKAGE_TESTING
            try takeTestingBeforePublicationDecision()?()
            #endif
            try beginPublication()
            #if DEBUG || LIGHTXT_PACKAGE_TESTING
            try takeTestingAfterPublicationDecision()?()
            #endif
            try publication.publish()
            lock.withLock { isTerminal = true }
            securityScope.stop()
            try? FileManager.default.removeItem(at: temporaryDirectory)
            return expectedRows
        } catch {
            // Only a failure that originated as cancellation is reported as
            // cancellation. Reading the token here would let a late cancel
            // hide an already-produced conversion or publication error.
            let caughtCancellation = error is CancellationError
                || (error as? ParquetQueryError) == .cancelled
            let shouldReportCancellation = lock.withLock { () -> Bool in
                let cancellationWon = !hasBegunPublication
                    && caughtCancellation
                isTerminal = true
                return cancellationWon
            }
            #if DEBUG || LIGHTXT_PACKAGE_TESTING
            takeTestingAfterFailureDecision()?()
            #endif
            writer.cancel()
            publication.cancel()
            securityScope.stop()
            try? FileManager.default.removeItem(at: temporaryDirectory)
            if shouldReportCancellation { throw CancellationError() }
            throw error
        }
    }

    /// The main thread can call this while DuckDB COPY is blocking the export
    /// queue. Cancelling only the Swift row token cannot stop native DuckDB
    /// work. Once publication begins, cancellation is intentionally too late:
    /// the final validation and commit transaction runs to completion.
    @discardableResult
    func cancel() -> Bool {
        let shouldInterrupt = lock.withLock { () -> Bool in
            guard !isTerminal, !hasBegunPublication else { return false }
            wasCancelled = true
            return true
        }
        guard shouldInterrupt else { return false }
        cancellation?.cancel()
        interruptHandle.interrupt()
        return true
    }

    private var isCancelled: Bool {
        cancellation?.isCancelled == true || lock.withLock { wasCancelled }
    }

    private func throwIfCancelled() throws {
        if isCancelled { throw CancellationError() }
    }

    /// Linearization point shared with `cancel()`: whichever obtains the
    /// state lock first decides whether the operation cancels or publishes.
    private func beginPublication() throws {
        let canPublish = lock.withLock { () -> Bool in
            guard !isTerminal,
                  !wasCancelled,
                  cancellation?.isCancelled != true else { return false }
            hasBegunPublication = true
            return true
        }
        if !canPublish { throw CancellationError() }
    }

    #if DEBUG || LIGHTXT_PACKAGE_TESTING
    func testingInstallBeforePublicationDecision(_ hook: @escaping () throws -> Void) {
        lock.withLock { testingBeforePublicationDecision = hook }
    }

    func testingInstallAfterPublicationDecision(_ hook: @escaping () throws -> Void) {
        lock.withLock { testingAfterPublicationDecision = hook }
    }

    func testingInstallAfterFailureDecision(_ hook: @escaping () -> Void) {
        lock.withLock { testingAfterFailureDecision = hook }
    }

    private func takeTestingBeforePublicationDecision() -> (() throws -> Void)? {
        lock.withLock {
            let hook = testingBeforePublicationDecision
            testingBeforePublicationDecision = nil
            return hook
        }
    }

    private func takeTestingAfterPublicationDecision() -> (() throws -> Void)? {
        lock.withLock {
            let hook = testingAfterPublicationDecision
            testingAfterPublicationDecision = nil
            return hook
        }
    }

    private func takeTestingAfterFailureDecision() -> (() -> Void)? {
        lock.withLock {
            let hook = testingAfterFailureDecision
            testingAfterFailureDecision = nil
            return hook
        }
    }
    #endif

    private func convert(expectedRows: Int64) throws {
        let handles = try runtime.openInMemory(
            options: Self.databaseOptions(spillDirectory: spillDirectory)
        )
        connectionStorage.install(database: handles.database, connection: handles.connection)
        interruptHandle.setConnection(handles.connection)
        defer {
            // Detach under the interrupt lock before freeing the C handle so a
            // late cancel cannot call DuckDB with a stale connection pointer.
            interruptHandle.setConnection(nil)
            connectionStorage.close()
        }

        try throwIfCancelled()
        _ = try runtime.execute(
            connection: handles.connection,
            sql: "SET allowed_paths = \(Self.duckDBListLiteral([inputURL.path, publication.stagingURL.path]))",
            bindings: []
        )
        _ = try runtime.execute(
            connection: handles.connection,
            sql: "SET allowed_directories = \(Self.duckDBListLiteral([spillDirectory.path]))",
            bindings: []
        )
        _ = try runtime.execute(
            connection: handles.connection,
            sql: "SET enable_external_access = false",
            bindings: []
        )
        _ = try runtime.execute(
            connection: handles.connection,
            sql: "SET lock_configuration = true",
            bindings: []
        )
        try throwIfCancelled()

        let result = try runtime.execute(
            connection: handles.connection,
            sql: Self.copySQL(columnNames: outputColumnNames),
            bindings: [.text(inputURL.path), .text(publication.stagingURL.path)]
        )
        try throwIfCancelled()
        guard let actualRows = result.int64(column: 0, row: 0) else {
            throw CSVParquetExportError.malformedOutput("The COPY result did not include a row count.")
        }
        guard actualRows == expectedRows else {
            throw CSVParquetExportError.rowCountMismatch(expected: expectedRows, actual: actualRows)
        }
    }

    private static func databaseOptions(spillDirectory: URL) -> [(String, String)] {
        [
            // Keep spill files private while leaving DuckDB's threads, memory,
            // temporary-storage allowance, and execution policy at its own
            // defaults. Export row/field bounds only protect Swift/UI buffers.
            ("temp_directory", spillDirectory.path),
            ("autoload_known_extensions", "false"),
            ("autoinstall_known_extensions", "false"),
            ("allow_community_extensions", "false"),
            ("allow_unsigned_extensions", "false"),
            ("enable_external_access", "true"),
        ]
    }

    private static func copySQL(columnNames: [String]) -> String {
        let internalNames = columnNames.indices.map { "__lightxt_csv_column_\($0)" }
        let projection = zip(internalNames, columnNames).map { internalName, outputName in
            "CASE WHEN \(quoteIdentifier(internalName)) = 'N' "
                + "THEN NULL ELSE substr(\(quoteIdentifier(internalName)), 2) END "
                + "AS \(quoteIdentifier(outputName))"
        }.joined(separator: ", ")
        let schema = internalNames.map {
            "\(duckDBStringLiteral($0)): 'VARCHAR'"
        }.joined(separator: ", ")
        return """
            COPY (
                SELECT \(projection)
                FROM read_csv(
                    $1,
                    auto_detect = false,
                    header = false,
                    columns = {\(schema)},
                    delim = ',',
                    quote = '"',
                    escape = '"',
                    new_line = '\\n',
                    strict_mode = true,
                    ignore_errors = false,
                    null_padding = false,
                    parallel = true,
                    max_line_size = \(maximumNormalizedLineBytes),
                    buffer_size = \(duckDBBufferBytes)
                )
            ) TO $2 (FORMAT PARQUET, PRESERVE_ORDER true, USE_TMP_FILE false)
            """
    }

    private static func validatedColumnNames(_ names: [String]) throws -> [String] {
        guard !names.isEmpty else { throw CSVParquetExportError.noColumns }
        guard names.count <= maximumColumns else {
            throw CSVParquetExportError.tooManyColumns(actual: names.count, maximum: maximumColumns)
        }
        var aggregateBytes = 0
        var used: Set<String> = []
        var output: [String] = []
        output.reserveCapacity(names.count)
        for (index, rawName) in names.enumerated() {
            let sanitized = rawName.replacingOccurrences(of: "\0", with: "\u{FFFD}")
            let base = sanitized.isEmpty ? "Column \(index + 1)" : sanitized
            var candidate = base
            var suffix = 2
            while used.contains(candidate.lowercased()) {
                candidate = "\(base)_\(suffix)"
                suffix += 1
            }
            let byteCount = candidate.utf8.count
            guard byteCount <= ParquetQueryService.Limits.maximumSchemaFieldUTF8Bytes else {
                throw CSVParquetExportError.columnNameTooLarge(column: index)
            }
            let (newAggregate, overflow) = aggregateBytes.addingReportingOverflow(byteCount)
            guard !overflow,
                  newAggregate <= ParquetQueryService.Limits.maximumAggregateSchemaUTF8Bytes else {
                throw CSVParquetExportError.aggregateColumnNamesTooLarge
            }
            aggregateBytes = newAggregate
            used.insert(candidate.lowercased())
            output.append(candidate)
        }
        return output
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LighTxt-parquet-export-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return directory
    }

    private static func quoteIdentifier(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func duckDBListLiteral(_ values: [String]) -> String {
        "[" + values.map(duckDBStringLiteral).joined(separator: ",") + "]"
    }

    private static func duckDBStringLiteral(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}

private nonisolated final class NormalizedCSVStageWriter: @unchecked Sendable {
    private let url: URL
    private var descriptor: Int32

    init(url: URL) throws {
        self.url = url
        descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw LighTxtCoreError.io(operation: "create Parquet staging data", path: url.path, code: errno)
        }
    }

    deinit { cancel() }

    func append(
        row: [String?],
        expectedColumnCount: Int,
        rowNumber: Int64,
        maximumFieldBytes: Int,
        maximumRowBytes: Int,
        isCancelled: () -> Bool
    ) throws {
        guard descriptor >= 0 else { throw CSVParquetExportError.alreadyFinished }
        guard row.count == expectedColumnCount else {
            throw CSVParquetExportError.invalidRowWidth(
                row: rowNumber,
                expected: expectedColumnCount,
                actual: row.count
            )
        }
        var rowBytes = 0
        for (column, value) in row.enumerated() {
            guard let value else { continue }
            let byteCount = value.utf8.count
            guard byteCount <= maximumFieldBytes else {
                throw CSVParquetExportError.fieldTooLarge(
                    row: rowNumber,
                    column: column,
                    byteCount: byteCount,
                    maximum: maximumFieldBytes
                )
            }
            let (sum, overflow) = rowBytes.addingReportingOverflow(byteCount)
            guard !overflow, sum <= maximumRowBytes else {
                throw CSVParquetExportError.rowTooLarge(
                    row: rowNumber,
                    byteCount: overflow ? .max : sum,
                    maximum: maximumRowBytes
                )
            }
            rowBytes = sum
        }

        for (index, value) in row.enumerated() {
            if isCancelled() { throw CancellationError() }
            if index > 0 { try writeByte(0x2C, isCancelled: isCancelled) }
            guard let value else {
                try writeByte(0x4E, isCancelled: isCancelled) // N = NULL
                continue
            }
            let data = Data(value.utf8)
            let needsQuotes = data.contains(0x2C)
                || data.contains(0x22)
                || data.contains(0x0A)
                || data.contains(0x0D)
            guard needsQuotes else {
                try writeByte(0x56, isCancelled: isCancelled) // V = non-NULL
                try write(data, isCancelled: isCancelled)
                continue
            }

            // Encode a maximum of one bounded field at a time. Building this
            // small buffer avoids a write syscall for every embedded quote in
            // adversarial-but-valid CSV while keeping peak memory bounded.
            var encoded = Data(capacity: data.count * 2 + 3)
            encoded.append(0x22)
            encoded.append(0x56)
            for byte in data {
                encoded.append(byte)
                if byte == 0x22 { encoded.append(0x22) }
            }
            encoded.append(0x22)
            try write(encoded, isCancelled: isCancelled)
        }
        try writeByte(0x0A, isCancelled: isCancelled)
    }

    func finish() throws {
        guard descriptor >= 0 else { return }
        if fsync(descriptor) != 0 {
            throw LighTxtCoreError.io(operation: "synchronize Parquet staging data", path: url.path, code: errno)
        }
        if Darwin.close(descriptor) != 0 {
            descriptor = -1
            throw LighTxtCoreError.io(operation: "close Parquet staging data", path: url.path, code: errno)
        }
        descriptor = -1
    }

    func cancel() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    private func writeByte(_ byte: UInt8, isCancelled: () -> Bool) throws {
        var value = byte
        try withUnsafeBytes(of: &value) { bytes in
            try write(bytes, isCancelled: isCancelled)
        }
    }

    private func write(_ data: Data, isCancelled: () -> Bool) throws {
        try data.withUnsafeBytes { bytes in
            try write(bytes, isCancelled: isCancelled)
        }
    }

    private func write(_ bytes: UnsafeRawBufferPointer, isCancelled: () -> Bool) throws {
        guard let base = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            if isCancelled() { throw CancellationError() }
            let result = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
            if result < 0 {
                if errno == EINTR { continue }
                throw LighTxtCoreError.io(operation: "write Parquet staging data", path: url.path, code: errno)
            }
            guard result > 0 else {
                throw LighTxtCoreError.io(operation: "write Parquet staging data", path: url.path, code: EIO)
            }
            offset += result
        }
    }
}

private nonisolated final class AtomicParquetPublication: @unchecked Sendable {
    /// A process can have several document windows exporting to the same path.
    /// Serialize their very short final replacement transactions before asking
    /// filecoordinationd to coordinate with writers outside this process.
    private static let existingDestinationPublicationLock = NSLock()

    private let targetURL: URL
    private let expectedDestination: FileFingerprint?
    private let targetMode: mode_t?
    private let stagingDirectoryURL: URL
    let stagingURL: URL
    private let lock = NSLock()
    private var isFinished = false

    init(targetURL: URL, expectedDestination: FileFingerprint?) throws {
        let target = targetURL.standardizedFileURL
        var status = stat()
        let targetExisted: Bool
        let currentDestination: FileFingerprint?
        if lstat(target.path, &status) == 0 {
            targetExisted = true
            currentDestination = FileFingerprint(status)
        } else if errno == ENOENT {
            targetExisted = false
            currentDestination = nil
        } else {
            throw LighTxtCoreError.io(operation: "inspect", path: target.path, code: errno)
        }
        guard currentDestination == expectedDestination else {
            throw LighTxtCoreError.fileChangedExternally(path: target.path)
        }
        let manager = FileManager.default
        let appropriateURL = targetExisted ? target : target.deletingLastPathComponent()
        let directory: URL
        if let replacement = try? manager.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: appropriateURL,
            create: true
        ) {
            directory = replacement
        } else {
            directory = target.deletingLastPathComponent().appendingPathComponent(
                ".LighTxt-parquet-\(UUID().uuidString)",
                isDirectory: true
            )
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        self.targetURL = target
        self.expectedDestination = expectedDestination
        self.targetMode = targetExisted ? mode_t(status.st_mode & 0o7777) : nil
        self.stagingDirectoryURL = directory
        self.stagingURL = directory.appendingPathComponent(UUID().uuidString + ".parquet")
    }

    deinit { cancel() }

    func publish() throws {
        guard !lock.withLock({ isFinished }) else { return }
        var pathStatus = stat()
        guard lstat(stagingURL.path, &pathStatus) == 0,
              (pathStatus.st_mode & S_IFMT) == S_IFREG,
              pathStatus.st_nlink == 1,
              pathStatus.st_size >= 12 else {
            throw CSVParquetExportError.malformedOutput("Its staging inode is missing or is not a regular file.")
        }
        let descriptor = Darwin.open(stagingURL.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            throw LighTxtCoreError.io(operation: "open completed Parquet export", path: stagingURL.path, code: errno)
        }
        var descriptorStatus = stat()
        guard fstat(descriptor, &descriptorStatus) == 0,
              descriptorStatus.st_dev == pathStatus.st_dev,
              descriptorStatus.st_ino == pathStatus.st_ino else {
            let code = errno == 0 ? EIO : errno
            Darwin.close(descriptor)
            throw LighTxtCoreError.io(operation: "validate completed Parquet export", path: stagingURL.path, code: code)
        }
        do {
            let first = try read(count: 4, offset: 0, descriptor: descriptor)
            let last = try read(count: 4, offset: descriptorStatus.st_size - 4, descriptor: descriptor)
            guard first == Data("PAR1".utf8), last == Data("PAR1".utf8) else {
                throw CSVParquetExportError.malformedOutput("Its PAR1 header or footer marker is missing.")
            }
            if let targetMode, fchmod(descriptor, targetMode) != 0 {
                throw LighTxtCoreError.io(
                    operation: "preserve Parquet export permissions for",
                    path: targetURL.path,
                    code: errno
                )
            }
            if fsync(descriptor) != 0 {
                throw LighTxtCoreError.io(operation: "synchronize Parquet export", path: stagingURL.path, code: errno)
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        if Darwin.close(descriptor) != 0 {
            throw LighTxtCoreError.io(operation: "close Parquet export", path: stagingURL.path, code: errno)
        }
        if expectedDestination != nil {
            try replaceExistingDestination()
        } else {
            do {
                // moveItem does not replace an entry that appeared after the
                // save panel was accepted, so new destinations need no CAS.
                try FileManager.default.moveItem(at: stagingURL, to: targetURL)
            } catch {
                if (try? FileFingerprint.atPath(targetURL.path)) != nil {
                    throw LighTxtCoreError.fileChangedExternally(path: targetURL.path)
                }
                throw error
            }
        }
        lock.withLock { isFinished = true }
        try? FileManager.default.removeItem(at: stagingDirectoryURL)
    }

    /// macOS has no public expected-inode compare-and-swap rename. Coordinate
    /// the final check and replacement as one write transaction so file
    /// presenters and other coordinated writers cannot enter the former gap.
    /// An uncoordinated raw POSIX rename remains outside NSFileCoordinator's
    /// contract, but is never made less safe by a validate-after-swap scheme.
    private func replaceExistingDestination() throws {
        Self.existingDestinationPublicationLock.lock()
        defer { Self.existingDestinationPublicationLock.unlock() }

        #if LIGHTXT_PACKAGE_TESTING
        // SwiftPM tests can run inside a hosted sandbox that intentionally has
        // no filecoordinationd XPC access (NSCocoaErrorDomain 512). Exercise
        // the same in-process transaction without making the unit suite depend
        // on that unrelated host service. Xcode app builds use the coordinator.
        try validateAndReplaceDestination(at: targetURL)
        #else
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var replacementResult: Result<Void, Error>?
        coordinator.coordinate(
            writingItemAt: targetURL,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            replacementResult = Result {
                try validateAndReplaceDestination(at: coordinatedURL)
            }
        }
        if let coordinationError { throw coordinationError }
        guard let replacementResult else {
            throw LighTxtCoreError.io(
                operation: "coordinate Parquet export",
                path: targetURL.path,
                code: EIO
            )
        }
        try replacementResult.get()
        #endif
    }

    private func validateAndReplaceDestination(at destinationURL: URL) throws {
        guard try FileFingerprint.atPath(destinationURL.path) == expectedDestination else {
            throw LighTxtCoreError.fileChangedExternally(path: targetURL.path)
        }
        _ = try FileManager.default.replaceItemAt(
            destinationURL,
            withItemAt: stagingURL,
            backupItemName: nil,
            options: .usingNewMetadataOnly
        )
    }

    func cancel() {
        let shouldRemove = lock.withLock { () -> Bool in
            guard !isFinished else { return false }
            isFinished = true
            return true
        }
        if shouldRemove { try? FileManager.default.removeItem(at: stagingDirectoryURL) }
    }

    private func read(count: Int, offset: off_t, descriptor: Int32) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let readCount = bytes.withUnsafeMutableBytes { buffer in
            Darwin.pread(descriptor, buffer.baseAddress, count, offset)
        }
        guard readCount == count else {
            throw CSVParquetExportError.malformedOutput("Its PAR1 envelope could not be read.")
        }
        return Data(bytes)
    }
}
