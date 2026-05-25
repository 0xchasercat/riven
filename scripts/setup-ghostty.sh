#!/usr/bin/env bash
# Clone Ghostty and build libghostty-vt for Riven.
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
# normal "I want to build Riven" flow rather than as a separate step
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

# ─── Full libghostty embedding (GhosttyKit) — migration spike ──────
# Set RIVEN_BUILD_GHOSTTY_KIT=1 to ALSO build the full embedding
# xcframework (app + surface + Metal renderer), used by the
# libghostty-surface migration. `zig build -Demit-xcframework`
# builds the xcframework AND then tries to assemble the macOS .app
# via xcodebuild, which fails outside an Xcode project context. The
# xcframework is produced BEFORE that step, so we tolerate the
# non-zero exit and verify the artifact instead of trusting the code.
if [ "${RIVEN_BUILD_GHOSTTY_KIT:-0}" = "1" ]; then
  KIT_INSTALL="$EXT/ghostty-kit-install"
  echo "Building GhosttyKit (full embedding) — trailing app-bundle step is expected to fail; we check the artifact."
  zig build -Doptimize=ReleaseFast -Demit-xcframework -Dxcframework-target=native || true
  KIT_SRC="$SRC/macos/GhosttyKit.xcframework"
  if [ ! -d "$KIT_SRC" ]; then
    echo "✗ GhosttyKit.xcframework was not produced at $KIT_SRC" >&2
    exit 1
  fi
  mkdir -p "$KIT_INSTALL/lib"
  rm -rf "$KIT_INSTALL/lib/GhosttyKit.xcframework"
  cp -R "$KIT_SRC" "$KIT_INSTALL/lib/"
  echo "Done. GhosttyKit at: $KIT_INSTALL/lib/GhosttyKit.xcframework"
fi
