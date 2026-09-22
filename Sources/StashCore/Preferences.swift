import Foundation
import ServiceManagement

public enum CollapseDelay: Int, CaseIterable, Sendable {
    case never = 0
    case after5 = 5
    case after10 = 10
    case after30 = 30

    public var label: String {
        switch self {
        case .never:   return "Nooit"
        case .after5:  return "Na 5 seconden"
        case .after10: return "Na 10 seconden"
        case .after30: return "Na 30 seconden"
        }
    }
}

public final class Preferences {

    private static let collapseDelayKey = "collapseDelaySeconds"
    private static let useGlobalHotKeyKey = "useGlobalHotKey"
    private static let showOnlyMenuBarAppsKey = "showOnlyMenuBarApps"
    private static let hotKeyKeyCodeKey = "hotKeyKeyCode"
    private static let hotKeyModifiersKey = "hotKeyModifiers"

    /// Written into `hotKeyKeyCodeKey` when the user clears the shortcut. A stored -1
    /// means "deliberately none", which is not the same as "nothing stored yet" — only
    /// the latter may fall back to the legacy migration value below.
    private static let noHotKeyCode = -1

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var collapseDelay: CollapseDelay {
        get {
            guard defaults.object(forKey: Self.collapseDelayKey) != nil else { return .after10 }
            return CollapseDelay(rawValue: defaults.integer(forKey: Self.collapseDelayKey)) ?? .after10
        }
        set { defaults.set(newValue.rawValue, forKey: Self.collapseDelayKey) }
    }

    /// Legacy flag from when the shortcut was the fixed ⌃⌥S. `hotKey` is now the source
    /// of truth and keeps this value in step with itself; it survives only so an existing
    /// install that had the fixed shortcut on migrates to ⌃⌥S instead of to nothing.
    /// Default `false`: an app that grabs a global hotkey without being asked is rude.
    public var useGlobalHotKey: Bool {
        get { defaults.bool(forKey: Self.useGlobalHotKeyKey) }
        set { defaults.set(newValue, forKey: Self.useGlobalHotKeyKey) }
    }

    /// Whether the user *wants* the list filtered to apps that actually own a menu bar
    /// item — the intent, deliberately not the outcome.
    ///
    /// This used to be reset to `false` whenever the permission was not already granted,
    /// which is exactly when the user had just asked for it: `AXIsProcessTrustedWithOptions`
    /// returns before the user has chosen anything, so the wish was thrown away a
    /// millisecond after it was made and nothing re-evaluated it when they came back from
    /// System Settings. It is kept now, and `MenuBarOwners.effectiveOwners(wanted:trusted:swept:)`
    /// decides separately whether it may be acted on. No permission still means the full
    /// list, never an empty one.
    ///
    /// Default `false`: this depends on the optional Accessibility permission, and Stash
    /// must not ask for it unprompted. `bool(forKey:)` already returns `false` for an
    /// absent key, same as `useGlobalHotKey` above.
    public var showOnlyMenuBarApps: Bool {
        get { defaults.bool(forKey: Self.showOnlyMenuBarAppsKey) }
        set { defaults.set(newValue, forKey: Self.showOnlyMenuBarAppsKey) }
    }

    /// The global shortcut, or `nil` for "no shortcut". This replaces the fixed ⌃⌥S:
    /// having a combination *is* the on-state, so there is no separate checkbox left to
    /// disagree with it.
    ///
    /// Migration: with nothing stored yet, a user who had the old fixed shortcut switched
    /// on (`useGlobalHotKey`) keeps ⌃⌥S; everyone else starts without one. A stored value
    /// that fails validation is treated as no shortcut rather than handed to Carbon —
    /// a hand-edited defaults file must not be able to grab a bare letter globally.
    public var hotKey: HotKeyCombo? {
        get {
            guard defaults.object(forKey: Self.hotKeyKeyCodeKey) != nil else {
                return useGlobalHotKey ? .legacyDefault : nil
            }
            let code = defaults.integer(forKey: Self.hotKeyKeyCodeKey)
            guard code >= 0, code <= Int(UInt16.max) else { return nil }
            let combo = HotKeyCombo(keyCode: UInt16(code),
                                    modifiers: UInt(bitPattern: defaults.integer(forKey: Self.hotKeyModifiersKey)))
            return combo.isValid ? combo : nil
        }
        set {
            defaults.set(newValue.map { Int($0.keyCode) } ?? Self.noHotKeyCode,
                         forKey: Self.hotKeyKeyCodeKey)
            defaults.set(newValue.map { Int(bitPattern: $0.modifiers) } ?? 0,
                         forKey: Self.hotKeyModifiersKey)
            // Keep the legacy flag in step so nothing downstream reads a stale "on".
            useGlobalHotKey = newValue != nil
        }
    }
}

extension Preferences {
    /// Reads the real status from the system rather than a flag of our own — those two
    /// drift apart the moment the user changes it in System Settings instead of here.
    ///
    /// `SMAppService` only works from a bundled, signed app. From `swift run` it throws;
    /// that is expected and gets logged, not crashed on.
    public var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Stash: kon login item niet wijzigen: \(error)")
            }
        }
    }
}
