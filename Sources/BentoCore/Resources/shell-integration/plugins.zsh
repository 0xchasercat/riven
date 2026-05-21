# Bento shell integration — plugin loader.
#
# Sources the vendored plugins in `$BENTO_INTEGRATION_DIR/plugins/`.
# Order matters: fast-syntax-highlighting MUST be the last widget to
# attach (per its own README — it re-wraps every ZLE widget and
# anything that wraps `self-insert` after it loses the highlight).
# Same for history-substring-search vs. autosuggestions:
#   1. autosuggestions      attach widgets
#   2. history-substring-search   attach widgets
#   3. fast-syntax-highlighting   wrap everything
#
# z.sh (jump-list cd) doesn't touch ZLE widgets, so it can land
# anywhere; we source it first because it's the lightest.

[[ -o interactive ]] || return 0

# ─── z.sh — jump-list cd ─────────────────────────────────────────
# Adds the `z <pattern>` command for frecency-based jumping. Tracks
# every cd in `~/.z` (plain text, one entry per line). Pure shell,
# zero subprocess overhead per prompt.
if [[ -r "$BENTO_INTEGRATION_DIR/plugins/z.sh" ]]; then
  _Z_DATA="${_Z_DATA:-$HOME/.z}"
  source "$BENTO_INTEGRATION_DIR/plugins/z.sh"
fi

# ─── zsh-autosuggestions — ghost text from history ────────────────
# Suggests the rest of the line you're typing, drawn in a dim color
# that's distinct from the active buffer. Right-arrow / Ctrl-E
# accepts (binding in keybinds.zsh).
#
# Style: ANSI 8 = "bright black" which Bento's themes map to a true
# dim color rather than a half-white-on-black artifact.
if [[ -r "$BENTO_INTEGRATION_DIR/plugins/zsh-autosuggestions.zsh" ]]; then
  ZSH_AUTOSUGGEST_HIGHLIGHT_STYLE='fg=8'
  ZSH_AUTOSUGGEST_STRATEGY=(history completion)
  ZSH_AUTOSUGGEST_BUFFER_MAX_SIZE=80   # don't suggest for huge buffers
  source "$BENTO_INTEGRATION_DIR/plugins/zsh-autosuggestions.zsh"
fi

# ─── zsh-history-substring-search — Up/Down search ────────────────
# Widgets are attached here; bindings happen in keybinds.zsh which
# we ran earlier (the widget names are static so it doesn't matter
# in which order the source + bindkey calls happen — `bindkey` just
# names a widget that gets resolved at keypress time).
if [[ -r "$BENTO_INTEGRATION_DIR/plugins/zsh-history-substring-search.zsh" ]]; then
  source "$BENTO_INTEGRATION_DIR/plugins/zsh-history-substring-search.zsh"
  # Highlight the matched substring in the buffer using the theme's
  # accent. ANSI 3 (yellow) -> bento amber / tokyo violet / etc.
  HISTORY_SUBSTRING_SEARCH_HIGHLIGHT_FOUND='bg=3,fg=black,bold'
  HISTORY_SUBSTRING_SEARCH_HIGHLIGHT_NOT_FOUND='bg=1,fg=white,bold'
fi

# ─── fast-syntax-highlighting — colorize as you type ──────────────
# MUST be loaded last (it wraps every other widget). Its theme
# subsystem is configurable but the default "default" theme reads
# fine on every Bento palette so we don't override.
if [[ -r "$BENTO_INTEGRATION_DIR/plugins/fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh" ]]; then
  source "$BENTO_INTEGRATION_DIR/plugins/fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh"
fi
