# Bento shell integration for zsh.
#
# Emits:
#   OSC 7        — current working directory (file://host/path), so Bento's
#                  per-workspace sidebar can follow `cd`.
#   OSC 133;A    — start-of-prompt marker.
#   OSC 133;B    — end-of-prompt / start-of-input marker.
#   OSC 133;C    — start-of-command-output marker (preexec).
#   OSC 133;D;N  — end-of-command marker, with exit code N (precmd).
#
# Install:
#   echo 'source /absolute/path/to/scripts/bento-shell-integration.zsh' >> ~/.zshrc
#
# Safe to source more than once: the hook arrays are de-duplicated and the
# OSC 133;B prefix is only added to PROMPT once.

# Only run in interactive zsh.
[[ -o interactive ]] || return 0
[[ -n "$ZSH_VERSION" ]] || return 0

# Avoid double-installation in the same shell.
if [[ -n "$__BENTO_SHELL_INTEGRATION_LOADED" ]]; then
  return 0
fi
typeset -g __BENTO_SHELL_INTEGRATION_LOADED=1

# Percent-encode a string for use inside an OSC 7 file:// URI.
# Keeps unreserved characters and '/' verbatim; everything else becomes %XX.
__bento_urlencode() {
  emulate -L zsh
  local s="$1" out="" i c
  for (( i = 1; i <= ${#s}; i++ )); do
    c="${s[i]}"
    case "$c" in
      [a-zA-Z0-9/._~-]) out+="$c" ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s' "$out"
}

# precmd: runs just before each prompt is drawn.
#   1. Emit OSC 133;D with the previous command's exit code.
#   2. Emit OSC 7 with the current working directory.
#   3. Emit OSC 133;A to mark the start of the next prompt.
__bento_precmd() {
  local exit_code=$?
  local host="${HOSTNAME:-${HOST:-localhost}}"
  local encoded_pwd
  encoded_pwd=$(__bento_urlencode "$PWD")
  printf '\033]133;D;%s\007' "$exit_code"
  printf '\033]7;file://%s%s\007' "$host" "$encoded_pwd"
  printf '\033]133;A\007'
}

# preexec: runs just after the user submits a command, before it executes.
__bento_preexec() {
  printf '\033]133;C\007'
}

# Register hooks. We append directly rather than depending on add-zsh-hook
# so the script runs cleanly under minimal/old configurations.
typeset -ga precmd_functions preexec_functions
if (( ! ${precmd_functions[(I)__bento_precmd]} )); then
  precmd_functions+=(__bento_precmd)
fi
if (( ! ${preexec_functions[(I)__bento_preexec]} )); then
  preexec_functions+=(__bento_preexec)
fi

# Prepend OSC 133;B (end-of-prompt) to PROMPT, wrapped in %{ %} so zsh does
# not count the escape bytes when computing the visible prompt width.
# Only do this once, even if the file is sourced again.
if [[ "$PROMPT" != *$'\033]133;B\007'* ]]; then
  PROMPT='%{'$'\033]133;B\007''%}'"$PROMPT"
fi
