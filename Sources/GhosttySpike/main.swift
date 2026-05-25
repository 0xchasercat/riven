import GhosttyKit

// Phase-0 link test for the full libghostty embedding API.
//
// Goal: prove the 134 MB GhosttyKit static lib links into a SwiftPM
// build and the `ghostty_*` C API is callable from Swift — the
// make-or-break before investing in the full app/surface binding.
//
// `ghostty_init` must run before anything else (it sets up the global
// state / CLI). `ghostty_info` returns build info we can print to
// confirm we're really talking to the library.
@main
struct GhosttySpike {
    static func main() {
        // ghostty_init(argc, argv) — pass our process args through.
        var args = CommandLine.unsafeArgv
        ghostty_init(UInt(CommandLine.argc), args)

        let info = ghostty_info()
        print("GhosttyKit linked OK")
        print("  build mode: \(info.build_mode.rawValue)")
        print("  version len: \(info.version_len)")
        if let ptr = info.version {
            let version = String(cString: ptr)
            print("  version: \(version)")
        }
        _ = args
    }
}
