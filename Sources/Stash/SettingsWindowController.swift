import AppKit
import SwiftUI

/// A plain `NSWindow` wrapping the SwiftUI view. Built by hand because the app is an
/// accessory app with no SwiftUI `App` lifecycle of its own.
// @MainActor: this only ever creates and drives AppKit objects (NSWindow, NSHostingView)
// from main-thread callbacks (the status item's right-click menu). No `deinit`, so — same
// reasoning as `SettingsModel` above and `AppDelegate`/`StatusItemController` —
// `@MainActor` is available and avoids the `@unchecked Sendable` route that `AppInventory`
// and `CollapseTimer` need only because they have a `deinit`.
@MainActor
final class SettingsWindowController {

    private var window: NSWindow?
    private let model: SettingsModel

    init(model: SettingsModel) {
        self.model = model
    }

    func show() {
        model.refresh()

        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Stash"
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        window.center()
        // Without this, closing the window releases it (NSWindow's default), but this
        // controller still holds `window` — a second `show()` would then dereference a
        // freed window instead of reusing or recreating one.
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }
}
