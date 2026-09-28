#!/usr/bin/env bash
# Builds CodexRemote.app. SwiftPM produces a bare executable; a MenuBarExtra app needs a real
# bundle with LSUIElement so it lives in the menu bar and not the Dock.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
APP="$ROOT/build/CodexRemote.app"

echo "▸ swift build -c $CONFIG"
swift build -c "$CONFIG" --package-path "$ROOT"

BIN="$ROOT/.build/$CONFIG/CodexRemoteApp"
CTL="$ROOT/.build/$CONFIG/codex-remote"
[ -x "$BIN" ] || { echo "CodexRemoteApp binary missing at $BIN" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Codex Remote"
[ -x "$CTL" ] && cp "$CTL" "$APP/Contents/MacOS/codex-remote"

VERSION="$(cat "$ROOT/VERSION" 2>/dev/null || echo 0.1.0)"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Codex Remote</string>
  <key>CFBundleDisplayName</key><string>Codex Remote</string>
  <key>CFBundleIdentifier</key><string>io.codexremote.app</string>
  <key>CFBundleExecutable</key><string>Codex Remote</string>
  <!-- The filename in Resources, not the display name: the rename swept this up too. -->
  <key>CFBundleIconFile</key><string>CodexRemote</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <!-- Menu bar only: no Dock tile, no main window. -->
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
</dict>
</plist>
PLIST

# OpenTofu is *not* put inside the app bundle.
#
# It was, and macOS XProtect flagged the result as malware and moved it to the Bin — which
# is a fair reaction to a 108 MB third-party Go binary embedded in an app bundle and
# re-signed with someone else's certificate. Instead it is installed next to Codex Remote's own
# state, where nothing re-signs it and its authenticity still rests on OpenTofu's published
# checksums. The app finds it there, and downloads it itself if it is missing.
echo "▸ opentofu"
# Must match Paths.codexRemoteHome, or the build installs tofu somewhere the app does not
# look — and recreates the pre-0.4.0 directory under ~/.codex on every build.
TOFU_DIR="${CODEX_REMOTE_HOME:-$HOME/.codex-remote}/tofu/bin"
if [ -x "$TOFU_DIR/tofu" ]; then
  echo "  already installed: $("$TOFU_DIR/tofu" version | head -1)"
elif "$ROOT/Scripts/fetch-opentofu.sh" "$TOFU_DIR" >/dev/null 2>&1; then
  echo "  installed to $TOFU_DIR"
else
  echo "  (not installed; Codex Remote will fetch and verify it on first use)"
fi

echo "▸ icon"
# make-icon.swift builds the .icns itself and prints its path. This used to expect an
# iconset directory and ran iconutil here; when the script changed, the `-d` test quietly
# failed and `|| true` swallowed it, so every build since shipped whatever stale icns was
# left in Resources. Hence no redirection and no `|| true`: a broken icon fails the build.
ICNS="$(swift "$ROOT/Scripts/make-icon.swift" "$ROOT/build" | tail -1)"
if [ ! -f "$ICNS" ]; then
  echo "  make-icon.swift did not produce an .icns (got: $ICNS)" >&2
  exit 1
fi
cp "$ICNS" "$APP/Contents/Resources/CodexRemote.icns"
echo "  $(du -h "$ICNS" | awk '{print $1}')"

# Signing.
#
# Uses whichever real code-signing identity is already in the keychain, because one that is
# already unlocked for Xcode signs silently. An earlier version created its own self-signed
# identity, whose private key was never authorised — so every single build raised a
# "codesign wants to access key" dialog. Never again: no identity is created here.
#
# Override with CODEX_REMOTE_SIGNING_IDENTITY="…", or force ad-hoc with CODEX_REMOTE_SIGN=0.
# No codesign step.
#
# `swift build` already ad-hoc signs the binaries it produces, which is all a locally built
# app needs — Gatekeeper only judges apps that arrive quarantined. Running codesign again
# bought nothing and cost a great deal:
#
#   * signing with an Apple *Development* certificate got the app quarantined as malware,
#     because that certificate reports CSSMERR_TP_CERT_REVOKED;
#   * the timeout guard around codesign SIGKILLed it while macOS was showing its "codesign
#     wants to access key" dialog, which leaves a stuck authorisation request behind that
#     re-appears until it is dismissed.
#
# For a distributable build, sign and notarize deliberately with a Developer ID — not here,
# on every incremental build.
if [ -n "${CODEX_REMOTE_SIGNING_IDENTITY:-}" ]; then
  echo "▸ codesign ($CODEX_REMOTE_SIGNING_IDENTITY)"
  codesign --force --timestamp --options runtime \
    --identifier io.codexremote.app \
    --sign "$CODEX_REMOTE_SIGNING_IDENTITY" "$APP" \
    || echo "  ! signing failed; the ad-hoc signature from swift build still stands" >&2
else
  echo "▸ codesign (ad-hoc, from swift build)"
fi
codesign -dv "$APP" 2>&1 | grep -E "^(Identifier|Authority|Signature)" | sed "s/^/  /" || true

echo "✓ $APP"
