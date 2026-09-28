# Releasing Better Claude

Releases are made from a Mac with `make`, the same cycle as Parallex:

```sh
# 1. Bump the version in Sources/CoworkKit/Update/AppVersion.swift, and add the release's
#    highlights to ReleaseHighlights in Sources/BetterClaude/App/WhatsNew.swift.
# 2. Commit and push to main.
# 3. Write the release notes, for people, in dist/release-notes.md.
make publish        # builds, signs and publishes the GitHub release
make app-install    # install the same build in /Applications
make deploy-site    # if the website changed
```

`make publish` refuses to run with uncommitted changes or unpushed commits, so a release is
always a commit that exists on GitHub.

## What a release contains

| File | For |
|---|---|
| `BetterClaude-<version>.zip` | the in-app updater |
| `BetterClaude-<version>.zip.sig` | its Ed25519 signature |
| `BetterClaude-<version>.zip.sha256` | anyone checking a download by hand |
| `BetterClaude.dmg` | the website's download button (`releases/latest/download/BetterClaude.dmg`) |
| `appcast.json` | Better Claude 0.1.x, whose updater reads it to find newer versions |

## Signing

Update archives are signed with an Ed25519 key that lives only in the login keychain of the
release Mac (service "Better Claude Release Signing"). The public half is compiled into the
app (`ReleaseSignature.publicKey` in `Sources/CoworkKit/Update/Updater.swift`), and the
updater installs nothing whose signature doesn't verify against it.

```sh
swift Scripts/release-key.swift public          # print the public key
swift Scripts/release-key.swift sign <file>     # what make dist runs
```

Losing the key means shipping a new public key in a release signed with the old one, so
keep a backup of the keychain item somewhere safe.

## The updater

The app asks GitHub for the latest release once a day (and when you choose Check for
Updates), offers it if it's newer, downloads the zip and its signature, verifies, and swaps
the app in place. A release without a signed zip is never offered.

## Gatekeeper

The app is ad-hoc signed, not notarized (that needs a paid Developer ID). A download from
the website is quarantined, so the first launch is blocked: System Settings, Privacy &
Security, Open Anyway. Updates installed by the app itself aren't quarantined and don't ask.

## Development

```sh
make debug-app                   # a separate debug app, with its own bundle id
make capture OUT=~/Desktop/shots # every screen from a sample Mac, light and dark
swift test
```
