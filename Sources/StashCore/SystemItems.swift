import Foundation

/// System items are passed as numeric ids. Known ids: clock 2, sound 5,
/// wifi 6, Control Center 8. The range demonstrably needs to go above 63:
/// with only 0...63, Screen Mirroring silently disappeared from the bar.
/// Hence the wide margin.
public enum SystemItems {
    public static let range = 0...255
    public static let all: [NSNumber] = range.map { NSNumber(value: $0) }

    public static let clock = 2
    public static let wifi = 6
    public static let controlCenter = 8

    /// What presentation mode keeps: the clock, which a presenter keeps glancing at, and
    /// Control Center, which holds Do Not Disturb and display settings mid-talk.
    public static let keptWhilePresenting: Set<Int> = [clock, controlCenter]

    /// Every system item except `hidden`. Only built when an assertion is actually
    /// activated — callers compare the small `hidden` set instead.
    public static func allowed(hiding hidden: Set<Int>) -> [NSNumber] {
        guard !hidden.isEmpty else { return all }
        return range.filter { !hidden.contains($0) }.map { NSNumber(value: $0) }
    }

    /// Which system items the rules take out of the bar right now. Wi-Fi goes only when
    /// the rule is on *and* there is a connection: the icon is worth its space exactly
    /// when something is wrong. Collapsed-only — expanding shows it again, same as apps.
    ///
    /// Presentation mode takes out every system item except `keptWhilePresenting`, the
    /// same collapsed-only way it empties the app allowlist.
    public static func hiddenByRules(wifiOnlyWhenDisconnected: Bool,
                                     wifiConnected: Bool,
                                     state: BarState,
                                     presenting: Bool = false) -> Set<Int> {
        guard state == .collapsed else { return [] }
        if presenting {
            return Set(range).subtracting(keptWhilePresenting)
        }
        guard wifiOnlyWhenDisconnected, wifiConnected else { return [] }
        return [wifi]
    }
}
