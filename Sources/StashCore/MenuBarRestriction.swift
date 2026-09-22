import Foundation
import MenuBarShim

public enum MenuBarRestrictionError: Error {
    case unavailable
    case activationFailed(String)
}

public final class MenuBarRestriction: @unchecked Sendable {

    private var token: AnyObject?
    private let lock = NSLock()

    public init() {}

    public var isAvailable: Bool { STMenuBarShim.isAvailable() }

    /// Replaces the current restriction. Idempotent. The new token becomes active
    /// synchronously; the old one is only invalidated once `completion` confirms
    /// activation actually succeeded, and is restored if it failed.
    public func apply(allowing bundleIDs: Set<String>, completion: ((Error?) -> Void)? = nil) {
        guard isAvailable else {
            completion?(MenuBarRestrictionError.unavailable)
            return
        }

        lock.lock()
        let old = token
        lock.unlock()

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
        lock.unlock()
    }

    /// Lifts every restriction; the bar is fully redrawn.
    public func clear() {
        lock.lock()
        let old = token
        token = nil
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
