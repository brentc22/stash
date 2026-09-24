import AppKit
import StashCore

let ownBundleID = "com.brentc22.Stash"

// @MainActor: every method here either touches AppKit directly (`NSApp.terminate`,
// `StatusItemController`) or is only ever called from a main-thread callback
// (app-lifecycle notifications, the button's target/action). Without this, Swift 6's
// strict concurrency checking rejects the build: `rebuild()`'s completion closure
// captures `self` and hands it to `DispatchQueue.main.async`, which the compiler treats
// as crossing an isolation boundary for a non-Sendable type unless the class itself is
// isolated. No `deinit` here, so this doesn't hit the trap that rules out `@MainActor`
// for `AppInventory` (its `deinit` calls `stop()`, and `deinit` cannot be actor-isolated).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let restriction = MenuBarRestriction()
    private let hidden = HiddenSet()
    private let inventory = AppInventory()
    private let preferences = Preferences()
    private var statusItem: StatusItemController!
    private var collapseTimer: CollapseTimer!
    private var settingsWindow: SettingsWindowController!
    private var settingsModel: SettingsModel!
    private var hotKey: GlobalHotKey!
    private var state: BarState = .collapsed
    /// The allowlist last handed to `restriction`, or `nil` when none is known to be
    /// active. `rebuild()` fires on every change to the running apps — most of them
    /// helper processes that never reach the allowlist — and each `apply` builds a new
    /// system assertion, so an identical list is skipped.
    private var appliedAllowlist: Set<String>?

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

        // Created before `SettingsModel` below: the model may reach back into
        // `syncHotKeyRegistration()` while it is still being built, and that force-
        // unwraps `hotKey`; building it after `SettingsModel` crashed on every launch.
        hotKey = GlobalHotKey { [weak self] in self?.toggle() }

        let model = SettingsModel(
            inventory: inventory,
            hidden: hidden,
            preferences: preferences,
            onChange: { [weak self] in self?.rebuild() },
            onHotKeyChanged: { [weak self] in self?.syncHotKeyRegistration() ?? false }
        )
        settingsModel = model
        settingsWindow = SettingsWindowController(model: model)

        // Same toggle as a click on the arrow — one path, no second implementation.
        syncHotKeyRegistration()
    }

    /// The Accessibility permission is granted in System Settings, in another process,
    /// and macOS offers no callback for it. Becoming active again is the only signal there
    /// is that the user has been there — so re-read trust then. Without this, a user who
    /// grants the permission sees nothing change until the next launch, which is exactly
    /// where the previous flow stranded them.
    func applicationDidBecomeActive(_ notification: Notification) {
        settingsModel?.refreshTrust()
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
        guard allowed != appliedAllowlist else { return }
        appliedAllowlist = allowed
        restriction.apply(allowing: allowed) { [weak self] error in
            guard let error else { return }
            NSLog("Stash: kon restrictie niet toepassen: \(error)")
            DispatchQueue.main.async {
                guard let self else { return }
                // Unknown what is active now, so the next rebuild must apply again.
                self.appliedAllowlist = nil
                self.statusItem.render(state: self.state, available: false)
            }
        }
    }

    private func showSettings() {
        settingsWindow.show()
    }

    /// Registers or unregisters the shortcut to match `preferences.hotKey`. Called once
    /// at launch and again every time the recorder in settings stores a new combination.
    ///
    /// Returns whether the shortcut is now genuinely in the state the preference claims.
    /// `false` means Carbon refused the combination — another app already holds it — and
    /// the caller must not let the recorder field keep showing it. Not a crash, not a
    /// silent failure: the `OSStatus` is logged, so a control never asserts something
    /// untrue.
    @discardableResult
    private func syncHotKeyRegistration() -> Bool {
        guard let combo = preferences.hotKey else {
            hotKey.unregister()
            return true
        }
        guard hotKey.register(combo) else {
            NSLog("Stash: kon globale sneltoets \(combo.displayString) niet registreren "
                  + "(OSStatus \(hotKey.lastRegisterStatus)) — waarschijnlijk al in "
                  + "gebruik door een andere app")
            return false
        }
        NSLog("Stash: globale sneltoets \(combo.displayString) geregistreerd (OSStatus 0)")
        return true
    }

    private func quit() {
        restriction.clear()
        NSApp.terminate(nil)
    }
}
