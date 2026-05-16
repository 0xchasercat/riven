# Bento

Bento is a native macOS workspace for power users: fast terminal panes, native editor panes, project resurrection, task panes, and unified search without AI features, telemetry, Electron, or web-terminal fallbacks.

## Current Alpha Scaffold

This repository now contains a Swift Package with three targets:

- `BentoCore`: pane graph, session YAML parsing, theme model, command palette model, snapshot persistence, scrollback persistence, unified search, and engine contracts.
- `Bento`: a native AppKit/SwiftUI executable shell with the mockup-inspired pane layout, first-run theme picker, and STTextView editor panes.
- `BentoAgent`: the beginning of the helper process boundary that will own terminal/task lifetime.

Ghostty VT is built from the vendored Ghostty source under `External/ghostty` and linked via the generated `ghostty-vt.xcframework`. Editor panes use STTextView.

## Verify

```sh
swift test
swift build -c release
swift run BentoAgent
```

## Shell Integration

Optional shell snippets in [`scripts/`](scripts/README.md) make your shell
emit OSC 7 (cwd reports) and OSC 133 A/B/C/D (semantic prompt markers) so
Bento's sidebar can follow `cd` and Bento can identify command boundaries
for block grouping. Available for zsh, bash, and fish. See
[`scripts/README.md`](scripts/README.md) for install + verification.

## Non-Negotiables

- No AI product features.
- No telemetry.
- No Electron, WebView terminal, or xterm.js fallback.
- Real `libghostty` for terminal panes.
- STTextView editor integration.
- Performance and UI precision over feature count.
