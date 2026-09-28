# Releasing

A release is cut by pushing a tag. `.github/workflows/release.yml` then builds, signs,
notarises, staples, publishes the GitHub release, writes the update feed and bumps the
Homebrew cask.

```bash
git tag v0.5.0 && git push origin v0.5.0
```

`Scripts/release.sh` does the same thing from a laptop, but it cannot notarise — it produces
an ad-hoc signed build. Use it only when the workflow is unavailable, and expect the
"damaged" dialog described below.

## Why notarisation is not optional

Gatekeeper judges anything that arrives with a quarantine flag — every browser download, and
every Homebrew cask that is not marked as coming from a notarised source. An ad-hoc
signature is not a signature Apple recognises, so the app is reported as **damaged**, not as
"from an unidentified developer". The right-click → Open escape hatch does not apply to it;
that is for the unidentified-developer case. Until a release is notarised, the cask has to
strip the quarantine flag in a `postflight`, which is a workaround the user has to trust.

Two things follow:

- The certificate must be **Developer ID Application**. An *Apple Development* certificate
  signs successfully and then fails notarisation, which is the worst of both outcomes.
- The ticket is stapled into the bundle before it is zipped, so a first launch with no
  network still validates.

`Scripts/cask-notarised.py` removes the quarantine workaround from the cask; the workflow
runs it on every release, so the first notarised build drops it automatically.

## Secrets

The workflow needs these on `PandelisZ/codex-remote`. The names match `RoderAI/roder`, so
the same values work unchanged — but GitHub never discloses a stored secret, so they have to
come from wherever the originals are kept.

| Secret | What it is |
|---|---|
| `APPLE_CERTIFICATE_BASE64` | Developer ID Application `.p12`, base64 |
| `APPLE_CERTIFICATE_PASSWORD` | the password for that `.p12` |
| `APPLE_NOTARIZE_KEY_BASE64` | App Store Connect API key `.p8`, base64 |
| `APPLE_NOTARIZE_KEY_ID` | that key's ID |
| `APPLE_NOTARIZE_ISSUER_ID` | the App Store Connect issuer ID |
| `HOMEBREW_TAP_TOKEN` | a token with `contents: write` on `PandelisZ/homebrew-tap` |

Setting them:

```bash
gh secret set APPLE_CERTIFICATE_BASE64   --repo PandelisZ/codex-remote < cert.p12.base64
gh secret set APPLE_CERTIFICATE_PASSWORD --repo PandelisZ/codex-remote
gh secret set APPLE_NOTARIZE_KEY_BASE64  --repo PandelisZ/codex-remote < AuthKey.p8.base64
gh secret set APPLE_NOTARIZE_KEY_ID      --repo PandelisZ/codex-remote
gh secret set APPLE_NOTARIZE_ISSUER_ID   --repo PandelisZ/codex-remote
gh secret set HOMEBREW_TAP_TOKEN         --repo PandelisZ/codex-remote
```

Where the base64 files come from, if they need regenerating — export the certificate from
Keychain Access as a `.p12`, then:

```bash
base64 -i cert.p12 -o cert.p12.base64
base64 -i AuthKey_XXXXXXXXXX.p8 -o AuthKey.p8.base64
```

The workflow fails with an explicit message if a secret is missing or if the certificate
turns out not to be a Developer ID Application one, rather than producing an unsigned build
and calling it a release.

## Checking a release afterwards

```bash
# The published build validates as notarised:
curl -sL https://github.com/PandelisZ/codex-remote/releases/latest/download/CodexRemote-0.5.0.zip -o /tmp/cr.zip
ditto -x -k /tmp/cr.zip /tmp/cr && spctl -a -vvv -t install /tmp/cr/CodexRemote.app

# The feed's checksum matches the asset the app would download:
curl -s https://codexremote.io/latest.json
shasum -a 256 /tmp/cr.zip

# A clean install works:
brew install --cask pandelisz/tap/codex-remote
```
