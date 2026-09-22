import Foundation

public enum BarState {
    case collapsed
    case expanded
}

/// The only place where we decide who is allowed to be visible.
public enum Allowlist {

    /// - Parameters:
    ///   - running: everything running right now. Must be fresh: a stale list will
    ///     leave a newly started app out of the allowlist, and it will then disappear
    ///     unwanted.
    ///   - hidden: what the user has marked "Verbergen" — back when expanded.
    ///   - alwaysHidden: what the user has marked "Altijd verbergen" — never back, in
    ///     neither state. Defaults to empty so existing call sites that only know about
    ///     `hidden` keep compiling and behaving exactly as before.
    ///   - state: collapsed or expanded.
    ///   - ownBundleID: our own ID. Always included, regardless of everything else —
    ///     including a hand-edited defaults file that marks it `alwaysHidden` — without
    ///     the arrow the user cannot expand.
    public static func compute(running: Set<String>,
                               hidden: Set<String>,
                               alwaysHidden: Set<String> = [],
                               state: BarState,
                               ownBundleID: String) -> Set<String> {
        let base: Set<String>
        switch state {
        case .expanded:  base = running.subtracting(alwaysHidden)
        case .collapsed: base = running.subtracting(hidden).subtracting(alwaysHidden)
        }
        return base.union([ownBundleID])
    }
}
