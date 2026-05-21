# Changelog

All notable changes per release. The top of the file is the version that's
about to ship; promote it on `git tag`.

## Unreleased

(work-in-progress; promote to a version header on tag.)

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
