# ~/Documents is iCloud-synced, which adds xattrs that break codesign; keep build products elsewhere.
BUILD_DIR ?= $(HOME)/Library/Caches/ComplexCommute-build
SIMULATOR ?= iPhone 17 Pro

.PHONY: project test build

project:
	xcodegen generate

test:
	swift test --package-path Packages/CommuteKit --scratch-path $(BUILD_DIR)/spm

build: project
	xcodebuild -project ComplexCommute.xcodeproj -scheme ComplexCommute \
		-destination 'platform=iOS Simulator,name=$(SIMULATOR)' \
		-derivedDataPath $(BUILD_DIR)/xcode build
