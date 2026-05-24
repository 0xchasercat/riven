# Riven shell integration — main entry point.
#
# This file is the entry point a user's ~/.zshrc sources.
#
# COEXISTENCE: integration.zsh (the OSC 7 / 133 emitters) is the only
# part Riven's features actually depend on — the sidebar follows `cd`
# and the chrome navigates prompt marks because of it. Everything else
# (prompt, autosuggestions, syntax highlighting, history search, z) is
# opinionated UX we apply ONLY on a shell that doesn't already have its
# own. If you run a framework (Zim, oh-my-zsh, prezto), starship /
# powerlevel10k, or your own autosuggest / highlight plugins, layering
# Riven's on top means two prompts, duelling highlighters, and widget
# conflicts. So we DETECT what's already loaded and skip the duplicates.
#
# Load order (each loader is small + idempotent):
#   1. options.zsh       zsh defaults (history, completion, …)
#   2. integration.zsh   OSC 7 / 133 hooks — ALWAYS loaded
#   3. prompt.zsh        minimal prompt — skipped if you have one
#   4. keybinds.zsh      emacs + plugin bindings (self-gating)
#   5. plugins.zsh       vendored plugins, each skipped if present
#
# Overrides (export before the source line in .zshrc):
#   RIVEN_MINIMAL=1   force OSC-only — skip ALL cosmetics
#   RIVEN_FULL=1      force the full Riven setup, ignore detection
#
# Everything is gated on `$TERM_PROGRAM == Riven` so this file is a
# NO-OP outside Riven — sourcing it from iTerm / Terminal.app / kitty
# leaves that shell untouched. Keep the source line in .zshrc
# unconditionally; no manual fencing needed.

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

# ── Coexistence detection ─────────────────────────────────────────
# Compute which cosmetic loaders to skip because an existing setup
# already provides them. Detection runs HERE (before any loader) so
# the framework's functions/vars — defined earlier in .zshrc, since
# the Riven source line goes last — are already visible. The skip
# flags are plain globals read by prompt/keybinds/plugins below.
typeset -g _riven_skip_prompt=0
typeset -g _riven_skip_autosuggest=0
typeset -g _riven_skip_highlight=0
typeset -g _riven_skip_histsearch=0
typeset -g _riven_skip_z=0
typeset -g _riven_coexist=0

if [[ -n "${RIVEN_FULL:-}" ]]; then
  : # honour everything — leave all skips at 0
elif [[ -n "${RIVEN_MINIMAL:-}" ]]; then
  _riven_skip_prompt=1
  _riven_skip_autosuggest=1
  _riven_skip_highlight=1
  _riven_skip_histsearch=1
  _riven_skip_z=1
  _riven_coexist=1
else
  # Existing prompt? starship, Zim, prezto, oh-my-zsh theme, or
  # powerlevel10k all count.
  if [[ -n "${STARSHIP_SHELL:-}" || -n "${ZIM_HOME:-}" || -n "${ZPREZTODIR:-}" \
        || ( -n "${ZSH:-}" && -n "${ZSH_THEME:-}" ) ]] \
     || (( $+functions[p10k] )) \
     || (( $+functions[prompt_powerlevel9k_setup] )); then
    _riven_skip_prompt=1
  fi
  # Existing autosuggestions? The plugin defines `_zsh_autosuggest_start`
  # when sourced.
  if (( $+functions[_zsh_autosuggest_start] )); then
    _riven_skip_autosuggest=1
  fi
  # Existing syntax highlighting — either zsh-syntax-highlighting
  # (`_zsh_highlight`) or fast-syntax-highlighting (`_fast_highlight_main`
  # / $FAST_HIGHLIGHT).
  if (( $+functions[_zsh_highlight] )) \
     || (( $+functions[_fast_highlight_main] )) \
     || [[ -n "${FAST_HIGHLIGHT+x}" ]]; then
    _riven_skip_highlight=1
  fi
  # Existing history-substring-search? Its up-widget is the tell.
  if (( $+functions[history-substring-search-up] )); then
    _riven_skip_histsearch=1
  fi
  # Existing jump tool? z function already defined, or zoxide on PATH
  # (the common modern replacement). Don't shadow either.
  if (( $+functions[z] )) || [[ -n "${commands[zoxide]:-}" ]]; then
    _riven_skip_z=1
  fi
  # "Coexist mode" umbrella: true if ANY of the above tripped. Gates
  # the intrusive `bindkey -e` in keybinds.zsh — we don't force the
  # emacs keymap on a shell that's clearly someone's curated setup
  # (they may run vi mode).
  if (( _riven_skip_prompt || _riven_skip_autosuggest \
        || _riven_skip_highlight || _riven_skip_histsearch )); then
    _riven_coexist=1
  fi
fi

# ── Load ───────────────────────────────────────────────────────────
# Always: options (defaults + guarded compinit) + integration (OSC).
for _riven_part in options integration; do
  [[ -r "$RIVEN_INTEGRATION_DIR/$_riven_part.zsh" ]] \
    && source "$RIVEN_INTEGRATION_DIR/$_riven_part.zsh"
done

# Prompt only when the shell doesn't already have one.
if (( ! _riven_skip_prompt )); then
  [[ -r "$RIVEN_INTEGRATION_DIR/prompt.zsh" ]] \
    && source "$RIVEN_INTEGRATION_DIR/prompt.zsh"
fi

# Keybinds + plugins always source; both self-gate the parts that
# would duplicate an existing plugin (they read the _riven_skip_*
# flags set above).
for _riven_part in keybinds plugins; do
  [[ -r "$RIVEN_INTEGRATION_DIR/$_riven_part.zsh" ]] \
    && source "$RIVEN_INTEGRATION_DIR/$_riven_part.zsh"
done
unset _riven_part

# Mark the integration as live so other tooling (e.g. a `riven doctor`
# script) can probe.
typeset -g RIVEN_INTEGRATION_LOADED=1
