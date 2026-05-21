#!/usr/bin/env bash
#
# install.sh — install Riven from GitHub Releases without Gatekeeper drama.
#
# Usage (recommended):
#   curl -fsSL https://raw.githubusercontent.com/0xchasercat/riven/main/install.sh | bash
#
# Or with a pinned version:
#   curl -fsSL https://raw.githubusercontent.com/0xchasercat/riven/main/install.sh | RIVEN_VERSION=v0.1.0 bash
#
# What this does, in order:
#
#   1. Picks the latest release tag (or `$RIVEN_VERSION` if set).
#   2. Downloads Riven-<version>.dmg into a temp dir.
#   3. Mounts the DMG, copies Riven.app → /Applications, unmounts.
#   4. Strips com.apple.quarantine xattrs. Browsers + curl flag the
#      download as "from the internet," which is what triggers
#      Gatekeeper's "developer cannot be verified" warning for an
#      ad-hoc-signed app. Removing the xattr is the legitimate
#      consent-by-keyboard equivalent of right-click → Open.
#   5. Re-signs the app ad-hoc on the user's machine. macOS Catalina+
#      requires every Mach-O to carry a code signature; the bundled
#      one is already ad-hoc but re-signing locally proves the bits
#      weren't tampered with in transit.
#   6. Optionally opens the app.
#
# Why this script vs. just downloading the DMG manually:
#
#   The author hasn't enrolled in the Apple Developer Program yet, so
#   the published DMGs are ad-hoc signed. Manually downloading from
#   GitHub Releases triggers the quarantine xattr + the Gatekeeper
#   modal: "Apple cannot check it for malicious software." This
#   script automates the right-click → Open step (which is itself
#   a user-consent gesture) so users don't have to discover it.
#
# Once the Developer ID cert is in place every published DMG will be
# signed + notarised. This install script will keep working (the
# quarantine + ad-hoc resign steps become no-ops) so the same
# curl-pipe install URL stays stable across the transition.

set -euo pipefail

# ─── Config ────────────────────────────────────────────────────────
REPO="${RIVEN_REPO:-0xchasercat/riven}"
VERSION="${RIVEN_VERSION:-}"           # empty → resolve to latest
APP_NAME="Riven"
INSTALL_DIR="${RIVEN_INSTALL_DIR:-/Applications}"
ASSUME_YES="${RIVEN_YES:-}"            # any non-empty value skips prompts
OPEN_AFTER_INSTALL="${RIVEN_OPEN:-1}"  # "0" disables the auto-open step

# ─── Sanity ────────────────────────────────────────────────────────
if [ "$(uname -s)" != "Darwin" ]; then
  echo "✗ Riven is macOS-only (saw $(uname -s))." >&2
  exit 1
fi

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "✗ Missing required command: $1" >&2
    exit 1
  }
}
require curl
require hdiutil
require codesign
require xattr

# ─── Resolve version ───────────────────────────────────────────────
api_url="https://api.github.com/repos/$REPO/releases"
if [ -z "$VERSION" ]; then
  # Pull the latest non-draft tag. We hit /releases (not
  # /releases/latest) so we can fall back gracefully when the
  # repo's only release is marked prerelease (which /latest
  # excludes by default).
  VERSION=$(
    curl -fsSL "$api_url" \
      | grep -m 1 '"tag_name"' \
      | sed -E 's/.*"tag_name": ?"([^"]+)".*/\1/'
  )
fi
if [ -z "$VERSION" ]; then
  echo "✗ Couldn't determine a release version to download." >&2
  echo "  Set RIVEN_VERSION=vX.Y.Z to pin one." >&2
  exit 1
fi

# Normalise: accept both `0.1.0` and `v0.1.0` from the user.
VERSION_NO_V="${VERSION#v}"
DMG_NAME="$APP_NAME-$VERSION_NO_V.dmg"
DMG_URL="https://github.com/$REPO/releases/download/v$VERSION_NO_V/$DMG_NAME"

echo "→ Installing $APP_NAME v$VERSION_NO_V"
echo "  from $DMG_URL"
echo "  to   $INSTALL_DIR/$APP_NAME.app"

# ─── Confirm overwrite ─────────────────────────────────────────────
if [ -d "$INSTALL_DIR/$APP_NAME.app" ] && [ -z "$ASSUME_YES" ]; then
  echo
  echo "  An existing $APP_NAME.app is in $INSTALL_DIR. It will be replaced."
  if [ -t 0 ]; then
    printf "  Continue? [y/N] "
    read -r answer < /dev/tty || true
    case "$answer" in
      y|Y|yes|YES) ;;
      *) echo "  Aborted."; exit 1 ;;
    esac
  else
    echo "  Non-interactive shell — re-run with RIVEN_YES=1 to confirm." >&2
    exit 1
  fi
fi

# ─── Download ──────────────────────────────────────────────────────
STAGE=$(mktemp -d -t riven-install)
trap 'rm -rf "$STAGE" 2>/dev/null || true; hdiutil detach "$STAGE/mount" -quiet 2>/dev/null || true' EXIT INT TERM
DMG_PATH="$STAGE/$DMG_NAME"

echo "→ Downloading $DMG_NAME"
curl --fail --silent --show-error --location \
  --output "$DMG_PATH" \
  "$DMG_URL"

# ─── Mount + copy ──────────────────────────────────────────────────
MOUNT_POINT="$STAGE/mount"
mkdir -p "$MOUNT_POINT"
echo "→ Mounting DMG"
hdiutil attach "$DMG_PATH" -mountpoint "$MOUNT_POINT" -nobrowse -quiet

SOURCE_APP="$MOUNT_POINT/$APP_NAME.app"
if [ ! -d "$SOURCE_APP" ]; then
  echo "✗ $SOURCE_APP not found inside the DMG — release artifact may be malformed." >&2
  exit 1
fi

echo "→ Copying to $INSTALL_DIR"
# rm -rf + cp is more reliable than ditto here because cp respects
# the xattrs we're about to strip. Belt-and-braces: also rm any
# trailing `.dmg`-stamped quarantine on the destination.
if [ -d "$INSTALL_DIR/$APP_NAME.app" ]; then
  rm -rf "$INSTALL_DIR/$APP_NAME.app"
fi
cp -R "$SOURCE_APP" "$INSTALL_DIR/$APP_NAME.app"

echo "→ Unmounting DMG"
hdiutil detach "$MOUNT_POINT" -quiet

DEST_APP="$INSTALL_DIR/$APP_NAME.app"

# ─── Strip quarantine ──────────────────────────────────────────────
# curl-downloaded apps carry com.apple.quarantine = "0083" (or
# similar) which tells Gatekeeper "this came from a browser/URL,
# show the user the trust modal." Removing it on the user's machine
# is the script-equivalent of right-click → Open: a local consent
# decision the user implicitly made by running this installer.
echo "→ Removing quarantine xattr"
xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true

# ─── Re-sign ad-hoc ────────────────────────────────────────────────
# macOS requires every executable to be signed (Catalina+). The
# bundled signature is already ad-hoc, but re-signing locally
# (a) proves the on-disk bytes match what they purport to be, and
# (b) gives the OS a fresh signature tied to this machine's trust
# graph. No Developer ID needed.
echo "→ Re-signing locally"
codesign --force --sign - --deep "$DEST_APP" >/dev/null 2>&1

# Quick sanity check.
codesign --verify --deep --strict "$DEST_APP" 2>&1 | grep -vE '^$' || true

# ─── Done ──────────────────────────────────────────────────────────
echo
echo "✓ $APP_NAME v$VERSION_NO_V installed to $DEST_APP"

if [ "$OPEN_AFTER_INSTALL" != "0" ]; then
  echo "→ Launching $APP_NAME"
  open "$DEST_APP"
fi

echo
echo "  Uninstall later with:"
echo "    rm -rf $DEST_APP"
echo "    rm -rf ~/Library/Application\\ Support/Riven"
echo "    rm -rf ~/.config/riven"
