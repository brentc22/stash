import AppKit
import ApplicationServices

/// Fires `onHover` when the pointer rests on Stash's own arrow.
///
/// A tracking area on the status item button never fires on macOS 27: the bar is one
/// window drawn by the system, and the button has no window of its own (`button.window`
/// is nil). The arrow's frame is only available through Accessibility, as a child of our
/// own process's `AXExtrasMenuBar` — so this watches the pointer globally and asks for
/// that frame only while the pointer is inside a menu bar.
///
/// Whether Accessibility answers for our own process without the Accessibility permission
/// is not something macOS promises — so this is treated as needing it: without an answer
/// `arrowFrames()` is empty and hover never fires. The settings row
/// asks for the permission when hover is switched on, and says so while it is missing.
@MainActor
final class HoverWatcher {

    /// How long the pointer must rest on the arrow. Long enough that sweeping across the
    /// bar to another item does not flash everything open.
    private static let dwell: TimeInterval = 0.35
    /// Taller than any menu bar, so a pointer on the arrow is always inside it.
    private static let barStrip: CGFloat = 40
    /// The arrow only moves when other items appear or go; re-reading its frame at most
    /// this often keeps the per-event cost to a rectangle test.
    private static let frameTTL: TimeInterval = 1

    private let onHover: () -> Void
    private var monitors: [Any] = []
    private var timer: Timer?
    private var isOverArrow = false
    private var cachedFrames: [CGRect] = []
    private var cachedAt: Date = .distantPast

    init(onHover: @escaping () -> Void) {
        self.onHover = onHover
    }

    var isRunning: Bool { !monitors.isEmpty }

    func start() {
        guard !isRunning else { return }
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

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        cancel()
        isOverArrow = false
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    private func pointerMoved() {
        // Accessibility uses top-left coordinates with the primary screen's top at 0;
        // NSEvent uses bottom-left. Each screen's menu bar sits at the top of *that* screen.
        guard let primary = NSScreen.screens.first else { return }
        let location = NSEvent.mouseLocation
        let point = CGPoint(x: location.x, y: primary.frame.maxY - location.y)
        let screens = NSScreen.screens.map { Self.axRect(of: $0, primary: primary) }
        guard let pointerScreen = screens.first(where: {
            $0.minX...$0.maxX ~= point.x && point.y >= $0.minY && point.y <= $0.minY + Self.barStrip
        }) else {
            if isOverArrow { isOverArrow = false; cancel() }
            return
        }

        let over = arrowFrames().contains { frame in
            Self.project(frame, from: screens, onto: pointerScreen).contains(point)
        }
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

    /// A screen's frame in Accessibility coordinates (top-left origin at the primary's top).
    private static func axRect(of screen: NSScreen, primary: NSScreen) -> CGRect {
        CGRect(x: screen.frame.minX, y: primary.frame.maxY - screen.frame.maxY,
               width: screen.frame.width, height: screen.frame.height)
    }

    /// Accessibility reports the arrow on one display only — which one follows the active
    /// display, not the pointer. Menu bar items sit the same distance from the right edge
    /// of every display's bar, so that frame carries over to the screen under the pointer.
    private static func project(_ frame: CGRect, from screens: [CGRect], onto target: CGRect) -> CGRect {
        guard let source = screens.first(where: { $0.contains(frame.origin) }) else { return frame }
        return CGRect(x: target.maxX - (source.maxX - frame.minX),
                      y: target.minY + (frame.minY - source.minY),
                      width: frame.width, height: frame.height)
    }

    private func arrowFrames() -> [CGRect] {
        if Date().timeIntervalSince(cachedAt) > Self.frameTTL {
            cachedFrames = Self.readArrowFrames()
            cachedAt = Date()
        }
        return cachedFrames
    }

    /// Our own menu bar items' frames, in Accessibility coordinates.
    private static func readArrowFrames() -> [CGRect] {
        let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        var bar: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, "AXExtrasMenuBar" as CFString, &bar) == .success,
              let bar else { return [] }
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(bar as! AXUIElement, kAXChildrenAttribute as CFString, &children) == .success,
              let items = children as? [AXUIElement] else { return [] }
        return items.compactMap { item in
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
}
