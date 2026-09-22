import Foundation

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
