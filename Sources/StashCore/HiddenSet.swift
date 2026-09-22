import Foundation

/// Which bundle IDs should be hidden when the bar is collapsed.
/// Knows nothing of the operating system; fully testable.
public final class HiddenSet {

    private static let key = "hiddenBundleIDs"

    private let defaults: UserDefaults
    private var storage: Set<String>

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.storage = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    public var bundleIDs: Set<String> { storage }

    public func isHidden(_ bundleID: String) -> Bool { storage.contains(bundleID) }

    public func hide(_ bundleID: String) {
        guard storage.insert(bundleID).inserted else { return }
        persist()
    }

    public func show(_ bundleID: String) {
        guard storage.remove(bundleID) != nil else { return }
        persist()
    }

    public func setHidden(_ hidden: Bool, for bundleID: String) {
        hidden ? hide(bundleID) : show(bundleID)
    }

    private func persist() {
        defaults.set(storage.sorted(), forKey: Self.key)
    }
}
