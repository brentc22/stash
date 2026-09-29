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
    private let presentationMonitor = PresentationMonitor()
    private let wifiMonitor = WiFiMonitor()
    /// Presentation mode switched on by hand. Not persisted: waking up tomorrow with an
    /// empty menu bar because of yesterday's talk would look broken.
    private var manualPresentation = false
    /// The user switched off an automatic presentation mode. Holds until the signal that
    /// caused it ends, so the next call or screen share turns it on again.
    private var presentationSuppressed = false
    /// When hover last expanded the bar — a click that lands right after must not
    /// immediately collapse what the hover just opened.
    private var hoverExpandedAt: Date?

    private var isPresenting: Bool {
        Presentation.isPresenting(manual: manualPresentation,
                                  automatic: preferences.automaticPresentationMode,
                                  suppressed: presentationSuppressed,
                                  signals: presentationMonitor.signals)
    }

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
            onToggle: { [weak self] in self?.clickToggle() },
            onSettings: { [weak self] in self?.showSettings() },
            onQuit: { [weak self] in self?.quit() },
            onHover: { [weak self] in self?.hoverReveal() },
            onPresentationToggle: { [weak self] in self?.togglePresentation() },
            presentationState: { [weak self] in
                (self?.manualPresentation ?? false, self?.isPresenting ?? false)
            }
        )
        render()

        collapseTimer = CollapseTimer { [weak self] in
            guard let self, self.state == .expanded else { return }
            self.toggle()
        }

        inventory.onChange = { [weak self] in self?.rebuild() }
        inventory.start()

        presentationMonitor.onChange = { [weak self] in
            guard let self else { return }
            if !self.presentationMonitor.signals.anyActive { self.presentationSuppressed = false }
            self.render()
            self.rebuild()
        }
        presentationMonitor.start()
        wifiMonitor.onChange = { [weak self] in self?.rebuild() }
        wifiMonitor.start()
        // "Show while active" depends on which app is in front.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
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

        Updater.shared.usesAccessibility = { [weak self] in self?.preferences.showOnlyMenuBarApps ?? false }
        Updater.shared.start()
        showSettingsIfUpdateLostTrust()
    }

    /// An update swaps in a new ad-hoc signed binary, and macOS ties the Accessibility
    /// grant to the old one's hash. Hiding keeps working, but the menu bar filter silently
    /// falls back to the full list — so right after an update that lost the grant, open
    /// the General tab, where `permissionHelp` explains the stale row and links to
    /// System Settings. The swap script relaunches with `--after-update`.
    private func showSettingsIfUpdateLostTrust() {
        guard CommandLine.arguments.contains("--after-update"),
              preferences.showOnlyMenuBarApps, !MenuBarOwners.isTrusted else { return }
        settingsModel.selectedTab = .general
        showSettings()
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

    /// A click on the arrow. Ignored when it lands within a second of a hover that just
    /// expanded the bar: the user was reaching for the arrow to open it, and the hover
    /// beat them to it.
    private func clickToggle() {
        if state == .expanded, let at = hoverExpandedAt, Date().timeIntervalSince(at) < 1 {
            hoverExpandedAt = nil
            return
        }
        toggle()
    }

    private func hoverReveal() {
        guard preferences.revealOnHover, state == .collapsed else { return }
        toggle()
        hoverExpandedAt = Date()
    }

    private func togglePresentation() {
        if isPresenting {
            manualPresentation = false
            if presentationMonitor.signals.anyActive { presentationSuppressed = true }
        } else {
            manualPresentation = true
        }
        render()
        rebuild(force: true)
    }

    private func render() {
        statusItem.render(state: state, available: restriction.isAvailable, presenting: isPresenting)
    }

    func toggle() {
        state = (state == .collapsed) ? .expanded : .collapsed
        hoverExpandedAt = nil
        render()
        if state == .expanded {
            collapseTimer.schedule(delay: preferences.collapseDelay)
        } else {
            collapseTimer.cancel()
        }
        rebuild(force: true)
    }

    /// Recomputes the allowlist and applies it. Called on every toggle, every change to
    /// the running apps, and after every change to the hidden set. An unchanged
    /// allowlist is skipped unless `force` — see `MenuBarRestriction.apply`.
    func rebuild(force: Bool = false) {
        guard restriction.isAvailable else { return }
        let allowed = Allowlist.compute(
            running: inventory.runningBundleIDs,
            hidden: hidden.bundleIDs,
            alwaysHidden: hidden.alwaysHiddenBundleIDs,
            state: state,
            ownBundleID: ownBundleID,
            showWhenActive: hidden.showWhenActiveBundleIDs,
            frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
            presenting: isPresenting
        )
        let systemItems = SystemItems.allowed(hiding: SystemItems.hiddenByRules(
            wifiOnlyWhenDisconnected: preferences.wifiOnlyWhenDisconnected,
            wifiConnected: wifiMonitor.isConnected,
            state: state
        ))
        restriction.apply(allowing: allowed, systemItems: systemItems, force: force) { [weak self] error in
            guard let error else { return }
            NSLog("Stash: could not apply restriction: \(error)")
            DispatchQueue.main.async {
                guard let self else { return }
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
            NSLog("Stash: could not register global shortcut \(combo.displayString) "
                  + "(OSStatus \(hotKey.lastRegisterStatus)) — probably already in "
                  + "use by another app")
            return false
        }
        NSLog("Stash: registered global shortcut \(combo.displayString) (OSStatus 0)")
        return true
    }

    private func quit() {
        restriction.clear()
        NSApp.terminate(nil)
    }
}
