#!/usr/bin/env bash
# Cuts a release: builds the app, packages it, publishes it to GitHub, updates the
# Homebrew cask, and writes the update feed the app itself checks.
#
#   Scripts/release.sh 0.3.0
#
# The feed at https://codexremote.io/latest.json is what installed copies poll. It carries
# the SHA-256 of the artifact that is actually uploaded, never a hand-typed one.
#
# Releases are signed and notarised here, on a Mac with the Developer ID certificate, rather
# than in CI — see docs/releasing.md. Scripts/notarize.sh does that part and refuses to
# continue if it cannot, because a release that is not notarised is one macOS reports as
# damaged on every machine that downloads it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
  echo "usage: Scripts/release.sh <version>    e.g. Scripts/release.sh 0.3.0" >&2
  exit 1
fi
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "version should look like 0.3.0" >&2
  exit 1
fi

TAG="v$VERSION"
ZIP="CodexRemote-$VERSION.zip"
ASSET="https://github.com/PandelisZ/codex-remote/releases/download/$TAG/$ZIP"

say() { printf '\n▸ %s\n' "$*"; }

if [ -n "$(git status --porcelain)" ]; then
  echo "working tree is dirty; commit first so the release matches what is on main" >&2
  exit 1
fi
if git rev-parse "$TAG" >/dev/null 2>&1; then
  echo "$TAG already exists" >&2
  exit 1
fi

say "Recording the version"
echo "$VERSION" > VERSION
# The MCP handshake reports this, so it has to move with the tag.
/usr/bin/sed -i '' -E "s/(static let current = )\"[^\"]+\"/\1\"$VERSION\"/" \
  Sources/CodexRemoteKit/Support/Log.swift

say "Testing"
swift test 2>&1 | tail -3

say "Publishing the docs to the site"
./Scripts/sync-site-docs.sh

say "Building the app"
./Scripts/bundle.sh >/dev/null
test -d build/CodexRemote.app

# Before the tag, not after: a failure here should leave nothing published and nothing
# tagged, rather than a release everyone's Gatekeeper rejects.
./Scripts/notarize.sh build/CodexRemote.app

say "Packaging"
mkdir -p dist && rm -f "dist/$ZIP"
# ditto, not zip: it keeps the bundle's symlinks, xattrs and signature intact. Zipped
# after stapling, so the ticket travels with the download and a first launch offline works.
ditto -c -k --keepParent --sequesterRsrc build/CodexRemote.app "dist/$ZIP"
SHA="$(shasum -a 256 "dist/$ZIP" | awk '{print $1}')"
SIZE="$(stat -f%z "dist/$ZIP")"
echo "  $ZIP  $SIZE bytes  $SHA"

say "Writing the update feed"
NOTES="${RELEASE_NOTES:-Codex Remote $VERSION}"
python3 - "$VERSION" "$ASSET" "$SHA" "$NOTES" <<'PY'
import json, sys, datetime, pathlib
version, url, sha, notes = sys.argv[1:5]
feed = {
    "version": version,
    "url": url,
    "sha256": sha,
    "notes": notes,
    "publishedAt": datetime.datetime.now(datetime.timezone.utc)
                     .replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    "minimumSystemVersion": "15.0",
}
pathlib.Path("site/latest.json").write_text(json.dumps(feed, indent=2) + "\n")
print("  site/latest.json ->", version)
PY

say "Committing and tagging"
git add VERSION Sources/CodexRemoteKit/Support/Log.swift site/latest.json
git commit -q -m "Codex Remote $VERSION"
git tag "$TAG"
git push -q origin main --tags

say "Publishing the release"
gh release create "$TAG" "dist/$ZIP" --title "Codex Remote $VERSION" --notes "$NOTES"

say "Updating the Homebrew cask"
TAP="$(mktemp -d)"
git clone -q git@github.com:PandelisZ/homebrew-tap.git "$TAP"
/usr/bin/sed -i '' -E "s/version \"[^\"]+\"/version \"$VERSION\"/" "$TAP/Casks/codex-remote.rb"
/usr/bin/sed -i '' -E "s/sha256 \"[0-9a-f]{64}\"/sha256 \"$SHA\"/" "$TAP/Casks/codex-remote.rb"
# The zap list still named the pre-0.4 home. `brew zap` was therefore leaving the real
# state directory behind and deleting a path that no longer exists.
/usr/bin/sed -i '' -E 's#"~/\.codex/codex-remote"#"~/.codex-remote"#' "$TAP/Casks/codex-remote.rb"
# A notarised build carries its own ticket, so the cask no longer has to strip the
# quarantine flag behind the user's back. No-op once it has already been removed.
python3 "$ROOT/Scripts/cask-notarised.py" "$TAP/Casks/codex-remote.rb"
git -C "$TAP" commit -qam "codex-remote $VERSION"
git -C "$TAP" push -q origin main
rm -rf "$TAP"

cat <<EOF

✓ Codex Remote $VERSION is out.

  Release   https://github.com/PandelisZ/codex-remote/releases/tag/$TAG
  Feed      https://codexremote.io/latest.json   (after the site deploys)
  Homebrew  brew upgrade --cask pandelisz/tap/codex-remote

Check the feed once the site has deployed:
  curl -s https://codexremote.io/latest.json
EOF
