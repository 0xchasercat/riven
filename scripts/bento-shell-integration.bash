# Bento shell integration for bash.
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
#   echo 'source /absolute/path/to/scripts/bento-shell-integration.bash' >> ~/.bashrc
#
# Requires bash 4+ (uses BASH_COMMAND and the DEBUG trap).

# Only run in interactive bash.
case "$-" in
  *i*) ;;
  *) return 0 ;;
esac
[ -n "$BASH_VERSION" ] || return 0

# Avoid double-installation in the same shell.
if [ -n "$__BENTO_SHELL_INTEGRATION_LOADED" ]; then
  return 0
fi
__BENTO_SHELL_INTEGRATION_LOADED=1

# Percent-encode a string for use inside an OSC 7 file:// URI.
# Keeps unreserved characters and '/' verbatim; everything else becomes %XX.
__bento_urlencode() {
  local s="$1" out="" i c
  local LC_ALL=C
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    case "$c" in
      [a-zA-Z0-9/._~-]) out+="$c" ;;
      *) printf -v out '%s%%%02X' "$out" "'$c" ;;
    esac
  done
  printf '%s' "$out"
}

# precmd: runs from PROMPT_COMMAND just before each prompt is drawn.
#   1. Set an "inside PROMPT_COMMAND" guard so the DEBUG trap stays quiet for
#      every other command bash runs as part of the prompt cycle.
#   2. Emit OSC 133;D with the previous command's exit code.
#   3. Emit OSC 7 with the current working directory.
#   4. Emit OSC 133;A to mark the start of the next prompt.
#   5. Clear the guard and arm the DEBUG trap so the *next* user command
#      fires preexec.
__bento_precmd() {
  local exit_code=$?
  __bento_in_prompt_command=1
  local host="${HOSTNAME:-localhost}"
  local encoded_pwd
  encoded_pwd=$(__bento_urlencode "$PWD")
  printf '\033]133;D;%s\007' "$exit_code"
  printf '\033]7;file://%s%s\007' "$host" "$encoded_pwd"
  printf '\033]133;A\007'
  __bento_in_prompt_command=
  __bento_preexec_armed=1
  return 0
}

# preexec: invoked by the DEBUG trap. The trap fires for every simple command
# bash runs, including the ones inside PROMPT_COMMAND. We use two gates:
#   - __bento_in_prompt_command: set while __bento_precmd is running, so
#     subshells/eval/etc. inside PROMPT_COMMAND don't trigger us.
#   - __bento_preexec_armed: a one-shot flag set by __bento_precmd and
#     cleared on the first eligible firing — guarantees we emit OSC 133;C
#     exactly once per command line.
# Plus a name-based filter as a belt-and-braces guard against re-entry.
__bento_preexec() {
  [ -n "$__bento_in_prompt_command" ] && return 0
  [ -n "$__bento_preexec_armed" ] || return 0
  case "$BASH_COMMAND" in
    __bento_precmd*|__bento_preexec*|__bento_urlencode*) return 0 ;;
  esac
  __bento_preexec_armed=
  printf '\033]133;C\007'
}

# Wire precmd into PROMPT_COMMAND without clobbering anything already there.
# Bash 5.1+ supports PROMPT_COMMAND as an array; we stick to the string form
# for maximum compatibility.
case ";${PROMPT_COMMAND};" in
  *";__bento_precmd;"*) ;;
  *) PROMPT_COMMAND="__bento_precmd${PROMPT_COMMAND:+;$PROMPT_COMMAND}" ;;
esac

# Wire preexec via the DEBUG trap.
trap '__bento_preexec' DEBUG

# Prepend OSC 133;B (end-of-prompt) to PS1, wrapped in \[ \] so bash does not
# count the escape bytes when computing the visible prompt width.
# Only do this once, even if the file is sourced again.
case "$PS1" in
  *$'\033]133;B\007'*) ;;
  *) PS1='\[\033]133;B\007\]'"$PS1" ;;
esac
