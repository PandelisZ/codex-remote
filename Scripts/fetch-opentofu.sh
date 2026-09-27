#!/usr/bin/env bash
# Downloads the OpenTofu binary for this Mac and puts it where the build asks for it.
#
# Remotu ships tofu inside the app bundle rather than asking the user to install it: the
# whole point of the app is that adding a machine is one click, and "first install
# OpenTofu" is not that. The download is verified against the release's own SHA256SUMS
# and cached, so a rebuild does not re-fetch it.
#
#   ./Scripts/fetch-opentofu.sh <destination-directory> [version]
set -euo pipefail

DEST="${1:-}"
VERSION="${2:-${CODEX_REMOTE_TOFU_VERSION:-1.12.6}}"
[ -n "$DEST" ] || { echo "usage: fetch-opentofu.sh <dest-dir> [version]" >&2; exit 2; }

case "$(uname -m)" in
  arm64|aarch64) ARCH=arm64 ;;
  x86_64)        ARCH=amd64 ;;
  *) echo "unsupported architecture $(uname -m)" >&2; exit 1 ;;
esac
case "$(uname -s)" in
  Darwin) OS=darwin ;;
  Linux)  OS=linux ;;
  *) echo "unsupported OS $(uname -s)" >&2; exit 1 ;;
esac

CACHE="${CODEX_REMOTE_CACHE:-$HOME/.cache/codex-remote}/opentofu/$VERSION"
ARCHIVE="tofu_${VERSION}_${OS}_${ARCH}.tar.gz"
BASE="https://github.com/opentofu/opentofu/releases/download/v${VERSION}"

mkdir -p "$CACHE" "$DEST"

if [ ! -x "$CACHE/tofu" ]; then
  echo "▸ downloading OpenTofu $VERSION ($OS/$ARCH)" >&2
  curl -fsSL --retry 3 -o "$CACHE/$ARCHIVE" "$BASE/$ARCHIVE"
  curl -fsSL --retry 3 -o "$CACHE/SHA256SUMS" "$BASE/tofu_${VERSION}_SHA256SUMS"

  EXPECTED="$(grep -F " $ARCHIVE" "$CACHE/SHA256SUMS" | awk '{print $1}')"
  [ -n "$EXPECTED" ] || { echo "no checksum published for $ARCHIVE" >&2; exit 1; }
  ACTUAL="$(shasum -a 256 "$CACHE/$ARCHIVE" | awk '{print $1}')"
  if [ "$EXPECTED" != "$ACTUAL" ]; then
    rm -f "$CACHE/$ARCHIVE"
    echo "checksum mismatch for $ARCHIVE" >&2
    echo "  expected $EXPECTED" >&2
    echo "  got      $ACTUAL" >&2
    exit 1
  fi

  tar -xzf "$CACHE/$ARCHIVE" -C "$CACHE" tofu
  chmod 755 "$CACHE/tofu"
  rm -f "$CACHE/$ARCHIVE"
fi

cp "$CACHE/tofu" "$DEST/tofu"
chmod 755 "$DEST/tofu"
"$DEST/tofu" version | head -1 >&2
echo "$DEST/tofu"
