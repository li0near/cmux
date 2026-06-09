// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CmuxAgentXray",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "CmuxAgentXray",
            targets: ["CmuxAgentXray"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/smittytone/HighlighterSwift.git",
            from: "3.1.0"
        ),
    ],
    targets: [
        .target(
            name: "CmuxAgentXray",
            dependencies: [
                .product(name: "Highlighter", package: "HighlighterSwift"),
            ],
            resources: [
                .process("Resources"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
        .testTarget(
            name: "CmuxAgentXrayTests",
            dependencies: ["CmuxAgentXray"],
            resources: [
                .process("Resources/Fixtures"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .enableUpcomingFeature("ExistentialAny"),
                .enableUpcomingFeature("InternalImportsByDefault"),
            ]
        ),
    ]
)
