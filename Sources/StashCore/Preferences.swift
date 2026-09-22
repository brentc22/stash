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

    /// Whether ⌃⌥S should toggle the bar. Default `false`: an app that grabs a global
    /// hotkey without being asked is rude. `bool(forKey:)` already returns `false` for an
    /// absent key, so no extra "has this ever been set" check is needed here, unlike
    /// `collapseDelay`'s `after10` default.
    public var useGlobalHotKey: Bool {
        get { defaults.bool(forKey: Self.useGlobalHotKeyKey) }
        set { defaults.set(newValue, forKey: Self.useGlobalHotKeyKey) }
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
