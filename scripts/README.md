# Bento shell integration

These shell snippets teach your shell to emit two well-known escape sequences
that Bento's terminal panes look for:

- **OSC 7** — the shell announces its current working directory after every
  prompt. Bento uses this to keep its per-workspace sidebar in sync as you
  `cd` around.
- **OSC 133 A/B/C/D** — semantic prompt markers that delimit prompt, input,
  command output, and exit status. Bento uses these to identify command
  boundaries (so prompts and outputs can be grouped into blocks later, the
  way Warp and iTerm3 do).

Bento works fine without these snippets — you just lose the cwd-following
sidebar and the future block-grouping affordances. Nothing else depends on
them, so you can install them in whichever shells you actually use.

These follow the same conventions as iTerm2, WezTerm, Kitty, and Ghostty
itself, so installing them once benefits any other terminal that understands
the same protocols.

## Files

| File                                  | Shell |
| ------------------------------------- | ----- |
| `bento-shell-integration.zsh`         | zsh   |
| `bento-shell-integration.bash`        | bash 4+ |
| `bento-shell-integration.fish`        | fish 3+ |

## Install

Replace `/absolute/path/to/Bento/scripts/` with the real path on your
machine.

### zsh

```sh
echo 'source /absolute/path/to/Bento/scripts/bento-shell-integration.zsh' >> ~/.zshrc
```

Open a new terminal (or `exec zsh`) to pick up the change.

### bash

```sh
echo 'source /absolute/path/to/Bento/scripts/bento-shell-integration.bash' >> ~/.bashrc
```

On macOS, Terminal-style login shells read `~/.bash_profile` instead — if
that's where your customizations live, add the line there (or have
`~/.bash_profile` source `~/.bashrc`).

### fish

The simplest install is to drop the file into fish's auto-loaded `conf.d`
directory:

```sh
mkdir -p ~/.config/fish/conf.d
cp /absolute/path/to/Bento/scripts/bento-shell-integration.fish ~/.config/fish/conf.d/
```

Open a new fish session and you're done. Alternatively, source it explicitly
from `~/.config/fish/config.fish`:

```fish
source /absolute/path/to/Bento/scripts/bento-shell-integration.fish
```

## Verify

### Quick check from any shell

After sourcing the snippet, run `cat -v` and press Enter on a fresh prompt.
`cat -v` prints control bytes as caret-escapes, so you should see something
like:

```
^[]133;C^G        # printed when you ran cat -v
^[]133;D;0^G      # exit status of the previous command (when you press ^D)
^[]7;file://host/your/cwd^G
^[]133;A^G
^[]133;B^G        # tail end of the next prompt
```

`^[` is ESC (`0x1B`) and `^G` is BEL (`0x07`), which is the OSC sequence
terminator we use.

### End-to-end check inside Bento

1. Open a Bento terminal pane.
2. `source /absolute/path/to/Bento/scripts/bento-shell-integration.<your-shell>`
   (or just open a fresh shell once it's wired into your dotfiles).
3. `cd ~/some/other/dir` — the workspace sidebar should follow the new
   directory.
4. Run any command (e.g. `ls`); Bento internally records the OSC 133 A/B/C/D
   markers around it for later block grouping.

If the sidebar doesn't update after `cd`, double-check that the snippet was
actually sourced (`echo $__BENTO_SHELL_INTEGRATION_LOADED` in zsh/bash, or
`set -q __bento_shell_integration_loaded; and echo yes` in fish).

## What the snippets emit

| Sequence              | When                                  | Why Bento cares                      |
| --------------------- | ------------------------------------- | ------------------------------------ |
| `OSC 7;file://host/path` | every prompt                          | cwd tracking for the sidebar         |
| `OSC 133;A`           | start of the prompt                   | block start anchor                   |
| `OSC 133;B`           | end of prompt / start of user input   | separates prompt from typed command  |
| `OSC 133;C`           | command starts running (preexec)      | start of command output region       |
| `OSC 133;D;<exit>`    | command finished (precmd)             | block end + success/failure status   |

The escape character is `\033` (ESC) and we terminate with `\007` (BEL) for
maximum compatibility with shell quoting.

## Notes & caveats

- **zsh**: appends to `precmd_functions` / `preexec_functions` directly. The
  OSC 133;B sequence is wrapped in `%{ %}` inside `PROMPT` so zsh doesn't
  miscount the visible prompt width.
- **bash**: requires bash 4 or newer (uses the `DEBUG` trap and
  `BASH_COMMAND`). The OSC 133;B sequence is wrapped in `\[ \]` inside `PS1`
  for the same width-counting reason. The `DEBUG` trap is one-shot per
  prompt — if you have other tools that also rely on the `DEBUG` trap (e.g.
  `bash-preexec`), install Bento's snippet *after* them so its trap takes
  precedence, or use `bash-preexec` and call our printers from there.
- **fish**: uses `fish_preexec` / `fish_postexec` events and wraps your
  existing `fish_prompt` once. If you redefine `fish_prompt` later in the
  session, re-source the snippet to re-wrap it.
- All three snippets are idempotent — sourcing them more than once is safe.
- Bento ships no telemetry. These OSC sequences never leave your machine;
  they're consumed by the terminal emulator inside your local Bento process.
