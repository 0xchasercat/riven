#!/usr/bin/env bash
# Clone Ghostty and build libghostty-vt for Bento.
# Requires zig 0.15.x on PATH.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXT="$REPO_ROOT/External"
SRC="$EXT/ghostty"
INSTALL="$EXT/ghostty-vt-install"
HOOKS="scripts/git-hooks"

# Wire repo-local git hooks (currently: pre-commit guard against
# re-tracking External/). Idempotent — setting hooksPath twice is fine.
# Lives here so a fresh clone gets the hook installed as part of the
# normal "I want to build Bento" flow rather than as a separate step
# nobody remembers to run.
if [ -d "$REPO_ROOT/$HOOKS" ]; then
  echo "Installing repo-local git hooks ($HOOKS)..."
  git -C "$REPO_ROOT" config core.hooksPath "$HOOKS"
fi

mkdir -p "$EXT"
if [ ! -d "$SRC/.git" ]; then
  echo "Cloning Ghostty..."
  git clone --filter=blob:none https://github.com/ghostty-org/ghostty.git "$SRC"
fi

echo "Building libghostty-vt -> $INSTALL"
cd "$SRC"
zig build -Doptimize=ReleaseFast -Demit-lib-vt=true -p "$INSTALL"

echo "Done. xcframework at: $INSTALL/lib/ghostty-vt.xcframework"
