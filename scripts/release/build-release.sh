#!/usr/bin/env bash
#
# scripts/release/build-release.sh
#
# Build a release .app + .dmg for Riven. Pre-1.0 local-only flow:
# you tag, you run this script, it spits out a signed (ad-hoc by
# default, Developer-ID when env vars are set) DMG into ./dist/
# ready to upload to a GitHub Release.
#
# Usage:
#   VERSION=0.1.0 scripts/release/build-release.sh
#
# Required:
#   VERSION                 — semver tag for the build (e.g. 0.1.0).
#                             If not set, derived from the latest git
#                             tag matching v*.
#
# Optional — set ALL THREE to enable Developer-ID signing + notarisation
# once you've enrolled in the Apple Developer Program:
#   APPLE_DEVELOPER_ID      — full identity string, e.g.
#                             "Developer ID Application: Marc Xavier (TEAMID)"
#   APPLE_NOTARY_KEYCHAIN_PROFILE
#                           — keychain profile name created via
#                             `xcrun notarytool store-credentials`.
#                             We never read Apple ID / app-specific
#                             password from env; the keychain profile
#                             is the right abstraction.
#   APPLE_TEAM_ID           — 10-char team identifier (TEAMID above,
#                             also used in --options runtime hardening).
#
# Without those three the script ad-hoc signs the bundle. Users
# launching an ad-hoc bundle from Finder get the "developer cannot
# be verified" warning and have to right-click → Open the first
# time. Fine for a friends-list alpha; fix before any wider push.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

# ─── Inputs ────────────────────────────────────────────────────────
VERSION="${VERSION:-}"
if [ -z "$VERSION" ]; then
  # Latest tag of the form vMAJOR.MINOR.PATCH, with the leading 'v'
  # stripped. Falls back to 0.0.0 for never-tagged repos.
  VERSION=$(git tag --list 'v*' --sort=-v:refname | head -n 1 | sed 's/^v//')
  VERSION="${VERSION:-0.0.0}"
  echo "→ No VERSION env var; using $VERSION (from latest git tag)"
fi
BUILD_NUMBER=$(date '+%Y%m%d%H%M')

DIST_DIR="$REPO_ROOT/dist"
APP_NAME="Riven"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DMG_NAME="$APP_NAME-$VERSION.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

echo "→ Building $APP_NAME v$VERSION (build $BUILD_NUMBER)"

# ─── Icon ──────────────────────────────────────────────────────────
# Regenerate AppIcon.icns from the source PNG so a fresh
# `assets/AppIcon-source.png` is always picked up. Cheap (~ms);
# skipped silently if the .icns already exists and the source
# hasn't changed since (mtime-based).
if [ -f "assets/AppIcon-source.png" ]; then
  if [ ! -f "assets/AppIcon.icns" ] || \
     [ "assets/AppIcon-source.png" -nt "assets/AppIcon.icns" ]; then
    "$REPO_ROOT/scripts/release/build-icon.sh"
  fi
fi

# ─── Tool checks ───────────────────────────────────────────────────
require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "✗ Missing required tool: $1" >&2
    echo "  Install it and re-run." >&2
    exit 1
  }
}

require swift
require codesign
require plutil
require hdiutil

# create-dmg is nicer than plain hdiutil but optional. We fall back
# to hdiutil if it's not installed. (`brew install create-dmg`.)
HAS_CREATE_DMG=0
if command -v create-dmg >/dev/null 2>&1; then
  HAS_CREATE_DMG=1
fi

# ─── Ghostty dependency check ──────────────────────────────────────
# The full libghostty embedding (GhosttyKit) has to be built before
# swift can link. The Package binaryTarget points at the xcframework
# produced by scripts/setup-ghostty.sh.
XCFRAMEWORK="External/ghostty-kit-install/lib/GhosttyKit.xcframework"
if [ ! -d "$XCFRAMEWORK" ]; then
  echo "✗ $XCFRAMEWORK is missing." >&2
  echo "  Run: scripts/setup-ghostty.sh" >&2
  echo "  (Requires zig 0.15.x on \$PATH.)" >&2
  exit 1
fi

# ─── Clean + build ─────────────────────────────────────────────────
echo "→ swift build -c release"
swift build -c release 2>&1 | grep -vE '^(Building|Computing|Preparing|Resolving|Fetching)' || true

# SwiftPM puts release output here. Architecture-suffixed on
# universal builds — Apple-silicon-only for now since GhosttyKit
# is built per-arch.
ARCH=$(uname -m | tr '[:upper:]' '[:lower:]')
BUILD_DIR="$REPO_ROOT/.build/$ARCH-apple-macosx/release"

if [ ! -x "$BUILD_DIR/Riven" ]; then
  echo "✗ Missing release binary: $BUILD_DIR/Riven" >&2
  exit 1
fi

# ─── Assemble .app bundle ──────────────────────────────────────────
echo "→ Assembling $APP_BUNDLE"
rm -rf "$DIST_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$BUILD_DIR/Riven"      "$APP_BUNDLE/Contents/MacOS/Riven"

# Drop the .icns into Contents/Resources/. Info.plist already
# references `AppIcon` (without extension) via CFBundleIconFile, so
# Finder + Dock + Cmd-Tab pick it up automatically. Skipped quietly
# if the user hasn't generated one yet — the bundle stays valid,
# just falls back to the generic .app icon.
if [ -f "assets/AppIcon.icns" ]; then
  cp "assets/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

# SwiftPM emits the resource bundle as Riven_RivenCore.bundle —
# carries the vendored rg + shell-integration tree.
# ShellIntegrationInstaller + RipgrepFileSearch resolve it via
# `Bundle.module`, which Swift looks up via the executable's
# `Bundle.main.bundleURL`. Drop it next to the executable so the
# lookup works.
RESOURCE_BUNDLE="$BUILD_DIR/Riven_RivenCore.bundle"
if [ ! -d "$RESOURCE_BUNDLE" ]; then
  echo "✗ Missing resource bundle: $RESOURCE_BUNDLE" >&2
  exit 1
fi
cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"

# Substitute placeholders in the Info.plist template.
INFO_TEMPLATE="$REPO_ROOT/scripts/release/Info.plist.template"
sed -e "s/@VERSION@/$VERSION/g" \
    -e "s/@BUILD@/$BUILD_NUMBER/g" \
    "$INFO_TEMPLATE" > "$APP_BUNDLE/Contents/Info.plist"
plutil -lint "$APP_BUNDLE/Contents/Info.plist" >/dev/null

# Old-school PkgInfo file — Mac OS legacy, still expected by some
# Finder code paths.
printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# ─── Code signing ──────────────────────────────────────────────────
# Sign inside-out: the nested `rg` Mach-O first, then the Riven
# executable, then the .app bundle itself. `--force` is safe
# because we just assembled the bundle; nothing's been signed yet.
sign_with_identity() {
  local identity="$1"
  local hardened_flag=""
  local entitlements_flag=""
  # Secure timestamp policy. Notarisation REQUIRES every signature
  # to carry a secure timestamp from Apple's TSA (timestamp.apple.com)
  # — `--timestamp` requests it. Ad-hoc signatures can't bind to the
  # TSA (no cert), so ad-hoc keeps `--timestamp=none`.
  local timestamp_flag="--timestamp=none"
  if [ "$identity" != "-" ]; then
    # Hardened runtime is required for notarisation. Ad-hoc
    # signing doesn't accept it.
    hardened_flag="--options=runtime"
    # Entitlement exceptions only take effect under a real
    # Developer ID + hardened runtime (ad-hoc signing embeds them
    # but the OS won't honour the Hardened-Runtime exceptions).
    # Applied to the two executables, NOT the resource bundle or
    # the outer .app wrapper.
    entitlements_flag="--entitlements $REPO_ROOT/scripts/release/Riven.entitlements"
    timestamp_flag="--timestamp"
  fi

  # Sign INSIDE-OUT: deepest nested code first, outer .app last.
  #
  # The vendored ripgrep binary lives inside the SwiftPM resource
  # bundle as a bare Mach-O. Notarisation rejected the first
  # attempt because `rg` was unsigned / no hardened runtime / no
  # timestamp — the outer .app seal covers its bytes but doesn't
  # give it its OWN signature, and the notary checks every Mach-O
  # individually. Sign it explicitly: Developer ID + hardened
  # runtime + secure timestamp. No entitlements — it's a plain CLI
  # tool with no special runtime needs.
  local rg_path="$APP_BUNDLE/Contents/Resources/Riven_RivenCore.bundle/rg"
  if [ -f "$rg_path" ]; then
    codesign --force --sign "$identity" $hardened_flag $timestamp_flag "$rg_path"
  fi

  # The resource bundle WRAPPER itself isn't signed (it has no
  # Info.plist, so codesign rejects it as an unrecognized bundle);
  # the outer .app seal covers it. Only the executable gets the
  # Hardened-Runtime entitlement exceptions: Riven hosts the UI,
  # statically links libghostty, and fork/exec's the user's shells
  # in-process (it's the responsible parent for everything the user
  # runs now that there's no separate broker).
  codesign --force --sign "$identity" $hardened_flag $entitlements_flag $timestamp_flag \
    "$APP_BUNDLE/Contents/MacOS/Riven"
  codesign --force --sign "$identity" $hardened_flag $timestamp_flag \
    "$APP_BUNDLE"
}

if [ -n "${APPLE_DEVELOPER_ID:-}" ]; then
  echo "→ Signing with Developer ID: $APPLE_DEVELOPER_ID"
  sign_with_identity "$APPLE_DEVELOPER_ID"
else
  echo "→ Ad-hoc signing (no APPLE_DEVELOPER_ID set)"
  echo "  ⚠ Users will see Gatekeeper warnings on first launch."
  sign_with_identity "-"
fi

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" 2>&1 | tail -3

# ─── Build the DMG ─────────────────────────────────────────────────
echo "→ Building $DMG_PATH"
if [ "$HAS_CREATE_DMG" = "1" ]; then
  # `create-dmg` does the legwork: background image, Applications
  # alias, icon positions. We skip the background image for v0.x
  # — a plain functional DMG is fine for an alpha.
  create-dmg \
    --volname "$APP_NAME $VERSION" \
    --window-pos 200 120 \
    --window-size 600 380 \
    --icon-size 96 \
    --icon "$APP_NAME.app" 175 180 \
    --hide-extension "$APP_NAME.app" \
    --app-drop-link 425 180 \
    "$DMG_PATH" \
    "$APP_BUNDLE" \
    >/dev/null
else
  # hdiutil fallback. Less polished UX (no Applications shortcut)
  # but ships a working DMG.
  echo "  ⚠ create-dmg not installed — falling back to hdiutil."
  echo "  (\`brew install create-dmg\` for a nicer artifact.)"
  hdiutil create -volname "$APP_NAME $VERSION" \
    -srcfolder "$APP_BUNDLE" \
    -ov -format UDZO \
    "$DMG_PATH" \
    >/dev/null
fi

# Sign the DMG itself when we have a real cert (notarisation
# requires a signed DMG with a secure timestamp).
if [ -n "${APPLE_DEVELOPER_ID:-}" ]; then
  codesign --force --sign "$APPLE_DEVELOPER_ID" --timestamp "$DMG_PATH"
fi

# ─── Notarisation ──────────────────────────────────────────────────
if [ -n "${APPLE_DEVELOPER_ID:-}" ] && \
   [ -n "${APPLE_NOTARY_KEYCHAIN_PROFILE:-}" ] && \
   [ -n "${APPLE_TEAM_ID:-}" ]; then
  echo "→ Submitting $DMG_NAME to Apple Notary"
  xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$APPLE_NOTARY_KEYCHAIN_PROFILE" \
    --team-id "$APPLE_TEAM_ID" \
    --wait

  echo "→ Stapling notarisation ticket to $DMG_NAME"
  xcrun stapler staple "$DMG_PATH"

  # Verify Gatekeeper accepts the result.
  spctl --assess --type open --context context:primary-signature \
    --verbose "$DMG_PATH" || {
    echo "✗ Gatekeeper assessment failed for $DMG_PATH" >&2
    echo "  The DMG was uploaded + stapled but Gatekeeper isn't happy." >&2
    exit 1
  }
else
  echo "→ Skipping notarisation (set APPLE_DEVELOPER_ID + "
  echo "  APPLE_NOTARY_KEYCHAIN_PROFILE + APPLE_TEAM_ID to enable)"
fi

# ─── Done ──────────────────────────────────────────────────────────
echo
echo "✓ Built $DMG_NAME"
ls -lh "$DMG_PATH"
echo
echo "Next steps:"
echo "  1. Test-install: open $DMG_PATH, drag Riven.app to /Applications,"
echo "     launch from /Applications/Riven.app."
echo "  2. Tag the release: git tag -a v$VERSION -m 'Riven v$VERSION'"
echo "  3. Push the tag:   git push origin v$VERSION"
echo "  4. Upload to GitHub Releases:"
echo "       gh release create v$VERSION $DMG_PATH \\"
echo "         --title 'Riven v$VERSION' \\"
echo "         --notes-file CHANGELOG.md"
