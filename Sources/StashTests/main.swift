import AppKit
import Foundation
import MenuBarShim
import StashCore

print("Stash tests")

T.test("shim ziet MenuBarClientCore") {
    T.expect(STMenuBarShim.isAvailable(),
             "MenuBarClientCore moet laadbaar zijn op macOS 27")
}

/// Applies an allowlist and returns the count MenuBarAgent logged for that specific
/// apply. `since` is captured immediately before the call so the probe can prove the
/// reading it returns was caused by this apply, not a stale one left over from a
/// previous test.
func applyAndCount(_ restriction: MenuBarRestriction, _ allowed: Set<String>) -> Int? {
    let since = Date()
    restriction.apply(allowing: allowed)
    return MenuBarProbe.lastTrailingItemsCount(since: since)
}

let allRunning = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))

T.test("lege allowlist levert minder items op dan een volle") {
    let restriction = MenuBarRestriction()
    guard restriction.isAvailable else {
        T.expect(false, "restriction moet beschikbaar zijn op macOS 27")
        return
    }

    // Narrow first, then wide: the natural pre-test state is never already "just
    // system items", so this transition is guaranteed to be a real, observable one.
    // Measuring wide first risks landing on a state that already looks like
    // "everything visible" — no redraw happens, and the log oracle waits forever for
    // an event that was never coming. Measured on 2026-09-22: applying the full
    // allowlist as the very first call of the whole run produced no new log line at
    // all for over 40 seconds, because the natural bar already showed everything.
    let narrow = applyAndCount(restriction, [])
    let wide = applyAndCount(restriction, allRunning)

    guard let wide, let narrow else {
        T.expect(false, "log gaf geen telling terug — draait MenuBarAgent?")
        return
    }
    T.expect(narrow < wide, "lege allowlist moet minder items opleveren: \(narrow) < \(wide)")
}

T.test("vervangen laat geen oude assertion achter") {
    let restriction = MenuBarRestriction()

    // Safe to start with collapsed here: the previous test's last measurement (wide)
    // already confirmed the bar had settled into an "everything visible" state before
    // returning, so this apply([]) is a real, observable transition, not a race against
    // an unconfirmed prior change.
    let collapsed = applyAndCount(restriction, [])
    let expanded = applyAndCount(restriction, allRunning)

    guard let collapsed, let expanded else {
        T.expect(false, "log gaf geen telling terug")
        return
    }
    T.expect(expanded > collapsed,
             "na vervangen moet de balk weer vol zijn: \(expanded) > \(collapsed)")
}

T.test("clear zet de balk volledig terug") {
    let restriction = MenuBarRestriction()

    // The baseline must come from `clear()`'s own resulting count, not from applying
    // `allRunning` and reading that back: `allRunning` is our own approximation of what's
    // visible, built from NSWorkspace bundle ids. A helper process with a real menu bar
    // item but no bundle id NSWorkspace reports would be invisible to that allowlist,
    // silently missing from a `wide`-based baseline, and then reappear after the real
    // `clear()` below — failing this test for a correct implementation. `clear()` asks
    // the OS to draw everything, so its own count is the true unrestricted baseline.
    // A narrow allowlist is applied first purely to force a state change, so the
    // `clear()` that follows actually produces a fresh, observable log line.
    _ = applyAndCount(restriction, [])
    let baselineSince = Date()
    restriction.clear()
    let baseline = MenuBarProbe.lastTrailingItemsCount(since: baselineSince)

    _ = applyAndCount(restriction, [])
    let restoredSince = Date()
    restriction.clear()
    let restored = MenuBarProbe.lastTrailingItemsCount(since: restoredSince)

    guard let baseline, let restored else {
        T.expect(false, "log gaf geen telling terug")
        return
    }
    T.equal(restored, baseline, "na clear:")
}

T.finish()
