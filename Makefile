PROJECT    := palium.xcodeproj
SCHEME     := palium
CONFIG     := Release
BUILD_DIR  := ./build
ARCHIVE    := $(BUILD_DIR)/palium.xcarchive
APP        := $(ARCHIVE)/Products/Applications/palium.app
ZIP        := $(BUILD_DIR)/palium.zip

PRODUCTS   := $(BUILD_DIR)/DerivedData/Build/Products/Release
RELEASE_APP := $(PRODUCTS)/palium.app

# Version stamped into the built app. Sparkle compares CFBundleVersion (BUILD)
# to decide whether an update is newer, so it must increase monotonically;
# commit count does that for free. Override either from CI.
VERSION ?= $(patsubst v%,%,$(shell git describe --tags --abbrev=0 2>/dev/null))
BUILD   ?= $(shell git rev-list --count HEAD 2>/dev/null)

VERSION_FLAGS := $(if $(VERSION),MARKETING_VERSION=$(VERSION)) \
                 $(if $(BUILD),CURRENT_PROJECT_VERSION=$(BUILD))

.PHONY: archive zip clean test test-all build-unsigned dmg zip-app release-artifacts version

version:
	@echo "MARKETING_VERSION=$(VERSION) CURRENT_PROJECT_VERSION=$(BUILD)"

archive:
	xcodebuild -project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-archivePath $(ARCHIVE) \
		$(VERSION_FLAGS) \
		archive

zip: archive
	cd $(ARCHIVE)/Products/Applications && zip -r -y $(CURDIR)/$(ZIP) palium.app
	@echo "\nReady for release: $(ZIP)"

build-unsigned:
	xcodebuild -project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-derivedDataPath $(BUILD_DIR)/DerivedData \
		CODE_SIGN_IDENTITY=- \
		$(VERSION_FLAGS) \
		build

test:
	xcodebuild -project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Debug \
		CODE_SIGN_IDENTITY=- \
		-skip-testing:paliumUITests \
		test

test-all:
	xcodebuild -project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration Debug \
		CODE_SIGN_IDENTITY=- \
		test

dmg:
	create-dmg $(RELEASE_APP) --dmg-title=Palium --no-version-in-filename $(if $(CI),--no-code-sign)
	@mv -f palium.dmg Palium.dmg 2>/dev/null || true

# Sparkle's update enclosure. ditto (not zip) so symlinks inside
# Sparkle.framework and the code signature survive the round trip.
zip-app:
	@rm -f Palium.zip
	ditto -c -k --sequesterRsrc --keepParent $(RELEASE_APP) Palium.zip
	@echo "Ready for Sparkle: Palium.zip"

release-artifacts: build-unsigned zip-app dmg

clean:
	rm -rf $(BUILD_DIR) Palium.zip Palium.dmg
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean
