import Darwin
import Foundation

/// Formats intentionally shared by CSV and Parquet exports. Each row is
/// encoded incrementally, so memory stays proportional to one field rather
/// than the number of rows in the result.
public nonisolated enum TabularExportFormat: String, CaseIterable, Sendable {
    case csv
    case tsv
    case pipe
    case jsonLines

    public var displayName: String {
        switch self {
        case .csv: "CSV (comma-delimited)"
        case .tsv: "TSV (tab-delimited)"
        case .pipe: "Pipe-delimited"
        case .jsonLines: "JSON Lines"
        }
    }

    public var preferredPathExtension: String {
        switch self {
        case .csv: "csv"
        case .tsv: "tsv"
        case .pipe: "psv"
        case .jsonLines: "jsonl"
        }
    }

    fileprivate var delimiter: UInt8? {
        switch self {
        case .csv: 0x2C
        case .tsv: 0x09
        case .pipe: 0x7C
        case .jsonLines: nil
        }
    }
}

public nonisolated struct TabularExportProgress: Sendable, Equatable {
    public let rowsWritten: Int64
    public let totalRows: Int64?

    public init(rowsWritten: Int64, totalRows: Int64?) {
        self.rowsWritten = max(0, rowsWritten)
        self.totalRows = totalRows.map { max(0, $0) }
    }

    public var fractionCompleted: Double? {
        guard let totalRows, totalRows > 0 else { return nil }
        return min(1, Double(rowsWritten) / Double(totalRows))
    }
}

/// Atomic, append-only export sink. The completed result replaces the chosen
/// destination only after every row has been encoded and the staging inode has
/// been synchronized. A destination fingerprint prevents a file changed after
/// the save panel was accepted from being silently overwritten.
nonisolated final class TabularExportSink: @unchecked Sendable {
    private struct StagingArea {
        let directory: URL
        let file: URL
    }

    let format: TabularExportFormat
    let headers: [String]?

    private let target: URL
    private let expectedDestination: FileFingerprint?
    private let targetExisted: Bool
    private let staging: StagingArea
    private var descriptor: Int32
    private var isFinished = false
    private var rowCount: Int64 = 0

    init(
        targetURL: URL,
        format: TabularExportFormat,
        headers: [String]?,
        expectedDestination: FileFingerprint?
    ) throws {
        let target = targetURL.standardizedFileURL
        guard try FileFingerprint.atPath(target.path) == expectedDestination else {
            throw LighTxtCoreError.fileChangedExternally(path: target.path)
        }
        var targetStatus = stat()
        let targetExisted = lstat(target.path, &targetStatus) == 0
        let staging = try Self.makeStagingArea(for: target, targetExists: targetExisted)
        let mode = targetExisted ? mode_t(targetStatus.st_mode & 0o7777) : mode_t(0o666)
        let descriptor = Darwin.open(
            staging.file.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            mode
        )
        guard descriptor >= 0 else {
            try? FileManager.default.removeItem(at: staging.directory)
            throw LighTxtCoreError.io(
                operation: "create temporary export file",
                path: staging.file.path,
                code: errno
            )
        }
        if targetExisted, fchmod(descriptor, mode) != 0 {
            let code = errno
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: staging.directory)
            throw LighTxtCoreError.io(
                operation: "preserve export permissions for",
                path: target.path,
                code: code
            )
        }

        self.target = target
        self.format = format
        self.headers = headers
        self.expectedDestination = expectedDestination
        self.targetExisted = targetExisted
        self.staging = staging
        self.descriptor = descriptor

        if format != .jsonLines, let headers {
            try appendDelimitedRow(headers.map(Optional.some))
        }
    }

    deinit {
        if descriptor >= 0 { Darwin.close(descriptor) }
        if !isFinished { try? FileManager.default.removeItem(at: staging.directory) }
    }

    static func expectedDestination(at url: URL) throws -> FileFingerprint? {
        try FileFingerprint.atPath(url.standardizedFileURL.path)
    }

    func append(row: [String?]) throws {
        guard descriptor >= 0, !isFinished else {
            throw LighTxtCoreError.io(operation: "append export row", path: target.path, code: EBADF)
        }
        if format == .jsonLines {
            try appendJSONLine(row)
        } else {
            try appendDelimitedRow(row)
        }
        rowCount += 1
    }

    func finish() throws {
        guard descriptor >= 0, !isFinished else { return }
        if fsync(descriptor) != 0 {
            throw LighTxtCoreError.io(operation: "synchronize export", path: staging.file.path, code: errno)
        }
        if Darwin.close(descriptor) != 0 {
            descriptor = -1
            throw LighTxtCoreError.io(operation: "close export", path: staging.file.path, code: errno)
        }
        descriptor = -1

        guard try FileFingerprint.atPath(target.path) == expectedDestination else {
            throw LighTxtCoreError.fileChangedExternally(path: target.path)
        }
        if targetExisted {
            _ = try FileManager.default.replaceItemAt(
                target,
                withItemAt: staging.file,
                backupItemName: nil,
                options: .usingNewMetadataOnly
            )
        } else {
            try FileManager.default.moveItem(at: staging.file, to: target)
        }
        isFinished = true
        try? FileManager.default.removeItem(at: staging.directory)
    }

    func cancel() {
        guard !isFinished else { return }
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
        try? FileManager.default.removeItem(at: staging.directory)
    }

    private func appendDelimitedRow(_ values: [String?]) throws {
        guard let delimiter = format.delimiter else { return }
        for (index, value) in values.enumerated() {
            if index > 0 { try writeByte(delimiter) }
            guard let value else { continue }
            try writeDelimitedField(value, delimiter: delimiter)
        }
        try writeByte(0x0A)
    }

    private func writeDelimitedField(_ value: String, delimiter: UInt8) throws {
        let data = Data(value.utf8)
        let needsQuotes = data.contains(delimiter)
            || data.contains(0x22)
            || data.contains(0x0A)
            || data.contains(0x0D)
        guard needsQuotes else {
            try write(data)
            return
        }
        try writeByte(0x22)
        var start = data.startIndex
        while let quote = data[start...].firstIndex(of: 0x22) {
            if start < quote { try write(data.subdata(in: start..<quote)) }
            try write(Data([0x22, 0x22]))
            start = data.index(after: quote)
        }
        if start < data.endIndex { try write(data.subdata(in: start..<data.endIndex)) }
        try writeByte(0x22)
    }

    private func appendJSONLine(_ values: [String?]) throws {
        if let headers, headers.count == values.count {
            try writeByte(0x7B) // {
            for index in values.indices {
                if index > 0 { try writeByte(0x2C) }
                try writeJSONString(headers[index])
                try writeByte(0x3A)
                try writeJSONValue(values[index])
            }
            try write(Data([0x7D, 0x0A])) // }\n
        } else {
            try writeByte(0x5B) // [
            for index in values.indices {
                if index > 0 { try writeByte(0x2C) }
                try writeJSONValue(values[index])
            }
            try write(Data([0x5D, 0x0A])) // ]\n
        }
    }

    private func writeJSONValue(_ value: String?) throws {
        guard let value else {
            try write(Data("null".utf8))
            return
        }
        try writeJSONString(value)
    }

    /// Foundation owns the exact JSON escaping rules while the sink retains
    /// row-level streaming. Encoding one scalar at a time also keeps the peak
    /// allocation bounded by the largest presented cell.
    private func writeJSONString(_ value: String) throws {
        let encoded = try JSONSerialization.data(withJSONObject: [value])
        guard encoded.count >= 2 else { return }
        try write(encoded.subdata(in: 1..<(encoded.count - 1)))
    }

    private func writeByte(_ byte: UInt8) throws {
        var value = byte
        try withUnsafeBytes(of: &value) { bytes in
            try write(bytes)
        }
    }

    private func write(_ data: Data) throws {
        try data.withUnsafeBytes { try write($0) }
    }

    private func write(_ bytes: UnsafeRawBufferPointer) throws {
        guard let base = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            let result = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
            if result < 0 {
                if errno == EINTR { continue }
                throw LighTxtCoreError.io(operation: "write export", path: staging.file.path, code: errno)
            }
            guard result > 0 else {
                throw LighTxtCoreError.io(operation: "write export", path: staging.file.path, code: EIO)
            }
            offset += result
        }
    }

    private static func makeStagingArea(for target: URL, targetExists: Bool) throws -> StagingArea {
        let manager = FileManager.default
        let directory: URL
        let appropriateURL = targetExists ? target : target.deletingLastPathComponent()
        if let replacement = try? manager.url(
               for: .itemReplacementDirectory,
               in: .userDomainMask,
               appropriateFor: appropriateURL,
               create: true
           ) {
            directory = replacement
        } else {
            // A global temporary directory may live on another volume, where
            // the final rename would fail after a long export. A private hidden
            // sibling keeps publication atomic for brand-new destinations too.
            directory = target.deletingLastPathComponent().appendingPathComponent(
                ".LighTxt-export-\(UUID().uuidString)",
                isDirectory: true
            )
            try manager.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        return StagingArea(
            directory: directory,
            file: directory.appendingPathComponent(UUID().uuidString)
        )
    }
}
