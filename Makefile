DERIVED := build
APP := $(DERIVED)/Build/Products/Debug/Pewter.app

# Optional signing override for capture-pipeline work (see CONTRIBUTING.md):
#   make build SIGNING='CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM=YOURTEAMID'
# Command-line build settings override project.yml; env vars do not.
# Set it permanently in an untracked Makefile.local.
SIGNING ?=
-include Makefile.local

.PHONY: gen build test run format lint clean

gen:
	xcodegen generate

build: gen
	xcodebuild -project Pewter.xcodeproj -scheme Pewter -configuration Debug -derivedDataPath $(DERIVED) $(SIGNING) build

test:
	swift test --package-path Core

run: build
	open $(APP)

format:
	swiftformat .

lint:
	swiftformat --lint .

clean:
	rm -rf $(DERIVED) Pewter.xcodeproj Core/.build
