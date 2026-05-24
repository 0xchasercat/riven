# Riven shell integration — keyboard bindings.
#
# Emacs-style by default (matches macOS expectation; readline does
# the same), with two upgrades:
#
#   1. Up / Down do *substring history search* on whatever's already
#      in the buffer. Type `git ` then ↑ to step through every past
#      git command — much better than the default literal history
#      walk. Provided by zsh-history-substring-search (loaded in
#      plugins.zsh).
#
#   2. Ctrl-R uses the same substring search inline (the buffer
#      mode), which lines up with fzf-style flows users already
#      expect.

[[ -o interactive ]] || return 0

# Use emacs keymap baseline — but ONLY on a bare shell. In coexist
# mode (riven.zsh detected a framework / curated setup) we leave the
# keymap alone: the user may run vi mode, and forcing `bindkey -e`
# from our last-sourced file would silently clobber it.
if (( ! ${_riven_coexist:-0} )); then
  bindkey -e
fi

# Bind history-substring-search to Up / Down arrows — only if WE
# loaded that plugin. When the user already has it
# (`_riven_skip_histsearch`) their own bindings own the arrows.
if (( ! ${_riven_skip_histsearch:-0} )); then
  bindkey '^[[A' history-substring-search-up
  bindkey '^[[B' history-substring-search-down
  # Same on the alternate cursor-key sequence terminals send in
  # application mode.
  bindkey '^[OA' history-substring-search-up
  bindkey '^[OB' history-substring-search-down
fi

# ─── zsh-autosuggestions accept binding ──────────────────────────
# Right-arrow accepts the ghost-text suggestion (the default).
# Bind Ctrl-E too — Emacs end-of-line is a natural twin gesture for
# "yes, finish the line for me." Only when WE own autosuggestions;
# otherwise the user's plugin already wired its own accept key.
if (( ! ${_riven_skip_autosuggest:-0} )); then
  bindkey '^E' autosuggest-accept
fi

# ─── Common pain points ──────────────────────────────────────────
# Option-Left / Option-Right walks by word in macOS terminals.
bindkey '^[b' backward-word
bindkey '^[f' forward-word

# Ctrl-W: delete the previous word. Emacs default but some users'
# configs blow it away.
bindkey '^W' backward-kill-word

# Home / End jump to the line edges even when the terminal sends
# the legacy `^[[1~` / `^[[4~` sequences.
bindkey '^[[H' beginning-of-line
bindkey '^[[F' end-of-line
bindkey '^[[1~' beginning-of-line
bindkey '^[[4~' end-of-line
