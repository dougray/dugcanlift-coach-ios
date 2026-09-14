SCHEME      := Coach
BUNDLE_ID   := com.dugcanlift.coach
SIM         := iPhone 17 Pro
DERIVED     := .build/DerivedData
APP         := $(DERIVED)/Build/Products/Debug-iphonesimulator/Coach.app
DEST        := platform=iOS Simulator,name=$(SIM)

# --- Real hardware -----------------------------------------------------------
#
# Its own derived-data path: device and simulator slices differ, and sharing
# one path makes every switch a full rebuild.
DEVICE_DERIVED := .build/DerivedData-device
DEVICE_APP     := $(DEVICE_DERIVED)/Build/Products/Debug-iphoneos/Coach.app

# The first connected iPhone or iPad. Override for a specific one:
#   make device DEVICE=901D197D-95D6-5FA6-B188-6C827D7B0109
# A paired-but-not-connected device reads "available (paired)" rather than
# "connected" and is skipped.
DEVICE ?= $(shell xcrun devicectl list devices 2>/dev/null | awk '/ connected / && /iPhone|iPad/ {print $$3; exit}')

# Unlike lift-ios, this app needs no entitlements override to build for a
# device on a free Apple Personal Team: it declares no entitlements at all.
# That is not an oversight. A personal team cannot sign Associated Domains,
# which is why Coach ingests plan links by paste rather than by Universal Link
# -- see PasteLinkView and SHARE-FORMAT.md. If a capability is ever added here,
# expect the device build to start failing and see lift-ios's Makefile for the
# CODE_SIGN_ENTITLEMENTS pattern that works around it.

# xcbeautify makes xcodebuild output readable. brew install xcbeautify
# Falls back to raw output if it isn't installed.
PRETTY := $(shell command -v xcbeautify 2>/dev/null || echo cat)

.PHONY: help project build test run clean sim logs reset-sim doctor devices device device-build

help:
	@grep -E '^[a-z-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

project: ## Regenerate Coach.xcodeproj from project.yml
	xcodegen generate

build: project ## Build for the simulator
	@set -o pipefail && xcodebuild \
		-project Coach.xcodeproj \
		-scheme $(SCHEME) \
		-destination '$(DEST)' \
		-derivedDataPath $(DERIVED) \
		build | $(PRETTY)

test: project ## Run unit tests
	@set -o pipefail && xcodebuild \
		-project Coach.xcodeproj \
		-scheme $(SCHEME) \
		-destination '$(DEST)' \
		-derivedDataPath $(DERIVED) \
		test | $(PRETTY)

sim: ## Boot the simulator and open it
	@xcrun simctl boot "$(SIM)" 2>/dev/null || true
	@open -a Simulator

run: build sim ## Build, install and launch on the simulator
	@xcrun simctl install booted "$(APP)"
	@xcrun simctl launch booted $(BUNDLE_ID)

devices: ## List connected iPhones and iPads
	@xcrun devicectl list devices

device-build: project ## Build for a connected device (no install)
	@test -n "$(DEVICE)" || { echo "No connected iPhone or iPad. Plug one in, unlock it, and trust this Mac. 'make devices' lists what is visible."; exit 1; }
	@set -o pipefail && xcodebuild \
		-project Coach.xcodeproj \
		-scheme $(SCHEME) \
		-destination 'platform=iOS,id=$(DEVICE)' \
		-derivedDataPath $(DEVICE_DERIVED) \
		-allowProvisioningUpdates \
		build | $(PRETTY)

device: device-build ## Build, install and launch on a connected device
	@echo "Installing on $(DEVICE)..."
	@xcrun devicectl device install app --device $(DEVICE) "$(DEVICE_APP)"
	@xcrun devicectl device process launch --device $(DEVICE) --terminate-existing $(BUNDLE_ID)

logs: ## Tail the app's log output
	@xcrun simctl spawn booted log stream \
		--predicate 'subsystem CONTAINS "$(BUNDLE_ID)"' \
		--level debug

reset-sim: ## Wipe simulator data — the reliable way to test a fresh install
	@xcrun simctl uninstall booted $(BUNDLE_ID) 2>/dev/null || true

clean: ## Remove build artifacts and the generated project
	@rm -rf $(DERIVED) $(DEVICE_DERIVED) Coach.xcodeproj
	@echo "Cleaned. Run 'make project' to regenerate."

doctor: ## Check that required tooling is present
	@command -v xcodegen  >/dev/null && echo "xcodegen    ok" || echo "xcodegen    MISSING  → brew install xcodegen"
	@command -v xcbeautify >/dev/null && echo "xcbeautify  ok" || echo "xcbeautify  missing  → brew install xcbeautify (optional)"
	@command -v claude    >/dev/null && echo "claude      ok" || echo "claude      MISSING  → curl -fsSL https://claude.ai/install.sh | bash"
	@xcodebuild -version | head -1
	@xcrun simctl list devices available | grep -q "$(SIM)" && echo "simulator   ok ($(SIM))" || echo "simulator   '$(SIM)' not found — set SIM in Makefile"
	@test -n "$(DEVICE)" && echo "device      ok ($(DEVICE))" || echo "device      none connected — 'make device' needs one"
