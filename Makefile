SCHEME      := Coach
BUNDLE_ID   := com.dugcanlift.coach
# The simulator to build, test and run on. Detected rather than pinned: a
# hard-coded model is wrong the moment Xcode ships a new one or this checkout
# moves to another Mac, and the failure -- "Unable to find a device matching
# the provided destination specifier" -- names the destination, not the cause.
# A booted iPhone wins, because it is already on screen and needs no boot;
# otherwise the first available iPhone. Override for a specific model:
#   make test SIM="iPhone 18 Pro"
#
# LPAREN carries the "(" that separates a simulator's name from its UDID: make
# counts parentheses while it parses $(shell ...), so a bare one inside the
# awk program ends the call early ("unterminated call to function `shell'").
LPAREN      := (
SIM         := $(shell xcrun simctl list devices available 2>/dev/null | awk '/^ +iPhone/ { n = substr($$0, 1, index($$0, " $(LPAREN)") - 1); sub(/^ +/, "", n); if (!f) f = n; if ($$0 ~ /Booted/) { print n; d = 1; exit } } END { if (!d) print f }')
DERIVED     := .build/DerivedData
APP         := $(DERIVED)/Build/Products/Debug-iphonesimulator/Coach.app
DEST        := platform=iOS Simulator,name=$(SIM)

# --- Real hardware -----------------------------------------------------------
#
# Its own derived-data path: device and simulator slices differ, and sharing
# one path makes every switch a full rebuild.
DEVICE_DERIVED := .build/DerivedData-device
DEVICE_APP     := $(DEVICE_DERIVED)/Build/Products/Debug-iphoneos/Coach.app

# The first iPhone or iPad devicectl knows about. Override for a specific one:
#   make device DEVICE=901D197D-95D6-5FA6-B188-6C827D7B0109
#
# Deliberately NOT filtered on State. This used to require "connected", on the
# assumption that "available (paired)" meant unreachable. It does not: installs
# succeed against a device in that state routinely, and the stricter filter
# refused to even try -- so every install had to pass DEVICE= by hand, which
# defeats the target. A device that really is unreachable fails at the install
# with a clear CoreDevice error, which is better than a build that declines to
# start.
DEVICE ?= $(shell xcrun devicectl list devices 2>/dev/null | awk '/iPhone|iPad/ { for (i = 1; i <= NF; i++) if ($$i ~ /^[0-9A-Fa-f]{8}-[0-9A-Fa-f-]+$$/) { print $$i; exit } }')

# Unlike lift-ios, this app needs no entitlements override to build for a
# device on a free Apple Personal Team. Its only capability is App Groups
# (group.com.dugcanlift.coach, the share extension's hand-off to the app), which
# a personal team can sign -- lift-ios's Lift-free.entitlements keeps its own
# App Group and drops only Associated Domains. That is the capability a
# personal team cannot sign, and why Coach ingests links by paste, by its
# dugcanliftcoach:// scheme and by share extension rather than by Universal
# Link. If a capability a free team can't sign is ever added here, expect the
# device build to fail and see lift-ios's Makefile for the
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

sim: ## Boot the simulator and open its window
	@xcrun simctl boot "$(SIM)" 2>/dev/null || true
# Xcode 27 removed Simulator.app and replaced it with DeviceHub.app
# (com.apple.dt.Devices), which also moved to Contents/Applications. Try both
# and never fail the target over it: `simctl install` and `launch` work against
# a booted device whether or not any window is showing it, so a missing window
# app must not stop `make run`.
	@open -a Simulator 2>/dev/null \
		|| open -b com.apple.dt.Devices 2>/dev/null \
		|| echo "Booted $(SIM). No simulator window app found; the app still installs and launches."

run: build sim ## Build, install and launch on the simulator
	@xcrun simctl install booted "$(APP)"
	@xcrun simctl launch booted $(BUNDLE_ID)

devices: ## List connected iPhones and iPads
	@xcrun devicectl list devices

device-build: project ## Build for a connected device (no install)
	@test -n "$(DEVICE)" || { echo "No iPhone or iPad visible at all. Plug one in, unlock it, and trust this Mac. 'make devices' lists what devicectl can see."; exit 1; }
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
