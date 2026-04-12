PROJECT    := palium.xcodeproj
SCHEME     := palium
CONFIG     := Release
BUILD_DIR  := ./build
ARCHIVE    := $(BUILD_DIR)/palium.xcarchive
APP        := $(ARCHIVE)/Products/Applications/palium.app
ZIP        := $(BUILD_DIR)/palium.zip

.PHONY: archive zip clean test build-unsigned

archive:
	xcodebuild -project $(PROJECT) \
		-scheme $(SCHEME) \
		-configuration $(CONFIG) \
		-archivePath $(ARCHIVE) \
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
	create-dmg $(BUILD_DIR)/DerivedData/Build/Products/Release/palium.app --dmg-title=Palium --no-version-in-filename $(if $(CI),--no-code-sign)

clean:
	rm -rf $(BUILD_DIR)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean
