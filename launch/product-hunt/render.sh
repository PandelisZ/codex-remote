#!/usr/bin/env bash
# Render the five Product Hunt gallery plates from real Codex Remote captures.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HERE="$ROOT/launch/product-hunt"
CHROME="${CHROME_OVERRIDE:-/Applications/Google Chrome.app/Contents/MacOS/Google Chrome}"
[ -x "$CHROME" ] || { echo "Chrome not found: $CHROME" >&2; exit 1; }

mkdir -p "$HERE/gallery"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

for number in 1 2 3 4 5; do
  raw="$work/$number@2x.png"
  profile="$work/chrome-$number"
  "$CHROME" \
    --headless=new --disable-gpu --hide-scrollbars \
    --force-device-scale-factor=2 --window-size=1270,760 \
    --screenshot="$raw" --user-data-dir="$profile" \
    --no-first-run --no-default-browser-check --disable-extensions \
    --disable-background-networking --disable-component-update --disable-sync \
    --password-store=basic --use-mock-keychain --virtual-time-budget=7000 \
    "file://$HERE/cards.html?card=$number" >/dev/null 2>&1 &
  chrome_pid=$!

  settled=0
  for _ in $(seq 1 60); do
    if [ -s "$raw" ]; then
      before="$(stat -f%z "$raw")"
      sleep 0.25
      if [ "$before" = "$(stat -f%z "$raw")" ]; then settled=1; break; fi
    fi
    sleep 0.25
  done
  kill "$chrome_pid" 2>/dev/null || true
  wait "$chrome_pid" 2>/dev/null || true
  [ "$settled" -eq 1 ] || { echo "Card $number did not render" >&2; exit 1; }

  out="$HERE/gallery/$(printf '%02d' "$number").png"
  magick "$raw" -resize '1270x760!' -strip "$out"
  printf '%s  %s bytes\n' "$out" "$(stat -f%z "$out")"
done

magick "$ROOT/site/img/app-icon.png" -resize '240x240!' -strip "$HERE/thumbnail.png"
printf '%s  %s bytes\n' "$HERE/thumbnail.png" "$(stat -f%z "$HERE/thumbnail.png")"
