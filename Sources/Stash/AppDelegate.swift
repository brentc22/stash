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
    private var hotKey: GlobalHotKey!
    private var state: BarState = .collapsed

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Single-instance guard: `make install` replaces the bundle on disk, but a
        // running instance keeps holding its assertion until it quits on its own. If
        // another process with our bundle identifier is already running, this is that
        // second copy — exit immediately instead of fighting over the status item and
        // the assessment-mode assertion.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let alreadyRunning = NSRunningApplication
            .runningApplications(withBundleIdentifier: ownBundleID)
            .contains { $0.processIdentifier != ownPID }
        if alreadyRunning {
            NSApp.terminate(nil)
            return
        }

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

        // Created before `SettingsModel` below: its `init` calls `refresh()`, which sets
        // `useGlobalHotKey` and fires that property's `didSet` — which, through
        // `onHotKeyPreferenceChanged`, reaches `syncHotKeyRegistration()`. That force-
        // unwraps `hotKey`; building it after `SettingsModel` crashed on every launch.
        hotKey = GlobalHotKey { [weak self] in self?.toggle() }

        let model = SettingsModel(
            inventory: inventory,
            hidden: hidden,
            preferences: preferences,
            onChange: { [weak self] in self?.rebuild() },
            onHotKeyPreferenceChanged: { [weak self] in self?.syncHotKeyRegistration() }
        )
        settingsWindow = SettingsWindowController(model: model)

        // Same toggle as a click on the arrow — one path, no second implementation.
        syncHotKeyRegistration()
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
            alwaysHidden: hidden.alwaysHiddenBundleIDs,
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

    /// Registers or unregisters ⌃⌥S to match `preferences.useGlobalHotKey`. Called once
    /// at launch and again every time the checkbox in settings changes.
    ///
    /// If registration fails — another app already holds the combination — this is not a
    /// crash and not a silent failure: log it and flip the preference back to off, so the
    /// checkbox never keeps claiming a hotkey that isn't actually active (the same
    /// mistake as F18 from the previous round: a checkbox asserting something untrue).
    private func syncHotKeyRegistration() {
        guard preferences.useGlobalHotKey else {
            hotKey.unregister()
            return
        }
        guard hotKey.register() else {
            NSLog("Stash: kon globale sneltoets ⌃⌥S niet registreren — "
                  + "waarschijnlijk al in gebruik door een andere app")
            preferences.useGlobalHotKey = false
            return
        }
    }

    private func quit() {
        restriction.clear()
        NSApp.terminate(nil)
    }
}
