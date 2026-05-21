# Riven shell integration — minimal, theme-aware prompt.
#
# Two lines of visible chrome, designed to match Riven's compartment
# aesthetic:
#
#     ~/code/ riven · main ✗
#     ›
#
#   * Last 2 segments of cwd. The leading dim chunks (`~/code/`) read
#     as breadcrumb; the active segment (`riven`) reads as the
#     anchor.
#   * Optional git branch + state indicator (`✗` dirty, `↑n` ahead,
#     `↓n` behind). Computed asynchronously so a slow `git status`
#     never blocks the prompt — the *next* prompt gets the result.
#   * Prompt character is the theme's prompt color (Amber,
#     Tokyo violet, etc.). Goes red after a non-zero exit so the
#     user notices a failure without scrolling up.
#
# Colors are 256-color ANSI escapes that flow through Riven's tuned
# palette (Sources/RivenCore/ThemeSpec.swift). That means the prompt
# automatically follows the active theme — switching from Riven to
# Tokyo in Riven's status-bar swatch re-tints the prompt without the
# shell reloading.

# Bail on non-interactive shells.
[[ -o interactive ]] || return 0

# ─── Color helpers ────────────────────────────────────────────────
# `%F{color}` / `%f` are zsh's portable foreground codes; `%K{c}` /
# `%k` are background. Inside %{ %} they don't count toward visible
# width — important so cursor positioning + line wrap stay correct
# at the right margin.

# Map to ANSI palette indices that Riven's themes interpret:
#   default fg  →  unset (terminal's fg)
#   dim         →  index 8  (bright black / "dim foreground")
#   accent      →  index 3  (yellow — themes remap this to riven
#                            amber / tokyo violet / paper ink etc.)
#   ok          →  index 2  (green)
#   warn        →  index 3  (yellow)
#   err         →  index 1  (red)
typeset -g _RIVEN_C_DIM='%F{8}'
typeset -g _RIVEN_C_ACCENT='%F{3}'
typeset -g _RIVEN_C_OK='%F{2}'
typeset -g _RIVEN_C_WARN='%F{3}'
typeset -g _RIVEN_C_ERR='%F{1}'
typeset -g _RIVEN_C_RESET='%f'

# ─── Async git status ─────────────────────────────────────────────
# A synchronous `git status --porcelain` adds 5-50ms per prompt — a
# floor of perceptual lag the user feels even with nothing changed.
# We push the probe into a background subshell, write the result to
# a file the next precmd reads. Worst case: the displayed status is
# 1 prompt stale, which is fine because the prompt redraws after
# every command anyway.

typeset -g _RIVEN_GIT_STATUS_DIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/riven-git-$$"
mkdir -p "$_RIVEN_GIT_STATUS_DIR"
trap "rm -rf '$_RIVEN_GIT_STATUS_DIR'" EXIT

# Last-seen pwd + last-seen branch so we can invalidate the cache
# when the user `cd`s into a different repo.
typeset -g _RIVEN_LAST_GIT_PWD=""
typeset -g _RIVEN_GIT_STATUS=""

_riven_git_probe_async() {
  local pwd_snapshot="$PWD"
  local outfile="$_RIVEN_GIT_STATUS_DIR/status"
  (
    cd "$pwd_snapshot" 2>/dev/null || exit 0
    local branch
    branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) \
      || branch=$(git rev-parse --short HEAD 2>/dev/null) \
      || exit 0
    local dirty ahead behind state=""
    if ! git diff --quiet --ignore-submodules HEAD 2>/dev/null \
       || [[ -n $(git ls-files --others --exclude-standard 2>/dev/null) ]]; then
      state+="✗"
    fi
    local upstream
    upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null) || true
    if [[ -n $upstream ]]; then
      ahead=$(git rev-list --count "$upstream..HEAD" 2>/dev/null || echo 0)
      behind=$(git rev-list --count "HEAD..$upstream" 2>/dev/null || echo 0)
      (( ahead  > 0 )) && state+=" ↑${ahead}"
      (( behind > 0 )) && state+=" ↓${behind}"
    fi
    printf '%s|%s\n' "$branch" "$state" > "$outfile.tmp"
    mv -f "$outfile.tmp" "$outfile"
  ) &!
}

_riven_git_read_status() {
  local outfile="$_RIVEN_GIT_STATUS_DIR/status"
  if [[ -r "$outfile" ]]; then
    _RIVEN_GIT_STATUS=$(<"$outfile")
  else
    _RIVEN_GIT_STATUS=""
  fi
}

# Append to integration.zsh's hooks. precmd already runs there for
# OSC marks; we add the git probe + status read here.
autoload -Uz add-zsh-hook

_riven_prompt_precmd() {
  # Trigger an async probe whenever the cwd changes. The result
  # lands in the next prompt or two — close enough.
  if [[ "$PWD" != "$_RIVEN_LAST_GIT_PWD" ]]; then
    _RIVEN_LAST_GIT_PWD="$PWD"
    _RIVEN_GIT_STATUS=""   # clear stale state immediately on cd
    rm -f "$_RIVEN_GIT_STATUS_DIR/status"
    _riven_git_probe_async
  else
    # Same repo, re-probe on each prompt so the dirty flag stays
    # honest. Skip if we're not even inside a git tree (cheap
    # check: presence of `.git` up the tree).
    if [[ -d "$PWD/.git" ]] || git rev-parse --is-inside-work-tree &>/dev/null; then
      _riven_git_probe_async
    else
      _RIVEN_GIT_STATUS=""
      rm -f "$_RIVEN_GIT_STATUS_DIR/status"
    fi
  fi
  _riven_git_read_status
}
add-zsh-hook precmd _riven_prompt_precmd

# ─── Prompt assembly ──────────────────────────────────────────────
# Each segment is a zsh prompt expansion. PROMPT_SUBST (set in
# options.zsh) makes the inline `$(…)` and `${…}` expansions evaluate
# every render. We keep the inline shellouts to zero — the git probe
# is async, the path math is parameter expansion, the exit-code peek
# is `%(?..)`.

# Two-segment cwd: ` parentDir/leaf `. `%2~` gives that with `~` for
# $HOME. For paths shorter than 2 segments, we just show the whole
# thing.
_riven_segment_cwd() {
  print -P "%2~"
}

# Builds the right-hand "git" segment from `_RIVEN_GIT_STATUS` (set
# by the async probe). Empty when not in a repo or before the first
# probe completes.
#
# Output goes through `$(_riven_segment_git)` in PROMPT, which means
# any `%F{...}` codes we emit ship verbatim (no re-expansion). Use
# raw SGR escapes wrapped in `%{...%}` so the prompt subsystem still
# treats them as zero-width — without `%{...%}` the cursor column
# count would be off by the escape byte count and line-wrap would
# break.
_riven_segment_git() {
  [[ -z $_RIVEN_GIT_STATUS ]] && return
  local branch="${_RIVEN_GIT_STATUS%%|*}"
  local state="${_RIVEN_GIT_STATUS#*|}"
  # \e[38;5;Nm = "256-color foreground, index N". We use the same
  # palette indices as the prompt-code %F{N}: 8 dim, 3 accent.
  local dim=$'%{\e[38;5;8m%}' accent=$'%{\e[38;5;3m%}' reset=$'%{\e[0m%}'
  if [[ -n $state ]]; then
    print -nr -- " ${dim}·${reset} ${accent}${branch}${reset} ${accent}${state}${reset}"
  else
    print -nr -- " ${dim}·${reset} ${accent}${branch}${reset}"
  fi
}

# Build the full prompt. Two lines:
#   line 1: cwd (last 2 segments, dim) + (optional) git branch
#   line 2: prompt char (accent normally, red after non-zero exit)
#
# Everything below uses zsh's native `%F{...}` / `%f` codes because
# they're processed by the prompt subsystem directly and AppKit /
# terminal-cell math gets the zero-width hint for free. Inside
# `$(…)` substitutions those codes ship as literal `%F{8}` strings
# (PROMPT_SUBST doesn't re-run prompt expansion) — so the git
# segment uses raw `\e[…m` ANSI escapes wrapped in `%{…%}` to keep
# zsh's width accounting honest.
PROMPT='%F{8}%2~%f'
PROMPT+='$(_riven_segment_git)'
PROMPT+=$'\n'
PROMPT+='%(?.%F{3}.%F{1})›%f '

# Right-side prompt: kept empty for now — Riven's status bar already
# carries duration / cwd info, and a right prompt fights the inner
# tab strip on narrow splits.
RPROMPT=''
