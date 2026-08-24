import Darwin
import Foundation
import XCTest
@testable import LighTxt

final class ParquetQueryServiceTests: XCTestCase {
    func testPagedQueriesFiltersSummariesAndSandboxAllowlist() async throws {
        let fixtureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LighTxt Parquet 'fixtures' \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: fixtureDirectory) }

        let sourceURL = fixtureDirectory.appendingPathComponent("quoted's sample.parquet")
        let fixtureData = try Data(contentsOf: Self.fixtureURL())
        try fixtureData.write(to: sourceURL)
        let deniedURL = fixtureDirectory.appendingPathComponent("other.parquet")
        try fixtureData.write(to: deniedURL)

        let service = try ParquetQueryService(
            url: sourceURL,
            limits: .init(maximumCellCharacters: 64),
            libraryURL: try Self.duckDBLibraryURL()
        )
        let metadata = try await service.open()
        XCTAssertEqual(metadata.rowCount, 8)
        XCTAssertEqual(metadata.totalColumnCount, 6)
        XCTAssertEqual(metadata.columns.map(\.name), [
            "id", "group_key", "value", "amount", "file_row_number", "nested",
        ])

        let first = try await service.page(offset: 0, limit: 2)
        let second = try await service.page(offset: 2, limit: 2)
        let third = try await service.page(offset: 4, limit: 2)
        let fourth = try await service.page(offset: 6, limit: 2)
        XCTAssertEqual((first.rows + second.rows + third.rows + fourth.rows).compactMap { $0.first?.value }, [
            "1", "2", "3", "4", "5", "6", "7", "8",
        ])
        XCTAssertEqual(
            first.sourceRowOrdinals + second.sourceRowOrdinals
                + third.sourceRowOrdinals + fourth.sourceRowOrdinals,
            Array(0..<8).map(Int64.init)
        )
        XCTAssertTrue(metadata.columns[5].isStructured)
        let nestedDetail = try await service.structuredCellDetail(
            sourceRowOrdinal: first.sourceRowOrdinals[0],
            column: 5
        )
        XCTAssertEqual(nestedDetail.json, #"{"name":"alpha","nums":[1,2]}"#)
        XCTAssertFalse(nestedDetail.isTruncated)

        let sortedQuery = ParquetTableQuery(
            sort: ParquetSortDescriptor(column: 1, order: .ascending)
        )
        let sortedIDs = try await [0, 2, 4, 6].asyncFlatMap { offset in
            try await service.page(offset: Int64(offset), limit: 2, query: sortedQuery)
                .rows.compactMap { $0.first?.value }
        }
        XCTAssertEqual(sortedIDs, ["4", "1", "2", "3", "6", "7", "8", "5"])
        XCTAssertEqual(Set(sortedIDs).count, 8, "Duplicate sort keys must not duplicate or omit page rows")

        let combined = ParquetTableQuery(filters: [
            .init(column: 1, selectedValues: [.text("same"), .null]),
            .init(column: 2, containsText: "zet"),
        ])
        let combinedIDs = try await service.page(offset: 0, limit: 10, query: combined)
            .rows.compactMap { $0.first?.value }
        XCTAssertEqual(combinedIDs, ["6"])

        for (filterValue, expectedID) in [
            (ParquetFilterValue.null, "1"),
            (.text(""), "2"),
            (.text("NULL"), "3"),
        ] {
            let query = ParquetTableQuery(filters: [
                .init(column: 2, selectedValues: [filterValue]),
            ])
            let filteredIDs = try await service.page(offset: 0, limit: 10, query: query)
                .rows.compactMap { $0.first?.value }
            XCTAssertEqual(filteredIDs, [expectedID])
        }

        let searchedFacets = try await service.uniqueValues(
            forColumn: 2,
            query: .init(filters: [.init(column: 1, selectedValues: [.text("other")])])
        )
        XCTAssertEqual(searchedFacets.values.map(\.value), [.text("O'Brien")])

        let filteredSummary = try await service.columnSummary(
            forColumn: 3,
            query: .init(filters: [.init(column: 1, selectedValues: [.text("same")])])
        )
        XCTAssertEqual(filteredSummary.rowCount, 6)
        XCTAssertEqual(filteredSummary.nullCount, 1)
        XCTAssertEqual(filteredSummary.minimum, "1.25")
        XCTAssertEqual(filteredSummary.maximum, "5.00")
        let nestedSummary = try await service.columnSummary(forColumn: 5)
        XCTAssertNil(nestedSummary.minimum)

        let longValuePage = try await service.page(offset: 4, limit: 1)
        XCTAssertEqual(longValuePage.rows[0][2].value?.count, 65)
        XCTAssertTrue(longValuePage.rows[0][2].isTruncated)

        let binaryStringPage = try await service.page(offset: 6, limit: 2)
        XCTAssertEqual(binaryStringPage.rows[0][2].value, "before\0after")
        XCTAssertEqual(binaryStringPage.rows[1][2].value, "\u{F8FF}\u{F8FE}")
        XCTAssertFalse(binaryStringPage.rows[1][2].isTruncated)

        #if DEBUG
        let cancellationOwnershipIsAtomic = await service.testingCancellationOwnershipIsAtomic()
        XCTAssertTrue(cancellationOwnershipIsAtomic)
        let canReadDeniedURL = await service.testingCanReadParquet(at: deniedURL)
        let canWriteTemporary = await service.testingCanWriteTemporaryProbe()
        let canUnlock = await service.testingCanExecuteSecurityProbe("SET enable_external_access = true")
        let canInstall = await service.testingCanExecuteSecurityProbe("INSTALL httpfs")
        let canLoad = await service.testingCanExecuteSecurityProbe("LOAD httpfs")
        XCTAssertFalse(canReadDeniedURL)
        XCTAssertTrue(canWriteTemporary)
        XCTAssertFalse(canUnlock)
        XCTAssertFalse(canInstall)
        XCTAssertFalse(canLoad)
        #endif
        service.cancelCurrentQuery()
        await service.close()
        // A late UI/task cancellation after close must never call DuckDB with
        // the connection pointer that close just freed.
        service.cancelCurrentQuery()

        do {
            _ = try await service.page(offset: 0, limit: 1)
            XCTFail("A closed Parquet service must reject new queries")
        } catch let error as ParquetQueryError {
            XCTAssertEqual(error, .closed)
        }
    }

    func testUniqueValuesSupportSearchPagingAndBoundedResultCaching() async throws {
        let service = try ParquetQueryService(
            url: Self.fixtureURL(),
            limits: .init(maximumUniqueValues: 2),
            libraryURL: try Self.duckDBLibraryURL()
        )
        defer { Task { await service.close() } }
        _ = try await service.open()

        var offset: Int64 = 0
        var allValues: [ParquetFilterValue] = []
        var reportedTotal: Int64?
        repeat {
            let page = try await service.uniqueValues(
                forColumn: 2,
                offset: offset,
                limit: 2
            )
            XCTAssertEqual(page.offset, offset)
            XCTAssertLessThanOrEqual(page.values.count, 2)
            if let reportedTotal {
                XCTAssertEqual(page.totalValueCount, reportedTotal)
            } else {
                reportedTotal = page.totalValueCount
            }
            allValues.append(contentsOf: page.values.map(\.value))
            guard let nextOffset = page.nextOffset else { break }
            XCTAssertTrue(page.hasMore)
            XCTAssertTrue(page.isTruncated)
            offset = nextOffset
        } while true
        XCTAssertEqual(Int(reportedTotal ?? -1), allValues.count)
        XCTAssertGreaterThan(allValues.count, 2, "The 2-row page limit must not cap the logical facet")
        XCTAssertEqual(Set(allValues).count, allValues.count)

        let beforeRepeat = await service.testingUniqueValuesCacheSnapshot()
        let repeated = try await service.uniqueValues(forColumn: 2, offset: 0, limit: 2)
        let afterRepeat = await service.testingUniqueValuesCacheSnapshot()
        XCTAssertEqual(repeated.offset, 0)
        XCTAssertEqual(afterRepeat.executedQueryCount, beforeRepeat.executedQueryCount)
        XCTAssertEqual(afterRepeat.hitCount, beforeRepeat.hitCount + 1)

        let searched = try await service.uniqueValues(
            forColumn: 2,
            searchText: "ZET",
            offset: 0,
            limit: 2
        )
        XCTAssertEqual(searched.values.map(\.value), [.text("zeta")])
        XCTAssertEqual(searched.totalValueCount, 1)
        XCTAssertFalse(searched.hasMore)
        let caseSensitive = try await service.uniqueValues(
            forColumn: 2,
            searchText: "ZET",
            searchIsCaseSensitive: true,
            offset: 0,
            limit: 2
        )
        XCTAssertTrue(caseSensitive.values.isEmpty)
        XCTAssertEqual(caseSensitive.totalValueCount, 0)

        // A target column's own draft remains excluded from its facet. Sort is
        // also irrelevant, so both requests share the exact same cache key.
        let targetFilteredAndSorted = ParquetTableQuery(
            filters: [.init(column: 2, selectedValues: [.text("zeta")])],
            sort: .init(column: 0, order: .descending)
        )
        let beforeEquivalentRequest = await service.testingUniqueValuesCacheSnapshot()
        _ = try await service.uniqueValues(
            forColumn: 2,
            query: targetFilteredAndSorted,
            offset: 0,
            limit: 2
        )
        let afterEquivalentRequest = await service.testingUniqueValuesCacheSnapshot()
        XCTAssertEqual(
            afterEquivalentRequest.executedQueryCount,
            beforeEquivalentRequest.executedQueryCount
        )
        XCTAssertEqual(afterEquivalentRequest.hitCount, beforeEquivalentRequest.hitCount + 1)

        let boundedService = try ParquetQueryService(
            url: Self.fixtureURL(),
            limits: .init(maximumUniqueValues: 2, maximumUniqueValueCacheBytes: 700),
            libraryURL: try Self.duckDBLibraryURL()
        )
        defer { Task { await boundedService.close() } }
        _ = try await boundedService.open()
        _ = try await boundedService.uniqueValues(
            forColumn: 2,
            searchText: "zet",
            limit: 2
        )
        let firstCached = await boundedService.testingUniqueValuesCacheSnapshot()
        XCTAssertEqual(firstCached.entryCount, 1)
        XCTAssertLessThanOrEqual(firstCached.retainedByteCost, firstCached.maximumByteCost)
        _ = try await boundedService.uniqueValues(
            forColumn: 2,
            searchText: "not-present",
            limit: 2
        )
        let afterEviction = await boundedService.testingUniqueValuesCacheSnapshot()
        XCTAssertLessThanOrEqual(afterEviction.entryCount, 1)
        XCTAssertLessThanOrEqual(afterEviction.retainedByteCost, afterEviction.maximumByteCost)
    }

    func testUniqueValueLengthLimitUsesUTF8Bytes() async throws {
        #if DEBUG
        let bootstrap = try ParquetQueryService(
            url: Self.fixtureURL(),
            libraryURL: try Self.duckDBLibraryURL()
        )
        _ = try await bootstrap.open()
        let fixtureURL = try await bootstrap.testingCreateFacetUTF8BoundaryFixture()
        let service = try ParquetQueryService(
            url: fixtureURL,
            limits: .init(maximumUniqueValues: 10, maximumFilterValueCharacters: 64),
            libraryURL: try Self.duckDBLibraryURL()
        )
        defer {
            Task {
                await service.close()
                await bootstrap.close()
            }
        }
        _ = try await service.open()

        let validMultibyte = String(repeating: "雪", count: 21) // 63 UTF-8 bytes
        let oversizedMultibyte = String(repeating: "雪", count: 22) // 66 UTF-8 bytes
        let values = try await service.uniqueValues(forColumn: 0, limit: 10)
        XCTAssertEqual(values.totalValueCount, 2)
        XCTAssertEqual(values.omittedOversizedValueCount, 2)
        XCTAssertEqual(
            Set(values.values.map(\.value)),
            Set([.text(validMultibyte), .text(String(repeating: "a", count: 64))])
        )
        XCTAssertFalse(values.values.map(\.value).contains(.text(oversizedMultibyte)))

        let selectable = try await service.page(
            offset: 0,
            limit: 10,
            query: .init(filters: [
                .init(column: 0, selectedValues: [.text(validMultibyte)]),
            ])
        )
        XCTAssertEqual(selectable.totalRowCount, 1)
        do {
            _ = try await service.page(
                offset: 0,
                limit: 10,
                query: .init(filters: [
                    .init(column: 0, selectedValues: [.text(oversizedMultibyte)]),
                ])
            )
            XCTFail("A facet must never return a value that selection validation rejects")
        } catch let error as ParquetQueryError {
            guard case .invalidFilter = error else {
                return XCTFail("Expected invalidFilter, got \(error)")
            }
        }
        #else
        throw XCTSkip("The UTF-8 boundary fixture generator is available in Debug tests.")
        #endif
    }

    func testFilteredFirstPageGetsExactCountInOneDuckDBQuery() async throws {
        let service = try ParquetQueryService(
            url: Self.fixtureURL(),
            libraryURL: try Self.duckDBLibraryURL()
        )
        defer { Task { await service.close() } }
        _ = try await service.open()
        let query = ParquetTableQuery(filters: [
            .init(column: 1, selectedValues: [.text("same")]),
        ])
        let before = await service.testingUniqueValuesCacheSnapshot()
        let first = try await service.page(offset: 0, limit: 2, query: query)
        let afterFirst = await service.testingUniqueValuesCacheSnapshot()
        XCTAssertEqual(first.totalRowCount, 6)
        XCTAssertEqual(first.rows.count, 2)
        XCTAssertEqual(afterFirst.executedQueryCount, before.executedQueryCount + 1)

        let second = try await service.page(offset: 2, limit: 2, query: query)
        let afterSecond = await service.testingUniqueValuesCacheSnapshot()
        XCTAssertEqual(second.totalRowCount, 6)
        XCTAssertEqual(second.rows.count, 2)
        XCTAssertEqual(afterSecond.executedQueryCount, afterFirst.executedQueryCount + 1)

        let emptyQuery = ParquetTableQuery(filters: [
            .init(column: 1, containsText: "definitely-not-present"),
        ])
        let beforeEmpty = await service.testingUniqueValuesCacheSnapshot()
        let empty = try await service.page(offset: 0, limit: 2, query: emptyQuery)
        let afterEmpty = await service.testingUniqueValuesCacheSnapshot()
        XCTAssertEqual(empty.totalRowCount, 0)
        XCTAssertTrue(empty.rows.isEmpty)
        XCTAssertEqual(afterEmpty.executedQueryCount, beforeEmpty.executedQueryCount + 1)
    }

    func testPinnedSourceSurvivesAtomicReplacementAndRejectsInPlaceMutation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LighTxt pinned parquet \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let sourceURL = directory.appendingPathComponent("source.parquet")
        let replacementURL = directory.appendingPathComponent("replacement.parquet")
        try Data(contentsOf: Self.fixtureURL()).write(to: sourceURL)
        try Self.structuredFixtureData().write(to: replacementURL)
        let service = try ParquetQueryService(
            url: sourceURL,
            libraryURL: try Self.duckDBLibraryURL()
        )
        let original = try await service.open()
        XCTAssertEqual(original.rowCount, 8)
        XCTAssertEqual(Darwin.rename(replacementURL.path, sourceURL.path), 0)

        // These requests were not made before replacement. They must still
        // query the original descriptor rather than reopening the pathname.
        let originalPage = try await service.page(offset: 6, limit: 2)
        XCTAssertEqual(originalPage.rows.compactMap { $0.first?.value }, ["7", "8"])
        let originalFacet = try await service.uniqueValues(
            forColumn: 2,
            searchText: "O'Brien",
            limit: 10
        )
        XCTAssertEqual(originalFacet.values.map(\.value), [.text("O'Brien")])
        await service.close()

        let replacementService = try ParquetQueryService(
            url: sourceURL,
            libraryURL: try Self.duckDBLibraryURL()
        )
        let replacement = try await replacementService.open()
        XCTAssertEqual(replacement.rowCount, 18)
        XCTAssertEqual(replacement.totalColumnCount, 5)
        await replacementService.close()

        // Truncate/rewrite keeps the same inode, so the pinned descriptor alone
        // is insufficient. Its fstat revision guard must reject every new scan.
        let mutableURL = directory.appendingPathComponent("mutable.parquet")
        try Data(contentsOf: Self.fixtureURL()).write(to: mutableURL)
        let mutableService = try ParquetQueryService(
            url: mutableURL,
            libraryURL: try Self.duckDBLibraryURL()
        )
        _ = try await mutableService.open()
        let cachedFacet = try await mutableService.uniqueValues(
            forColumn: 2,
            searchText: "zet",
            limit: 10
        )
        let writer = try FileHandle(forWritingTo: mutableURL)
        try writer.truncate(atOffset: 0)
        try writer.write(contentsOf: Self.structuredFixtureData())
        try writer.close()

        // Already-materialized UI data remains usable, while an uncached scan
        // cannot mix a new byte stream into the old document generation.
        let repeatedCachedFacet = try await mutableService.uniqueValues(
            forColumn: 2,
            searchText: "zet",
            limit: 10
        )
        XCTAssertEqual(repeatedCachedFacet, cachedFacet)
        do {
            _ = try await mutableService.page(offset: 2, limit: 2)
            XCTFail("An in-place rewrite must require explicit Reload")
        } catch let error as ParquetQueryError {
            XCTAssertEqual(error, .sourceChanged)
        }
        await mutableService.close()
    }

    func testOptInParquetDistinctBenchmark() async throws {
        guard let path = ProcessInfo.processInfo.environment["LIGHTXT_PARQUET_BENCHMARK_PATH"],
              !path.isEmpty else {
            throw XCTSkip("Set LIGHTXT_PARQUET_BENCHMARK_PATH to run the large-file facet benchmark.")
        }
        let service = try ParquetQueryService(
            url: URL(fileURLWithPath: path),
            libraryURL: try Self.duckDBLibraryURL()
        )
        defer { Task { await service.close() } }
        let metadata = try await service.open()
        let requestedName = ProcessInfo.processInfo.environment["LIGHTXT_PARQUET_BENCHMARK_COLUMN"] ?? "NPI"
        guard let column = metadata.columns.firstIndex(where: {
            $0.name.caseInsensitiveCompare(requestedName) == .orderedSame
        }) else {
            XCTFail("The benchmark column was not present in the visible schema.")
            return
        }

        let before = await service.testingUniqueValuesCacheSnapshot()
        let firstStart = ProcessInfo.processInfo.systemUptime
        let first = try await service.uniqueValues(forColumn: column)
        let firstSeconds = ProcessInfo.processInfo.systemUptime - firstStart
        let afterFirst = await service.testingUniqueValuesCacheSnapshot()
        let repeatStart = ProcessInfo.processInfo.systemUptime
        let repeated = try await service.uniqueValues(forColumn: column)
        let repeatSeconds = ProcessInfo.processInfo.systemUptime - repeatStart
        let afterRepeat = await service.testingUniqueValuesCacheSnapshot()

        XCTAssertEqual(repeated, first)
        XCTAssertEqual(afterFirst.executedQueryCount, before.executedQueryCount + 1)
        XCTAssertEqual(afterRepeat.executedQueryCount, afterFirst.executedQueryCount)
        XCTAssertLessThan(firstSeconds, 8.0, "The first DuckDB facet exceeded the interactive budget")
        XCTAssertLessThan(repeatSeconds, min(0.05, max(0.005, firstSeconds * 0.1)))
        print(
            "LighTxt Parquet facet benchmark: first=\(firstSeconds)s, cached=\(repeatSeconds)s, "
                + "rows=\(metadata.rowCount), values=\(first.values.count), total=\(first.totalValueCount)"
        )
    }

    func testStructuredDetailsCoverStructListMapSpecialTextAndBounds() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LighTxt structured parquet \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("structured values.parquet")
        try Self.structuredFixtureData().write(to: url)

        let service = try ParquetQueryService(url: url, libraryURL: try Self.duckDBLibraryURL())
        defer { Task { await service.close() } }
        let metadata = try await service.open()
        XCTAssertEqual(metadata.rowCount, 18)
        XCTAssertEqual(metadata.columns.map(\.isStructured), [false, true, true, true, false])
        for typeName in [
            "STRUCT(message VARCHAR)", "MAP(VARCHAR, INTEGER)", "INTEGER[]",
            "VARCHAR[3]", "LIST(INTEGER)", "UNION(number INTEGER, text VARCHAR)",
        ] {
            XCTAssertTrue(ParquetColumn(index: 0, name: "value", typeName: typeName, isNullable: true).isStructured)
        }
        for typeName in ["VARCHAR", "JSON", "DECIMAL(18,2)", "TIMESTAMP", "ENUM('[value]')"] {
            XCTAssertFalse(ParquetColumn(index: 0, name: "value", typeName: typeName, isNullable: true).isStructured)
        }

        let page = try await service.page(offset: 0, limit: 18)
        XCTAssertEqual(page.sourceRowOrdinals, Array(0..<18).map(Int64.init))
        let structDetail = try await service.structuredCellDetail(sourceRowOrdinal: 0, column: 1)
        XCTAssertEqual(
            structDetail.json,
            #"{"message":"quote \" comma, braces {} newline\n雪","nums":[1,2]}"#
        )
        let listDetail = try await service.structuredCellDetail(sourceRowOrdinal: 0, column: 2)
        XCTAssertEqual(listDetail.json, #"["item,1","雪\"1"]"#)
        let mapDetail = try await service.structuredCellDetail(sourceRowOrdinal: 0, column: 3)
        XCTAssertEqual(mapDetail.json, #"{"key":"value\"1","braces{}":"line\n1"}"#)
        let nullDetail = try await service.structuredCellDetail(sourceRowOrdinal: 1, column: 1)
        XCTAssertNil(nullDetail.json)
        XCTAssertFalse(nullDetail.isTruncated)

        let longDetail = try await service.structuredCellDetail(sourceRowOrdinal: 17, column: 1)
        XCTAssertTrue(longDetail.isTruncated)
        XCTAssertEqual(
            longDetail.json?.count,
            ParquetQueryService.Limits.maximumStructuredDetailCharacters
        )
        XCTAssertTrue(longDetail.json?.hasPrefix(#"{"message":"xxxx"#) == true)

        do {
            _ = try await service.structuredCellDetail(sourceRowOrdinal: 0, column: 4)
            XCTFail("JSON-looking scalar text must not be treated as a nested Parquet type")
        } catch let error as ParquetQueryError {
            guard case .queryFailed = error else {
                return XCTFail("Expected a structured-type rejection, got \(error)")
            }
        }
    }

    func testMalformedEnvelopeIsDiagnosed() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LighTxt malformed parquet \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("broken.parquet")
        try Data("not parquet".utf8).write(to: url)
        let service = try ParquetQueryService(url: url, libraryURL: try Self.duckDBLibraryURL())
        defer { Task { await service.close() } }
        do {
            _ = try await service.open()
            XCTFail("A missing PAR1 envelope must fail before DuckDB scans it")
        } catch let error as ParquetQueryError {
            guard case .malformedFile = error else {
                return XCTFail("Expected malformedFile, got \(error)")
            }
        }
    }

    func testQueryAndCustomLimitsRemainGloballyBounded() async throws {
        let limits = ParquetQueryService.Limits(
            maximumPageCharacters: .max,
            maximumUniqueValues: 5_000,
            maximumSelectedValuesPerColumn: 5_000,
            maximumFilterValueCharacters: 1_048_576,
            workerThreads: 999
        )
        XCTAssertEqual(limits.maximumPageCharacters, 16_777_216)
        XCTAssertEqual(limits.maximumUniqueValues, 8)
        XCTAssertEqual(limits.workerThreads, 4)
        XCTAssertNotEqual(ParquetFilterValue.null.displayText, ParquetFilterValue.text("(null)").displayText)
        XCTAssertNotEqual(ParquetFilterValue.text("").displayText, ParquetFilterValue.text("(empty)").displayText)

        let service = try ParquetQueryService(
            url: Self.fixtureURL(),
            limits: limits,
            libraryURL: try Self.duckDBLibraryURL()
        )
        _ = try await service.open()

        let duplicateColumnQuery = ParquetTableQuery(filters: [
            .init(column: 1, containsText: "same"),
            .init(column: 1, selectedValues: [.text("other")]),
        ])
        await assertInvalidFilter(service, query: duplicateColumnQuery)

        let tooManySelected = ParquetTableQuery(filters: (0..<6).map { column in
            let values = Set((0..<834).map { ParquetFilterValue.text("\(column)-\($0)") })
            return ParquetColumnFilter(column: column, selectedValues: values)
        })
        await assertInvalidFilter(service, query: tooManySelected)

        let largeContains = String(repeating: "x", count: 900_000)
        let tooManyFilterBytes = ParquetTableQuery(filters: (0..<5).map { column in
            ParquetColumnFilter(column: column, containsText: largeContains + String(column))
        })
        await assertInvalidFilter(service, query: tooManyFilterBytes)
        await service.close()
    }

    private func assertInvalidFilter(
        _ service: ParquetQueryService,
        query: ParquetTableQuery,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await service.page(offset: 0, limit: 1, query: query)
            XCTFail("Expected an invalidFilter error", file: file, line: line)
        } catch let error as ParquetQueryError {
            guard case .invalidFilter = error else {
                return XCTFail("Expected invalidFilter, got \(error)", file: file, line: line)
            }
        } catch {
            XCTFail("Expected ParquetQueryError, got \(error)", file: file, line: line)
        }
    }

    private static func duckDBLibraryURL() throws -> URL {
        let repository = repositoryURL()
        let archive = repository
            .appendingPathComponent("ThirdParty/DuckDB/libduckdb-osx-universal-v1.4.5.zip")
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LighTxt-DuckDB-tests-v1.4.5", isDirectory: true)
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
                domain: "ParquetQueryServiceTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "Could not extract the pinned DuckDB test runtime."]
            )
        }
        return library
    }

    private static func fixtureURL() -> URL {
        repositoryURL().appendingPathComponent("Tests/Fixtures/Parquet/query-service.parquet")
    }

    private static func structuredFixtureData() throws -> Data {
        let url = repositoryURL()
            .appendingPathComponent("Tests/Fixtures/Parquet/structured-values.parquet.base64")
        let encoded = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: encoded) else {
            throw NSError(
                domain: "ParquetQueryServiceTests",
                code: 65,
                userInfo: [NSLocalizedDescriptionKey: "The structured Parquet fixture is not valid base64."]
            )
        }
        return data
    }

    private static func repositoryURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static let fixtureBase64 = "UEFSMRUAFTwVTiwVDBUAFQYVBgAAKLUv/SAe8QAAAgAAAAwBAQAAAAIAAAADAAAABAAAAAUAAAAGAAAAFQAVoAEVaCwVDBUAFQYVBgAAKLUv/SBQXQEAJAIjAAAACAFBAgAEAAAAc2FtZQUAAABvdGhlcgQAAABzYW1lAgArCBfBERUAFfgIFXYsFQwVABUGFQYAACi1L/1gPAGNAQB0AiEAAABBPgAEAAAATlVMTAcAAABPJ0JyaWVu9AEAAHgEAAAAemV0YQIAwAN1OGALFQAVmgEVWiwVDBUAFQYVBgAAKLUv/SBNJQEAyCEAAABBOwB9APoAcP7/awMALAEAAAAAAAAFEAAy7hh4wKIRFQAVPBVOLBUMFQAVBhUGAAAotS/9IB7xAAACAAAADAFjAAAAYgAAAGEAAABgAAAAXwAAAF4AAAAVABXmARWIASwVDBUAFQYVBgAAKLUv/SBz3QEAFANBAAAAQSoKAAUAAABhbHBoYQQAAABiZXRhBQAAAGdhbW1kZWx0YQcAAABlcHNpbG9uAgCxCEMSiAMVABXEAhVyLBUQFQAVBhUGAAAotS/9IKKFAQA0AiEAAABBQgBhJAWSAQAAAAIAAAADAAAACQAAAAoAAAAFAAAABAAFEgA3SLFXBEYVAhm8NQAYDWR1Y2tkYl9zY2hlbWEVDAAVAiUCGAJpZCUiABUMJQIYCWdyb3VwX2tleSUAABUMJQIYBXZhbHVlJQAAFQQlAhgGYW1vdW50JQoVBBUULFwVBBUUAAAAFQIlAhgPZmlsZV9yb3dfbnVtYmVyJSIANQIYBm5lc3RlZBUEABUMJQIYBG5hbWUlAAA1AhgEbnVtcxUCFQYANQQYBGxpc3QVAgAVAiUCGAdlbGVtZW50JSIAFgwZHBl8JgAcFQIZFQAZGAJpZBUMFgwWXhZwJgg8GAQGAAAAGAQBAAAAFgAoBAYAAAAYBAEAAAAREQAAACYAHBUMGRUAGRgJZ3JvdXBfa2V5FQwWDBbEARaMASZ4PBgEc2FtZRgFb3RoZXIWAigEc2FtZRgFb3RoZXIREQAAACYAHBUMGRUAGRgFdmFsdWUVDBYMFpwJFpoBJoQCPBgEemV0YSYCKAR6ZXRhGAAREQAAACYAHBUEGRUAGRgGYW1vdW50FQwWDBa+ARZ+Jp4DPBgIawMAAAAAAAAYCHD+////////FgIoCGsDAAAAAAAAGAhw/v///////xERAAAAJgAcFQIZFQAZGA9maWxlX3Jvd19udW1iZXIVDBYMFl4WcCacBDwYBGMAAAAYBF4AAAAWACgEYwAAABgEXgAAABERAAAAJgAcFQwZFQAZKAZuZXN0ZWQEbmFtZRUMFgwWjAIWrgEmjAU8GAVnYW1tYRgFYWxwaGEWAigFZ2FtbWFYBWFscGhhEREAAAAmABwVAhkVABlIBmVzdGVkBG51bXMEbGlzdAdlbGVtZW50FQwWEBboAhagASa6BjwYBAoAAAAYBAEAAAAWBCgECgAAABgEAQAAABERAAAAFs4SFgwmCBLIBwAoKER1Y2tEQiB2ZXJzaW9uIHYxLjUuMyAoYnVpbGQgMTRlY2ExMWJkKRl8HAAAHAAAHAAAHAAAHAAAHAAHAAAADgAgAAUEFSMA=="
}

private extension Array where Element == Int {
    func asyncFlatMap<T>(_ transform: (Int) async throws -> [T]) async rethrows -> [T] {
        var output: [T] = []
        for element in self { output += try await transform(element) }
        return output
    }
}
