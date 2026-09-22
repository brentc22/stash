import AppKit
import StashCore

/// The chevron in the bar. Knows nothing about the private API.
// @MainActor: this class only ever touches AppKit (NSStatusItem, NSButton, NSMenu),
// created in and driven entirely by main-thread callbacks (target/action). Without it,
// Swift 6's strict concurrency checking flags every AppKit access here as a reference
// to main-actor-isolated state from a nonisolated context. No `deinit`, so the Task 4
// `AppInventory` trap (a `deinit` that calls `stop()`, which cannot be actor-isolated)
// does not apply.
@MainActor
final class StatusItemController: NSObject {

    private let item: NSStatusItem
    private let onToggle: () -> Void
    private let onSettings: () -> Void
    private let onQuit: () -> Void

    init(onToggle: @escaping () -> Void,
         onSettings: @escaping () -> Void,
         onQuit: @escaping () -> Void) {
        self.onToggle = onToggle
        self.onSettings = onSettings
        self.onQuit = onQuit
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        item.button?.target = self
        item.button?.action = #selector(buttonPressed)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    func render(state: BarState, available: Bool) {
        guard let button = item.button else { return }
        let symbol: String
        let description: String
        if !available {
            symbol = "exclamationmark.triangle"
            description = "Verbergen niet beschikbaar"
        } else {
            switch state {
            case .collapsed: symbol = "chevron.left";  description = "Toon verborgen items"
            case .expanded:  symbol = "chevron.right"; description = "Verberg items"
            }
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        button.image?.isTemplate = true
        button.toolTip = description
    }

    @objc private func buttonPressed() {
        guard let event = NSApp.currentEvent else { onToggle(); return }
        if event.type == .rightMouseUp {
            showMenu()
        } else {
            onToggle()
        }
    }

    private func showMenu() {
        guard let button = item.button else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: "Instellingen…", action: #selector(settingsPressed), keyEquivalent: ",")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Stash stoppen", action: #selector(quitPressed), keyEquivalent: "q")
            .target = self
        // popUp instead of assigning item.menu: the latter also shows the menu on a
        // left click, which would make toggling impossible.
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.height + 4),
                   in: button)
    }

    @objc private func settingsPressed() { onSettings() }
    @objc private func quitPressed() { onQuit() }
}
