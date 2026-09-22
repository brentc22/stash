import Foundation
import MenuBarShim

public enum MenuBarRestrictionError: Error {
    case unavailable
    case activationFailed(String)
}

public protocol MenuBarRestricting: AnyObject {
    var isAvailable: Bool { get }
    /// Replaces the current restriction. Idempotent. Swapping the token happens
    /// synchronously; `completion` only reports whether the system complained afterwards.
    func apply(allowing bundleIDs: Set<String>, completion: ((Error?) -> Void)?)
    /// Lifts every restriction; the bar is fully redrawn.
    func clear()
}

public extension MenuBarRestricting {
    func apply(allowing bundleIDs: Set<String>) { apply(allowing: bundleIDs, completion: nil) }
}

public final class MenuBarRestriction: MenuBarRestricting, @unchecked Sendable {

    private var token: AnyObject?
    private let lock = NSLock()

    public init() {}

    public var isAvailable: Bool { STMenuBarShim.isAvailable() }

    public func apply(allowing bundleIDs: Set<String>, completion: ((Error?) -> Void)? = nil) {
        guard isAvailable else {
            completion?(MenuBarRestrictionError.unavailable)
            return
        }

        let created = STMenuBarShim.activate(
            withAllowedBundleIdentifiers: bundleIDs.sorted(),
            allowedSystemItems: SystemItems.all
        ) { error in
            if let error {
                completion?(MenuBarRestrictionError.activationFailed(error.localizedDescription))
            } else {
                completion?(nil)
            }
        }

        guard let created = created as AnyObject? else {
            completion?(MenuBarRestrictionError.unavailable)
            return
        }

        // Activate the new one first, only then drop the old one: the bar must never
        // sit without an active restriction for a moment, or every icon jumps back briefly.
        lock.lock()
        let old = token
        token = created
        lock.unlock()
        STMenuBarShim.invalidate(old)
    }

    public func clear() {
        lock.lock()
        let old = token
        token = nil
        lock.unlock()
        STMenuBarShim.invalidate(old)
    }

    deinit { clear() }
}
