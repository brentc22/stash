import AppKit
import StashCore

let ownBundleID = "com.brentc22.Stash"

// @MainActor: every method here either touches AppKit directly (`NSApp.terminate`,
// `StatusItemController`) or is only ever called from a main-thread callback
// (app-lifecycle notifications, the button's target/action). Without this, Swift 6's
// strict concurrency checking rejects the build: `rebuild()`'s completion closure
// captures `self` and hands it to `DispatchQueue.main.async`, which the compiler treats
// as crossing an isolation boundary for a non-Sendable type unless the class itself is
// isolated. No `deinit` here, so this doesn't hit the trap that ruled out `@MainActor`
// for `AppInventory` in Task 4 (its `deinit` calls `stop()`, and `deinit` cannot be
// actor-isolated).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let restriction = MenuBarRestriction()
    private let hidden = HiddenSet()
    private let inventory = AppInventory()
    private let preferences = Preferences()
    private var statusItem: StatusItemController!
    private var collapseTimer: CollapseTimer!
    private var settingsWindow: SettingsWindowController!
    private var state: BarState = .collapsed

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(
            onToggle: { [weak self] in self?.toggle() },
            onSettings: { [weak self] in self?.showSettings() },
            onQuit: { [weak self] in self?.quit() }
        )
        statusItem.render(state: state, available: restriction.isAvailable)

        collapseTimer = CollapseTimer { [weak self] in
            guard let self, self.state == .expanded else { return }
            self.toggle()
        }

        inventory.onChange = { [weak self] in self?.rebuild() }
        inventory.start()
        rebuild()

        let model = SettingsModel(
            inventory: inventory,
            hidden: hidden,
            preferences: preferences
        ) { [weak self] in
            self?.rebuild()
        }
        settingsWindow = SettingsWindowController(model: model)
    }

    func applicationWillTerminate(_ notification: Notification) {
        restriction.clear()
    }

    func toggle() {
        state = (state == .collapsed) ? .expanded : .collapsed
        statusItem.render(state: state, available: restriction.isAvailable)
        if state == .expanded {
            collapseTimer.schedule(delay: preferences.collapseDelay)
        } else {
            collapseTimer.cancel()
        }
        rebuild()
    }

    /// Recomputes the allowlist and applies it. Called on every toggle, every app
    /// launch, and after every change to the hidden set.
    func rebuild() {
        guard restriction.isAvailable else { return }
        let allowed = Allowlist.compute(
            running: inventory.runningBundleIDs,
            hidden: hidden.bundleIDs,
            state: state,
            ownBundleID: ownBundleID
        )
        restriction.apply(allowing: allowed) { [weak self] error in
            guard let error else { return }
            NSLog("Stash: kon restrictie niet toepassen: \(error)")
            DispatchQueue.main.async {
                guard let self else { return }
                self.statusItem.render(state: self.state, available: false)
            }
        }
    }

    private func showSettings() {
        settingsWindow.show()
    }

    private func quit() {
        restriction.clear()
        NSApp.terminate(nil)
    }
}
