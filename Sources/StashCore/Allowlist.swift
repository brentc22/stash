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
    ///   - hidden: what the user has checked to hide.
    ///   - state: collapsed or expanded.
    ///   - ownBundleID: our own ID. Always included, regardless of everything else —
    ///     without the chevron the user cannot expand.
    public static func compute(running: Set<String>,
                               hidden: Set<String>,
                               state: BarState,
                               ownBundleID: String) -> Set<String> {
        let base: Set<String>
        switch state {
        case .expanded:  base = running
        case .collapsed: base = running.subtracting(hidden)
        }
        return base.union([ownBundleID])
    }
}
