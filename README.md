# Riven

A native macOS workspace for power users. Terminal panes, an integrated editor, project-aware search, theme-aware everything. No AI features, no telemetry, no Electron, no web-terminal fallback.

> **Riven** — to split, to cleave, to rive a window into compartments. Every workspace splits into tabs, every tab splits into surfaces, every surface owns its own PTY or buffer.

---

## What's in the box

- **Terminal panes** backed by [libghostty-vt](https://github.com/ghostty-org/ghostty). Out-of-process PTY broker so UI crashes don't kill your shells.
- **Editor panes** as first-class tab citizens (not a side column), backed by [STTextView](https://github.com/krzyzanowskim/STTextView). Dirty indicators, save-on-close prompts, file-deletion detection.
- **Workspaces, tabs, splits** — three nested levels of structure. Each workspace has its own sidebar following the live `cd`. Splits land inside a tab; the tab lives inside a workspace.
- **Global search** across every project and every past session. Vendored ripgrep for file matches, scrollback metadata sidecars so `grep cargo` in last Tuesday's session still finds the hit.
- **Four bundled themes** (Amber · Carbon · Tokyo · Paper) plus user-authored JSON themes. Live theme switching from the menu, palette, or status-bar swatch.
- **Optional zsh shell integration** with a minimal theme-aware prompt, async git status, autosuggestions, fast-syntax-highlighting, substring history search, and a frecency-based smart `cd`. Two clicks to install, two clicks to remove.
- **Hardening**: dirty-quit prompts, file-vanished detection, project-fallback banner, broker respawn that preserves focus, sleep/wake recovery.

## Targets

| Target | What it is |
|---|---|
| `RivenCore` | Pure model + persistence layer. Pane graph, session YAML, themes, scrollback store with metadata sidecars, ripgrep + unified search, IPC protocol, recent-searches ring. |
| `Riven` | The macOS app: AppKit/SwiftUI shell, command palette, overlays, hosting controllers, BrokeredTerminalView wrapping libghostty-vt. |
| `RivenAgent` | Helper process owning every PTY. Survives UI restarts; the app re-attaches by paneID. |

External dependencies: [Yams](https://github.com/jpsim/Yams) for session YAML, [STTextView](https://github.com/krzyzanowskim/STTextView) for the editor, vendored Universal2 [ripgrep](https://github.com/BurntSushi/ripgrep) for file search.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/0xchasercat/riven/main/install.sh | bash
```

Pins to the latest tagged release, drops `Riven.app` into `/Applications`, strips the download-quarantine xattr (the script-equivalent of macOS's right-click → Open consent), and ad-hoc re-signs on the user's machine so Gatekeeper accepts the launch. Pin a specific version with `RIVEN_VERSION=v0.1.0`. Skip the post-install launch with `RIVEN_OPEN=0`.

Until the Apple Developer ID cert lands, the published DMG is ad-hoc signed; the installer dance above is the cleanest path. After Developer ID + notarisation are wired up, the same install script keeps working — the quarantine-strip + re-sign steps become no-ops on an already-trusted binary.

Manual install path: grab the latest `Riven-X.Y.Z.dmg` from the [Releases page](https://github.com/0xchasercat/riven/releases), open it, drag `Riven.app` to `/Applications`. Right-click → Open the first time to dismiss Gatekeeper.

## Build from source

Requires macOS 15+, Xcode 16+ toolchain (Swift 6.2), and [zig](https://ziglang.org) 0.15.x for the one-time Ghostty build.

```sh
# First-time setup: clone Ghostty + build libghostty-vt.
./scripts/setup-ghostty.sh

# Subsequent builds:
swift build              # debug
swift build -c release   # release
swift run RivenAgent     # broker on its own (rarely useful directly)
```

The `Riven` and `RivenAgent` executables drop into `.build/<config>/`. Launch `Riven` from Finder for the real experience — when launched that way the AgentLauncher spawns RivenAgent automatically and the app picks up `TERM=xterm-256color`, `COLORTERM=truecolor`, `TERM_PROGRAM=Riven` for every PTY it opens.

## Release

Riven ships as a `.dmg` from [GitHub Releases](https://github.com/0xchasercat/riven/releases). Drag `Riven.app` to `/Applications` and launch.

To cut a fresh release locally:

```sh
VERSION=0.1.0 scripts/release/build-release.sh
```

The script builds in release mode, assembles `Riven.app` with the right `Info.plist` + nested binaries + resource bundle, ad-hoc signs it (or Developer-ID signs + Apple-notarises when the relevant env vars are set), and produces `dist/Riven-<VERSION>.dmg` ready to upload.

Signed + notarised builds require an Apple Developer Program enrollment. Set:

```sh
export APPLE_DEVELOPER_ID="Developer ID Application: <Name> (<TEAM_ID>)"
export APPLE_NOTARY_KEYCHAIN_PROFILE="riven-notary"   # configured via `xcrun notarytool store-credentials`
export APPLE_TEAM_ID="<TEAM_ID>"
```

Until then the script produces ad-hoc-signed builds — users will see "developer cannot be verified" on first launch and have to right-click → Open.

## Troubleshooting

### "The file viewer can't access anything"

On first launch Riven asks for permission to read each user folder it touches (Documents, Desktop, Downloads, network volumes, removable drives). Click **Allow** when the system prompt appears. If you missed the prompt, grant access manually in **System Settings → Privacy & Security → Files and Folders → Riven**.

For projects outside the standard user folders (mounted volumes, `/opt`, `/Users/Shared`, etc.) macOS requires **Full Disk Access** instead. Add Riven via **System Settings → Privacy & Security → Full Disk Access**.

A fresh launch from Finder boots Riven into `$HOME`. If you'd rather it open a specific project, drag the project folder onto the Riven dock icon or launch from the command line: `open -a Riven /path/to/project`.

## Shell integration

Open the command palette (`⌘⇧P`) and search for **shell integration** to install. Bundled inside the app — no clone, no manual sourcing.

Installed files land at `~/.config/riven/shell/`. A fenced source block goes into `~/.zshrc`. Uninstall through the same menu or palette entry; it removes both halves and leaves your own zsh config intact.

See [`Sources/RivenCore/Resources/shell-integration/README.md`](Sources/RivenCore/Resources/shell-integration/README.md) for what gets activated.

## Tests

```sh
swift test --filter 'Theme|ScrollbackMetadata|ScrollbackStore|SearchIndex|RecentSearches|Ripgrep|CustomThemeLoader|EditorBuffer|WorkspaceStateDirtyFilename|CommandHistory|CommandPalette|PaneGraph|StringEllipsis|ProjectFileTreeCap|ProjectFileTree|ShellIntegrationInstaller|PseudoTerminal|WorkspaceController'
```

This curated filter excludes the broker IPC tests, which are flaky on contended CI but pass deterministically when run in isolation:

```sh
swift test --filter 'BrokerPersistence|LiveTerminalGhostty|AgentService|AgentIPC'
```

## Non-negotiables

- No AI product features.
- No telemetry, no analytics, no phone-home.
- No Electron, WebView terminal, or xterm.js fallback.
- libghostty for terminals. STTextView for the editor. AppKit + SwiftUI for chrome.
- Performance and UI precision over feature count.

## Status

Pre-1.0. Functional and used daily by the author; expect rough edges. See the commit log for the active work.
