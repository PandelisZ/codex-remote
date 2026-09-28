#!/usr/bin/env bash
# Copies docs/*.md onto the site, so codexremote.io/docs/… serves the same text as the repo.
#
#   Scripts/sync-site-docs.sh
#
# Run by Scripts/release.sh, so the published docs move with each release rather than
# drifting quietly. Copies rather than symlinks: GitHub Pages does not follow symlinks.
#
# The copies carry a header pointing at the source, because someone who lands on the site
# version and edits it there would otherwise have their change overwritten by the next
# release without a word.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/docs"
DEST="$ROOT/site/docs"

rm -rf "$DEST"
mkdir -p "$DEST"

for file in "$SRC"/*.md; do
  name="$(basename "$file")"
  {
    printf '<!-- Copied from docs/%s by Scripts/sync-site-docs.sh. Edit the repo, not this. -->\n\n' "$name"
    cat "$file"
  } > "$DEST/$name"
  echo "  docs/$name"
done

echo "✓ $(ls -1 "$DEST" | wc -l | tr -d ' ') docs published to site/docs/"
