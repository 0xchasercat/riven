# Changelog

All notable changes per release. The top of the file is the version that's
about to ship; promote it on `git tag`.

## Unreleased

### Changed — terminal engine

- **Now powered by the full libghostty embedding.** Riven's terminal panes
  render with Ghostty's own GPU (Metal) renderer and use Ghostty's native
  input + PTY, via the `ghostty_app_*` / `ghostty_surface_*` C API
  (`GhosttyKit`). This replaces Riven's previous hand-rolled stack
  (libghostty-vt parser + a custom CoreText renderer + an out-of-process
  `RivenAgent` PTY broker). You get Ghostty's terminal quality with Riven's
  workspace model — tabs, splits, sidebar, command bar, themes — on top.
- The command bar, themes, sidebar-follows-`cd`, bell/title, search, and
  session restore all carry over. Terminal theming maps Riven's palette to
  `ghostty_config`; scrollback search pulls live grid text via
  `ghostty_surface_read_text` on demand.

### Removed

- The out-of-process `RivenAgent` broker. **Tradeoff:** PTYs now run
  in-process and exit with the app — a UI crash takes your running shells
  with it. Session *restore* (tab/split/cwd layout, via snapshots) is
  unchanged; if anything it's snappier. The custom CoreText renderer,
  libghostty-vt binding, and the IPC layer are gone.

## 0.1.0 — first public alpha

First tagged release. Honest expectation-setting: this is alpha. Used daily
by the author but there are rough edges, missing features, and the on-disk
formats (Application Support snapshot, scrollback metadata sidecar) may
break across releases until 1.0.

### What works end-to-end

- **Terminal panes** backed by libghostty-vt. Out-of-process broker
  (`RivenAgent`) so UI crashes don't kill your shells; pane state survives
  across UI reattaches.
- **Editor panes** as inner-tab citizens, backed by STTextView. Dirty
  indicators, save-on-close prompts, file-deletion detection,
  save-error banner.
- **Workspaces → tabs → splits** — three nested levels of structure.
  Sidebar follows the live `cd` via OSC 7; never collapses below the
  48-pt icon rail floor.
- **Global search** across files (vendored ripgrep) and across every
  past session (scrollback + metadata sidecars). Peek view for any
  hit. Recent-searches ring.
- **Four bundled themes** — Amber, Carbon, Tokyo, Paper — plus custom
  JSON themes dropped into `~/Library/Application Support/Riven/themes/`.
  Live switching from menu / palette / status-bar swatch.
- **Optional zsh shell integration** with a minimal theme-aware prompt
  (async git status), zsh-autosuggestions, fast-syntax-highlighting,
  substring history search, and `z.sh` smart `cd`. One-click install
  from the palette or `Riven → Preferences → Install Shell Integration…`.
- **Terminal input that actually works** — Cmd+A / Cmd+C / Cmd+V /
  Cmd+X, drag-to-select, Ctrl+letter forwarding (Ctrl+X exits nano,
  Ctrl+R reverse-searches, …), PageUp/Down/Home/End, F1–F12, scroll-
  wheel-as-arrow-keys in alt-screen, mouse-pass-through to TUIs.
- **Auto-focus on TUIs** — typing `nano` and Enter pulls focus from the
  command bar to the terminal so keystrokes flow to the TUI.
- **Zsh-style autosuggestions in the command bar** — type a few
  characters, see the most recent matching command in dim ghost text,
  press Right Arrow to accept.

### Known rough edges

- No Sparkle / in-app update yet. Re-download the DMG for new versions.
- No custom app icon — Mac OS's generic .app icon.
- Broker IPC tests are flaky on contended runners (deterministic in
  isolation).
- No Mac App Store presence. (Sandboxing + spawning a child broker
  process don't compose well.)
- No Windows or Linux build. Native macOS only.

### License

MIT. Bundled third-party components retain their own licenses (see `LICENSE`).
