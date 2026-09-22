APP      := Stash
BUNDLE   := $(APP).app
CONTENTS := $(BUNDLE)/Contents

.PHONY: all build bundle sign install run clean test

all: bundle

build:
	swift build -c release

bundle: build
	rm -rf $(BUNDLE)
	mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources
	cp .build/release/$(APP) $(CONTENTS)/MacOS/$(APP)
	cp Resources/Info.plist $(CONTENTS)/Info.plist
	-cp Resources/$(APP).icns $(CONTENTS)/Resources/$(APP).icns
	$(MAKE) sign

sign:
	codesign --force --deep --sign - $(BUNDLE)
	codesign --verify --verbose $(BUNDLE)

install: bundle
	rm -rf /Applications/$(BUNDLE)
	cp -R $(BUNDLE) /Applications/
	@echo "geinstalleerd in /Applications/$(BUNDLE)"

run: bundle
	open $(BUNDLE)

test:
	swift run StashTests

clean:
	rm -rf .build $(BUNDLE)
