// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Riven",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "RivenCore", targets: ["RivenCore"]),
        .executable(name: "Riven", targets: ["Riven"]),
        .executable(name: "RivenAgent", targets: ["RivenAgent"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.1"),
        .package(url: "https://github.com/krzyzanowskim/STTextView.git", from: "2.0.0")
    ],
    targets: [
        .target(
            name: "RivenCore",
            dependencies: ["Yams", "GhosttyVt"],
            resources: [
                // Ships the vendored Universal2 ripgrep binary so
                // RipgrepFileSearch can locate it via Bundle.module.
                // Refresh via `scripts/install-rg.sh`.
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "Riven",
            dependencies: [
                "RivenCore",
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
        .executableTarget(
            name: "RivenAgent",
            dependencies: ["RivenCore"],
            swiftSettings: [
                // main.swift uses @main on a top-level type. Without this
                // flag SourceKit (and some toolchain configurations) flags
                // "@main attribute cannot be used in a module that contains
                // top-level code" because the filename main.swift would
                // otherwise be treated as a script.
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
        .testTarget(name: "RivenCoreTests", dependencies: ["RivenCore"]),
        .binaryTarget(
            name: "GhosttyVt",
            path: "External/ghostty-vt-install/lib/ghostty-vt.xcframework"
        )
    ]
)
