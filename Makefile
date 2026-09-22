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
	@pkill -x $(APP) 2>/dev/null || true
	@for i in 1 2 3 4 5 6 7 8 9 10; do pgrep -x $(APP) >/dev/null || break; sleep 0.2; done
	rm -rf /Applications/$(BUNDLE)
	cp -R $(BUNDLE) /Applications/
	@echo "installed in /Applications/$(BUNDLE)"

run: install
	open /Applications/$(BUNDLE)

test:
	swift run StashTests

clean:
	rm -rf .build $(BUNDLE)
