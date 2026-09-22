import AppKit
import ApplicationServices

/// Which running apps currently own a real menu bar status item, discovered via
/// Accessibility (`AXExtrasMenuBar`). See `.superpowers/sdd/2026-09-22-stash/
/// menubar-detection-research.md` for the full measurement — this route was picked over
/// the private `MenuBarClientCore` framework (entitlement-gated to Apple-signed binaries,
/// confirmed a dead end: do not retry it) and the unified log (works without any
/// permission, but only sees the display being re-laid out, only currently-visible items,
/// and scrapes debug-level English text that Apple can change any time).
public enum MenuBarOwners {

    /// Measured on this codebase's research machine: 2438 ms for 112 processes with the
    /// default AX messaging timeout, 263 ms with this one set per element. The gap is
    /// entirely AX timeouts against unresponsive helper processes (WebKit content
    /// processes and the like) — non-negotiable, not a tuning knob.
    private static let messagingTimeout: Float = 0.25

    /// Bundle identifiers of apps that own a menu bar extra right now.
    ///
    /// Returns `nil` when Accessibility is not granted — `nil` means "unknown", which the
    /// caller must treat as "show everything", never as "no app has an icon". Costs
    /// roughly 263 ms across ~112 running processes on the machine this was measured on;
    /// callers must cache the result and never call this per UI render or per keystroke.
    public static func sweep() -> Set<String>? {
        guard isTrusted else { return nil }

        var owners = Set<String>()
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier else { continue }
            let element = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(element, messagingTimeout)

            var value: CFTypeRef?
            let result = AXUIElementCopyAttributeValue(element, "AXExtrasMenuBar" as CFString, &value)
            if result == .success {
                owners.insert(bundleID)
            }
        }
        return owners
    }

    /// Whether the user has already granted Stash the Accessibility permission.
    public static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Triggers the system Accessibility prompt when not already trusted. Returns
    /// immediately with no indication of what the user will eventually choose — granting
    /// happens later, in System Settings, outside this process's control. Callers that
    /// need to know whether trust was actually granted must re-check `isTrusted`
    /// afterwards, which will still read `false` immediately after this call and only
    /// flips once the user has gone through System Settings.
    public static func requestTrust() {
        // Not `kAXTrustedCheckOptionPrompt.takeUnretainedValue()`: that global `CFStringRef`
        // trips Swift 6's concurrency-safety check ("shared mutable state"). Its value is a
        // fixed, documented constant, so the literal is used directly instead.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}
