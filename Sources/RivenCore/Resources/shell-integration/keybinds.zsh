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

# Use emacs keymap baseline. Vim users can `bindkey -v` in their
# .zshrc after sourcing Riven — we don't override their personal
# config.
bindkey -e

# Bind history-substring-search to Up / Down arrows. The plugin is
# loaded later (plugins.zsh) but its widgets are declared at load
# time, so this binding works as long as plugins.zsh runs after
# keybinds.zsh — which it does, per the order in riven.zsh.
bindkey '^[[A' history-substring-search-up
bindkey '^[[B' history-substring-search-down
# Same on the alternate cursor-key sequence terminals send in
# application mode.
bindkey '^[OA' history-substring-search-up
bindkey '^[OB' history-substring-search-down

# Ctrl-R: same substring search, but inline (Emacs muscle memory).
# zsh-history-substring-search exposes `history-incremental-search-backward`
# under that binding by default; we keep zsh's built-in for now and
# revisit if users ask for fzf-style replacement.

# ─── zsh-autosuggestions accept binding ──────────────────────────
# Right-arrow accepts the ghost-text suggestion (the default).
# Bind Ctrl-E too — Emacs end-of-line is a natural twin gesture for
# "yes, finish the line for me." Without this, users have to reach
# for the arrow to take a suggestion.
bindkey '^E' autosuggest-accept

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
