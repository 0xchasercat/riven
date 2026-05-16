// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Bento",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "BentoCore", targets: ["BentoCore"]),
        .executable(name: "Bento", targets: ["Bento"]),
        .executable(name: "BentoAgent", targets: ["BentoAgent"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.1"),
        .package(url: "https://github.com/krzyzanowskim/STTextView.git", from: "2.0.0")
    ],
    targets: [
        .target(name: "BentoCore", dependencies: ["Yams", "GhosttyVt"]),
        .executableTarget(
            name: "Bento",
            dependencies: [
                "BentoCore",
                .product(name: "STTextView", package: "STTextView")
            ],
            swiftSettings: [
                // main.swift uses @main on a top-level type, which requires
                // parse-as-library mode (otherwise @main + top-level code
                // conflict). The file is owned by the orchestrator and must
                // not be renamed.
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
        .executableTarget(name: "BentoAgent", dependencies: ["BentoCore"]),
        .testTarget(name: "BentoCoreTests", dependencies: ["BentoCore"]),
        .binaryTarget(
            name: "GhosttyVt",
            path: "External/ghostty-vt-install/lib/ghostty-vt.xcframework"
        )
    ]
)
