import AppKit

let app = NSApplication.shared
// Accessory: no Dock icon, no menu bar menus, but a status item.
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
