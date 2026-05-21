# scripts/

Build + maintenance scripts for the Riven repo. **Not** the place users go to install Riven's shell integration — that ships with the app and installs via the menu or palette (see [the in-app shell integration docs](../Sources/RivenCore/Resources/shell-integration/README.md)).

| Script | Purpose |
|---|---|
| `setup-ghostty.sh` | One-time clone + build of [Ghostty](https://github.com/ghostty-org/ghostty) into `External/`. Produces the `ghostty-vt.xcframework` that `Riven` links against. Also installs the repo-local git hooks. Re-run safely; idempotent. |
| `install-rg.sh` | Refresh the vendored Universal2 ripgrep binary at `Sources/RivenCore/Resources/rg`. Pinned to a specific upstream tag, SHA-256 verified, `lipo`-fused. |
| `lint/no-hardcoded-chrome.sh` | Lint pass that fails when a `Color(hex:` or `NSColor(hex:` literal appears outside `ThemeSpec.swift` and `ColorHelpers.swift`. Run manually pre-commit; not currently wired to CI (the repo has no CI). |
| `git-hooks/pre-commit` | Pre-commit hook installed by `setup-ghostty.sh`. Blocks accidental commits to anything under `External/` (vendored, gitignored, occasionally re-tracked by mistake). |
| `notes/` | Design notes that informed past polish passes. |

## On the shell integration

Earlier revisions of this repo shipped freestanding shell snippets under this directory. They've been replaced by a richer in-app integration that lives at [`Sources/RivenCore/Resources/shell-integration/`](../Sources/RivenCore/Resources/shell-integration/) and is installed through Riven itself:

- **Menu**: `Riven → Preferences → Install Shell Integration…`
- **Palette**: `⌘⇧P` → "Install Riven shell integration"

The installer copies the bundled config + plugins to `~/.config/riven/shell/` and appends a fenced source block to `~/.zshrc`. Uninstall removes both. The integration is a no-op when sourced outside a Riven terminal (gates on `$TERM_PROGRAM == Riven`), so the same `~/.zshrc` works across every terminal you use.
