import AppKit
import Foundation
import MenuBarShim
import StashCore

print("Stash tests")

/// Runs `body` against a throwaway `UserDefaults` suite and removes that suite again
/// afterwards, so no test ever reads what another test persisted.
func withTestDefaults(_ body: (UserDefaults) -> Void) {
    let suite = "com.brentc22.Stash.tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
        T.expect(false, "kon geen testsuite maken")
        return
    }
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    body(defaults)
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

/// The same reading for a `clear()` instead of an `apply()`, under the same
/// capture-`since`-first discipline.
func clearAndCount(_ restriction: MenuBarRestriction) -> Int? {
    let since = Date()
    restriction.clear()
    return MenuBarProbe.lastTrailingItemsCount(since: since)
}

T.test("shim ziet MenuBarClientCore") {
    T.expect(STMenuBarShim.isAvailable(),
             "MenuBarClientCore moet laadbaar zijn op macOS 27")
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
    let baseline = clearAndCount(restriction)

    _ = applyAndCount(restriction, [])
    let restored = clearAndCount(restriction)

    guard let baseline, let restored else {
        T.expect(false, "log gaf geen telling terug")
        return
    }
    T.equal(restored, baseline, "na clear:")
}

let ownID = "com.brentc22.Stash"

T.test("uitgeklapt staat alles toe") {
    let result = Allowlist.compute(
        running: ["com.a", "com.b", "com.c"],
        hidden: ["com.b"],
        state: .expanded,
        ownBundleID: ownID
    )
    T.equal(result, ["com.a", "com.b", "com.c", ownID])
}

T.test("ingeklapt laat de verborgen apps weg") {
    let result = Allowlist.compute(
        running: ["com.a", "com.b", "com.c"],
        hidden: ["com.b"],
        state: .collapsed,
        ownBundleID: ownID
    )
    T.equal(result, ["com.a", "com.c", ownID])
}

T.test("eigen bundle id zit er altijd in, ook als hij verborgen is gemarkeerd") {
    let result = Allowlist.compute(
        running: ["com.a"],
        hidden: [ownID],
        state: .collapsed,
        ownBundleID: ownID
    )
    T.expect(result.contains(ownID), "de app mag z'n eigen pijltje nooit verbergen")
}

T.test("een app die start terwijl je ingeklapt bent verdwijnt niet") {
    // This is the pitfall: the allowlist is a snapshot. If an app starts and we do not
    // recompute, it is not in the list and disappears unwanted. Recomputing with the new
    // inventory should bring it back.
    let before = Allowlist.compute(
        running: ["com.a"], hidden: ["com.b"], state: .collapsed, ownBundleID: ownID
    )
    T.expect(!before.contains("com.nieuw"), "opzet: com.nieuw draait nog niet")

    let after = Allowlist.compute(
        running: ["com.a", "com.nieuw"], hidden: ["com.b"], state: .collapsed, ownBundleID: ownID
    )
    T.expect(after.contains("com.nieuw"),
             "een nieuw gestarte app die niet verborgen is hoort zichtbaar te blijven")
}

T.test("verborgen set overleeft opnieuw laden") {
    withTestDefaults { defaults in
        let first = HiddenSet(defaults: defaults)
        first.hide("com.a")
        first.hide("com.b")
        first.show("com.a")

        let second = HiddenSet(defaults: defaults)
        T.equal(second.bundleIDs, ["com.b"])
        T.expect(second.isHidden("com.b"), "com.b hoort verborgen te zijn")
        T.expect(!second.isHidden("com.a"), "com.a is weer getoond")
    }
}

T.test("inventory ziet draaiende apps") {
    withTestDefaults { defaults in
        let inventory = AppInventory(defaults: defaults)
        T.expect(inventory.runningBundleIDs.count > 10,
                 "er draaien er meer dan 10, kreeg \(inventory.runningBundleIDs.count)")
        T.expect(inventory.runningBundleIDs.contains("com.apple.controlcenter"),
                 "Control Center draait altijd")
    }
}

T.test("inventory onthoudt apps die gestopt zijn") {
    withTestDefaults { defaults in
        defaults.set(["com.verdwenen.app": "Verdwenen App"], forKey: "knownAppNames")
        let inventory = AppInventory(defaults: defaults)

        let known = inventory.knownApps.first { $0.id == "com.verdwenen.app" }
        T.expect(known != nil, "een eerder gezien app hoort in de lijst te blijven staan")
        T.equal(known?.isRunning, false)
        T.equal(known?.name, "Verdwenen App")
    }
}

T.test("inventory meldt een wijziging") {
    withTestDefaults { defaults in
        let inventory = AppInventory(defaults: defaults)
        var called = 0
        inventory.onChange = { called += 1 }
        inventory.refresh()
        T.equal(called, 1, "refresh hoort onChange aan te roepen:")
    }
}

T.test("inventory reageert op systeemnotificaties") {
    withTestDefaults { defaults in
        let inventory = AppInventory(defaults: defaults)
        var callCount = 0
        inventory.onChange = { callCount += 1 }
        inventory.start()

        // Post didLaunchApplicationNotification manually
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didLaunchApplicationNotification,
            object: NSWorkspace.shared
        )
        // Spin the run loop to let the notification be delivered on .main
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        T.expect(callCount == 1, "start() moet onChange aanroepen na systeemnotificatie")

        // Now stop and post again
        inventory.stop()
        NSWorkspace.shared.notificationCenter.post(
            name: NSWorkspace.didLaunchApplicationNotification,
            object: NSWorkspace.shared
        )
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        T.equal(callCount, 1, "na stop() hoort onChange niet meer aan te roepen:")
    }
}

T.test("CollapseDelay rondreist door UserDefaults") {
    withTestDefaults { defaults in
        let prefs = Preferences(defaults: defaults)
        T.equal(prefs.collapseDelay, .after10, "standaard:")

        prefs.collapseDelay = .never
        T.equal(Preferences(defaults: defaults).collapseDelay, .never)

        prefs.collapseDelay = .after30
        T.equal(Preferences(defaults: defaults).collapseDelay, .after30)
    }
}

T.test("every delay has an English label") {
    for delay in CollapseDelay.allCases {
        T.expect(!delay.label.isEmpty, "\(delay) is missing a label")
    }
    T.equal(CollapseDelay.never.label, "Never")
    T.equal(CollapseDelay.after10.label, "After 10 seconds")
}

T.finish()
