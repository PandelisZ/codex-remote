#!/usr/bin/env bash
# Renders site/img/og.png — the card Slack, LinkedIn, iMessage and X show when the site is
# shared.
#
#   Scripts/make-og.sh
#
# Rendered through headless Chrome rather than drawn, so the card uses the same Google Fonts
# as the site itself: Archivo, Source Serif 4 and JetBrains Mono are not installed locally,
# and reproducing that typography by hand would drift from the page it advertises. Which
# also means this needs the network, so it is a script you run when the card changes, not
# part of the build.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$ROOT/Scripts/og-template.html"
OUT="$ROOT/site/img/og.png"

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ ! -x "$CHROME" ]; then
  echo "Google Chrome is not installed at $CHROME." >&2
  echo "Any Chromium works: set CHROME=… and run this again." >&2
  exit 1
fi
CHROME="${CHROME_OVERRIDE:-$CHROME}"

# 1200x630 is the size every one of these services wants; anything else gets cropped by
# whichever of them cares least.
WIDTH=1200
HEIGHT=630

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --headless=new explicitly: Chrome 132 removed the old headless binary, and on 154 a bare
# --headless hangs indefinitely instead of failing. The rest keeps a throwaway profile from
# reaching the network or the keychain, either of which can stall a run for minutes.
#
# Backgrounded and polled rather than waited on, because Chrome writes the screenshot and
# then frequently does not exit -- it sits there until something kills it. Waiting on the
# process means the script hangs long after its work is done, so instead we wait for the
# file, let it settle, and shut Chrome down ourselves. macOS ships no coreutils `timeout`,
# hence the hand-rolled loop.
"$CHROME" \
  --headless=new \
  --disable-gpu \
  --hide-scrollbars \
  --force-device-scale-factor=2 \
  --window-size="$WIDTH,$HEIGHT" \
  --screenshot="$WORK/og@2x.png" \
  --user-data-dir="$WORK/profile" \
  --no-first-run \
  --no-default-browser-check \
  --disable-extensions \
  --disable-background-networking \
  --disable-component-update \
  --disable-sync \
  --password-store=basic \
  --use-mock-keychain \
  --virtual-time-budget=8000 \
  "file://$TEMPLATE" >/dev/null 2>&1 &
CHROME_PID=$!

settled=0
for _ in $(seq 1 120); do
  if [ -s "$WORK/og@2x.png" ]; then
    # Two identical sizes half a second apart means the write has finished.
    before="$(stat -f%z "$WORK/og@2x.png")"
    sleep 0.5
    if [ "$before" = "$(stat -f%z "$WORK/og@2x.png")" ]; then settled=1; break; fi
  fi
  sleep 0.5
done

kill "$CHROME_PID" 2>/dev/null || true
wait "$CHROME_PID" 2>/dev/null || true

if [ "$settled" -ne 1 ]; then
  echo "Chrome produced no screenshot within 60s." >&2
  exit 1
fi

if [ ! -f "$WORK/og@2x.png" ]; then
  echo "Chrome produced no screenshot." >&2
  exit 1
fi

# Rendered at 2x and scaled down: text rasterised straight at 1200x630 is noticeably
# coarser, and these cards are often shown on a retina screen at close to full size.
mkdir -p "$(dirname "$OUT")"
/usr/bin/sips --resampleHeightWidth "$HEIGHT" "$WIDTH" "$WORK/og@2x.png" --out "$OUT" >/dev/null

# A card nobody can load is worse than none, and several services simply skip one over 1MB.
BYTES="$(stat -f%z "$OUT")"
echo "site/img/og.png  ${WIDTH}x${HEIGHT}  $((BYTES / 1024)) KB"
if [ "$BYTES" -gt 1000000 ]; then
  echo "  warning: over 1MB; some services will not fetch it" >&2
fi
