# Releasing Better Claude

## Cut a release

```sh
git tag -a v1.2.3 -m "Short summary of the release" -m "Longer body, if you want one."
git push origin v1.2.3
```

Pushing a `v*` tag starts `.github/workflows/release.yml` on a `macos-14` runner, which:

1. selects the newest installed Xcode and derives `1.2.3` from the tag;
2. runs `swift build -c release` and `swift test` — a test failure stops the release here,
   before anything is published;
3. runs `Scripts/make-app.sh release`, stamps the version into `Info.plist`, and re-signs;
4. runs `Scripts/make-dmg.sh` to produce `BetterClaude-1.2.3.dmg`;
5. produces `BetterClaude-1.2.3.zip` via `ditto -c -k --keepParent`;
6. writes `appcast.json`;
7. creates the GitHub Release with all three files attached.

Use an **annotated** tag. The workflow takes the release notes from the tag's message and
falls back to the latest commit subject, so a lightweight tag gives you a one-line release.

To rebuild an existing release, or to release without tagging first, run the workflow
manually from the Actions tab and pass the version (`1.2.3`, no leading `v`). It creates the
tag if it does not exist, and replaces the assets on a release that already exists.

## Version has two sources of truth

`Scripts/make-app.sh` writes `Info.plist` from a heredoc with `CFBundleShortVersionString`
hardcoded (currently `0.1.0`) and `CFBundleVersion` hardcoded to `1`. The workflow does not
edit that script. It runs `make-app.sh`, then overwrites both keys with `PlistBuddy` and
re-signs the bundle, because editing `Info.plist` invalidates the ad-hoc signature.

Consequences:

- A **locally** built app always reports the version in the heredoc, whatever tag you are on.
  Only CI-built apps carry the real version.
- The heredoc value will drift from the released version and is not worth chasing. Treat the
  git tag as authoritative.

The clean fix is a one-line change to `make-app.sh`, once whoever owns it is ready:

```sh
VERSION="${BC_VERSION:-0.1.0}"
BUILD="${BC_BUILD:-1}"
```

and interpolating those in the plist heredoc (drop the quotes on `<<'PLIST'` so the shell
expands them, and make sure nothing else in the plist needs escaping). The workflow already
exports `BC_VERSION` and `BC_BUILD` before calling the script, so it would start working
immediately; the `PlistBuddy` step would then be redundant and could be deleted.

`CFBundleVersion` is set to the workflow's run number. It only has to increase monotonically
so an updater can compare builds — it is not meaningful on its own.

## Test the dmg locally

```sh
./Scripts/make-app.sh release
./Scripts/make-dmg.sh
```

The output is `dist/BetterClaude-<version>.dmg`, where `<version>` is read back out of the
built bundle's `Info.plist` — so locally it will say `0.1.0` until the point above is fixed.
The script prints the SHA-256 it computed.

Check it by hand:

```sh
hdiutil attach dist/BetterClaude-0.1.0.dmg
ls -la "/Volumes/Better Claude"        # BetterClaude.app + an Applications symlink
hdiutil detach "/Volumes/Better Claude"
```

The script is idempotent — running it twice in a row is safe. It detaches a stale
`/Volumes/Better Claude` from an interrupted earlier run before creating a new image, and
removes its scratch files on exit.

The volume also picks up the app's own icon when `make-app.sh` has generated one, which needs
`SetFile` from the Xcode command line tools. Without them the image gets the generic disk icon
and nothing else changes.

One caveat: the icon positions and window size are set by driving the Finder over AppleScript.
That needs a Finder willing to answer Apple events for a mounted volume, which is not the case
in a headless session, over ssh, or under some automation restrictions. When it fails the
script prints a warning and continues; the dmg is valid and still contains both items, it just
uses the Finder's default layout. If you care about the layout for a given release, build the
dmg in a normal desktop login session and confirm before publishing.

## Gatekeeper and notarisation

**The app is ad-hoc signed only (`codesign -s -`). It is not notarised.** This is a real
limitation, not a warning to route around.

A locally built bundle never gets the `com.apple.quarantine` attribute, so it launches with no
complaint. Anything downloaded from a GitHub Release does get quarantined, so on first launch
macOS reports that the app cannot be opened because Apple cannot check it for malicious
software. The user has to right-click the app and choose **Open**, then confirm — once per
installed version. The workflow appends this instruction to every release body.

Fixing it properly requires:

1. an Apple Developer Program membership (paid) and a **Developer ID Application** certificate;
2. importing that certificate plus its password into the repository as encrypted secrets, and
   into a temporary keychain on the runner;
3. signing with `codesign --sign "Developer ID Application: …" --options runtime --timestamp`
   instead of `--sign -`, with a hardened-runtime entitlements file if any is needed;
4. submitting the dmg and the zip with
   `xcrun notarytool submit --wait --apple-id … --team-id … --password …`
   (an app-specific password, or an App Store Connect API key);
5. `xcrun stapler staple` on the dmg, so the ticket travels with the download.

Both artefacts need this — stapling only the dmg leaves the zip quarantined.

Note also that the app is deliberately **not sandboxed**, for the reasons in the comment at the
top of `make-app.sh`. That is compatible with Developer ID distribution; it only rules out the
Mac App Store.

## The appcast and the in-app updater

Each release carries an `appcast.json` asset:

```json
{
  "version": "1.2.3",
  "build": "12",
  "minimumSystemVersion": "14.0",
  "publishedAt": "2026-08-01T00:00:00Z",
  "zipURL": "https://github.com/mandipadk/BetterClaude/releases/download/v1.2.3/BetterClaude-1.2.3.zip",
  "zipSHA256": "…",
  "dmgURL": "https://github.com/mandipadk/BetterClaude/releases/download/v1.2.3/BetterClaude-1.2.3.dmg",
  "dmgSHA256": "…",
  "notes": "…"
}
```

The updater should fetch it from the **latest release**, at the redirecting URL:

```
https://github.com/mandipadk/BetterClaude/releases/latest/download/appcast.json
```

That path always resolves to the newest non-prerelease release's asset, so the updater never
needs to know a version number or call the API. It then compares `version` (or `build`) against
the running bundle's `Info.plist`, checks `minimumSystemVersion`, downloads `zipURL`, and
verifies the download against `zipSHA256` before unpacking.

The updater downloads the **zip**, not the dmg: it unpacks with `ditto -x -k` and needs no disk
image mount. `dmgURL` and `dmgSHA256` are there for the download page and for anyone who wants
to verify a manual download.

A zip the updater fetches and unpacks itself is not quarantined the way a browser download is,
so an in-app update does not hit the Gatekeeper prompt described above. A user who downloads
the same zip in a browser does.
