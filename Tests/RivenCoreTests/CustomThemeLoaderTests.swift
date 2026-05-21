import Foundation
import Testing
@testable import RivenCore

@Suite("Custom theme loader")
struct CustomThemeLoaderTests {
    /// Builds a temporary directory, drops the supplied JSON payloads
    /// into it, and returns a loader rooted there.
    private func loader(_ files: [(name: String, body: String)]) throws -> (CustomThemeLoader, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("riven-theme-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for file in files {
            try Data(file.body.utf8).write(
                to: dir.appendingPathComponent(file.name),
                options: .atomic
            )
        }
        return (CustomThemeLoader(directory: dir), dir)
    }

    /// A minimal well-formed ThemeSpec JSON body — uses the same shape
    /// as the back-compat decoder fixture in `ThemeSpecTests`. Keeping
    /// the chrome block compact here on purpose; the loader doesn't
    /// care about the values, only that they decode.
    private func okBody(id: String, name: String) -> String {
        """
        {
          "id": "\(id)",
          "name": "\(name)",
          "chrome": {
            "background": "#000000",
            "panel": "#111111",
            "border": "#222222",
            "activeBorder": "#333333",
            "text": "#dddddd",
            "dimText": "#888888",
            "elevated": "#1a1a1a",
            "overlay": "#000000",
            "tertiaryText": "#555555",
            "invertedText": "#ffffff",
            "hairline": "#181818",
            "accent": "#aaaaaa",
            "accentSoft": "#aaaaaa22",
            "success": "#5a8888",
            "warning": "#b96666",
            "danger": "#b66666"
          },
          "terminal": {
            "foreground": "#dddddd",
            "background": "#111111",
            "prompt": "#aaaaaa",
            "cursor": "#ffffff",
            "ansi": {
              "red": "#E61919", "green": "#19E619", "blue": "#1919E6",
              "cyan": "#19E6E6", "magenta": "#E619E6", "yellow": "#E6E619",
              "brightRed": "#EE6666", "brightGreen": "#66EE66",
              "brightBlue": "#6666EE", "brightCyan": "#66EEEE",
              "brightMagenta": "#EE66EE", "brightYellow": "#EEEE66"
            }
          },
          "syntax": {
            "keyword": "#aaaaaa", "function": "#ffffff",
            "string": "#999999", "comment": "#555555"
          }
        }
        """
    }

    @Test("missing directory returns an empty list (no crash)")
    func missingDirectory() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("riven-missing-\(UUID().uuidString)", isDirectory: true)
        let loader = CustomThemeLoader(directory: dir)
        #expect(loader.themes.isEmpty)
    }

    @Test("well-formed JSON files are returned in id-sorted order")
    func loadsWellFormedThemes() throws {
        let (loader, _) = try loader([
            (name: "zebra.json", body: okBody(id: "zebra", name: "Zebra")),
            (name: "alpha.json", body: okBody(id: "alpha", name: "Alpha"))
        ])
        #expect(loader.themes.map(\.id) == ["alpha", "zebra"])
        #expect(loader.themes.first?.name == "Alpha")
    }

    @Test("bogus JSON is dropped, valid files still appear")
    func skipsBogusFiles() throws {
        let (loader, _) = try loader([
            (name: "broken.json", body: "{ this is not json"),
            (name: "also-broken.json", body: "{\"id\":\"x\"}"), // valid JSON but wrong shape
            (name: "good.json", body: okBody(id: "good", name: "Good"))
        ])
        #expect(loader.themes.map(\.id) == ["good"])
    }

    @Test("non-json siblings are ignored")
    func ignoresNonJsonFiles() throws {
        let (loader, _) = try loader([
            (name: "notes.txt", body: "hello"),
            (name: "ok.json", body: okBody(id: "ok", name: "OK"))
        ])
        #expect(loader.themes.map(\.id) == ["ok"])
    }

    @Test("seedDefaultTemplate writes the first builtin and is idempotent")
    func seedDefaultTemplate() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("riven-theme-seed-\(UUID().uuidString)", isDirectory: true)
        let first = CustomThemeLoader.seedDefaultTemplate(directory: dir)
        let target = try #require(first)
        #expect(FileManager.default.fileExists(atPath: target.path))

        // The seeded JSON should round-trip back to the Bento builtin
        // so users start from something that actually loads.
        let data = try Data(contentsOf: target)
        let decoded = try JSONDecoder().decode(ThemeSpec.self, from: data)
        #expect(decoded.id == ThemeSpec.builtIns.first?.id)

        // Second call must not overwrite — the file already exists, so
        // the user's edits would otherwise be clobbered.
        let originalContents = data
        let second = CustomThemeLoader.seedDefaultTemplate(directory: dir)
        #expect(second?.path == target.path)
        let after = try Data(contentsOf: target)
        #expect(after == originalContents)
    }
}
