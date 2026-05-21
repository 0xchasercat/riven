#!/usr/bin/env bash
#
# scripts/release/build-icon.sh
#
# Turn `assets/AppIcon-source.png` into a multi-resolution
# `AppIcon.icns` ready to drop into the .app bundle.
#
# macOS apps want their icon in .icns format — a container that
# carries every size Finder, Dock, Spotlight, Cmd-Tab, and Mission
# Control reach for, including @2x retina variants. Apple's
# canonical set is 16, 32, 128, 256, 512 (with @2x for each, i.e.
# 32, 64, 256, 512, 1024). `iconutil -c icns <dir>.iconset` packs
# them.
#
# Inputs:
#   assets/AppIcon-source.png    — square master, ideally 1024×1024.
#                                  We `sips`-resize down for each
#                                  target dimension. Resizing UP
#                                  isn't supported (looks awful);
#                                  the source needs to be at least
#                                  1024×1024.
#
# Outputs:
#   assets/AppIcon.icns          — the bundle-ready .icns.
#
# The release build script (`build-release.sh`) calls this before
# assembling the .app bundle so the user only ever has to drop a
# new source PNG; the .icns regenerates from it.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

SOURCE="assets/AppIcon-source.png"
OUT="assets/AppIcon.icns"

if [ ! -f "$SOURCE" ]; then
  echo "✗ Missing $SOURCE" >&2
  echo "  Drop a square PNG (1024×1024 or larger) at that path." >&2
  exit 1
fi

command -v sips >/dev/null      || { echo "✗ sips missing (macOS-only)" >&2; exit 1; }
command -v iconutil >/dev/null  || { echo "✗ iconutil missing (macOS-only)" >&2; exit 1; }

# Verify source is at least 1024×1024; sips upscaling on Apple-
# silicon Macs produces noticeably blurry tiles that read as
# unprofessional in Finder.
SRC_W=$(sips -g pixelWidth  "$SOURCE" | awk '/pixelWidth/  {print $2}')
SRC_H=$(sips -g pixelHeight "$SOURCE" | awk '/pixelHeight/ {print $2}')
if [ "$SRC_W" -lt 1024 ] || [ "$SRC_H" -lt 1024 ]; then
  echo "✗ Source PNG must be at least 1024×1024 (got ${SRC_W}×${SRC_H})." >&2
  exit 1
fi

ICONSET=$(mktemp -d -t riven-icon)
trap 'rm -rf "$ICONSET"' EXIT INT TERM
mv "$ICONSET" "${ICONSET}.iconset"
ICONSET="${ICONSET}.iconset"
mkdir -p "$ICONSET"

# Apple's canonical set. Each row is "<size> <filename>".
# Sizes match what iconutil expects in the .iconset directory.
sizes=(
  "16    icon_16x16.png"
  "32    icon_16x16@2x.png"
  "32    icon_32x32.png"
  "64    icon_32x32@2x.png"
  "128   icon_128x128.png"
  "256   icon_128x128@2x.png"
  "256   icon_256x256.png"
  "512   icon_256x256@2x.png"
  "512   icon_512x512.png"
  "1024  icon_512x512@2x.png"
)

echo "→ Rendering iconset at ${SRC_W}×${SRC_H} → 10 sizes"
for line in "${sizes[@]}"; do
  size=$(echo "$line" | awk '{print $1}')
  name=$(echo "$line" | awk '{print $2}')
  sips --setProperty format png \
       --resampleHeightWidth "$size" "$size" \
       "$SOURCE" \
       --out "$ICONSET/$name" \
       >/dev/null
done

echo "→ Packing $OUT"
iconutil -c icns "$ICONSET" -o "$OUT"

ls -l "$OUT"
echo "✓ AppIcon.icns built"
