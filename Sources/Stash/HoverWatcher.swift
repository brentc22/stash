import AppKit
import ApplicationServices

/// Fires `onHover` when the pointer rests on Stash's own arrow.
///
/// A tracking area on the status item button never fires on macOS 27: the bar is one
/// window drawn by the system, and the button has no window of its own (`button.window`
/// is nil). The arrow's frame is only available through Accessibility, as the child of
/// our own process's `AXExtrasMenuBar` — so this watches the pointer globally and asks
/// for that frame only while the pointer is inside the menu bar strip.
@MainActor
final class HoverWatcher {

    /// How long the pointer must rest on the arrow. Long enough that sweeping across the
    /// bar to another item does not flash everything open.
    private static let dwell: TimeInterval = 0.35
    /// Taller than any menu bar, so a pointer on the arrow is always inside it.
    private static let barStrip: CGFloat = 40

    private let onHover: () -> Void
    private var monitors: [Any] = []
    private var timer: Timer?
    private var isOverArrow = false

    init(onHover: @escaping () -> Void) {
        self.onHover = onHover
    }

    func start() {
        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved, handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved, handler: { event in
            handler(event)
            return event
        }) {
            monitors.append(local)
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    private func pointerMoved() {
        // Accessibility uses top-left coordinates of the primary screen; NSEvent bottom-left.
        guard let primary = NSScreen.screens.first else { return }
        let location = NSEvent.mouseLocation
        let point = CGPoint(x: location.x, y: primary.frame.height - location.y)

        let over = point.y <= Self.barStrip && (Self.arrowFrame()?.contains(point) ?? false)
        guard over != isOverArrow else { return }
        isOverArrow = over
        cancel()
        if over {
            timer = Timer.scheduledTimer(withTimeInterval: Self.dwell, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.isOverArrow else { return }
                    self.onHover()
                }
            }
        }
    }

    /// Our own menu bar item's frame, in Accessibility coordinates.
    private static func arrowFrame() -> CGRect? {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &bar) == .success,
              let bar else { return nil }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
              let item = (children as? [AXUIElement])?.first else { return nil }
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(item, kAXSizeAttribute as CFString, &size) == .success,
              let position, let size else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        AXValueGetValue(position as! AXValue, .cgPoint, &origin)
        AXValueGetValue(size as! AXValue, .cgSize, &extent)
        return CGRect(origin: origin, size: extent)
    }
}
