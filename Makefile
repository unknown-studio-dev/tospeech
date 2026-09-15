# ToSpeech — single entry point for build / run / test / sign / notarize.
# Requires Xcode 26+, Apple Silicon, macOS 26+. `make gen` also needs xcodegen.

SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := help

PROJECT     := ToSpeech.xcodeproj
SCHEME      := ToSpeech
DERIVED     := $(PWD)/.build
DEST        := platform=macOS,arch=arm64
DEBUG_APP   := $(DERIVED)/Build/Products/Debug/ToSpeech.app
RELEASE_APP := $(DERIVED)/Build/Products/Release/ToSpeech.app

# Developer ID signing + notarization. Override on the command line as needed.
DEV_ID      ?= Developer ID Application: Khang Truong (Y8DVMS7BH2)
TEAM_ID     ?= Y8DVMS7BH2
ENT_APP     := ToSpeech/App/ToSpeech.entitlements
ENT_HELPER  := scripts/audio/SandboxedHelper.entitlements
ENT_PY      := scripts/audio/PythonHelper.entitlements
# Notarization credentials — pass one set on the command line:
#   make notarize NOTARY_PROFILE=tospeech
#   make notarize APPLE_ID=you@example.com APP_PW=abcd-efgh-ijkl-mnop
NOTARY_PROFILE ?=
APPLE_ID       ?=
APP_PW         ?=

XCB = xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -destination "$(DEST)" -derivedDataPath "$(DERIVED)"

.PHONY: help gen bump build run test components render clean release install sign notarize dmg

help:
	@echo "ToSpeech — make targets:"
	@echo "  make gen         Regenerate ToSpeech.xcodeproj from project.yml (xcodegen)"
	@echo "  make bump        Set version (VERSION=x.y.z [BUILD=n]) in project.yml + version.json, then gen"
	@echo "  make build       Build Debug"
	@echo "  make run         Build Debug + launch the app"
	@echo "  make test        Build + run the Swift Testing suite"
	@echo "  make components  Build + open the UI Components gallery"
	@echo "  make render      Build + export SwiftUI view PNGs, then exit"
	@echo "  make clean       Remove the .build derived-data directory"
	@echo "  make release     Build Release"
	@echo "  make install     Release build + copy ToSpeech.app into /Applications (replaces existing)"
	@echo "  make sign        Release build + Developer ID sign every embedded Mach-O + verify"
	@echo "  make notarize    Sign + notarize + staple  (NOTARY_PROFILE=... | APPLE_ID=... APP_PW=...)"
	@echo "  make dmg         Notarize + build the drag-to-Applications DMG users download, notarized + stapled"

gen:
	@command -v xcodegen >/dev/null || { echo "✗ xcodegen not installed (brew install xcodegen)"; exit 1; }
	xcodegen generate

# Move MARKETING_VERSION (and the build number) in project.yml and version.json together,
# so the shipping bundle and the release feed can never disagree. Attach the updated
# version.json to the matching GitHub release; the app checks that permalink.
#   make bump VERSION=0.2.0            # auto-increments the build number
#   make bump VERSION=0.2.0 BUILD=12   # sets an explicit build number
bump:
	@[ -n "$(VERSION)" ] || { echo "✗ usage: make bump VERSION=x.y.z [BUILD=n]"; exit 1; }
	@echo "$(VERSION)" | grep -qE '^[0-9]+(\.[0-9]+)*$$' || { echo "✗ VERSION must be dotted digits (e.g. 0.2.0)"; exit 1; }
	@new_build="$(BUILD)"; \
	if [ -z "$$new_build" ]; then \
	  cur_build=$$(grep -E 'CURRENT_PROJECT_VERSION:' project.yml | grep -oE '[0-9]+' | head -1); \
	  new_build=$$(( $${cur_build:-0} + 1 )); \
	fi; \
	sed -i '' -E 's/(MARKETING_VERSION: )"[^"]*"/\1"$(VERSION)"/' project.yml; \
	sed -i '' -E "s/(CURRENT_PROJECT_VERSION: )\"[^\"]*\"/\1\"$$new_build\"/" project.yml; \
	sed -i '' -E 's/("version": )"[^"]*"/\1"$(VERSION)"/' version.json; \
	sed -i '' -E "s/(\"build\": )\"[^\"]*\"/\1\"$$new_build\"/" version.json; \
	echo "▶ Bumped to $(VERSION) (build $$new_build) in project.yml + version.json."; \
	echo "  Next: make release, then attach version.json to the GitHub release tagged v$(VERSION)."
	@$(MAKE) gen

build:
	$(XCB) -configuration Debug build

run: build
	open "$(DEBUG_APP)"

test:
	$(XCB) -configuration Debug test

components: build
	[ -x "$(DEBUG_APP)/Contents/MacOS/ToSpeech" ] || { echo "✗ binary missing"; exit 1; }
	"$(DEBUG_APP)/Contents/MacOS/ToSpeech" --preview-fixtures --components

render: build
	[ -x "$(DEBUG_APP)/Contents/MacOS/ToSpeech" ] || { echo "✗ binary missing"; exit 1; }
	"$(DEBUG_APP)/Contents/MacOS/ToSpeech" --preview-fixtures --render-previews

clean:
	rm -rf "$(DERIVED)"

release:
	$(XCB) -configuration Release build
	@echo "▶ Release app: $(RELEASE_APP)"

# Local install for testing the Release build like a user would; distribution still
# goes through notarize + zip/dmg.
install: release
	pkill -x ToSpeech 2>/dev/null || true
	rm -rf "/Applications/ToSpeech.app"
	/usr/bin/ditto "$(RELEASE_APP)" "/Applications/ToSpeech.app"
	@echo "▶ Installed: /Applications/ToSpeech.app"

# Signing / notarization / packaging live in scripts/release (macOS make is 3.81, no
# .ONESHELL). Each target is one command so the Makefile stays the entry point.
sign: release
	APP="$(RELEASE_APP)" DEV_ID="$(DEV_ID)" ENT_APP="$(ENT_APP)" ENT_HELPER="$(ENT_HELPER)" ENT_PY="$(ENT_PY)" \
	  bash scripts/release/sign.sh

notarize: sign
	TEAM_ID="$(TEAM_ID)" NOTARY_PROFILE="$(NOTARY_PROFILE)" APPLE_ID="$(APPLE_ID)" APP_PW="$(APP_PW)" \
	  bash scripts/release/notarize.sh "$(RELEASE_APP)"

# Attach the DMG and version.json to the GitHub release tagged v<version>.
dmg: sign
	APP="$(RELEASE_APP)" DEV_ID="$(DEV_ID)" TEAM_ID="$(TEAM_ID)" \
	  VERSION="$$(sed -nE 's/.*"version": "([^"]+)".*/\1/p' version.json)" \
	  NOTARY_PROFILE="$(NOTARY_PROFILE)" APPLE_ID="$(APPLE_ID)" APP_PW="$(APP_PW)" \
	  bash scripts/release/dmg.sh
