import Foundation

/// What the system currently says about presenting. Gathered by the app target — every
/// field comes from a different OS facility — and judged here, where it can be tested.
public struct PresentationSignals: Equatable, Sendable {
    public var screenShared: Bool
    public var mirroring: Bool
    public var inCall: Bool

    public init(screenShared: Bool = false, mirroring: Bool = false, inCall: Bool = false) {
        self.screenShared = screenShared
        self.mirroring = mirroring
        self.inCall = inCall
    }

    public var anyActive: Bool { screenShared || mirroring || inCall }

    /// Whether `self` has a signal that `previous` did not — a new session starting, even
    /// while another one (a permanently mirrored display) is still on.
    public func startsSession(after previous: PresentationSignals) -> Bool {
        (screenShared && !previous.screenShared) || (mirroring && !previous.mirroring)
            || (inCall && !previous.inCall)
    }
}

public enum Presentation {
    /// Whether a "switched off by hand" from an earlier session still holds. It lapses
    /// when every signal is gone *or* a new one starts: the promise is that the next call
    /// or share turns presentation mode on again, and a projector that stays mirrored all
    /// day must not break that.
    public static func keepsSuppression(_ suppressed: Bool, from previous: PresentationSignals,
                                        to next: PresentationSignals) -> Bool {
        suppressed && next.anyActive && !next.startsSession(after: previous)
    }

    /// The manual switch always wins; the signals only count when the user opted in to
    /// automatic presentation mode and has not switched it off for the current session.
    public static func isPresenting(manual: Bool, automatic: Bool, suppressed: Bool = false,
                                    signals: PresentationSignals) -> Bool {
        manual || (automatic && !suppressed && signals.anyActive)
    }
}
