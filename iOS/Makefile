.PHONY: help setup project lint test build clean

# Default destination for xcodebuild test/build commands.
# Override with `make test DEST='platform=iOS Simulator,name=iPhone 17'`.
DEST ?= platform=iOS Simulator,name=iPhone 17

help: ## Show this help.
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

setup: ## First-time developer setup: brew bundle, generate Xcode project.
	@command -v brew >/dev/null 2>&1 || { echo "Homebrew is required. Install from https://brew.sh"; exit 1; }
	brew bundle --file=Brewfile
	$(MAKE) project
	@echo
	@echo "Setup complete. Open iOS/LakeloomApp.xcodeproj in Xcode 26+ to build."

project: ## Regenerate the Xcode project from project.yml.
	xcodegen generate

lint: ## Run SwiftLint and swift-format on the App/AppTests/AppUITests trees.
	./BuildScripts/lint.sh

test: ## Run unit + UI tests on a simulator (override DEST=...).
	xcodebuild test \
	  -project LakeloomApp.xcodeproj \
	  -scheme LakeloomApp \
	  -destination '$(DEST)' \
	  -enableCodeCoverage YES \
	  | xcbeautify

build: ## Debug build for the simulator (override DEST=...).
	xcodebuild build \
	  -project LakeloomApp.xcodeproj \
	  -scheme LakeloomApp \
	  -configuration Debug \
	  -destination '$(DEST)' \
	  | xcbeautify

clean: ## Remove the generated Xcode project and SPM build artifacts. Sources and resources are preserved.
	rm -rf LakeloomApp.xcodeproj
	rm -rf .build
	rm -rf ~/Library/Developer/Xcode/DerivedData/LakeloomApp-*
