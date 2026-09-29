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
}

public enum Presentation {
    /// The manual switch always wins; the signals only count when the user opted in to
    /// automatic presentation mode and has not switched it off for the current session.
    public static func isPresenting(manual: Bool, automatic: Bool, suppressed: Bool = false,
                                    signals: PresentationSignals) -> Bool {
        manual || (automatic && !suppressed && signals.anyActive)
    }
}
