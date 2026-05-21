import Foundation
import Testing
@testable import BentoCore

@Suite("Themes")
struct ThemeSpecTests {
    @Test("ships mockup-inspired selectable themes")
    func builtInThemes() throws {
        let themes = ThemeSpec.builtIns

        #expect(themes.map(\.id) == ["bento", "carbon", "tokyo", "paper"])
        #expect(try #require(ThemeSpec.theme(id: "bento")).terminal.foreground.hex == "#ece1cb")
        #expect(try #require(ThemeSpec.theme(id: "carbon")).syntax.keyword.hex == "#c8c8c8")
        #expect(ThemeSpec.theme(id: "missing") == nil)
    }

    @Test("each builtin populates mockup-parity chrome tokens")
    func mockupParityChrome() throws {
        for theme in ThemeSpec.builtIns {
            // All new fields must be present (non-default) for builtins —
            // they're not allowed to fall back to the panel/elevated
            // shadow at runtime; the builtins curated the real values.
            #expect(!theme.chrome.panelInactive.hex.isEmpty, "panelInactive missing for \(theme.id)")
            #expect(!theme.chrome.paneHeaderBg.hex.isEmpty, "paneHeaderBg missing for \(theme.id)")
            #expect(!theme.chrome.statusBg.hex.isEmpty, "statusBg missing for \(theme.id)")
            #expect(!theme.chrome.statusText.hex.isEmpty, "statusText missing for \(theme.id)")
            #expect(!theme.chrome.selectionBg.hex.isEmpty, "selectionBg missing for \(theme.id)")
        }

        // Spot-check the mockup-derived values for Bento + Paper to catch
        // accidental hex typos in the builtins table.
        let bento = try #require(ThemeSpec.theme(id: "bento"))
        #expect(bento.chrome.panelInactive.hex == "#15100b")
        #expect(bento.chrome.paneHeaderBg.hex == "#150f0a")
        #expect(bento.chrome.statusBg.hex == "#0a0604")

        let paper = try #require(ThemeSpec.theme(id: "paper"))
        #expect(paper.chrome.panelInactive.hex == "#efeadd")
        #expect(paper.chrome.statusText.hex == "#6f6650")
    }

    @Test("geometry tokens differentiate the compartment look between themes")
    func geometryReflectsMockup() throws {
        let bento = try #require(ThemeSpec.theme(id: "bento"))
        let carbon = try #require(ThemeSpec.theme(id: "carbon"))
        let tokyo = try #require(ThemeSpec.theme(id: "tokyo"))
        let paper = try #require(ThemeSpec.theme(id: "paper"))

        // Bento ships the thick bento-box divider; other themes stay
        // at hairline weight.
        #expect(bento.geometry.dividerWeight == 6)
        #expect(carbon.geometry.dividerWeight == 1)
        #expect(tokyo.geometry.dividerWeight == 1)
        #expect(paper.geometry.dividerWeight == 1)

        // Pane radii match the mockup: 0/4/6/3 across the four themes.
        #expect(carbon.geometry.paneRadius == 0)
        #expect(bento.geometry.paneRadius == 4)
        #expect(tokyo.geometry.paneRadius == 6)
        #expect(paper.geometry.paneRadius == 3)

        // Bento's active border glows softly (alpha ~0.55); others draw
        // their accent at full strength.
        #expect(bento.geometry.activeHighlightAlpha < 0.6)
        #expect(carbon.geometry.activeHighlightAlpha == 1.0)
    }

    @Test("Paper ships as the light-mode theme; others are dark")
    func materialModes() throws {
        #expect(try #require(ThemeSpec.theme(id: "bento")).material.mode == .dark)
        #expect(try #require(ThemeSpec.theme(id: "carbon")).material.mode == .dark)
        #expect(try #require(ThemeSpec.theme(id: "tokyo")).material.mode == .dark)
        #expect(try #require(ThemeSpec.theme(id: "paper")).material.mode == .light)
    }

    @Test("ThemeSpec decoder fills geometry + material when missing (back-compat)")
    func decoderFillsMissingFields() throws {
        // Simulate an older snapshot that predates `geometry` + `material`.
        let legacy = """
        {
          "id": "legacy",
          "name": "Legacy",
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
            "success": "#5a8",
            "warning": "#b96",
            "danger": "#b66"
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
            "keyword": "#aaa", "function": "#fff", "string": "#999", "comment": "#555"
          }
        }
        """
        let decoded = try JSONDecoder().decode(ThemeSpec.self, from: Data(legacy.utf8))
        #expect(decoded.geometry.dividerWeight == 1) // default
        #expect(decoded.material.mode == .dark)      // default
        // Chrome fallbacks for missing tokens — should never crash.
        #expect(decoded.chrome.panelInactive.hex == decoded.chrome.panel.hex)
        #expect(decoded.chrome.paneHeaderBg.hex == decoded.chrome.elevated.hex)
        #expect(decoded.chrome.selectionBg.hex == decoded.chrome.accentSoft.hex)
    }
}
