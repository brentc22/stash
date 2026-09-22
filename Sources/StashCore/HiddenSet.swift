import Foundation

/// The three standing visibility states an app can have.
public enum AppVisibility: String, CaseIterable, Sendable {
    case visible        // altijd in de balk
    case hidden         // weg bij ingeklapt, terug bij uitgeklapt
    case alwaysHidden   // nooit in de balk, in geen enkele stand

    public var label: String {
        switch self {
        case .visible:      return "Zichtbaar"
        case .hidden:       return "Verbergen"
        case .alwaysHidden: return "Altijd verbergen"
        }
    }
}

/// Which bundle IDs should be hidden when the bar is collapsed, and which should never
/// be shown at all. Knows nothing of the operating system; fully testable.
public final class HiddenSet {

    private static let key = "hiddenBundleIDs"
    private static let alwaysHiddenKey = "alwaysHiddenBundleIDs"

    private let defaults: UserDefaults
    private var storage: Set<String>
    private var alwaysHiddenStorage: Set<String>

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.storage = Set(defaults.stringArray(forKey: Self.key) ?? [])
        self.alwaysHiddenStorage = Set(defaults.stringArray(forKey: Self.alwaysHiddenKey) ?? [])
    }

    public var bundleIDs: Set<String> { storage }
    public var alwaysHiddenBundleIDs: Set<String> { alwaysHiddenStorage }

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

    /// The three-state visibility for one app. An app that ended up in both the hidden
    /// and always-hidden sets — should not happen through the UI, which only ever puts
    /// an app in one of them, but a hand-edited or migrated defaults file could — counts
    /// as `alwaysHidden`: the stronger guarantee wins.
    public func visibility(for bundleID: String) -> AppVisibility {
        if alwaysHiddenStorage.contains(bundleID) { return .alwaysHidden }
        if storage.contains(bundleID) { return .hidden }
        return .visible
    }

    public func setVisibility(_ visibility: AppVisibility, for bundleID: String) {
        switch visibility {
        case .visible:
            storage.remove(bundleID)
            alwaysHiddenStorage.remove(bundleID)
        case .hidden:
            storage.insert(bundleID)
            alwaysHiddenStorage.remove(bundleID)
        case .alwaysHidden:
            alwaysHiddenStorage.insert(bundleID)
            storage.remove(bundleID)
        }
        persist()
    }

    private func persist() {
        defaults.set(storage.sorted(), forKey: Self.key)
        defaults.set(alwaysHiddenStorage.sorted(), forKey: Self.alwaysHiddenKey)
    }
}
