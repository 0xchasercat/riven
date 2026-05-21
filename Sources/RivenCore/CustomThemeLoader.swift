import Foundation

/// Loads user-authored theme JSON files from
/// `~/Library/Application Support/Riven/themes/*.json`.
///
/// T-6 scope: the loader scans the directory once at construction time
/// and caches the result for the lifetime of the process. Themes here
/// are layered over the built-in palette via `ThemeSpec.all()`; a custom
/// theme whose `id` shadows a builtin wins, which lets users tweak the
/// shipped palettes without recompiling.
///
/// **Failure mode**: a file that doesn't parse is logged to stderr and
/// dropped. The loader never throws and never crashes the app — a stray
/// `themes/notes.txt` or a broken JSON file leaves the rest of the
/// scan untouched.
public final class CustomThemeLoader: @unchecked Sendable {
    /// Directory that holds user theme files. Public so the menu's
    /// "Reveal themes folder" can open it in Finder.
    public let directory: URL
    private let cache: [ThemeSpec]

    public init(directory: URL) {
        self.directory = directory
        self.cache = Self.scan(directory: directory)
    }

    /// Default location under the user's Application Support folder.
    public static func defaultDirectory() -> URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("Riven", isDirectory: true)
            .appendingPathComponent("themes", isDirectory: true)
        return support
    }

    /// Process-wide shared loader rooted at the default themes directory.
    /// Cheap to call — the cache is built once.
    public static let shared: CustomThemeLoader = CustomThemeLoader(
        directory: CustomThemeLoader.defaultDirectory()
    )

    public var themes: [ThemeSpec] { cache }

    private static func scan(directory: URL) -> [ThemeSpec] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDir),
              isDir.boolValue else {
            return []
        }
        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            FileHandle.standardError.write(
                Data("[riven] custom themes: scan failed: \(error)\n".utf8)
            )
            return []
        }
        let decoder = JSONDecoder()
        var out: [ThemeSpec] = []
        for url in entries where url.pathExtension.lowercased() == "json" {
            do {
                let data = try Data(contentsOf: url)
                let theme = try decoder.decode(ThemeSpec.self, from: data)
                out.append(theme)
            } catch {
                FileHandle.standardError.write(
                    Data("[riven] custom theme \(url.lastPathComponent) failed to load: \(error)\n".utf8)
                )
            }
        }
        // Stable order so a future "list custom themes" UI doesn't
        // shuffle between launches.
        return out.sorted { $0.id < $1.id }
    }

    /// Best-effort: write a starter template into the themes directory
    /// based on the first builtin, so the user has something to crib
    /// from. Skips when the file already exists. Returns the URL it
    /// wrote (or would have written) so callers can reveal it in Finder.
    @discardableResult
    public static func seedDefaultTemplate(directory: URL = CustomThemeLoader.defaultDirectory()) -> URL? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(
                Data("[riven] custom themes: mkdir failed: \(error)\n".utf8)
            )
            return nil
        }
        let target = directory.appendingPathComponent("riven-default.json")
        if fm.fileExists(atPath: target.path) { return target }
        guard let template = ThemeSpec.builtIns.first else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(template)
            try data.write(to: target, options: .atomic)
            return target
        } catch {
            FileHandle.standardError.write(
                Data("[riven] custom themes: template write failed: \(error)\n".utf8)
            )
            return nil
        }
    }
}
