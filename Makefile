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

# Sign with a stable identity when one exists, ad-hoc otherwise.
# An ad-hoc signature makes the designated requirement the binary's own hash,
# so every rebuild is a new identity to macOS and the Accessibility grant stops
# applying. Resources/make-signing-cert.sh creates a local certificate that
# keeps the identity stable. Override with STASH_SIGN_IDENTITY.
sign:
	@id="$${STASH_SIGN_IDENTITY:-}"; \
	if [ -z "$$id" ] && security find-identity -p codesigning 2>/dev/null | grep -q "Stash Self-Signed"; then \
		id="Stash Self-Signed"; \
	fi; \
	if [ -z "$$id" ]; then \
		id="-"; \
		echo "signing ad-hoc — the Accessibility permission will not survive the next build"; \
		echo "run Resources/make-signing-cert.sh once to keep it"; \
	else \
		echo "signing with identity: $$id"; \
	fi; \
	codesign --force --deep --sign "$$id" $(BUNDLE)
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
