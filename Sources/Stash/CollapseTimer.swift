import Foundation
import StashCore

/// Klapt de balk vanzelf weer in. Eén timer, altijd eerst geannuleerd voor een nieuwe.
/// - Note: Marked `@unchecked Sendable` rather than `@MainActor`, on the same precedent
///   as `AppInventory` (Task 4): this class has `deinit { cancel() }`, and a nonisolated
///   `deinit` may not call a `@MainActor` method. It is safe because `Timer` is only ever
///   scheduled and invalidated from the main thread — `schedule`/`cancel` are called from
///   `AppDelegate`, which is itself `@MainActor`, and the fire closure below hops back to
///   `self` on the run loop the timer was scheduled on (the main run loop).
final class CollapseTimer: @unchecked Sendable {

    private var timer: Timer?
    private let onFire: () -> Void

    init(onFire: @escaping () -> Void) {
        self.onFire = onFire
    }

    func schedule(delay: CollapseDelay) {
        cancel()
        guard delay != .never else { return }
        timer = Timer.scheduledTimer(withTimeInterval: TimeInterval(delay.rawValue),
                                     repeats: false) { [weak self] _ in
            self?.onFire()
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }

    deinit { cancel() }
}
