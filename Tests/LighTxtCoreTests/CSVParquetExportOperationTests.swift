import Darwin
import Foundation
import XCTest
@testable import LighTxt

final class CSVParquetExportOperationTests: XCTestCase {
    private enum InjectedFailure: Error, Equatable {
        case afterConversion
    }

    func testDuckDBResourceSettingsUseEngineDefaults() {
        let configuredOptions = CSVParquetExportOperation.testingDatabaseOptionNames
        for name in [
            "threads", "worker_threads", "external_threads",
            "memory_limit", "max_memory", "max_temp_directory_size",
            "preserve_insertion_order", "enable_external_file_cache",
        ] {
            XCTAssertFalse(configuredOptions.contains(name), "Unexpected DuckDB override: \(name)")
        }
        XCTAssertTrue(configuredOptions.contains("temp_directory"))
    }

    func testRoundTripPreservesExactStringsNullsOrderAndSafeColumnNames() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("quoted's export.parquet")
        let operation = try CSVParquetExportOperation(
            targetURL: target,
            columnNames: ["Name", "name", "", "quoted\"column", "nul\0name"],
            expectedDestination: nil,
            libraryURL: try Self.duckDBLibraryURL()
        )
        XCTAssertEqual(operation.outputColumnNames, [
            "Name", "name_2", "Column 3", "quoted\"column", "nul\u{FFFD}name",
        ])

        let expectedRows: [[String?]] = [
            ["00123", "comma,value", "", "line 1\nline 2", "before\0after"],
            [nil, "quote \" value", "N", "snow 雪", nil],
            ["2026-09-07", "carriage\rreturn", "VN", "apostrophe's", "end"],
        ]
        for row in expectedRows { try operation.append(row: row) }
        let exportedRowCount = try operation.finish()
        XCTAssertEqual(exportedRowCount, 3)

        let envelope = try Data(contentsOf: target)
        XCTAssertEqual(envelope.prefix(4), Data("PAR1".utf8))
        XCTAssertEqual(envelope.suffix(4), Data("PAR1".utf8))

        let service = try ParquetQueryService(
            url: target,
            limits: .init(maximumCellCharacters: 65_536),
            libraryURL: try Self.duckDBLibraryURL()
        )
        defer { Task { await service.close() } }
        let metadata = try await service.open()
        XCTAssertEqual(metadata.rowCount, 3)
        XCTAssertEqual(metadata.columns.map(\.name), operation.outputColumnNames)
        XCTAssertEqual(metadata.columns.map(\.typeName), Array(repeating: "VARCHAR", count: 5))
        let page = try await service.page(offset: 0, limit: 10)
        XCTAssertEqual(page.rows.map { $0.map(\.value) }, expectedRows)
        await service.close()
    }

    func testOneColumnNullRowAndEmptyDatasetRemainRepresentable() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let nullTarget = directory.appendingPathComponent("one-null.parquet")
        let nullOperation = try CSVParquetExportOperation(
            targetURL: nullTarget,
            columnNames: ["value"],
            expectedDestination: nil,
            libraryURL: try Self.duckDBLibraryURL()
        )
        try nullOperation.append(row: [nil])
        let nullRowCount = try nullOperation.finish()
        XCTAssertEqual(nullRowCount, 1)
        let nullService = try ParquetQueryService(
            url: nullTarget,
            libraryURL: try Self.duckDBLibraryURL()
        )
        let nullMetadata = try await nullService.open()
        XCTAssertEqual(nullMetadata.rowCount, 1)
        let nullPage = try await nullService.page(offset: 0, limit: 1)
        XCTAssertNil(nullPage.rows[0][0].value)
        await nullService.close()

        let emptyTarget = directory.appendingPathComponent("empty.parquet")
        let emptyOperation = try CSVParquetExportOperation(
            targetURL: emptyTarget,
            columnNames: ["value"],
            expectedDestination: nil,
            libraryURL: try Self.duckDBLibraryURL()
        )
        let emptyRowCount = try emptyOperation.finish()
        XCTAssertEqual(emptyRowCount, 0)
        let emptyService = try ParquetQueryService(
            url: emptyTarget,
            libraryURL: try Self.duckDBLibraryURL()
        )
        let emptyMetadata = try await emptyService.open()
        XCTAssertEqual(emptyMetadata.rowCount, 0)
        let emptyPage = try await emptyService.page(offset: 0, limit: 1)
        XCTAssertTrue(emptyPage.rows.isEmpty)
        await emptyService.close()
    }

    func testLargeQuotedLineExceedsDuckDBDefaultButStillExports() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("large-line.parquet")
        let operation = try CSVParquetExportOperation(
            targetURL: target,
            columnNames: ["large"],
            expectedDestination: nil,
            libraryURL: try Self.duckDBLibraryURL()
        )
        // Embedded quotes force the normalized CSV beyond DuckDB's default
        // 2 MB maximum line size while staying inside the exact-export bound.
        let value = String(repeating: "\"", count: (2 << 20) + 1)
        try operation.append(row: [value])
        let exportedRowCount = try operation.finish()
        XCTAssertEqual(exportedRowCount, 1)

        let service = try ParquetQueryService(
            url: target,
            libraryURL: try Self.duckDBLibraryURL()
        )
        let metadata = try await service.open()
        XCTAssertEqual(metadata.rowCount, 1)
        await service.close()
    }

    func testCancellationAndDestinationMutationNeverPublishPartialOutput() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let libraryURL = try Self.duckDBLibraryURL()

        let cancelledTarget = directory.appendingPathComponent("cancelled.parquet")
        let original = Data("original destination".utf8)
        try original.write(to: cancelledTarget)
        let cancellation = CancellationToken()
        let cancelled = try CSVParquetExportOperation(
            targetURL: cancelledTarget,
            columnNames: ["value"],
            expectedDestination: try CSVParquetExportOperation.expectedDestination(at: cancelledTarget),
            cancellation: cancellation,
            libraryURL: libraryURL
        )
        try cancelled.append(row: ["new value"])
        cancelled.testingInstallBeforePublicationDecision { [weak cancelled] in
            XCTAssertTrue(cancelled?.cancel() ?? false)
        }
        XCTAssertThrowsError(try cancelled.finish()) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(try Data(contentsOf: cancelledTarget), original)

        let changedTarget = directory.appendingPathComponent("changed.parquet")
        try original.write(to: changedTarget)
        let lateCancellation = CancellationToken()
        let changed = try CSVParquetExportOperation(
            targetURL: changedTarget,
            columnNames: ["value"],
            expectedDestination: try CSVParquetExportOperation.expectedDestination(at: changedTarget),
            cancellation: lateCancellation,
            libraryURL: libraryURL
        )
        try changed.append(row: ["new value"])
        let external = Data("external replacement".utf8)
        changed.testingInstallAfterPublicationDecision {
            // Once publication wins, a late token must not turn a real
            // destination-conflict failure into CancellationError.
            lateCancellation.cancel()
            try external.write(to: changedTarget, options: .atomic)
        }
        XCTAssertThrowsError(try changed.finish()) { error in
            guard case .fileChangedExternally = error as? LighTxtCoreError else {
                return XCTFail("Expected fileChangedExternally, got \(error)")
            }
        }
        XCTAssertEqual(try Data(contentsOf: changedTarget), external)
    }

    func testExistingDestinationIsReplacedAndLateOperationCancellationLoses() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("existing.parquet")
        try Data("original destination".utf8).write(to: target)
        XCTAssertEqual(chmod(target.path, 0o640), 0)

        let operation = try CSVParquetExportOperation(
            targetURL: target,
            columnNames: ["value"],
            expectedDestination: try CSVParquetExportOperation.expectedDestination(at: target),
            libraryURL: try Self.duckDBLibraryURL()
        )
        try operation.append(row: ["replacement"])
        operation.testingInstallAfterPublicationDecision { [weak operation] in
            XCTAssertFalse(operation?.cancel() ?? true)
        }
        let exportedRowCount = try operation.finish()
        XCTAssertEqual(exportedRowCount, 1)

        var status = stat()
        XCTAssertEqual(lstat(target.path, &status), 0)
        XCTAssertEqual(status.st_mode & 0o777, 0o640)
        let service = try ParquetQueryService(
            url: target,
            libraryURL: try Self.duckDBLibraryURL()
        )
        let metadata = try await service.open()
        XCTAssertEqual(metadata.rowCount, 1)
        let page = try await service.page(offset: 0, limit: 1)
        XCTAssertEqual(page.rows[0][0].value, "replacement")
        await service.close()
    }

    func testConcurrentCoordinatedReplacementsDoNotOverwriteTheFirstWinner() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("contended.parquet")
        try Data("accepted destination".utf8).write(to: target)
        let expected = try CSVParquetExportOperation.expectedDestination(at: target)
        let libraryURL = try Self.duckDBLibraryURL()
        let first = try CSVParquetExportOperation(
            targetURL: target,
            columnNames: ["value"],
            expectedDestination: expected,
            libraryURL: libraryURL
        )
        let second = try CSVParquetExportOperation(
            targetURL: target,
            columnNames: ["value"],
            expectedDestination: expected,
            libraryURL: libraryURL
        )
        try first.append(row: ["first"])
        try second.append(row: ["second"])

        let outcomes = await withTaskGroup(of: String.self) { group in
            group.addTask { Self.finishOutcome(first) }
            group.addTask { Self.finishOutcome(second) }
            var values: [String] = []
            for await value in group { values.append(value) }
            return values
        }
        XCTAssertEqual(outcomes.filter { $0 == "success" }.count, 1)
        XCTAssertEqual(outcomes.filter { $0 == "fileChangedExternally" }.count, 1)
        guard outcomes.filter({ $0 == "success" }).count == 1,
              outcomes.filter({ $0 == "fileChangedExternally" }).count == 1 else {
            return
        }

        let service = try ParquetQueryService(url: target, libraryURL: libraryURL)
        _ = try await service.open()
        let page = try await service.page(offset: 0, limit: 1)
        XCTAssertTrue(["first", "second"].contains(page.rows[0][0].value))
        await service.close()
    }

    func testFailureIsNotMaskedByCancellationBeforeItIsClassified() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("failed.parquet")
        let cancellation = CancellationToken()
        let operation = try CSVParquetExportOperation(
            targetURL: target,
            columnNames: ["value"],
            expectedDestination: nil,
            cancellation: cancellation,
            libraryURL: try Self.duckDBLibraryURL()
        )
        try operation.append(row: ["value"])
        operation.testingInstallBeforePublicationDecision { [weak operation] in
            XCTAssertTrue(operation?.cancel() ?? false)
            throw InjectedFailure.afterConversion
        }
        operation.testingInstallAfterFailureDecision { [weak operation] in
            XCTAssertFalse(operation?.cancel() ?? true)
        }

        XCTAssertThrowsError(try operation.finish()) { error in
            XCTAssertEqual(error as? InjectedFailure, .afterConversion)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testRowShapeAndSizeLimitsFailBeforePublication() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("invalid.parquet")
        let operation = try CSVParquetExportOperation(
            targetURL: target,
            columnNames: ["a", "b"],
            expectedDestination: nil,
            libraryURL: try Self.duckDBLibraryURL()
        )
        XCTAssertThrowsError(try operation.append(row: ["only one"])) { error in
            XCTAssertEqual(
                error as? CSVParquetExportError,
                .invalidRowWidth(row: 0, expected: 2, actual: 1)
            )
        }
        XCTAssertThrowsError(
            try operation.append(row: [String(repeating: "x", count: (4 << 20) + 1), ""])
        ) { error in
            guard case .fieldTooLarge(row: 0, column: 0, _, maximum: 4 << 20) =
                    error as? CSVParquetExportError else {
                return XCTFail("Expected fieldTooLarge, got \(error)")
            }
        }
        operation.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "LighTxt CSV Parquet tests \(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private static func finishOutcome(_ operation: CSVParquetExportOperation) -> String {
        do {
            _ = try operation.finish()
            return "success"
        } catch let error as LighTxtCoreError {
            if case .fileChangedExternally = error { return "fileChangedExternally" }
            return "error: \(error.localizedDescription)"
        } catch {
            return "error: \(error.localizedDescription)"
        }
    }

    private static func duckDBLibraryURL() throws -> URL {
        let archive = repositoryURL()
            .appendingPathComponent("ThirdParty/DuckDB/libduckdb-osx-universal-v1.4.5.zip")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LighTxt-DuckDB-export-tests-v1.4.5", isDirectory: true)
        let library = directory.appendingPathComponent("libduckdb.dylib")
        if FileManager.default.fileExists(atPath: library.path) { return library }
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: library.path) else {
            throw NSError(
                domain: "CSVParquetExportOperationTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Could not extract DuckDB for testing."]
            )
        }
        return library
    }

    private static func repositoryURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
