import AppKit
import Foundation
import MenuBarShim
import StashCore

print("Stash tests")

T.test("shim ziet MenuBarClientCore") {
    T.expect(STMenuBarShim.isAvailable(),
             "MenuBarClientCore moet laadbaar zijn op macOS 27")
}

/// Applies an allowlist, waits for the bar to redraw, and returns the count
/// MenuBarAgent logged. 2 seconds is generous: in the 2026-09-22 probe the new
/// count showed up in the log within ~200 ms.
func applyAndCount(_ restriction: MenuBarRestriction, _ allowed: Set<String>) -> Int? {
    restriction.apply(allowing: allowed)
    Thread.sleep(forTimeInterval: 2)
    return MenuBarProbe.lastTrailingItemsCount()
}

let allRunning = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))

T.test("lege allowlist levert minder items op dan een volle") {
    let restriction = MenuBarRestriction()
    guard restriction.isAvailable else {
        T.expect(false, "restriction moet beschikbaar zijn op macOS 27")
        return
    }

    let wide = applyAndCount(restriction, allRunning)
    let narrow = applyAndCount(restriction, [])

    restriction.clear()
    Thread.sleep(forTimeInterval: 2)

    guard let wide, let narrow else {
        T.expect(false, "log gaf geen telling terug — draait MenuBarAgent?")
        return
    }
    T.expect(narrow < wide, "lege allowlist moet minder items opleveren: \(narrow) < \(wide)")
}

T.test("vervangen laat geen oude assertion achter") {
    let restriction = MenuBarRestriction()

    let collapsed = applyAndCount(restriction, [])
    let expanded = applyAndCount(restriction, allRunning)

    restriction.clear()
    Thread.sleep(forTimeInterval: 2)

    guard let collapsed, let expanded else {
        T.expect(false, "log gaf geen telling terug")
        return
    }
    T.expect(expanded > collapsed,
             "na vervangen moet de balk weer vol zijn: \(expanded) > \(collapsed)")
}

T.test("clear zet de balk volledig terug") {
    let restriction = MenuBarRestriction()

    let baseline = applyAndCount(restriction, allRunning)
    _ = applyAndCount(restriction, [])

    restriction.clear()
    Thread.sleep(forTimeInterval: 2)
    let restored = MenuBarProbe.lastTrailingItemsCount()

    guard let baseline, let restored else {
        T.expect(false, "log gaf geen telling terug")
        return
    }
    T.equal(restored, baseline, "na clear:")
}

T.finish()
