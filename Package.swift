// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "LighTxtCore",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(name: "LighTxtCore", targets: ["LighTxt"]),
    ],
    targets: [
        .target(
            name: "LighTxtJSONAccelerator",
            path: "LighTxt/Vendor/JSONAccelerator",
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("simdjson"),
                // Keep the native multi-gigabyte scanner fast while the Swift
                // product remains fully debuggable under -Onone. Without this,
                // simdjson's semantic traversal is compiled at -O0 and a 3.53
                // GB file takes minutes in an ordinary Debug run.
                .unsafeFlags(["-O3"], .when(configuration: .debug)),
                .unsafeFlags(["-O3"], .when(configuration: .release)),
            ]
        ),
        .target(
            name: "LighTxt",
            dependencies: ["LighTxtJSONAccelerator"],
            path: "LighTxt",
            exclude: [
                "Application",
                "Assets.xcassets",
                "Core/README.md",
                "Documents",
                "Info.plist",
                "LighTxt.entitlements",
                "LighTxt-Bridging-Header.h",
                "Sparkle-LICENSE.txt",
                "ThirdPartyNotices.txt",
                "Model/DocumentSearchController.swift",
                "Model/LighTxtDocumentSession.swift",
                "UI",
                "Vendor",
            ],
            sources: [
                "Core",
                "Syntax",
                "Model/SparseUTF8LineIndex.swift",
                "Model/JSONStructureController.swift",
            ]
        ),
        .testTarget(
            name: "LighTxtCoreTests",
            dependencies: ["LighTxt", "LighTxtJSONAccelerator"],
            path: "Tests/LighTxtCoreTests"
        ),
        .testTarget(
            name: "LighTxtSyntaxTests",
            dependencies: ["LighTxt"],
            path: "Tests/LighTxtSyntaxTests"
        ),
        .testTarget(
            name: "LighTxtLineIndexTests",
            dependencies: ["LighTxt"],
            path: "Tests/LighTxtLineIndexTests"
        ),
    ]
)
