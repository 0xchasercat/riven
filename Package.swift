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
                // Use `.copy` (preserves layout) rather than
                // `.process` (flattens directories). The shell
                // integration NEEDS its subdirectory tree intact
                // — riven.zsh sources its siblings by relative
                // path, and fast-syntax-highlighting sources a
                // multi-file tree from a single entry point.
                // `.process("Resources")` flattened both, so
                // `Bundle.module.url(forResource: "shell-integration",
                // withExtension: nil)` returned nil and the
                // installer reported "missing bundle resources."
                //
                // The ripgrep binary still ships via the same
                // bundle; RipgrepFileSearch resolves it via
                // `Bundle.module.url(forResource: "rg",
                // withExtension: nil)` which keeps working
                // because the file lives at the bundle root either
                // way (we just declare it explicitly now).
                .copy("Resources/rg"),
                .copy("Resources/shell-integration"),
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
