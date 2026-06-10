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
    ],
    targets: [
        .target(
            name: "CmuxAgentXray",
            dependencies: [
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
