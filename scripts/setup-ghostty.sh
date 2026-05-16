#!/usr/bin/env bash
# Clone Ghostty and build libghostty-vt for Bento.
# Requires zig 0.15.x on PATH.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXT="$REPO_ROOT/External"
SRC="$EXT/ghostty"
INSTALL="$EXT/ghostty-vt-install"

mkdir -p "$EXT"
if [ ! -d "$SRC/.git" ]; then
  echo "Cloning Ghostty..."
  git clone --filter=blob:none https://github.com/ghostty-org/ghostty.git "$SRC"
fi

echo "Building libghostty-vt -> $INSTALL"
cd "$SRC"
zig build -Doptimize=ReleaseFast -Demit-lib-vt=true -p "$INSTALL"

echo "Done. xcframework at: $INSTALL/lib/ghostty-vt.xcframework"
