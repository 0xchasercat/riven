#!/usr/bin/env bash
#
# install-rg.sh — fetch ripgrep release tarballs for darwin/aarch64 and
# darwin/x86_64, verify their SHA-256 sums, and lipo-fuse them into a single
# Universal2 binary at Sources/BentoCore/Resources/rg.
#
# This script is the canonical way to refresh the vendored binary. CI / dev
# machines without an `rg` already on PATH should run this once after a
# fresh clone. The resulting binary is committed to the repo so end-users
# don't need network access at build time.
#
# Usage:
#   scripts/install-rg.sh                      # uses pinned default version
#   RG_VERSION=15.1.0 scripts/install-rg.sh    # override
#
# Requirements: curl, tar, shasum, lipo (Xcode CLT). All present on macOS by
# default.

set -euo pipefail

RG_VERSION="${RG_VERSION:-15.1.0}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="$REPO_ROOT/Sources/BentoCore/Resources"
DEST_BIN="$DEST_DIR/rg"

mkdir -p "$DEST_DIR"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

fetch() {
    local arch="$1"      # aarch64 | x86_64
    local tarball="ripgrep-${RG_VERSION}-${arch}-apple-darwin.tar.gz"
    local url="https://github.com/BurntSushi/ripgrep/releases/download/${RG_VERSION}/${tarball}"
    local sha_url="${url}.sha256"

    echo "[install-rg] downloading $tarball"
    curl -fsSL -o "$TMP_DIR/$tarball" "$url"
    curl -fsSL -o "$TMP_DIR/$tarball.sha256" "$sha_url"

    # Verify integrity. The .sha256 file from the release is in the
    # `<hex>  <filename>` shasum format.
    ( cd "$TMP_DIR" && shasum -a 256 -c "$tarball.sha256" )

    tar -xzf "$TMP_DIR/$tarball" -C "$TMP_DIR"
    mv "$TMP_DIR/ripgrep-${RG_VERSION}-${arch}-apple-darwin/rg" "$TMP_DIR/rg-${arch}"
}

fetch aarch64
fetch x86_64

echo "[install-rg] fusing into Universal2"
lipo -create "$TMP_DIR/rg-aarch64" "$TMP_DIR/rg-x86_64" -output "$DEST_BIN"
chmod +x "$DEST_BIN"

echo "[install-rg] done"
lipo -info "$DEST_BIN"
"$DEST_BIN" --version | head -1
