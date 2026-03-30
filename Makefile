PROJECT = Veil.xcodeproj
SCHEME = Veil
DEST = platform=macOS
DERIVED = .build
APP = $(DERIVED)/Build/Products/Release/Veil.app
INSTALL_DIR = /Applications

XCODEBUILD = xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination '$(DEST)'

.PHONY: build debug test clean install

build:
	$(XCODEBUILD) -configuration Release -derivedDataPath $(DERIVED) -quiet
	@echo "Built: $(APP)"

debug:
	$(XCODEBUILD) -configuration Debug -derivedDataPath $(DERIVED) -quiet

test:
	$(XCODEBUILD) -only-testing:VeilTests CODE_SIGNING_ALLOWED=NO test

clean:
	$(XCODEBUILD) clean -quiet
	rm -rf $(DERIVED)

install: build
	rsync -a "$(APP)/" "$(INSTALL_DIR)/Veil.app/"
	@echo "Installed to $(INSTALL_DIR)/Veil.app"
