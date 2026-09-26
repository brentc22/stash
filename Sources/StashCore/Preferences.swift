import Foundation
import ServiceManagement

public enum CollapseDelay: Int, CaseIterable, Sendable {
    case never = 0
    case after5 = 5
    case after10 = 10
    case after30 = 30

    public var label: String {
        switch self {
        case .never:   return "Never"
        case .after5:  return "After 5 seconds"
        case .after10: return "After 10 seconds"
        case .after30: return "After 30 seconds"
        }
    }
}

public final class Preferences {

    private static let collapseDelayKey = "collapseDelaySeconds"

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
                NSLog("Stash: could not change login item: \(error)")
            }
        }
    }
}
