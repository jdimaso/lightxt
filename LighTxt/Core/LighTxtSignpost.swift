import Foundation
import os

nonisolated enum LighTxtSignpost {
    static let log = OSLog(subsystem: "app.lightext.LighTxt", category: .pointsOfInterest)

    static func begin(_ name: StaticString, id: OSSignpostID = .exclusive, bytes: Int64 = 0) {
        os_signpost(.begin, log: log, name: name, signpostID: id, "bytes=%{public}lld", bytes)
    }

    static func end(_ name: StaticString, id: OSSignpostID = .exclusive, bytes: Int64 = 0) {
        os_signpost(.end, log: log, name: name, signpostID: id, "bytes=%{public}lld", bytes)
    }

    static func event(_ name: StaticString, bytes: Int64 = 0) {
        os_signpost(.event, log: log, name: name, "bytes=%{public}lld", bytes)
    }

    static func jsonParserAdmission(
        bytes: Int64,
        maximumResidentBytes: Int64,
        residentSource: Bool
    ) {
        os_signpost(
            .event,
            log: log,
            name: "JSONParserAdmission",
            "bytes=%{public}lld resident_limit=%{public}lld resident=%{public}d",
            bytes,
            maximumResidentBytes,
            residentSource ? 1 : 0
        )
    }

    static func jsonIndexReady(
        bytes: Int64,
        accelerated: Bool,
        sourceSeconds: Double,
        parserSeconds: Double,
        nativeBuildSeconds: Double,
        validationSeconds: Double,
        publicationSeconds: Double
    ) {
        os_signpost(
            .event,
            log: log,
            name: "JSONIndexReady",
            "bytes=%{public}lld accelerated=%{public}d source_ms=%{public}.3f parser_ms=%{public}.3f native_ms=%{public}.3f validation_ms=%{public}.3f publication_ms=%{public}.3f",
            bytes,
            accelerated ? 1 : 0,
            sourceSeconds * 1_000,
            parserSeconds * 1_000,
            nativeBuildSeconds * 1_000,
            validationSeconds * 1_000,
            publicationSeconds * 1_000
        )
    }
}
