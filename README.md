# Stash

Stash hides macOS menu bar icons behind a single chevron, so a crowded bar collapses to
one click. It targets macOS 27, where every menu bar icon-hiding app on the market
(Ice, Bartender, Hidden Bar, Dozer) stopped working.

<p>
  <img src="docs/images/stash-demo.gif" alt="A crowded macOS menu bar collapsing behind Stash's chevron and reappearing" width="590">
</p>

*Click the chevron and the icons you don't need disappear; click again and they're back.*

## Why this exists

Until macOS 26, the system drew every menu bar item as its own tiny window. That was
never a published API, but it was stable enough to build on, and an entire category of
app did: Ice, Bartender, Hidden Bar and Dozer all worked by enumerating those windows,
screenshotting them, and moving them off-screen or back.

macOS 27 draws the whole menu bar as a **single window**. There is nothing left to
enumerate. Two things broke as a direct result:

- The classic fallback — inflate a spacer item until everything to its left falls off
  the edge of the screen — no longer works either. A status item whose backing window
  crosses half the screen's width gets **dropped from the layout**, not clamped, so the
  trick that used to hide icons stops taking effect at exactly the wrong width.
- The new menu bar engine maintains its own idea of which status items are *supported*,
  and silently drops the rest. On the machine this was built on, the system's own
  `MenuBarAgent` process logs lines like:

  ```
  [com.apple.menubar:statusItems] Filtering out unsupported status item: com.jordanbaird.Ice
  ```

  repeated dozens of times a minute — Ice's own spacer items were being actively
  filtered out of the bar it was trying to control.

None of this is a bug in Ice, Bartender or any of the others. It's a rewrite that
removed the implementation detail their entire category depended on, and there is no
public replacement for what they used to do.

## How Stash works instead

macOS 27 does still contain a facility for hiding menu bar items: the one behind
**assessment mode**, the exam mode schools use to strip a Mac's menu bar down during a
test. It works as an allowlist — you hold an assertion listing which apps are allowed to
draw a status item, and the system simply doesn't draw anything else.

That facility lives in a private framework, `MenuBarClientCore`, behind two
undocumented classes: `MBAssessmentModeConfiguration` and `MBAssessmentModeAssertion`.
Stash `dlopen`s the framework, builds a configuration listing the running apps that
should stay visible, and activates an assertion with it. Toggling the chevron replaces
that assertion with a new one; quitting Stash invalidates it, which hands every icon
straight back.

This is a private API, not a stable contract. If Apple changes or removes it, Stash's
own chevron shows a warning triangle instead of a working toggle, and no apps get
hidden — it does not crash, and it doesn't touch anything else on the system.

## Limitations

These are limits of the underlying facility, not choices Stash made:

- **Per app, not per icon.** An app that puts up several status items goes as a whole;
  there is no way to hide just one of them.
- **No reordering.** The allowlist controls whether something is drawn, not where.
- **No second bar or panel showing the hidden icons.** The technique that made that kind
  of UI possible — enumerating and repositioning each item's own window — doesn't exist
  on macOS 27.
- **The UI is in Dutch.** ("Verbergen" = Hide, "Automatisch inklappen" = Auto-collapse,
  "Starten bij inloggen" = Start at login.) It isn't localized yet; the labels are short
  enough to follow from the screenshots.

## Install

### Homebrew (recommended)

```
brew install --cask --no-quarantine brentc22/stash/stash
```

`--no-quarantine` is required: Stash is not notarised by Apple, so without it macOS
refuses to open the app on first launch. If you left it out, clear the flag once with
`xattr -dr com.apple.quarantine /Applications/Stash.app`.

### From a release build

```
make install
open /Applications/Stash.app
```

`make install` builds a release binary, bundles it, ad-hoc code-signs it, and copies it
to `/Applications`.

**The `/Applications` location is a real requirement, not a suggestion.** Stash keeps
its own chevron visible only when it runs as the copy of `com.brentc22.Stash` that
LaunchServices resolves — in practice, the one in `/Applications`. Run the binary
straight out of `.build/` (or anywhere else) and everything else still works — the
chevron reacts to clicks, hiding and restoring other apps' icons — but the system never
draws Stash's own icon.

### From source

```
git clone https://github.com/brentc22/stash.git
cd stash
make install
```

## Requirements

- macOS 27, Apple Silicon.
- Xcode Command Line Tools with Swift 6.4. Xcode itself is not required and not used.
- **`swift test` does not work here.** Both XCTest and swift-testing fail at link time
  on a Command-Line-Tools-only setup — they need pieces that only ship inside Xcode. The
  test suite is instead a plain executable target, run with `swift run StashTests`;
  exit code 0 means every test passed. This is worth knowing before you go looking for
  why `swift test` won't even build.

## Building and testing

```
swift build            # debug build
swift run StashTests   # run the test suite (exit 0 = green)
make build              # release build
make bundle             # release build + Stash.app, ad-hoc signed
make install            # bundle + copy to /Applications
make clean              # remove .build and Stash.app
```

The debug binary built by plain `swift build`/`swift run` has no app bundle, so
`UserDefaults.standard` never sees Stash's `com.brentc22.Stash` domain and its own chevron
never renders (see Install, above). That's expected — use `make install` when you want
to see the real thing running.

## Settings

Right-click the chevron for "Instellingen…" (Settings): a checklist of every app that
has ever shown a status item, an auto-collapse delay, and a "Starten bij inloggen"
(start at login) toggle backed by `SMAppService`.

<p>
  <img src="docs/images/settings-window.png" alt="Stash's settings window, listing known apps with checkboxes plus auto-collapse and login-item controls" width="420">
</p>

## License

MIT. See [LICENSE](LICENSE).

## Contributing

This has been built and tested on exactly one Mac, on one build of macOS 27.0
(26A428). If you hit different behavior — a different `LSMinimumSystemVersion` cutoff,
a Mac where the private framework isn't present, a build where the allowlist behaves
differently — an issue with your macOS build number and what you saw is the most useful
thing you can send.
