<!-- Copied from docs/releasing.md by Scripts/sync-site-docs.sh. Edit the repo, not this. -->

# Releasing

Releases are cut from a Mac, not from CI:

```bash
Scripts/release.sh 0.5.0
```

That builds the app, signs it with a Developer ID certificate, notarises it with Apple,
staples the ticket, packages it, publishes the GitHub release, writes the update feed and
bumps the Homebrew cask. Notarisation runs *before* the tag, so a failure leaves nothing
published and nothing tagged.

Signing happens here rather than in a workflow because the certificate's private key stays
on one machine. Nothing has to be exported to a `.p12`, base64-encoded, and handed to a CI
provider to be decrypted onto a shared runner.

## Why notarisation is not optional

Gatekeeper judges anything that arrives with a quarantine flag — every browser download, and
every Homebrew cask not marked as coming from a notarised source. An ad-hoc signature is not
a signature Apple recognises, so macOS reports the app as **damaged**. The familiar
right-click → Open escape hatch does not help: that one is for the different "unidentified
developer" case. Notarising is the only thing that fixes it.

Two consequences worth knowing before you hit them:

- The certificate must be **Developer ID Application**. An *Apple Development* certificate
  signs successfully and is then rejected by notarisation — the worst of both outcomes, and
  the one that produces the damaged-app report. `Scripts/notarize.sh` checks for this case
  specifically and says so rather than letting you find out at the end.
- The ticket is stapled into the bundle before it is zipped, so a first launch with no
  network still validates.

`Scripts/cask-notarised.py` strips the cask's quarantine workaround; `release.sh` runs it on
every release, so the first notarised build drops it automatically.

## One-time setup

### 1. A Developer ID Application certificate

Check what you have:

```bash
security find-identity -v -p codesigning
```

If there is no `Developer ID Application: …` line, either import the `.p12` you already have,
or create one:

> Xcode → Settings → Accounts → *your Apple ID* → Manage Certificates → **+** →
> **Developer ID Application**

Xcode generates the key locally and installs it. Creating one does not revoke an existing
certificate, and builds already notarised stay valid.

### 2. A notarytool credential profile

`notarytool` prompts for the secret and stores it in the keychain, so it never passes through
a script, a command line, or the environment. Do this once:

```bash
xcrun notarytool store-credentials "codex-remote" \
  --apple-id "<your Apple Developer account>" --team-id "<TEAMID>"
```

It asks for an app-specific password — appleid.apple.com, Sign-In and Security,
App-Specific Passwords. You do not need to look the team id up: run `Scripts/notarize.sh`
once the certificate is installed and it prints the command with the id already filled in,
read from the certificate's own subject.

Note the Apple ID here is the Apple Developer account, which is not necessarily the one
signed in anywhere else on the machine. If the keychain happens to hold a certificate from
another team, its id is that team's, not yours.

or, with an App Store Connect API key:

```bash
xcrun notarytool store-credentials "codex-remote" \
  --key AuthKey_XXXXXXXXXX.p8 --key-id "<KEYID>" --issuer "<ISSUERID>"
```

The profile name is `codex-remote`; override it with `CODEX_REMOTE_NOTARY_PROFILE`.

### 3. Push access to the tap

`release.sh` pushes the cask bump to `PandelisZ/homebrew-tap` over SSH, so the usual `git`
credentials cover it.

## Checking the setup without cutting a release

`Scripts/notarize.sh` runs standalone against an existing build:

```bash
Scripts/bundle.sh
Scripts/notarize.sh
```

It reports exactly which of the two prerequisites is missing, and submits nothing until both
are in place.

## Checking a release afterwards

```bash
# The published build validates as notarised, from a clean download:
curl -sL https://github.com/PandelisZ/codex-remote/releases/latest/download/CodexRemote-0.5.0.zip -o /tmp/cr.zip
ditto -x -k /tmp/cr.zip /tmp/cr && spctl -a -vvv -t install /tmp/cr/CodexRemote.app

# The feed's checksum matches the asset the app would download:
curl -s https://codexremote.io/latest.json
shasum -a 256 /tmp/cr.zip

# A clean install works:
brew install --cask pandelisz/tap/codex-remote
```

If a submission is rejected, Apple's reason is in its log:

```bash
xcrun notarytool history --keychain-profile "codex-remote"
xcrun notarytool log <submission-id> --keychain-profile "codex-remote"
```
