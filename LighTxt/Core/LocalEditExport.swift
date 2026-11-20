import Foundation

/// An original inode may no longer be readable, but the immutable piece tree
/// still knows which bytes to copy and owns every inserted or rewritten byte.
nonisolated enum LocalEditExport {
    static func write(
        snapshot: DocumentSnapshot, sourceURL: URL, to destination: URL,
        expectedDestination: FileFingerprint?
    ) throws {
        let target = destination.standardizedFileURL.resolvingSymlinksInPath()
        let source = sourceURL.standardizedFileURL.resolvingSymlinksInPath()
        guard target != source else { throw LighTxtCoreError.copyDestinationMatchesDocument }
        if let existing = expectedDestination, let current = try FileFingerprint.atPath(source.path),
           existing.device == current.device && existing.inode == current.inode {
            throw LighTxtCoreError.copyDestinationMatchesDocument
        }
        let sink = try TabularExportSink(targetURL: target, format: .jsonLines,
                                        headers: nil, expectedDestination: expectedDestination)
        var header: [String: Any] = [
            "format": "LighTxt local edits", "version": 1, "editedByteCount": snapshot.byteCount,
            "instructions": "Start with an empty output. Process records in order. For copyOriginal, copy byteCount bytes at zero-based byteOffset from a byte-identical copy of the original revision. For insertUTF8, append the UTF-8 bytes of text. For insertBase64, append the decoded bytes. Omitted original bytes were deleted.",
        ]
        if let original = snapshot.originalFile {
            let stamp = original.fingerprint
            header["original"] = [
                "filename": original.url.lastPathComponent, "byteCount": stamp.byteCount,
                "device": String(stamp.device), "inode": String(stamp.inode),
                "modificationUnixSeconds": stamp.modifiedSeconds,
                "modificationNanoseconds": stamp.modifiedNanoseconds,
            ] as [String: Any]
        }
        try sink.appendJSONRecord(header)
        try snapshot.forEachLocalEditSegment { range in
            try Task.checkCancellation()
            try sink.appendJSONRecord([
                "op": "copyOriginal", "byteOffset": range.lowerBound,
                "byteCount": range.upperBound - range.lowerBound,
            ])
        } inserted: { bytes in
            try Task.checkCancellation()
            let data = Data(bytes)
            if let text = String(data: data, encoding: .utf8), data.elementsEqual(text.utf8) {
                try sink.appendJSONRecord(["op": "insertUTF8", "text": text])
            } else {
                try sink.appendJSONRecord(["op": "insertBase64", "base64": data.base64EncodedString()])
            }
        }
        try Task.checkCancellation()
        try sink.finish()
    }
}
