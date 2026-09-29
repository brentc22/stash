import Foundation
import MenuBarShim

public enum MenuBarRestrictionError: Error {
    case unavailable
    case activationFailed(String)
}

public final class MenuBarRestriction: @unchecked Sendable {

    private var token: AnyObject?
    /// The allowlist `token` enforces, or `nil` when that is unknown (nothing applied,
    /// cleared, or rolled back after a failure). Guarded by `lock`, like `token`.
    private var appliedBundleIDs: Set<String>?
    private let lock = NSLock()

    public init() {}

    public var isAvailable: Bool { STMenuBarShim.isAvailable() }

    /// Replaces the current restriction. The new token becomes active synchronously; the
    /// old one is only invalidated once `completion` confirms activation actually
    /// succeeded, and is restored if it failed.
    ///
    /// Skips the call when `bundleIDs` is exactly what is already enforced: every `apply`
    /// builds a new system assertion, and callers re-apply on every change to the running
    /// apps, most of which never reach the allowlist. `force` applies anyway — for a
    /// deliberate user action, which then also repairs an assertion the system dropped
    /// without telling us.
    public func apply(allowing bundleIDs: Set<String>,
                      force: Bool = false,
                      completion: ((Error?) -> Void)? = nil) {
        guard isAvailable else {
            completion?(MenuBarRestrictionError.unavailable)
            return
        }

        lock.lock()
        let old = token
        let unchanged = !force && old != nil && appliedBundleIDs == bundleIDs
        lock.unlock()
        if unchanged {
            completion?(nil)
            return
        }

        // `activate` returns its token synchronously; the completion closure below only
        // fires afterward. The box exists purely to carry that synchronous return value
        // into a closure that was necessarily created before the value existed.
        let box = TokenBox()

        let created = STMenuBarShim.activate(
            withAllowedBundleIdentifiers: bundleIDs.sorted(),
            allowedSystemItems: SystemItems.all
        ) { [weak self] error in
            guard let self, let createdToken = box.token else { return }
            if let error {
                // Activation failed after the fact: hand control back to the old
                // assertion — but only if nothing newer has replaced this call's token
                // in the meantime. A late error from an older `apply` must never clobber
                // a token a later `apply` already installed.
                self.lock.lock()
                if self.token === createdToken {
                    self.token = old
                    self.appliedBundleIDs = nil
                }
                self.lock.unlock()
                completion?(MenuBarRestrictionError.activationFailed(error.localizedDescription))
            } else {
                STMenuBarShim.invalidate(old)
                completion?(nil)
            }
        }

        guard let created = created as AnyObject? else {
            completion?(MenuBarRestrictionError.unavailable)
            return
        }
        box.token = created

        // Install the new token right away: the coexistence test established that the
        // newest assertion wins even while an older one is still technically alive, so
        // the bar is never without an active restriction for a moment. The old token is
        // only invalidated once the completion above confirms activation actually
        // succeeded — see the rollback branch for what happens if it didn't.
        lock.lock()
        token = created
        appliedBundleIDs = bundleIDs
        lock.unlock()
    }

    /// Lifts every restriction; the bar is fully redrawn.
    public func clear() {
        lock.lock()
        let old = token
        token = nil
        appliedBundleIDs = nil
        lock.unlock()
        STMenuBarShim.invalidate(old)
    }

    deinit { clear() }
}

/// Carries the token `activate` returns synchronously into its own completion closure —
/// that closure is necessarily created before the value exists and needs to read it once
/// set. `@unchecked Sendable`: the completion always fires strictly after the synchronous
/// return that sets `token`, never before or during it.
private final class TokenBox: @unchecked Sendable {
    var token: AnyObject?
}
