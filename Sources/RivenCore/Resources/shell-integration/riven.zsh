# Riven shell integration — main entry point.
#
# This file is the entry point a user's ~/.zshrc sources. It loads the
# rest of the Riven integration in a deterministic order:
#
#   1. options.zsh   sensible zsh defaults (history, completion, etc.)
#   2. integration.zsh   OSC 7 / 133 hooks so Riven's sidebar + chrome
#                        can track shell state
#   3. prompt.zsh    minimal theme-aware prompt
#   4. keybinds.zsh  emacs-style bindings + history-substring search
#   5. plugins.zsh   sources the vendored plugins in the order they
#                    want (syntax-highlighting MUST load last per its
#                    own docs)
#
# Everything below is gated on `$BENTO` (or `$TERM_PROGRAM == Riven`)
# so this file is a NO-OP outside Riven. Sourcing it from another
# terminal (iTerm, Terminal.app, kitty) leaves that shell untouched.
# That way users can keep the source line in .zshrc without having to
# fence it themselves.

# Identify ourselves. `$RIVEN_INTEGRATION_VERSION` lets Riven's installer
# compare against the bundled version and prompt for upgrade if the
# user's on-disk copy is older. Bump this whenever the integration
# changes in a user-visible way.
export RIVEN_INTEGRATION_VERSION="1"

# Run-only-inside-Riven gate. Riven sets `TERM_PROGRAM=Riven` on every
# PTY spawn (Sources/Riven/TerminalPaneView.swift). Other terminals
# don't, so sourcing this from a non-Riven shell is a clean no-op.
if [[ "${TERM_PROGRAM:-}" != "Riven" ]]; then
  return 0
fi

# Resolve the directory this file lives in so the rest of the loaders
# can find their siblings, regardless of where the user dropped them.
# We don't rely on `${0:A}` because some users source the file via
# `eval $(...)` which loses the script path.
typeset -g RIVEN_INTEGRATION_DIR="${RIVEN_INTEGRATION_DIR:-${${(%):-%N}:A:h}}"

# Load order matters. Each loader is small + idempotent.
for _bento_part in options integration prompt keybinds plugins; do
  if [[ -r "$RIVEN_INTEGRATION_DIR/$_bento_part.zsh" ]]; then
    source "$RIVEN_INTEGRATION_DIR/$_bento_part.zsh"
  fi
done
unset _bento_part

# Mark the integration as live so other tooling (e.g. a `riven doctor`
# script) can probe.
typeset -g RIVEN_INTEGRATION_LOADED=1
