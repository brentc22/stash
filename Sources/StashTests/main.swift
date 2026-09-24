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
        first.setVisibility(.hidden, for: "com.a")
        first.setVisibility(.hidden, for: "com.b")
        first.setVisibility(.visible, for: "com.a")

        let second = HiddenSet(defaults: defaults)
        T.equal(second.bundleIDs, ["com.b"])
        T.equal(second.visibility(for: "com.b"), .hidden, "com.b:")
        T.equal(second.visibility(for: "com.a"), .visible, "com.a is weer getoond:")
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

T.test("inventory reageert op het starten en stoppen van apps") {
    withTestDefaults { defaults in
        let inventory = AppInventory(defaults: defaults)
        var callCount = 0
        inventory.onChange = { callCount += 1 }
        inventory.start()

        // A real launch: KVO on runningApplications can't be faked with a posted notification.
        // -g -j: in the background and hidden, so the test doesn't steal focus.
        let app = "/System/Applications/Calculator.app"
        let wasRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.calculator").isEmpty
        _ = Process.launchedProcess(launchPath: "/usr/bin/open", arguments: ["-g", "-j", app])
        let deadline = Date().addingTimeInterval(5)
        while callCount == 0, Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.1)) }
        T.expect(wasRunning || callCount > 0, "start() moet onChange aanroepen als een app start")

        inventory.stop()
        let before = callCount
        if !wasRunning {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.calculator").forEach { $0.terminate() }
            RunLoop.current.run(until: Date().addingTimeInterval(1))
        }
        T.equal(callCount, before, "na stop() hoort onChange niet meer aan te roepen:")
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

T.test("alle vertragingen hebben een Nederlands label") {
    for delay in CollapseDelay.allCases {
        T.expect(!delay.label.isEmpty, "\(delay) mist een label")
    }
    T.equal(CollapseDelay.never.label, "Nooit")
    T.equal(CollapseDelay.after10.label, "Na 10 seconden")
}

T.test("zoekveld filtert op naam of bundle id, hoofdletter-ongevoelig") {
    let app = KnownApp(id: "com.apple.finder", name: "Finder", isRunning: true)
    T.expect(app.matches(searchQuery: ""), "lege query moet alles tonen")
    T.expect(app.matches(searchQuery: "find"), "moet matchen op naam")
    T.expect(app.matches(searchQuery: "FIND"), "moet hoofdletter-ongevoelig matchen op naam")
    T.expect(app.matches(searchQuery: "com.apple"), "moet matchen op bundle id")
    T.expect(!app.matches(searchQuery: "safari"), "mag niet matchen op iets anders")
}

T.test("altijd verborgen app zit niet in de allowlist bij ingeklapt") {
    let result = Allowlist.compute(
        running: ["com.a", "com.b"],
        hidden: [],
        alwaysHidden: ["com.b"],
        state: .collapsed,
        ownBundleID: ownID
    )
    T.expect(!result.contains("com.b"), "com.b is altijd verborgen, hoort er niet in te zitten")
}

T.test("altijd verborgen app zit niet in de allowlist bij uitgeklapt") {
    // Dit is het verschil met `hidden` en de reden dat de feature bestaat: uitklappen
    // brengt een gewone `hidden` app terug, maar een `alwaysHidden` app nooit.
    let result = Allowlist.compute(
        running: ["com.a", "com.b"],
        hidden: [],
        alwaysHidden: ["com.b"],
        state: .expanded,
        ownBundleID: ownID
    )
    T.expect(!result.contains("com.b"),
             "com.b is altijd verborgen, hoort ook bij uitgeklapt niet terug te komen")
}

T.test("eigen bundle id zit er nog steeds in als hij altijd-verborgen is gemarkeerd") {
    let result = Allowlist.compute(
        running: ["com.a"],
        hidden: [],
        alwaysHidden: [ownID],
        state: .collapsed,
        ownBundleID: ownID
    )
    T.expect(result.contains(ownID),
             "zonder pijltje kan de gebruiker niets meer uitklappen")
}

T.test("driestand overleeft opnieuw laden uit UserDefaults") {
    withTestDefaults { defaults in
        let first = HiddenSet(defaults: defaults)
        first.setVisibility(.hidden, for: "com.a")
        first.setVisibility(.alwaysHidden, for: "com.b")

        let second = HiddenSet(defaults: defaults)
        T.equal(second.visibility(for: "com.a"), .hidden)
        T.equal(second.visibility(for: "com.b"), .alwaysHidden)
        T.equal(second.visibility(for: "com.c"), .visible, "nooit gezette apps zijn zichtbaar:")
    }
}

T.test("een app in beide sets telt als altijd-verborgen") {
    withTestDefaults { defaults in
        // Simuleert een hand-bewerkt of gemigreerd defaults-bestand waar een bundle id in
        // beide sleutels tegelijk voorkomt — de normale UI-weg zet nooit beide.
        defaults.set(["com.a"], forKey: "hiddenBundleIDs")
        defaults.set(["com.a"], forKey: "alwaysHiddenBundleIDs")

        let hiddenSet = HiddenSet(defaults: defaults)
        T.equal(hiddenSet.visibility(for: "com.a"), .alwaysHidden,
                "in beide sets moet de sterkste garantie winnen")
    }
}

T.test("sneltoets-voorkeur staat standaard uit en reist rond door UserDefaults") {
    withTestDefaults { defaults in
        let prefs = Preferences(defaults: defaults)
        T.expect(!prefs.useGlobalHotKey, "standaard uit: een app die ongevraagd een "
                 + "globale toets inpikt is onbeleefd")

        prefs.useGlobalHotKey = true
        T.expect(Preferences(defaults: defaults).useGlobalHotKey,
                 "aan-stand hoort opnieuw te laden als aan")

        prefs.useGlobalHotKey = false
        T.expect(!Preferences(defaults: defaults).useGlobalHotKey,
                 "uit-stand hoort opnieuw te laden als uit")
    }
}

T.test("showOnlyMenuBarApps staat standaard uit en reist rond door UserDefaults") {
    withTestDefaults { defaults in
        let prefs = Preferences(defaults: defaults)
        T.expect(!prefs.showOnlyMenuBarApps, "standaard uit: filteren kost een permissie "
                 + "die de gebruiker nog niet gegeven heeft")

        prefs.showOnlyMenuBarApps = true
        T.expect(Preferences(defaults: defaults).showOnlyMenuBarApps,
                  "aan-stand hoort opnieuw te laden als aan")

        prefs.showOnlyMenuBarApps = false
        T.expect(!Preferences(defaults: defaults).showOnlyMenuBarApps,
                  "uit-stand hoort opnieuw te laden als uit")
    }
}

T.test("filterfunctie met nil eigenaars-set geeft alle apps terug") {
    let apps = [
        KnownApp(id: "com.a", name: "A", isRunning: true),
        KnownApp(id: "com.b", name: "B", isRunning: true),
    ]
    let result = apps.filtered(owners: nil, query: "", filter: .all) { _ in .visible }
    T.equal(result.count, 2, "nil betekent onbekend, dus alles tonen:")
}

T.test("filterfunctie met een lege eigenaars-set geeft alle apps terug, niet nul") {
    let apps = [
        KnownApp(id: "com.a", name: "A", isRunning: true),
        KnownApp(id: "com.b", name: "B", isRunning: true),
    ]
    let result = apps.filtered(owners: [], query: "", filter: .all) { _ in .visible }
    T.equal(result.count, 2, "een lege set mag nooit de hele lijst leegmaken:")
}

T.test("filterfunctie met een gevulde eigenaars-set geeft alleen die apps terug") {
    let apps = [
        KnownApp(id: "com.a", name: "A", isRunning: true),
        KnownApp(id: "com.b", name: "B", isRunning: true),
        KnownApp(id: "com.c", name: "C", isRunning: true),
    ]
    let result = apps.filtered(owners: ["com.b"], query: "", filter: .all) { _ in .visible }
    T.equal(result.map(\.id), ["com.b"])
}

T.test("zoekterm en eigenaars-filter werken cumulatief") {
    let apps = [
        KnownApp(id: "com.raycast.macos", name: "Raycast", isRunning: true),
        KnownApp(id: "com.apple.weather.menu", name: "Weather", isRunning: true),
        KnownApp(id: "com.vorssaint.utils", name: "Utils", isRunning: true),
    ]
    let owners: Set<String> = ["com.raycast.macos", "com.apple.weather.menu"]

    // Owners alone would keep raycast + weather; adding a search query on top must
    // narrow that further, not replace it or ignore it.
    let ownersOnly = apps.filtered(owners: owners, query: "", filter: .all) { _ in .visible }
    T.equal(Set(ownersOnly.map(\.id)), ["com.raycast.macos", "com.apple.weather.menu"])

    let ownersAndQuery = apps.filtered(owners: owners, query: "ray", filter: .all) { _ in .visible }
    T.equal(ownersAndQuery.map(\.id), ["com.raycast.macos"],
            "moet cumulatief filteren, niet alleen op de zoekterm:")

    // A query matching an app outside the owners set must still exclude it.
    let excludedByOwners = apps.filtered(owners: owners, query: "utils", filter: .all) { _ in .visible }
    T.expect(excludedByOwners.isEmpty,
              "com.vorssaint.utils matcht de zoekterm maar niet de eigenaars-set")
}

T.test("lijstfilter Alles/Verborgen/Altijd filtert en combineert met de zoekterm") {
    let apps = [
        KnownApp(id: "com.a", name: "Alfa", isRunning: true),
        KnownApp(id: "com.b", name: "Bravo", isRunning: true),
        KnownApp(id: "com.c", name: "Charlie", isRunning: true),
        KnownApp(id: "com.d", name: "Bravissimo", isRunning: true),
    ]
    let states: [String: AppVisibility] = [
        "com.a": .visible,
        "com.b": .hidden,
        "com.c": .alwaysHidden,
        "com.d": .hidden,
    ]
    func visibility(_ id: String) -> AppVisibility { states[id] ?? .visible }

    T.equal(apps.filtered(owners: nil, query: "", filter: .all, visibility: visibility).count, 4,
            "Alles toont alles:")
    T.equal(apps.filtered(owners: nil, query: "", filter: .hidden, visibility: visibility)
                .map(\.id), ["com.b", "com.d"])
    T.equal(apps.filtered(owners: nil, query: "", filter: .alwaysHidden, visibility: visibility)
                .map(\.id), ["com.c"])

    // Cumulatief: de zoekterm mag het segment niet vervangen. "bra" matcht Bravo en
    // Bravissimo, allebei verborgen; met segment Altijd blijft er niets over.
    T.equal(apps.filtered(owners: nil, query: "bra", filter: .hidden, visibility: visibility)
                .map(\.id), ["com.b", "com.d"])
    T.expect(apps.filtered(owners: nil, query: "bra", filter: .alwaysHidden,
                           visibility: visibility).isEmpty,
             "Bravo/Bravissimo zijn verborgen, niet altijd-verborgen")

    // En de eigenaars-set blijft er bovenop werken.
    T.equal(apps.filtered(owners: ["com.d"], query: "bra", filter: .hidden,
                          visibility: visibility).map(\.id), ["com.d"])
}

T.test("elke lijstfilter- en zichtbaarheidsstand heeft een label, symbool en tooltip") {
    for filter in AppListFilter.allCases {
        T.expect(!filter.label.isEmpty, "\(filter) mist een label")
    }
    T.equal(AppListFilter.all.label, "Alles")
    T.equal(AppListFilter.alwaysHidden.label, "Altijd")

    for visibility in AppVisibility.allCases {
        T.expect(!visibility.symbolName.isEmpty, "\(visibility) mist een SF Symbol")
        T.expect(!visibility.hint.isEmpty, "\(visibility) mist een tooltip")
    }
    T.equal(AppVisibility.visible.symbolName, "eye")
    T.equal(AppVisibility.hidden.symbolName, "eye.slash")
    T.equal(AppVisibility.alwaysHidden.symbolName, "lock")
}

T.test("sneltoets reist als keyCode plus modifiers rond door UserDefaults") {
    withTestDefaults { defaults in
        let prefs = Preferences(defaults: defaults)
        T.expect(prefs.hotKey == nil, "zonder migratie en zonder opgeslagen waarde: geen sneltoets")

        let combo = HotKeyCombo(keyCode: 49,
                                modifiers: NSEvent.ModifierFlags([.command, .shift]).rawValue)
        prefs.hotKey = combo

        let reloaded = Preferences(defaults: defaults).hotKey
        T.equal(reloaded?.keyCode, 49)
        T.equal(reloaded?.modifiers, combo.modifiers)
        T.equal(reloaded?.displayString, "⌘⇧Spatie")

        // Wissen is iets anders dan "nog nooit gezet": na een expliciete nil mag de
        // migratie niet alsnog ⌃⌥S terugzetten.
        prefs.hotKey = nil
        T.expect(Preferences(defaults: defaults).hotKey == nil, "gewiste sneltoets blijft gewist")
    }
}

T.test("migratie neemt ⌃⌥S over als de oude vaste sneltoets aanstond") {
    withTestDefaults { defaults in
        defaults.set(true, forKey: "useGlobalHotKey")
        let migrated = Preferences(defaults: defaults).hotKey
        T.equal(migrated, HotKeyCombo.legacyDefault, "oude vaste sneltoets:")
        T.equal(migrated?.displayString, "⌥⌃S")
    }
}

T.test("een combinatie zonder modifiers wordt geweigerd") {
    let bare = HotKeyCombo(keyCode: 1, modifiers: 0)
    T.expect(!bare.isValid, "kale S mag nooit een globale sneltoets worden")
    T.expect(bare.rejectionReason != nil, "een geweigerde combinatie hoort een reden te geven")
}

T.test("alleen Shift als modifier wordt ook geweigerd") {
    let shiftOnly = HotKeyCombo(keyCode: 1, modifiers: NSEvent.ModifierFlags.shift.rawValue)
    T.expect(!shiftOnly.isValid, "⇧S is nog steeds gewoon een letter typen")
    T.expect(HotKeyCombo(keyCode: 1, modifiers: NSEvent.ModifierFlags.control.rawValue).isValid,
             "⌃S hoort wel te mogen")
    T.expect(HotKeyCombo(keyCode: 1,
                         modifiers: NSEvent.ModifierFlags([.shift, .command]).rawValue).isValid,
             "⇧⌘S hoort wel te mogen")
}

T.test("de weergavestring zet de modifiers in de vaste volgorde ⌘⌥⌃⇧ plus de toets") {
    let all = HotKeyCombo(keyCode: 1,
                          modifiers: NSEvent.ModifierFlags([.shift, .control, .option, .command]).rawValue)
    T.equal(all.displayString, "⌘⌥⌃⇧S", "vaste volgorde, ongeacht hoe hij getypt is:")

    // Caps lock en fn horen er niet in te lekken.
    let noisy = HotKeyCombo(keyCode: 1,
                            modifiers: NSEvent.ModifierFlags([.command, .capsLock, .function]).rawValue)
    T.equal(noisy.displayString, "⌘S")
    T.equal(HotKeyCombo(keyCode: 126, modifiers: NSEvent.ModifierFlags.option.rawValue).displayString,
            "⌥↑")
}

T.test("een onbekende keyCode geeft een terugvalnaam, geen lege string") {
    let name = HotKeyCombo.keyName(for: 200)
    T.expect(!name.isEmpty, "een onbekende toets mag nooit een lege naam opleveren")
    T.equal(name, "Toets 200")

    let combo = HotKeyCombo(keyCode: 200, modifiers: NSEvent.ModifierFlags.control.rawValue)
    T.equal(combo.displayString, "⌃Toets 200")
}

T.test("filter wil aan maar zonder toestemming: volledige lijst, niet leeg") {
    // Dit is precies de val waar de vorige flow in liep: de wens stond aan, de
    // toestemming was er nog niet, en het resultaat mocht nooit een lege lijst zijn.
    let owners = MenuBarOwners.effectiveOwners(wanted: true, trusted: false,
                                               swept: ["com.a"])
    T.expect(owners == nil, "zonder toestemming is de eigenaars-set onbekend, niet leeg")

    let apps = [
        KnownApp(id: "com.a", name: "A", isRunning: true),
        KnownApp(id: "com.b", name: "B", isRunning: true),
    ]
    T.equal(apps.filtered(owners: owners, query: "", filter: .all) { _ in .visible }.count, 2,
            "en onbekend betekent: alles tonen:")
}

T.test("zodra de toestemming er is werkt dezelfde wens wel, zonder tweede klik") {
    let swept: Set<String> = ["com.a"]
    // Zelfde `wanted: true` als hierboven — alleen `trusted` is gewijzigd. De wens hoeft
    // dus niet opnieuw gezet te worden nadat de gebruiker terugkomt uit Systeeminstellingen.
    T.equal(MenuBarOwners.effectiveOwners(wanted: true, trusted: true, swept: swept), swept)
    T.expect(MenuBarOwners.effectiveOwners(wanted: false, trusted: true, swept: swept) == nil,
             "uitgezet filter mag ook met toestemming niets wegfilteren")
    T.expect(MenuBarOwners.effectiveOwners(wanted: true, trusted: true, swept: nil) == nil,
             "toestemming zonder sweep is nog steeds onbekend")
}

T.test("de wens overleeft een geweigerde toestemming in UserDefaults") {
    withTestDefaults { defaults in
        let prefs = Preferences(defaults: defaults)
        prefs.showOnlyMenuBarApps = true
        // Geen enkele code mag deze wens terugzetten omdat de toestemming ontbreekt —
        // dat was de bug: de gebruiker vinkte aan, kwam terug, en het vinkje stond uit.
        T.expect(Preferences(defaults: defaults).showOnlyMenuBarApps,
                 "de wens hoort bewaard te blijven, los van de toestemming")
    }
}

T.test("een expliciete keuze ruimt een app op die in beide sets stond") {
    withTestDefaults { defaults in
        defaults.set(["com.a"], forKey: "hiddenBundleIDs")
        defaults.set(["com.a"], forKey: "alwaysHiddenBundleIDs")
        HiddenSet(defaults: defaults).setVisibility(.alwaysHidden, for: "com.a")

        let reloaded = HiddenSet(defaults: defaults)
        T.equal(reloaded.bundleIDs, [], "uit de gewone verborgen set:")
        T.equal(reloaded.alwaysHiddenBundleIDs, ["com.a"])
    }
}

// MARK: - Updates

let updateTmp = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("stash-update-tests-\(UUID().uuidString)").resolvingSymlinksInPath()

T.test("versies: tags parsen en numeriek vergelijken") {
    T.equal(AppVersion("v0.2.0")?.description, "0.2.0")
    T.equal(AppVersion("0.2")?.description, "0.2.0", "ontbrekende delen tellen als 0:")
    T.expect(AppVersion("1.10.0")! > AppVersion("1.9.9")!, "1.10.0 > 1.9.9")
    T.expect(AppVersion("0.2.0")! > AppVersion("0.1.9")!, "0.2.0 > 0.1.9")
    T.expect(AppVersion("0.1.0") == AppVersion("v0.1"), "0.1.0 == v0.1")
    T.equal(AppVersion("2.0.0-beta.1")?.description, "2.0.0", "pre-release-suffix valt weg:")
}

T.test("versies: wat geen versie is wordt geweigerd") {
    T.expect(AppVersion("latest") == nil, "latest")
    T.expect(AppVersion("1.2.3.4") == nil, "vier delen")
    T.expect(AppVersion("1..2") == nil, "leeg deel")
    T.expect(AppVersion("") == nil, "leeg")
}

func releaseJSON(tag: String, prerelease: Bool = false, assets: [String] = ["Stash-0.2.0.zip"]) -> Data {
    let list = assets.map { #"{"name":"\#($0)","browser_download_url":"https://example.com/\#($0)"}"# }
    return Data(#"""
    {"tag_name":"\#(tag)","html_url":"https://github.com/brentc22/stash/releases/tag/\#(tag)",
     "body":"- Nieuw icoon","draft":false,"prerelease":\#(prerelease),"assets":[\#(list.joined(separator: ","))],
     "author":{"login":"brentc22"}}
    """#.utf8)
}

T.test("release: GitHubs releases/latest decoderen en de zip vinden") {
    do {
        let release = try Release.decode(releaseJSON(tag: "v0.2.0", assets: ["checksums.txt", "Stash-0.2.0.zip"]))
        T.equal(release.version, AppVersion("0.2.0"))
        T.equal(release.body, "- Nieuw icoon")
        T.equal(release.zipURL(appName: "Stash")?.lastPathComponent, "Stash-0.2.0.zip")
        T.expect(release.zipURL(appName: "Portside") == nil, "de zip van een andere app is niet de onze")
    } catch {
        T.expect(false, "decode gooide \(error)")
    }
}

T.test("updatebeleid: alleen nieuwere, niet-overgeslagen, definitieve releases") {
    do {
        let current = AppVersion("0.1.0")!
        let newer = try Release.decode(releaseJSON(tag: "v0.2.0"))
        let same = try Release.decode(releaseJSON(tag: "v0.1.0"))
        let beta = try Release.decode(releaseJSON(tag: "v0.3.0", prerelease: true))
        T.expect(UpdatePolicy.shouldOffer(newer, current: current, skipped: nil, userInitiated: false), "nieuwer")
        T.expect(!UpdatePolicy.shouldOffer(same, current: current, skipped: nil, userInitiated: true), "zelfde versie")
        T.expect(!UpdatePolicy.shouldOffer(beta, current: current, skipped: nil, userInitiated: true), "prerelease")
        T.expect(!UpdatePolicy.shouldOffer(newer, current: current, skipped: "0.2.0", userInitiated: false),
                 "overgeslagen versie blijft stil bij automatische checks")
        T.expect(UpdatePolicy.shouldOffer(newer, current: current, skipped: "0.2.0", userInitiated: true),
                 "maar verschijnt als de gebruiker zelf controleert")
        T.expect(UpdatePolicy.shouldOffer(newer, current: current, skipped: "0.1.5", userInitiated: false),
                 "een oudere overgeslagen versie verbergt geen nieuwere")
    } catch {
        T.expect(false, "decode gooide \(error)")
    }
}

T.test("updatebeleid: hoogstens één keer per dag controleren") {
    let now = Date()
    T.expect(UpdatePolicy.isCheckDue(lastCheck: nil, now: now), "nog nooit gecontroleerd")
    T.expect(!UpdatePolicy.isCheckDue(lastCheck: now.addingTimeInterval(-3600), now: now), "een uur geleden")
    T.expect(UpdatePolicy.isCheckDue(lastCheck: now.addingTimeInterval(-25 * 3600), now: now), "25 uur geleden")
}

/// Builds a signed fake app and zips it the way a release zip is made.
func fakeRelease(in dir: URL, bundleID: String = "com.brentc22.Stash", version: String = "0.2.0",
                 tamper: Bool = false) throws -> URL {
    let fm = FileManager.default
    try? fm.removeItem(at: dir)
    let app = dir.appendingPathComponent("build/Stash.app")
    try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    try fm.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("Contents/MacOS/Stash").path)
    let info: NSDictionary = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version,
                              "CFBundleExecutable": "Stash", "CFBundlePackageType": "APPL"]
    info.write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
    try UpdateInstaller.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
    if tamper {
        try Data("tampered".utf8).write(to: app.appendingPathComponent("Contents/MacOS/Stash"))
    }
    let zip = dir.appendingPathComponent("Stash.zip")
    try UpdateInstaller.run("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, zip.path])
    return zip
}

let updateDir = updateTmp.appendingPathComponent("update")

func prepareError(_ zip: () throws -> URL) -> UpdateError? {
    do {
        _ = try UpdateInstaller.prepare(zip: try zip(), in: updateDir, bundleID: "com.brentc22.Stash",
                                        version: AppVersion("0.2.0")!)
        return nil
    } catch { return error as? UpdateError }
}

T.test("installer: ondertekende app met juiste id en versie wordt aanvaard") {
    do {
        let zip = try fakeRelease(in: updateDir)
        let app = try UpdateInstaller.prepare(zip: zip, in: updateDir, bundleID: "com.brentc22.Stash",
                                              version: AppVersion("0.2.0")!)
        T.equal(app.lastPathComponent, "Stash.app")
    } catch {
        T.expect(false, "prepare gooide \(error)")
    }
}

T.test("installer: andere app, andere versie of kapotte handtekening wordt geweigerd") {
    T.equal(prepareError { try fakeRelease(in: updateDir, bundleID: "com.example.Evil") },
            .wrongApp(bundleID: "com.example.Evil"))
    T.equal(prepareError { try fakeRelease(in: updateDir, version: "0.1.9") },
            .wrongVersion(found: "0.1.9", expected: "0.2.0"))
    let tampered = prepareError { try fakeRelease(in: updateDir, tamper: true) }
    if case .invalidSignature = tampered { T.expect(true, "") } else { T.expect(false, "kreeg \(String(describing: tampered))") }
}

T.test("installer: swapscript vervangt de app zodra het oude proces weg is") {
    do {
        let fm = FileManager.default
        let dir = updateTmp.appendingPathComponent("swap it's here")  // a quote in the path, on purpose
        try? fm.removeItem(at: dir)
        let installed = dir.appendingPathComponent("Applications/Stash.app")
        let fresh = dir.appendingPathComponent("work/Stash.app")
        try fm.createDirectory(at: installed, withIntermediateDirectories: true)
        try fm.createDirectory(at: fresh, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: installed.appendingPathComponent("marker"))
        try Data("new".utf8).write(to: fresh.appendingPathComponent("marker"))

        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        let script = UpdateInstaller.swapScript(pid: finished.processIdentifier, newApp: fresh,
                                                destination: installed, relaunch: false)
        try UpdateInstaller.run("/bin/sh", ["-c", script])

        T.equal(try String(contentsOf: installed.appendingPathComponent("marker"), encoding: .utf8), "new")
        T.expect(!fm.fileExists(atPath: fresh.path), "nieuwe kopie verplaatst, niet gekopieerd")
        T.expect(!fm.fileExists(atPath: dir.appendingPathComponent("work/previous.app").path), "backup opgeruimd")
        T.expect(UpdateInstaller.swapScript(pid: 1, newApp: fresh, destination: installed)
                    .contains("--args --after-update"), "herstart meldt dat er net een update was")
    } catch {
        T.expect(false, "gooide \(error)")
    }
}

try? FileManager.default.removeItem(at: updateTmp)

T.finish()
