# Stash

A menu bar hider for **macOS 27** — the release that broke every existing one.

> **Status: design only.** The specification and the implementation plan are finished and
> measured against a real machine. No code has been written yet. This repository is published
> mainly for the research in [`docs/`](docs/): if you maintain a menu bar utility, section 2
> of the design is probably what you are looking for.

## Why the existing tools stopped working

Until macOS 26, the system drew every status item as its own window. That was never a public
API, but it gave the whole category — Ice, Bartender, Hidden Bar, Dozer — something to hold on
to: you could enumerate those windows through `CGWindowList`, capture them with ScreenCaptureKit
and push them off screen.

macOS 27 draws the menu bar as **one window**. There is nothing left to enumerate. Two further
changes make the classic workarounds fail outright:

- An `NSStatusItem` whose backing window reaches **half the screen width** is *dropped* from the
  layout instead of being clamped. The old trick — inflate a spacer item until everything to its
  left falls off screen — no longer pushes anything anywhere. Measured on a 1728pt display:
  848pt hides, 849pt does not (848 + 16pt of chrome = 864 = 1728 / 2).
- The new engine has a notion of *supported* status items and refuses the rest. Straight out of
  `MenuBarAgent` on this machine:

  ```
  [com.apple.menubar:statusItems] Filtering out unsupported status item: com.jordanbaird.Ice
  ```

  34 times in a single minute. The spacer items are actively filtered out of the bar.

macOS 27 does ship its own overflow chevron (`•••`), but it decides for itself what collapses.
There is no supported way to choose per app what gets hidden.

## What does still work

macOS 27 contains the facility behind **assessment mode** — the exam mode schools use to strip
the menu bar bare. It behaves as an **allowlist**: you hold an assertion listing which apps may
remain visible, and the system simply does not draw the rest.

Stash is built on that. It keeps one assertion alive permanently; collapsing and expanding is
nothing more than replacing that assertion with one carrying a different allowlist.

Read [`docs/superpowers/specs/2026-09-22-stash-design.md`](docs/superpowers/specs/2026-09-22-stash-design.md)
for the full reasoning, the probe output it is based on, and the pitfalls (an `NSSet` where the
API demands an `NSArray` throws; an `allowedSystemItems` range of `0...63` silently kills Screen
Mirroring).

The task-by-task implementation plan lives in
[`docs/superpowers/plans/2026-09-22-stash.md`](docs/superpowers/plans/2026-09-22-stash.md).

## Planned architecture

| Layer | Responsibility |
|---|---|
| `MenuBarShim` (Objective-C) | wraps the private `MenuBarClientCore` framework via `dlopen` + runtime lookup |
| `StashCore` (Swift) | pure logic: app inventory − hidden set → allowlist; persistence; assertion lifecycle |
| `Stash` (AppKit + SwiftUI) | chevron status item, settings window, accessory app |

Swift 6.4, SwiftPM, no Xcode project.

## Caveats

This relies on a **private framework**. It can break with any macOS update, and an app built on
it cannot ship on the Mac App Store. That is a deliberate trade-off: the supported alternative
is having no control over the menu bar at all.

The documents under `docs/` are written in Dutch.

## License

MIT — see [LICENSE](LICENSE).
