PROJECT = Veil.xcodeproj
SCHEME = Veil
DEST = platform=macOS
DERIVED = .build
APP = $(DERIVED)/Build/Products/Release/Veil.app
INSTALL_DIR = /Applications
UNIVERSAL = ONLY_ACTIVE_ARCH=NO
NO_PROFILING = CLANG_ENABLE_CODE_COVERAGE=NO CLANG_COVERAGE_MAPPING=NO

XCODEBUILD = xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)'

.PHONY: build debug test clean install zip release lsp

build:
	$(XCODEBUILD) -configuration Release -derivedDataPath $(DERIVED) $(UNIVERSAL) $(NO_PROFILING) -quiet
	@echo "Built: $(APP)"

debug:
	$(XCODEBUILD) -configuration Debug -derivedDataPath $(DERIVED) -quiet

test:
	$(XCODEBUILD) -derivedDataPath $(DERIVED) -only-testing:VeilTests CODE_SIGNING_ALLOWED=NO test

clean:
	$(XCODEBUILD) clean -quiet
	rm -rf $(DERIVED)

install: build
	rsync -a "$(APP)/" "$(INSTALL_DIR)/Veil.app/"
	@echo "Installed to $(INSTALL_DIR)/Veil.app"

zip: build
	ditto -c -k --keepParent "$(APP)" Veil.zip
	@echo "Packaged: Veil.zip"

lsp:
	xcode-build-server config -project $(PROJECT) -scheme $(SCHEME) --build_root $(DERIVED)

# Usage: make release V=0.2
release:
ifndef V
	$(error Usage: make release V=x.y)
endif
	sed -i '' 's/MARKETING_VERSION = [^;]*/MARKETING_VERSION = $(V)/' $(PROJECT)/project.pbxproj
	git add $(PROJECT)/project.pbxproj
	git commit -m "Release v$(V)"
	@echo "Version set to $(V) and committed. Now tag and push."
