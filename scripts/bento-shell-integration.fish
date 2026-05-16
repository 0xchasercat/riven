# Bento shell integration for fish.
#
# Emits:
#   OSC 7        — current working directory (file://host/path), so Bento's
#                  per-workspace sidebar can follow `cd`.
#   OSC 133;A    — start-of-prompt marker.
#   OSC 133;B    — end-of-prompt / start-of-input marker.
#   OSC 133;C    — start-of-command-output marker (fish_preexec).
#   OSC 133;D;N  — end-of-command marker, with exit code N (fish_postexec).
#
# Install (recommended — auto-loaded on every interactive shell):
#   cp scripts/bento-shell-integration.fish ~/.config/fish/conf.d/
#
# Or source manually from config.fish:
#   source /absolute/path/to/scripts/bento-shell-integration.fish

# Only run in interactive fish.
status is-interactive; or exit 0

# Avoid double-installation in the same shell.
if set -q __bento_shell_integration_loaded
    exit 0
end
set -g __bento_shell_integration_loaded 1

# Percent-encode a string for use inside an OSC 7 file:// URI.
# Keeps unreserved characters and '/' verbatim; everything else becomes %XX.
function __bento_urlencode
    set -l s $argv[1]
    set -l out ""
    set -l len (string length -- $s)
    for i in (seq 1 $len)
        set -l c (string sub -s $i -l 1 -- $s)
        if string match -qr '^[a-zA-Z0-9/._~-]$' -- $c
            set out $out$c
        else
            # printf '%%%02X' on the byte value.
            set -l hex (printf '%%%02X' (printf '%d' "'$c"))
            set out $out$hex
        end
    end
    printf '%s' $out
end

# fish_preexec fires after the user submits a command, before it runs.
function __bento_preexec --on-event fish_preexec
    printf '\033]133;C\007'
end

# fish_postexec fires after the command finishes, before the next prompt.
# We emit:
#   OSC 133;D with the exit code,
#   OSC 7 with the new cwd,
#   OSC 133;A to open the next prompt.
function __bento_postexec --on-event fish_postexec
    set -l exit_code $status
    set -l host (hostname 2>/dev/null; or echo localhost)
    set -l encoded_pwd (__bento_urlencode "$PWD")
    printf '\033]133;D;%s\007' $exit_code
    printf '\033]7;file://%s%s\007' $host $encoded_pwd
    printf '\033]133;A\007'
end

# Wrap fish_prompt so it ends with OSC 133;B (end-of-prompt marker).
# Copy the existing fish_prompt to __bento_orig_fish_prompt and replace it.
# Idempotent: only wrap once even if this file is loaded multiple times.
if not functions -q __bento_orig_fish_prompt
    if functions -q fish_prompt
        functions -c fish_prompt __bento_orig_fish_prompt
    else
        function __bento_orig_fish_prompt
            printf '%s@%s %s> ' (whoami) (hostname | cut -d. -f1) (prompt_pwd)
        end
    end

    function fish_prompt
        __bento_orig_fish_prompt
        printf '\033]133;B\007'
    end
end

# Emit an initial OSC 7 + OSC 133;A so Bento knows the cwd and prompt boundary
# for the first prompt of the session (before any command has run).
set -l __bento_init_host (hostname 2>/dev/null; or echo localhost)
set -l __bento_init_pwd (__bento_urlencode "$PWD")
printf '\033]7;file://%s%s\007' $__bento_init_host $__bento_init_pwd
printf '\033]133;A\007'
