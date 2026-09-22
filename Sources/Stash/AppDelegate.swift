import AppKit
import StashCore

let ownBundleID = "be.vernast.Stash"

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let restriction = MenuBarRestriction()
    private let hidden = HiddenSet()
    private let inventory = AppInventory()
    private var statusItem: StatusItemController!
    private var state: BarState = .collapsed

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(
            onToggle: { [weak self] in self?.toggle() },
            onSettings: { [weak self] in self?.showSettings() },
            onQuit: { [weak self] in self?.quit() }
        )
        statusItem.render(state: state, available: restriction.isAvailable)

        inventory.onChange = { [weak self] in self?.rebuild() }
        inventory.start()
        rebuild()
    }

    func applicationWillTerminate(_ notification: Notification) {
        restriction.clear()
    }

    func toggle() {
        state = (state == .collapsed) ? .expanded : .collapsed
        statusItem.render(state: state, available: restriction.isAvailable)
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
        // Filled in in task 7.
    }

    private func quit() {
        restriction.clear()
        NSApp.terminate(nil)
    }
}
