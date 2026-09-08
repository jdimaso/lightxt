import Foundation
import XCTest
@testable import LighTxt

final class CSVInMemoryQueryServiceTests: XCTestCase {
    func testHeaderedCSVSupportsResidentPagingFilteringSortingFacetsAndSummary() async throws {
        let directory = try Self.makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("resident.csv")
        try Data(Self.fixture.utf8).write(to: source)

        let concrete = try CSVInMemoryQueryService(
            url: source,
            configuration: .init(
                columnNames: ["Name", "Group", "Amount", "Note"],
                delimiter: .comma,
                firstRowIsHeader: true
            ),
            limits: .init(maximumCellCharacters: 64),
            libraryURL: try Self.duckDBLibraryURL()
        )
        defer { Task { await concrete.close() } }
        let service: any TabularQueryService = concrete

        let metadata = try await service.open()
        XCTAssertEqual(metadata.rowCount, 4)
        XCTAssertEqual(metadata.totalColumnCount, 4)
        XCTAssertEqual(metadata.columns.map(\.name), ["Name", "Group", "Amount", "Note"])
        XCTAssertEqual(metadata.columns.map(\.typeName), Array(repeating: "VARCHAR", count: 4))

        let first = try await service.page(
            offset: 0,
            limit: 2,
            query: ParquetTableQuery()
        )
        let second = try await service.page(
            offset: 2,
            limit: 2,
            query: ParquetTableQuery()
        )
        XCTAssertEqual(first.sourceRowOrdinals + second.sourceRowOrdinals, [0, 1, 2, 3])
        XCTAssertEqual((first.rows + second.rows).map { $0[0].value }, [
            "Alpha", "Beta, Jr", "gamma", "delta",
        ])
        XCTAssertEqual(second.rows[0][3].value, "multi\nline")
        XCTAssertEqual(second.rows[1][1].value, "", "An empty CSV field must not become SQL NULL")
        XCTAssertEqual(second.rows[1][3].value, "NULL", "The literal NULL must remain text")

        let filtered = try await service.page(
            offset: 0,
            limit: 10,
            query: ParquetTableQuery(filters: [
                .init(column: 0, containsText: "A"),
                .init(column: 1, selectedValues: [.text("same")]),
            ])
        )
        XCTAssertEqual(filtered.rows.map { $0[0].value }, ["Alpha", "Beta, Jr"])
        let filteredStatements = Array((await concrete.testingRecentExecutedSQL()).suffix(2))
        XCTAssertEqual(filteredStatements.count, 2)
        XCTAssertTrue(filteredStatements[0].contains("SELECT COUNT(*)::BIGINT"))
        XCTAssertFalse(filteredStatements[1].contains("COUNT(*) OVER"))

        let nullSelection = try await service.page(
            offset: 0,
            limit: 10,
            query: ParquetTableQuery(filters: [
                .init(column: 1, selectedValues: [.null]),
            ])
        )
        XCTAssertEqual(nullSelection.totalRowCount, 0)

        let sorted = try await service.page(
            offset: 0,
            limit: 10,
            query: ParquetTableQuery(
                sort: .init(column: 1, order: .ascending)
            )
        )
        XCTAssertEqual(sorted.rows.map { $0[0].value }, ["delta", "gamma", "Alpha", "Beta, Jr"])
        XCTAssertEqual(sorted.sourceRowOrdinals, [3, 2, 0, 1], "Equal keys must keep source order")

        let unique = try await service.uniqueValues(
            forColumn: 1,
            query: ParquetTableQuery(filters: [
                .init(column: 1, selectedValues: [.text("same")]),
                .init(column: 0, containsText: "a"),
            ]),
            searchText: "",
            searchIsCaseSensitive: false,
            offset: 0,
            limit: 10
        )
        XCTAssertEqual(unique.totalValueCount, 3, "A facet excludes its own active filter")
        XCTAssertEqual(
            Dictionary(unique.values.map { ($0.value, $0.count) }, uniquingKeysWith: { first, _ in first }),
            [.text("same"): 2, .text(""): 1, .text("other"): 1]
        )

        let summary = try await service.columnSummary(
            forColumn: 2,
            query: ParquetTableQuery(filters: [.init(column: 1, selectedValues: [.text("same")])])
        )
        XCTAssertEqual(summary.rowCount, 2)
        XCTAssertEqual(summary.nullCount, 0)
        XCTAssertEqual(summary.minimum, "10")
        XCTAssertEqual(summary.maximum, "2")

        do {
            _ = try await service.structuredCellDetail(sourceRowOrdinal: 0, column: 0)
            XCTFail("Resident CSV text must not advertise structured details")
        } catch let error as CSVInMemoryQueryError {
            guard case .queryFailed = error else {
                return XCTFail("Expected an explicit unsupported-detail error, got \(error)")
            }
        }
    }

    func testHeaderlessSemicolonCSVPreservesFirstRecordAndDuplicateDisplayNames() async throws {
        let directory = try Self.makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("headerless.csv")
        try Data("one;1\r\ntwo;2\r\n".utf8).write(to: source)

        let service = try CSVInMemoryQueryService(
            url: source,
            configuration: .init(
                columnNames: ["Value", "Value"],
                delimiter: .semicolon,
                firstRowIsHeader: false
            ),
            libraryURL: try Self.duckDBLibraryURL()
        )
        defer { Task { await service.close() } }
        let metadata = try await service.open()
        XCTAssertEqual(metadata.columns.map(\.name), ["Value", "Value"])
        XCTAssertEqual(metadata.rowCount, 2)
        let page = try await service.page(offset: 0, limit: 10)
        XCTAssertEqual(page.rows.map { $0.map(\.value) }, [
            ["one", "1"],
            ["two", "2"],
        ])

        // Once loaded, the database is independent of subsequent path writes.
        try Data("replacement;99\r\n".utf8).write(to: source, options: .atomic)
        let afterReplacement = try await service.page(offset: 0, limit: 10)
        XCTAssertEqual(afterReplacement.rows, page.rows)
    }

    func testDatabaseOptionsDoNotCapDuckDBThreadsMemoryOrTemporaryStorage() async throws {
        let optionNames = Set(CSVInMemoryQueryService.databaseOptions.map(\.0))
        for name in [
            "threads", "worker_threads", "external_threads",
            "memory_limit", "max_memory", "max_temp_directory_size",
            "preserve_insertion_order", "enable_external_file_cache",
        ] {
            XCTAssertFalse(optionNames.contains(name), "Unexpected DuckDB override: \(name)")
        }
        XCTAssertFalse(optionNames.contains("temp_directory"))

        let directory = try Self.makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("cancel.csv")
        try Data("value\n1\n".utf8).write(to: source)
        let service = try CSVInMemoryQueryService(
            url: source,
            configuration: .init(columnNames: ["value"], firstRowIsHeader: true),
            libraryURL: try Self.duckDBLibraryURL()
        )
        let resourceSettings = try await service.testingResourceSettings()
        let queryPath = await service.testingSourceQueryPath()
        XCTAssertEqual(queryPath, source.resolvingSymlinksInPath().standardizedFileURL.path)
        XCTAssertFalse(queryPath.hasPrefix("/dev/fd/"))
        XCTAssertEqual(
            resourceSettings.threads,
            Int64(ProcessInfo.processInfo.activeProcessorCount),
            "DuckDB should retain its all-available-processor default"
        )
        XCTAssertFalse(resourceSettings.memoryLimit.isEmpty)
        let ownershipIsAtomic = await service.testingCancellationOwnershipIsAtomic()
        XCTAssertTrue(ownershipIsAtomic)
        await service.close()
        service.cancelCurrentQuery() // A late UI cancellation must be harmless.
    }

    func testMalformedCSVSurfacesLoadFailureAndClosedServiceRejectsQueries() async throws {
        let directory = try Self.makeFixtureDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let malformed = directory.appendingPathComponent("malformed.csv")
        try Data("a,b\n\"unterminated,b\n".utf8).write(to: malformed)
        let failed = try CSVInMemoryQueryService(
            url: malformed,
            configuration: .init(columnNames: ["a", "b"], firstRowIsHeader: true),
            libraryURL: try Self.duckDBLibraryURL()
        )
        do {
            _ = try await failed.open()
            XCTFail("Malformed CSV input must not publish a resident table")
        } catch let error as CSVInMemoryQueryError {
            guard case let .loadFailed(reason) = error else {
                return XCTFail("Expected loadFailed, got \(error)")
            }
            XCTAssertFalse(reason.isEmpty, "DuckDB's diagnostic must reach the caller")
        }

        let valid = directory.appendingPathComponent("valid.csv")
        try Data("a\n1\n".utf8).write(to: valid)
        let closed = try CSVInMemoryQueryService(
            url: valid,
            configuration: .init(columnNames: ["a"], firstRowIsHeader: true),
            libraryURL: try Self.duckDBLibraryURL()
        )
        _ = try await closed.open()
        await closed.close()
        do {
            _ = try await closed.page(offset: 0, limit: 1)
            XCTFail("A closed resident CSV service must reject queries")
        } catch let error as CSVInMemoryQueryError {
            XCTAssertEqual(error, .closed)
        }
    }

    private static let fixture = """
        Name,Group,Amount,Note
        Alpha,same,10,first
        "Beta, Jr",same,2,
        gamma,other,30,"multi
        line"
        delta,,4,NULL
        """

    private static func makeFixtureDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LighTxt-CSV-memory-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    private static let duckDBLibraryResult: Result<URL, Error> = Result {
        if let path = ProcessInfo.processInfo.environment["LIGHTXT_DUCKDB_LIBRARY_PATH"],
           FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let archive = repository
            .appendingPathComponent("ThirdParty/DuckDB/libduckdb-osx-universal-v1.4.5.zip")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LighTxt-DuckDB-memory-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let library = directory.appendingPathComponent("libduckdb.dylib")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              FileManager.default.fileExists(atPath: library.path) else {
            throw NSError(
                domain: "CSVInMemoryQueryServiceTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Could not extract the pinned DuckDB test runtime."]
            )
        }
        return library
    }

    private static func duckDBLibraryURL() throws -> URL {
        try duckDBLibraryResult.get()
    }
}
