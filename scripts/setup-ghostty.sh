#!/usr/bin/env bash
# Clone Ghostty and build the full libghostty embedding (GhosttyKit:
# app + surface + Metal renderer + PTY) that Riven's terminal panes use.
# Requires zig 0.15.x on PATH.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
EXT="$REPO_ROOT/External"
SRC="$EXT/ghostty"
KIT_INSTALL="$EXT/ghostty-kit-install"
HOOKS="scripts/git-hooks"

# The Ghostty commit Riven's libghostty binding is built + verified
# against. Pinned for reproducibility: the embedding C API
# (ghostty.h) is internal-but-stable, so we pin a known-good revision
# and rebase deliberately rather than tracking main. Override with
# GHOSTTY_REF=<sha|tag> to build a different revision.
GHOSTTY_REF="${GHOSTTY_REF:-46d54ed673a004df09078bee56e809421a82370e}"

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

echo "Checking out pinned Ghostty ref: $GHOSTTY_REF"
git -C "$SRC" fetch --quiet origin "$GHOSTTY_REF" 2>/dev/null || git -C "$SRC" fetch --quiet origin
git -C "$SRC" checkout --quiet "$GHOSTTY_REF"

# Build the full embedding xcframework (app + surface + Metal renderer).
# `zig build -Demit-xcframework` builds the xcframework AND then tries
# to assemble the macOS .app via xcodebuild, which fails outside an
# Xcode project context. The xcframework is produced BEFORE that step,
# so we tolerate the non-zero exit and verify the artifact instead of
# trusting the exit code.
echo "Building GhosttyKit (full libghostty embedding) -> $KIT_INSTALL"
echo "  (the trailing app-bundle step is expected to fail; we check the artifact.)"
cd "$SRC"
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
