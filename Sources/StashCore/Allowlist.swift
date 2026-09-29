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
    ///   - hidden: what the user has marked "Hide" — back when expanded.
    ///   - alwaysHidden: what the user has marked "Always hide" — never back, in
    ///     neither state. Defaults to empty so existing call sites that only know about
    ///     `hidden` keep compiling and behaving exactly as before.
    ///   - state: collapsed or expanded.
    ///   - ownBundleID: our own ID. Always included, regardless of everything else —
    ///     including a hand-edited defaults file that marks it `alwaysHidden` — without
    ///     the arrow the user cannot expand.
    ///   - showWhenActive: hidden apps that come back while they are the frontmost app.
    ///     Only affects `hidden` apps: "Always hide" keeps meaning never.
    ///   - frontmost: the bundle ID of the frontmost app, if any.
    ///   - presenting: presentation mode. While collapsed, only the arrow stays — even
    ///     apps marked visible go. Expanding still shows everything not always-hidden:
    ///     that is a deliberate click, and it must keep working mid-presentation.
    public static func compute(running: Set<String>,
                               hidden: Set<String>,
                               alwaysHidden: Set<String> = [],
                               state: BarState,
                               ownBundleID: String,
                               showWhenActive: Set<String> = [],
                               frontmost: String? = nil,
                               presenting: Bool = false) -> Set<String> {
        let base: Set<String>
        switch state {
        case .expanded:
            base = running.subtracting(alwaysHidden)
        case .collapsed where presenting:
            base = []
        case .collapsed:
            var shown = running.subtracting(hidden).subtracting(alwaysHidden)
            if let frontmost, showWhenActive.contains(frontmost), hidden.contains(frontmost),
               !alwaysHidden.contains(frontmost), running.contains(frontmost) {
                shown.insert(frontmost)
            }
            base = shown
        }
        return base.union([ownBundleID])
    }
}
