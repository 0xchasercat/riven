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
        .executable(name: "RivenAgent", targets: ["RivenAgent"]),
        // Phase-0 spike: a throwaway link-test for the full
        // libghostty embedding (GhosttyKit). Proves the 134 MB
        // static lib links + the C API is callable from Swift
        // before we invest in the full app/surface binding. Lives
        // on the `spike/libghostty-surface` branch only.
        .executable(name: "GhosttySpike", targets: ["GhosttySpike"]),
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
        ),
        // Full libghostty embedding lib (app + surface + Metal
        // renderer). Built via `zig build -Demit-xcframework`.
        // Separate from GhosttyVt — they share `ghostty_*` symbols,
        // so a target links ONE or the other, never both.
        .binaryTarget(
            name: "GhosttyKit",
            path: "External/ghostty-kit-install/lib/GhosttyKit.xcframework"
        ),
        .executableTarget(
            name: "GhosttySpike",
            dependencies: ["GhosttyKit"],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ],
            // The full static lib references the macOS frameworks
            // Ghostty's renderer + runtime use. They must be linked
            // for symbol resolution even for a trivial call.
            linkerSettings: [
                // Ghostty's renderer embeds C++ (spirv-cross for
                // shader cross-compile, imgui for the inspector), so
                // the C++ runtime must be linked.
                .linkedLibrary("c++"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("AppKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("IOSurface"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
    ]
)
