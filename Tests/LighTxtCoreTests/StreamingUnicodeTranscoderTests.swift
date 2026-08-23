import Foundation
import XCTest
@testable import LighTxt

final class StreamingUnicodeTranscoderTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LighTxt-transcoder-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: false
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    func testEverySupportedSourceEncodingStreamsToBOMFreeUTF8() throws {
        // A leading NUL makes UTF-16 LE's BOM + first code unit byte-identical
        // to the UTF-32 LE BOM. The explicit source selection must win.
        let text = "\0Aé😀𝄞\r\n終"
        let encodings: [DocumentTextEncoding] = [
            .utf8,
            .utf16LittleEndian,
            .utf16BigEndian,
            .utf32LittleEndian,
            .utf32BigEndian,
        ]

        for encoding in encodings {
            let source = sourceURL("source-\(encoding.rawValue)")
            let bom = byteOrderMark(for: encoding)
            var input = Data(bom)
            input.append(try encoded(text, as: encoding))
            try input.write(to: source)

            let result = try StreamingUnicodeTranscoder.transcodeFileToUTF8(
                at: source,
                sourceEncoding: encoding,
                configuration: configuration(readChunkByteCount: 1)
            )

            XCTAssertEqual(try Data(contentsOf: result.fileURL), Data(text.utf8))
            XCTAssertEqual(result.sourceEncoding, encoding)
            XCTAssertEqual(result.outputEncoding, .utf8)
            XCTAssertEqual(result.sourceByteOrderMarkByteCount, bom.count)
            XCTAssertEqual(result.outputByteOrderMarkByteCount, 0)
            XCTAssertEqual(result.sourceByteCount, Int64(input.count))
            XCTAssertEqual(result.outputByteCount, Int64(text.utf8.count))
        }
    }

    func testCodeUnitsAndSurrogatePairsCanCrossEveryChunkBoundaryWithoutBOM() throws {
        let text = "x😀y𐐷z"
        for encoding in [
            DocumentTextEncoding.utf16LittleEndian,
            .utf16BigEndian,
            .utf32LittleEndian,
            .utf32BigEndian,
        ] {
            let source = sourceURL("boundary-\(encoding.rawValue)")
            try encoded(text, as: encoding).write(to: source)

            for chunkSize in 1...5 {
                let result = try StreamingUnicodeTranscoder.transcodeFileToUTF8(
                    at: source,
                    sourceEncoding: encoding,
                    configuration: configuration(readChunkByteCount: chunkSize)
                )
                XCTAssertEqual(
                    try String(contentsOf: result.fileURL, encoding: .utf8),
                    text,
                    "\(encoding.rawValue), chunk \(chunkSize)"
                )
                XCTAssertEqual(result.sourceByteOrderMarkByteCount, 0)
            }
        }
    }

    func testUTF8SequencesCanCrossSingleByteChunks() throws {
        let text = "ASCII € 😀 𐐷"
        let source = sourceURL("utf8-boundaries.txt")
        try Data(text.utf8).write(to: source)

        let result = try StreamingUnicodeTranscoder.transcodeFileToUTF8(
            at: source,
            sourceEncoding: .utf8,
            configuration: configuration(readChunkByteCount: 1)
        )

        XCTAssertEqual(try String(contentsOf: result.fileURL, encoding: .utf8), text)
    }

    func testSnapshotUTF8ValidationCrossesBoundedReadSlices() throws {
        let source = sourceURL("snapshot-valid.txt")
        var input = Data(repeating: 0x61, count: (1 << 20) - 1)
        input.append(contentsOf: [0xE2, 0x82, 0xAC]) // Euro sign split at 1 MiB.
        input.append(contentsOf: [0xF0, 0x9F, 0x98, 0x80])
        try input.write(to: source)

        let engine = try FileBackedPieceTable(opening: source)
        defer { engine.close() }
        let snapshot = try engine.snapshot()
        var updates: [UnicodeTranscodingProgress] = []

        XCTAssertNoThrow(
            try StreamingUnicodeTranscoder.validateUTF8(
                snapshot: snapshot,
                progress: { updates.append($0) }
            )
        )
        XCTAssertEqual(updates.first?.sourceBytesProcessed, 0)
        XCTAssertEqual(updates.last?.sourceBytesProcessed, Int64(input.count))
        XCTAssertEqual(updates.last?.fractionCompleted, 1)
    }

    func testSnapshotUTF8ValidationRejectsBytesBeyondSampleAndTruncatedEOF() throws {
        let lateSource = sourceURL("snapshot-late-invalid.txt")
        var lateInput = Data(repeating: 0x61, count: (64 << 10) + 7)
        lateInput.append(contentsOf: [0xF0, 0x28, 0x8C, 0xBC])
        try lateInput.write(to: lateSource)
        let lateEngine = try FileBackedPieceTable(opening: lateSource)
        defer { lateEngine.close() }

        XCTAssertThrowsError(
            try StreamingUnicodeTranscoder.validateUTF8(
                snapshot: lateEngine.snapshot()
            )
        ) { error in
            XCTAssertEqual(
                error as? UnicodeTranscodingError,
                .malformedInput(
                    encoding: .utf8,
                    byteOffset: Int64((64 << 10) + 7)
                )
            )
        }

        let truncatedSource = sourceURL("snapshot-truncated.txt")
        var truncatedInput = Data(repeating: 0x61, count: 1_024)
        truncatedInput.append(contentsOf: [0xE2, 0x82])
        try truncatedInput.write(to: truncatedSource)
        let truncatedEngine = try FileBackedPieceTable(opening: truncatedSource)
        defer { truncatedEngine.close() }

        XCTAssertThrowsError(
            try StreamingUnicodeTranscoder.validateUTF8(
                snapshot: truncatedEngine.snapshot()
            )
        ) { error in
            XCTAssertEqual(
                error as? UnicodeTranscodingError,
                .malformedInput(encoding: .utf8, byteOffset: 1_024)
            )
        }
    }

    func testConflictingByteOrderMarkFailsBeforeCreatingScratchOutput() throws {
        let source = sourceURL("mismatch.txt")
        var input = Data(byteOrderMark(for: .utf16LittleEndian))
        input.append(try encoded("hello", as: .utf16LittleEndian))
        try input.write(to: source)

        XCTAssertThrowsError(
            try StreamingUnicodeTranscoder.transcodeFileToUTF8(
                at: source,
                sourceEncoding: .utf16BigEndian,
                configuration: configuration(readChunkByteCount: 2)
            )
        ) { error in
            XCTAssertEqual(
                error as? UnicodeTranscodingError,
                .byteOrderMarkMismatch(
                    expected: .utf16BigEndian,
                    found: .utf16LittleEndian
                )
            )
        }
        XCTAssertEqual(try scratchDirectories(), [])
    }

    func testMalformedInputReportsSequenceStartAndLeavesNoScratchOutput() throws {
        let cases: [(DocumentTextEncoding, [UInt8], Int64)] = [
            (.utf8, [0x61, 0xF0, 0x28, 0x8C, 0xBC], 1),
            (.utf8, [0x61, 0xE2, 0x82], 1),
            (.utf16LittleEndian, [0x3D, 0xD8], 0),
            (.utf16BigEndian, [0xDC, 0x00], 0),
            (.utf16LittleEndian, [0x61], 0),
            (.utf32LittleEndian, [0x00, 0xD8, 0x00, 0x00], 0),
            (.utf32BigEndian, [0x00, 0x11, 0x00, 0x00], 0),
            (.utf32LittleEndian, [0x41, 0x00, 0x00], 0),
        ]

        for (index, testCase) in cases.enumerated() {
            let source = sourceURL("malformed-\(index)")
            try Data(testCase.1).write(to: source)
            XCTAssertThrowsError(
                try StreamingUnicodeTranscoder.transcodeFileToUTF8(
                    at: source,
                    sourceEncoding: testCase.0,
                    configuration: configuration(readChunkByteCount: 1)
                )
            ) { error in
                XCTAssertEqual(
                    error as? UnicodeTranscodingError,
                    .malformedInput(
                        encoding: testCase.0,
                        byteOffset: testCase.2
                    ),
                    "case \(index)"
                )
            }
            XCTAssertEqual(try scratchDirectories(), [], "case \(index)")
        }
    }

    func testCancellationIsObservedAndPartialScratchDirectoryIsRemoved() throws {
        let source = sourceURL("cancel.txt")
        try Data(repeating: 0x61, count: 32 << 10).write(to: source)
        let cancellation = CancellationToken()
        var updates: [UnicodeTranscodingProgress] = []

        XCTAssertThrowsError(
            try StreamingUnicodeTranscoder.transcodeFileToUTF8(
                at: source,
                sourceEncoding: .utf8,
                configuration: configuration(
                    readChunkByteCount: 17,
                    progressIntervalByteCount: 17
                ),
                cancellation: cancellation,
                progress: { update in
                    updates.append(update)
                    if update.sourceBytesProcessed >= 34 {
                        cancellation.cancel()
                    }
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError, "Unexpected error: \(error)")
        }

        XCTAssertGreaterThanOrEqual(updates.count, 3)
        XCTAssertEqual(updates.first?.sourceBytesProcessed, 0)
        XCTAssertEqual(
            updates.map(\.sourceBytesProcessed),
            updates.map(\.sourceBytesProcessed).sorted()
        )
        XCTAssertEqual(try scratchDirectories(), [])
    }

    func testProgressCompletesMonotonicallyAndConfigurationRemainsBounded() throws {
        let text = String(repeating: "a😀", count: 8_000)
        let source = sourceURL("progress.txt")
        try Data(text.utf8).write(to: source)
        var updates: [UnicodeTranscodingProgress] = []
        var configuration = configuration(
            readChunkByteCount: .max,
            progressIntervalByteCount: 2_003
        )
        XCTAssertEqual(
            configuration.readChunkByteCount,
            UnicodeTranscodingConfiguration.maximumReadChunkByteCount
        )
        // Public configuration is mutable; the operation must still enforce
        // its bound if a caller changes it after initialization.
        configuration.readChunkByteCount = .max

        let result = try StreamingUnicodeTranscoder.transcodeFileToUTF8(
            at: source,
            sourceEncoding: .utf8,
            configuration: configuration,
            progress: { updates.append($0) }
        )

        XCTAssertEqual(updates.first?.sourceBytesProcessed, 0)
        XCTAssertEqual(updates.last?.sourceBytesProcessed, result.sourceByteCount)
        XCTAssertEqual(updates.last?.outputBytesProduced, result.outputByteCount)
        XCTAssertEqual(updates.last?.fractionCompleted, 1)
        XCTAssertEqual(
            updates.map(\.sourceBytesProcessed),
            updates.map(\.sourceBytesProcessed).sorted()
        )
    }

    func testScratchOutputHasPrivatePermissionsAtomicFinalNameAndOwnedLifetime() throws {
        let source = sourceURL("permissions.txt")
        try Data("private".utf8).write(to: source)

        var result: UnicodeScratchFile? = try StreamingUnicodeTranscoder
            .transcodeFileToUTF8(
                at: source,
                sourceEncoding: .utf8,
                configuration: configuration(readChunkByteCount: 2)
            )
        let scratchDirectory = try XCTUnwrap(result?.scratchDirectoryURL)
        let fileURL = try XCTUnwrap(result?.fileURL)

        XCTAssertEqual(try permissions(at: scratchDirectory), 0o700)
        XCTAssertEqual(try permissions(at: fileURL), 0o600)
        let names = try FileManager.default.contentsOfDirectory(atPath: scratchDirectory.path)
        XCTAssertEqual(names, [fileURL.lastPathComponent])
        XCTAssertFalse(names.contains { $0.hasSuffix(".partial") })

        result = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratchDirectory.path))
    }

    func testUTF8FileStreamsToUTF16AndUTF32WithSelectableBOM() throws {
        let text = "hello é 😀 𐐷\n"
        let source = sourceURL("export.txt")
        try Data(text.utf8).write(to: source)

        for encoding in [
            DocumentTextEncoding.utf16LittleEndian,
            .utf16BigEndian,
            .utf32LittleEndian,
            .utf32BigEndian,
        ] {
            let result = try StreamingUnicodeTranscoder.transcodeUTF8File(
                at: source,
                to: encoding,
                includeByteOrderMark: true,
                configuration: configuration(readChunkByteCount: 1)
            )
            let output = try Data(contentsOf: result.fileURL)
            let bom = byteOrderMark(for: encoding)
            XCTAssertTrue(output.starts(with: bom))
            XCTAssertEqual(try decoded(Data(output.dropFirst(bom.count)), as: encoding), text)
            XCTAssertEqual(
                result.outputByteOrderMarkByteCount,
                byteOrderMark(for: encoding).count
            )
        }

        let withoutBOM = try StreamingUnicodeTranscoder.transcodeUTF8File(
            at: source,
            to: .utf16LittleEndian,
            includeByteOrderMark: false,
            configuration: configuration(readChunkByteCount: 3)
        )
        let data = try Data(contentsOf: withoutBOM.fileURL)
        XCTAssertFalse(data.starts(with: byteOrderMark(for: .utf16LittleEndian)))
        XCTAssertEqual(
            String(data: data, encoding: .utf16LittleEndian),
            text
        )
    }

    func testRealUTF8ValidationReleaseQAWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["LIGHTXT_UTF8_VALIDATION_TARGET"],
              !path.isEmpty else {
            throw XCTSkip(
                "Set LIGHTXT_UTF8_VALIDATION_TARGET for the opt-in read-only UTF-8 validation QA"
            )
        }
        let url = URL(fileURLWithPath: path)
        let before = try FileManager.default.attributesOfItem(atPath: path)
        let engine = try FileBackedPieceTable(opening: url)
        defer { engine.close() }
        let snapshot = try engine.snapshot()
        let clock = ContinuousClock()
        let started = clock.now

        try StreamingUnicodeTranscoder.validateUTF8(snapshot: snapshot)

        let elapsed = started.duration(to: clock.now)
        let after = try FileManager.default.attributesOfItem(atPath: path)
        XCTAssertEqual(before[.size] as? NSNumber, after[.size] as? NSNumber)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
        XCTAssertFalse(engine.hasUnsavedChanges)
        print(
            "LighTxt UTF-8 validation release QA: bytes=\(snapshot.byteCount), elapsed=\(elapsed)"
        )
    }

    private func configuration(
        readChunkByteCount: Int,
        progressIntervalByteCount: Int64 = 4 << 20
    ) -> UnicodeTranscodingConfiguration {
        UnicodeTranscodingConfiguration(
            readChunkByteCount: readChunkByteCount,
            progressIntervalByteCount: progressIntervalByteCount,
            scratchDirectoryParentURL: temporaryDirectory
        )
    }

    private func sourceURL(_ name: String) -> URL {
        temporaryDirectory.appendingPathComponent(name)
    }

    private func scratchDirectories() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: temporaryDirectory.path)
            .filter { $0.hasPrefix("LighTxt-transcode-") }
            .sorted()
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func encoded(
        _ text: String,
        as encoding: DocumentTextEncoding
    ) throws -> Data {
        let foundationEncoding: String.Encoding
        switch encoding {
        case .utf8: foundationEncoding = .utf8
        case .utf16LittleEndian: foundationEncoding = .utf16LittleEndian
        case .utf16BigEndian: foundationEncoding = .utf16BigEndian
        case .utf32LittleEndian: foundationEncoding = .utf32LittleEndian
        case .utf32BigEndian: foundationEncoding = .utf32BigEndian
        }
        return try XCTUnwrap(text.data(using: foundationEncoding))
    }

    private func decoded(
        _ data: Data,
        as encoding: DocumentTextEncoding
    ) throws -> String {
        let foundationEncoding: String.Encoding
        switch encoding {
        case .utf8: foundationEncoding = .utf8
        case .utf16LittleEndian: foundationEncoding = .utf16LittleEndian
        case .utf16BigEndian: foundationEncoding = .utf16BigEndian
        case .utf32LittleEndian: foundationEncoding = .utf32LittleEndian
        case .utf32BigEndian: foundationEncoding = .utf32BigEndian
        }
        return try XCTUnwrap(String(data: data, encoding: foundationEncoding))
    }

    private func byteOrderMark(for encoding: DocumentTextEncoding) -> [UInt8] {
        switch encoding {
        case .utf8: [0xEF, 0xBB, 0xBF]
        case .utf16LittleEndian: [0xFF, 0xFE]
        case .utf16BigEndian: [0xFE, 0xFF]
        case .utf32LittleEndian: [0xFF, 0xFE, 0x00, 0x00]
        case .utf32BigEndian: [0x00, 0x00, 0xFE, 0xFF]
        }
    }
}
