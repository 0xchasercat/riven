# Bento shell integration

Optional zsh config that ships with Bento. Install via the menu (Bento → Preferences → Shell Integration…) or the first-run welcome banner.

## What it installs

| File | What it does |
|---|---|
| `bento.zsh` | Entry point. Sourced from your `~/.zshrc`. Loads the rest. |
| `options.zsh` | History (100k entries, shared across shells), case-insensitive completion, sensible globbing. |
| `integration.zsh` | OSC 7 cwd reports + OSC 133 prompt/command marks so Bento's sidebar + chrome can track shell state. |
| `prompt.zsh` | Minimal two-line prompt with async git status. Pulls colors from Bento's tuned ANSI palette → automatically follows the active theme. |
| `keybinds.zsh` | Emacs bindings + ↑/↓ history-substring-search + Ctrl-E to accept ghost text. |
| `plugins.zsh` | Sources the vendored plugins in the correct order. |
| `plugins/z.sh` | Frecency-based `z <pattern>` smart cd. |
| `plugins/zsh-autosuggestions.zsh` | Ghost-text completion from history. |
| `plugins/zsh-history-substring-search.zsh` | Substring-match history walk on ↑/↓. |
| `plugins/fast-syntax-highlighting/` | Live command-token coloring. |

## Where the files live

After install:
```
~/.config/bento/shell/        bento.zsh + all of the above
~/.zshrc                      adds one source line guarded by `# >>> Bento`
~/.cache/zsh/zcompdump        compinit cache (auto-created)
~/.z                          z.sh's frecency database (auto-created)
```

## Activation gate

Every file gates on `$TERM_PROGRAM == Bento`. Sourcing this from iTerm / Terminal.app / kitty is a no-op — your other shells stay untouched.

## Uninstall

Bento → Preferences → Shell Integration → Uninstall. Removes the source line from `~/.zshrc` and deletes `~/.config/bento/shell/`. Your history file (`~/.zsh_history`) and z.sh database (`~/.z`) are left in place.

## License

| Component | License |
|---|---|
| Bento config + integration hooks | (same as Bento) |
| zsh-autosuggestions | MIT |
| zsh-history-substring-search | BSD-2-Clause |
| fast-syntax-highlighting | BSD-3-Clause |
| z.sh | MIT (rupa/z) |
