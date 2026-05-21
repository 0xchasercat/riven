#!/usr/bin/env bash
# no-hardcoded-chrome.sh — fail if a hex color literal is being used
# anywhere outside the two files that are *allowed* to know about hex:
#
#   - Sources/BentoCore/ThemeSpec.swift  (the literals live here)
#   - Sources/Bento/ColorHelpers.swift   (the parser lives here)
#
# Everything else in the app should route colors through `theme.chrome.*`,
# `theme.terminal.*`, or `theme.syntax.*` tokens so a single theme switch
# propagates without grepping a thousand files. See T-2 in the foundation
# brief for context.
#
# Usage: ./scripts/lint/no-hardcoded-chrome.sh
#
# Hook this into your pre-commit flow manually:
#
#   ./scripts/lint/no-hardcoded-chrome.sh || exit 1
#
# There's no CI in this repo yet — keep this script honest by running it
# before pushing chrome-touching changes. Returns 0 on a clean pass, 1
# when a violation is found (with the offending lines printed).

set -euo pipefail

# Files that are explicitly allowed to contain hex literals.
ALLOWED_FILES=(
  "Sources/BentoCore/ThemeSpec.swift"
  "Sources/Bento/ColorHelpers.swift"
)

# Build the grep --exclude args from ALLOWED_FILES.
EXCLUDES=()
for f in "${ALLOWED_FILES[@]}"; do
  # grep --exclude takes a basename pattern; both allowed files are
  # uniquely named in the tree so the basename is unambiguous.
  EXCLUDES+=("--exclude=$(basename "$f")")
done

# We look for the hex-color call sites:
#   - Color(hex: "#…")   — SwiftUI side
#   - NSColor(hex: "#…") — AppKit side
#
# Anything calling those constructors with a literal hex string is a
# violation; the constructor itself (defined in ColorHelpers.swift) is
# fine because it's excluded above.
PATTERN='(NS)?Color\(hex:[[:space:]]*"#'

# Search both source trees; exclude the allowed files. `|| true` keeps
# the script alive when grep finds nothing (exit code 1 is "no match").
HITS="$(grep -rnE "${EXCLUDES[@]}" "$PATTERN" Sources/ || true)"

if [ -n "$HITS" ]; then
  echo "[no-hardcoded-chrome] hex color literals found outside the allowed files:" >&2
  echo "" >&2
  echo "$HITS" >&2
  echo "" >&2
  echo "Allowed files:" >&2
  for f in "${ALLOWED_FILES[@]}"; do
    echo "  - $f" >&2
  done
  echo "" >&2
  echo "Route through a theme token (theme.chrome.*, theme.terminal.*," >&2
  echo "or theme.syntax.*) instead. If you genuinely need a new token," >&2
  echo "add it to BentoCore/ThemeSpec.swift and populate it in all" >&2
  echo "four builtins (bento/carbon/tokyo/paper)." >&2
  exit 1
fi

echo "[no-hardcoded-chrome] clean — no hex literals outside allowed files."
