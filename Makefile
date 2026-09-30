# Better Claude's development cycle, the same as Parallex's:
#
#   make app            build dist/BetterClaude.app (universal, ad-hoc signed)
#   make app-install    …and install it in /Applications
#   make dist           the release files: signed zip, signature, checksum, disk image
#   make publish        publish a GitHub release with the notes in dist/release-notes.md
#   make deploy-site    publish the website to Cloudflare
#
# The version lives in one place, Sources/CoworkKit/Update/AppVersion.swift.
VERSION := $(shell sed -n 's/.*static let current = "\(.*\)"/\1/p' Sources/CoworkKit/Update/AppVersion.swift)
APP := dist/BetterClaude.app
ZIP := dist/BetterClaude-$(VERSION).zip
DMG := dist/BetterClaude.dmg
APPCAST := dist/appcast.json
NOTES ?= dist/release-notes.md
REPO := mandipadk/BetterClaude

.PHONY: build test corpus app app-install debug-app capture dist publish deploy-site clean

build:
	swift build

test:
	swift test

# Adds the shapes of this Mac's Claude Code and Codex files (field names and types, never
# content) to the test corpus, one file per version. Review the diff before committing.
corpus:
	swift run cowork formats --write Tests/CoworkKitTests/Corpus

app:
	Scripts/make-app.sh release

app-install: app
	@if pgrep -xq BetterClaude; then osascript -e 'quit app "Better Claude"' >/dev/null 2>&1 || true; \
	  for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq BetterClaude || break; sleep 0.5; done; \
	  if pgrep -xq BetterClaude; then echo "Better Claude didn't quit; ending it so the new version opens."; pkill -TERM -x BetterClaude; sleep 1; fi; fi
	rm -rf /Applications/BetterClaude.app
	ditto "$(APP)" /Applications/BetterClaude.app
	xattr -dr com.apple.quarantine /Applications/BetterClaude.app 2>/dev/null || true
	@echo "Installed /Applications/BetterClaude.app $(VERSION)"

# A separate debug app (its own bundle id), which honours BC_FIXTURE_ROOT and BC_UI_ROUTE.
debug-app:
	Scripts/make-app.sh debug

# Every screen, from a sample Mac, in light and dark: make capture OUT=~/Desktop/shots
capture:
	Scripts/capture.sh "$(or $(OUT),dist/shots)"

# Release files: the zip the in-app updater installs and its signature (made with the release
# key in the login keychain), a checksum, the disk image for the website, and the checksum
# manifest Better Claude 0.1.x reads to find this release.
dist: app
	rm -f "$(ZIP)" "$(ZIP).sig" "$(ZIP).sha256" "$(DMG)" "$(APPCAST)"
	ditto -c -k --sequesterRsrc --keepParent "$(APP)" "$(ZIP)"
	swift Scripts/release-key.swift sign "$(ZIP)" > "$(ZIP).sig"
	cd dist && shasum -a 256 "$(notdir $(ZIP))" > "$(notdir $(ZIP)).sha256"
	DMG_OUT="$(DMG)" Scripts/make-dmg.sh "$(APP)"
	python3 Scripts/make-appcast.py "$(VERSION)" "$(ZIP)" "$(DMG)" "$(NOTES)" > "$(APPCAST)"
	@echo "Built $(ZIP), its signature and checksum, $(DMG) and $(APPCAST)"

publish: dist
	@test -s "$(NOTES)" || { echo "error: write the release notes to $(NOTES) first"; exit 1; }
	@test -z "$$(git status --porcelain -- Sources Package.swift Scripts Makefile)" || { echo "error: commit your changes first"; exit 1; }
	@test "$$(git rev-parse HEAD)" = "$$(git rev-parse @{u} 2>/dev/null)" || { echo "error: push main first"; exit 1; }
	gh release create "v$(VERSION)" "$(ZIP)" "$(ZIP).sig" "$(ZIP).sha256" "$(DMG)" "$(APPCAST)" \
		--repo $(REPO) --target "$$(git rev-parse HEAD)" \
		--title "Better Claude $(VERSION)" --notes-file "$(NOTES)"

# The site is static: checked for anything loaded off-origin, then served by Cloudflare.
# Wrangler's own two build scripts are approved up front, so pnpm doesn't stop to ask.
deploy-site:
	python3 Scripts/check-selfcontained.py site/public
	cd site && pnpm dlx --allow-build=esbuild --allow-build=workerd wrangler deploy

clean:
	swift package clean
	rm -rf dist
