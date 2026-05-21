# Riven shell integration — sensible zsh defaults.
#
# We avoid the kitchen-sink Oh-My-Zsh approach. These are the options
# that pay rent: bigger history, case-insensitive completion, smart
# globbing. Nothing here changes user-facing behaviour beyond what a
# careful manual .zshrc would do — we just save people from typing it.

# ─── History ──────────────────────────────────────────────────────
# 100k entries on disk is generous but not silly — it's ~10MB on a
# busy shell, and ripgrep through it (via Riven's global search,
# S-3) takes <50ms. The in-memory buffer is the same so up-arrow
# walks the same set.
HISTFILE="${HISTFILE:-$HOME/.zsh_history}"
HISTSIZE=100000
SAVEHIST=100000

# Share history across concurrent shells, append don't overwrite, and
# drop duplicate consecutive commands. `inc_append_history` writes on
# every command rather than on shell exit so a crash doesn't lose the
# session — important because Riven's broker outlives the UI.
setopt INC_APPEND_HISTORY
setopt SHARE_HISTORY
setopt HIST_IGNORE_DUPS
setopt HIST_IGNORE_SPACE      # leading-space commands aren't saved
setopt HIST_REDUCE_BLANKS
setopt HIST_VERIFY            # show !! expansion before running

# ─── Completion ───────────────────────────────────────────────────
# Cache compinit's dump so subsequent shells start fast. Stamp lives
# in ~/.cache so it's discoverable + clearable.
typeset -g _riven_compdump="${XDG_CACHE_HOME:-$HOME/.cache}/zsh/zcompdump"
mkdir -p "${_riven_compdump:h}"

# Load completion subsystem with the cache. `-C` skips security
# checks (the dump's mtime drives the decision) — fast path. We
# re-check perms only once a day.
autoload -Uz compinit
if [[ -n $_riven_compdump(#qN.mh+24) ]]; then
  compinit -d "$_riven_compdump"
else
  compinit -C -d "$_riven_compdump"
fi
unset _riven_compdump

# Smart matching: case-insensitive, partial-word, dashed-prefix all
# count as matches. Order matters — first matcher wins.
zstyle ':completion:*' matcher-list \
  'm:{a-zA-Z}={A-Za-z}' \
  'r:|[._-]=* r:|=*' \
  'l:|=* r:|=*'
# Group matches by category (commands / files / etc.) with a dim header.
zstyle ':completion:*' group-name ''
zstyle ':completion:*:descriptions' format $'\e[2m%d\e[0m'
# Use a menu-style selector for ambiguous completions; arrow keys move.
zstyle ':completion:*' menu select
# Cache rarely-changing completions (rsync's host list, brew packages).
zstyle ':completion:*' use-cache yes
zstyle ':completion:*' cache-path "${XDG_CACHE_HOME:-$HOME/.cache}/zsh/.zcompcache"

# ─── Globbing / navigation ────────────────────────────────────────
setopt EXTENDED_GLOB          # `~`, `^`, `#` qualifiers in globs
setopt NO_CASE_GLOB           # `*.PNG` matches `.png`
setopt AUTO_CD                # `cd foo` → `foo` if `foo` is a dir
setopt AUTO_PUSHD             # every cd pushes onto the dir stack
setopt PUSHD_IGNORE_DUPS

# ─── Misc UX ──────────────────────────────────────────────────────
setopt INTERACTIVE_COMMENTS   # `# foo bar` is a comment, not an error
setopt NO_BEEP                # silent terminal — Riven has the banner
setopt PROMPT_SUBST           # required for the dynamic prompt below

# ─── Color env ────────────────────────────────────────────────────
# Riven sets TERM=xterm-256color + COLORTERM=truecolor on every PTY
# spawn. Make sure common tools pick that up.
export CLICOLOR=1
export LESS="${LESS:-FRX}"    # raw-control-chars, no-init, quit-if-one-screen
export PAGER="${PAGER:-less}"

# Riven's compartment chrome is dark by default. Tell ls to use a
# palette that reads on dark + cream backgrounds (the GNU one works
# fine; macOS BSD ls falls back gracefully).
export LSCOLORS="ExGxFxDxCxegedabagacad"
