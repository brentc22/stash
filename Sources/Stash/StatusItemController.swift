import AppKit
import StashCore

/// The arrow in the bar. Knows nothing about the private API.
// @MainActor: this class only ever touches AppKit (NSStatusItem, NSButton, NSMenu),
// created in and driven entirely by main-thread callbacks (target/action). Without it,
// Swift 6's strict concurrency checking flags every AppKit access here as a reference
// to main-actor-isolated state from a nonisolated context. No `deinit`, so the
// `AppInventory` trap (a `deinit` that calls `stop()`, which cannot be actor-isolated)
// does not apply.
@MainActor
final class StatusItemController: NSObject {

    private let item: NSStatusItem
    private let onToggle: () -> Void
    private let onSettings: () -> Void
    private let onQuit: () -> Void
    private let onPresentationToggle: () -> Void
    /// Read when the menu opens, so the checkmark is never stale.
    private let presentationState: () -> (manual: Bool, active: Bool)
    private let hoverWatcher: HoverWatcher

    init(onToggle: @escaping () -> Void,
         onSettings: @escaping () -> Void,
         onQuit: @escaping () -> Void,
         onHover: @escaping () -> Void,
         onPresentationToggle: @escaping () -> Void,
         presentationState: @escaping () -> (manual: Bool, active: Bool)) {
        self.onToggle = onToggle
        self.onSettings = onSettings
        self.onQuit = onQuit
        self.onPresentationToggle = onPresentationToggle
        self.presentationState = presentationState
        self.hoverWatcher = HoverWatcher(onHover: onHover)
        self.item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        item.button?.target = self
        item.button?.action = #selector(buttonPressed)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    /// Hover detection costs a global mouse monitor, so it only runs while wanted.
    func setHoverEnabled(_ enabled: Bool) {
        if enabled { hoverWatcher.start() } else { hoverWatcher.stop() }
    }

    func render(state: BarState, available: Bool, presenting: Bool = false) {
        guard let button = item.button else { return }
        let symbol: String
        let description: String
        if !available {
            symbol = "exclamationmark.triangle"
            description = "Hiding unavailable"
        } else {
            switch state {
            // "chevron.*" are SF Symbol identifiers, not our wording: renaming them to
            // "arrow.*" selects a different symbol. The prose calls this an arrow.
            case .collapsed where presenting:
                symbol = "chevron.left.2"; description = "Presentation mode — show hidden items"
            case .collapsed: symbol = "chevron.left";  description = "Show hidden items"
            case .expanded:  symbol = "chevron.right"; description = "Hide items"
            }
        }
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        button.image?.isTemplate = true
        button.toolTip = description
    }

    @objc private func buttonPressed() {
        hoverWatcher.cancel()
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
        if let version = Updater.shared.available?.version {
            let update = menu.addItem(withTitle: "Update available: Stash \(version)…",
                                      action: #selector(updatePressed), keyEquivalent: "")
            update.target = self
            update.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: nil)
            menu.addItem(.separator())
        }
        let presentation = presentationState()
        let presentationItem = menu.addItem(
            withTitle: presentation.active && !presentation.manual ? "Presentation Mode (automatic)" : "Presentation Mode",
            action: #selector(presentationPressed), keyEquivalent: "")
        presentationItem.target = self
        presentationItem.state = presentation.active ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(settingsPressed), keyEquivalent: ",")
            .target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Stash", action: #selector(quitPressed), keyEquivalent: "q")
            .target = self
        // popUp instead of assigning item.menu: the latter also shows the menu on a
        // left click, which would make toggling impossible.
        //
        // Anchored to the pointer, not the button: on macOS 27 with more than one display
        // the button's position follows the *active* display's menu bar, so anchoring to
        // it opened the menu on the other screen. The pointer is always on the arrow that
        // was actually clicked; the menu goes right below that screen's menu bar.
        let pointer = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) {
            menu.popUp(positioning: nil, at: NSPoint(x: pointer.x, y: screen.visibleFrame.maxY), in: nil)
        } else {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }

    @objc private func settingsPressed() { onSettings() }
    @objc private func presentationPressed() { onPresentationToggle() }
    @objc private func updatePressed() { Updater.shared.offerAvailable() }
    @objc private func quitPressed() { onQuit() }
}
