# Riven shell integration — terminal escape sequence hooks.
#
# Two flavors of OSC (Operating System Command) sequences feed Riven's
# chrome state:
#
#   OSC 7  — "the shell is now in directory X"
#            Riven's BrokeredTerminalView reads this in its draw loop
#            (snapshotFrame + reportCwdIfChanged), and the sidebar
#            updates to scan that path. Without this, the sidebar
#            stays parked at the workspace's initial cwd even after
#            you `cd elsewhere`.
#
#   OSC 133 — Final Term-style prompt / command boundary marks.
#            Each command segment is delimited by:
#              A  prompt about to start
#              B  prompt finished, command line begins
#              C  command running
#              D  command finished, exit code follows
#            These let Riven (and any future "jump to previous
#            prompt" / "select last command output" feature) know
#            where each command starts + ends without parsing the
#            visible buffer.
#
# Both are zero-visible-bytes — every modern terminal that doesn't
# understand them just drops the escape on the floor.

# Bail if the shell isn't interactive — these hooks are for the user's
# prompt, not for a `zsh -c 'cmd'` invocation.
[[ -o interactive ]] || return 0

# ─── OSC 7: report cwd ────────────────────────────────────────────
# RFC: ESC ] 7 ; file:// <hostname> <path> ESC \
# The path must be URL-encoded. zsh's `printf` doesn't have a
# bulit-in encoder, so we hand-roll one with parameter substitution.

_riven_url_encode() {
  emulate -L zsh
  local input="$1" output=""
  local -i i
  for (( i = 1; i <= ${#input}; i++ )); do
    local c="${input[i]}"
    case "$c" in
      [a-zA-Z0-9/._~-]) output+="$c" ;;
      *) output+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  print -r -- "$output"
}

_riven_osc7() {
  printf '\e]7;file://%s%s\e\\' "${HOST}" "$(_riven_url_encode "$PWD")"
}

# ─── OSC 133: prompt + command marks ──────────────────────────────
# Marks are emitted from chpwd / preexec / precmd hooks so they fire
# exactly once per command lifecycle and never on no-op redraws.

_riven_osc133_prompt_start() { printf '\e]133;A\e\\'; }
_riven_osc133_prompt_end()   { printf '\e]133;B\e\\'; }
_riven_osc133_cmd_start()    { printf '\e]133;C\e\\'; }
_riven_osc133_cmd_end()      { printf '\e]133;D;%s\e\\' "$1"; }

# ─── Hook plumbing ────────────────────────────────────────────────
# `add-zsh-hook` is the official way to attach to zsh's lifecycle
# events without clobbering whatever the user already has.

autoload -Uz add-zsh-hook

# Track the exit status of the *previous* command so OSC 133 D can
# carry it.
typeset -g _RIVEN_LAST_EXIT=0

# precmd runs right before the prompt is rendered (i.e. just after a
# command finished or at shell start). Emit:
#   * D with the previous exit code (skip on the first ever precmd,
#     where no command has run yet — `_RIVEN_PRECMD_RAN` gates this)
#   * the cwd report (OSC 7)
#   * A to mark the new prompt's start
_riven_precmd() {
  _RIVEN_LAST_EXIT=$?
  if (( ${+_RIVEN_PRECMD_RAN} )); then
    _riven_osc133_cmd_end "$_RIVEN_LAST_EXIT"
  fi
  typeset -g _RIVEN_PRECMD_RAN=1
  _riven_osc7
  _riven_osc133_prompt_start
}

# preexec runs after the user hits Enter and before the command runs.
# Mark prompt-end + command-start back-to-back so the visible buffer
# region between A and C is exactly the user's typed line.
_riven_preexec() {
  _riven_osc133_prompt_end
  _riven_osc133_cmd_start
}

add-zsh-hook precmd  _riven_precmd
add-zsh-hook preexec _riven_preexec

# ─── Ctrl-clickable file paths ────────────────────────────────────
# Print absolute paths with the OSC 8 hyperlink escape so Riven can
# turn them into ⌘-clickable links. Tools like `ls`, `git`, etc.
# print bare paths; users can opt into hyperlinking by piping through
# `riven-hyperlink`. We don't auto-wrap because rewriting every
# command's output is fragile + slow.
#
# (Reserved for a future polish ticket — the OSC 8 spec is in place,
# the helper isn't shipped yet.)
