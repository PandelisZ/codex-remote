#!/usr/bin/env bash
# Signs, notarises and staples build/CodexRemote.app, in place.
#
#   Scripts/notarize.sh [path/to/CodexRemote.app]
#
# Run by Scripts/release.sh; runnable on its own to check the setup without cutting a
# release. It needs two things, both one-time:
#
#   1. A **Developer ID Application** certificate in the login keychain.
#   2. A notarytool credential profile called $PROFILE (see below).
#
# Neither a password nor a key is read by this script, passed on a command line, or held in
# the environment. notarytool talks to its own keychain item; this script only names it.
#
# Why bother: Gatekeeper judges anything that arrives quarantined, which is every browser
# download and every Homebrew cask not marked as notarised. An ad-hoc signature is not a
# signature Apple recognises, so macOS reports the app as *damaged* — and the familiar
# right-click → Open escape hatch does not apply, because that one is for the different
# "unidentified developer" case. Notarising is the only thing that actually fixes it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="${1:-$ROOT/build/CodexRemote.app}"
PROFILE="${CODEX_REMOTE_NOTARY_PROFILE:-codex-remote}"

say() { printf '\n▸ %s\n' "$*"; }
die() { printf '\n✗ %s\n' "$*" >&2; exit 1; }

[ -d "$APP" ] || die "no app bundle at $APP — run Scripts/bundle.sh first"

# ---------------------------------------------------------------- the certificate

say "Looking for a Developer ID Application certificate"
IDENTITY="$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"

if [ -z "$IDENTITY" ]; then
  # Worth separating the two cases: an Apple Development certificate signs perfectly well
  # and then fails notarisation, which produces exactly the damaged-app symptom this script
  # exists to remove. Saying "no certificate" when one is right there would send whoever
  # hits this down the wrong path.
  if security find-identity -v -p codesigning | grep -q "Apple Development"; then
    cat >&2 <<'EOF'

✗ The only signing certificate here is an Apple Development one.

  It will sign the app, and then notarisation will reject it — which leaves the app
  reporting as damaged, the exact failure this step exists to prevent.

  Notarising needs a Developer ID Application certificate. To create one:

    Xcode → Settings → Accounts → (your Apple ID) → Manage Certificates
      → + → Developer ID Application

  That generates the key locally and installs it. It does not revoke an existing one,
  and builds already notarised stay valid.

EOF
    exit 1
  fi
  die "no code-signing certificate in the keychain at all"
fi
echo "  $IDENTITY"

# The team id is the OU of the certificate's subject. Read rather than asked for, because
# notarytool needs it and hunting it down on developer.apple.com is a detour.
TEAM_ID="$(security find-certificate -c "$IDENTITY" -p 2>/dev/null \
  | openssl x509 -noout -subject 2>/dev/null \
  | sed -n 's/.*OU=\([A-Z0-9]\{10\}\).*/\1/p' | head -1)"
[ -n "$TEAM_ID" ] && echo "  team $TEAM_ID"

# ---------------------------------------------------------------- the credentials

say "Checking the notarytool credential profile '$PROFILE'"
# No --limit: notarytool 1.1.2, which ships with current Xcode, does not accept it.
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  cat >&2 <<EOF

✗ No usable notarytool profile called '$PROFILE'.

  Create it once. notarytool prompts for the secret and stores it in the keychain, so it
  never passes through this script, a command line, or the environment. The team id below
  was read from the certificate above, so this is ready to paste:

    xcrun notarytool store-credentials "$PROFILE" \\
      --apple-id "<your Apple Developer account>" --team-id "${TEAM_ID:-<TEAMID>}"

  It will ask for an app-specific password — appleid.apple.com, Sign-In and Security,
  App-Specific Passwords. Or use an App Store Connect key instead:

    xcrun notarytool store-credentials "$PROFILE" \\
      --key AuthKey_XXXXXXXXXX.p8 --key-id "<KEYID>" --issuer "<ISSUERID>"

EOF
  exit 1
fi
echo "  ok"

# ---------------------------------------------------------------- signing

say "Signing"
# Inside-out: nested code must be signed before the bundle that contains it. The bundled
# CLI is a Mach-O of its own and is not covered by signing the app around it.
while IFS= read -r binary; do
  echo "  $(basename "$binary")"
  codesign --force --timestamp --options runtime \
    --entitlements "$ROOT/Scripts/CodexRemote.entitlements" \
    --sign "$IDENTITY" "$binary"
done < <(find "$APP/Contents/MacOS" -type f -perm -u+x)

codesign --force --timestamp --options runtime \
  --entitlements "$ROOT/Scripts/CodexRemote.entitlements" \
  --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# ---------------------------------------------------------------- notarising

say "Submitting to Apple (this usually takes a few minutes)"
SUBMISSION="$(mktemp -d)/notarize.zip"
# ditto, not zip: it keeps the bundle's symlinks and signature, which zip flattens — and a
# flattened bundle fails notarisation.
ditto -c -k --keepParent --sequesterRsrc "$APP" "$SUBMISSION"

set +e
xcrun notarytool submit "$SUBMISSION" --keychain-profile "$PROFILE" --wait --timeout 30m
STATUS=$?
set -e
rm -f "$SUBMISSION"
if [ $STATUS -ne 0 ]; then
  cat >&2 <<EOF

✗ Notarisation failed. Apple's reason is in the log for that submission:

    xcrun notarytool history --keychain-profile "$PROFILE"
    xcrun notarytool log <submission-id> --keychain-profile "$PROFILE"

EOF
  exit 1
fi

# ---------------------------------------------------------------- stapling

say "Stapling the ticket into the bundle"
# Without this the app still validates, but only by asking Apple — so a first launch with
# no network shows the damaged dialog anyway.
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

say "Verifying the way Gatekeeper will"
spctl -a -vvv -t install "$APP"

printf '\n✓ %s is signed, notarised and stapled.\n' "$APP"
