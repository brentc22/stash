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

    /// SF Symbol for the per-row segmented control. Lives here next to `label` rather than
    /// in the view so the three states keep one single description of themselves.
    public var symbolName: String {
        switch self {
        case .visible:      return "eye"
        case .hidden:       return "eye.slash"
        case .alwaysHidden: return "lock"
        }
    }

    /// The row buttons carry no text, so this is the only explanation the user gets —
    /// shown as a tooltip and used as the accessibility label.
    public var hint: String {
        switch self {
        case .visible:      return "Altijd zichtbaar"
        case .hidden:       return "Verbergen achter het pijltje"
        case .alwaysHidden: return "Nooit tonen"
        }
    }
}

/// Which rows the Apps tab shows, independent of the search query. Purely a view filter:
/// it never changes an app's stored visibility, only whether you are looking at it.
public enum AppListFilter: String, CaseIterable, Sendable {
    case all
    case hidden
    case alwaysHidden

    public var label: String {
        switch self {
        case .all:          return "Alles"
        case .hidden:       return "Verborgen"
        case .alwaysHidden: return "Altijd"
        }
    }

    public func matches(_ visibility: AppVisibility) -> Bool {
        switch self {
        case .all:          return true
        case .hidden:       return visibility == .hidden
        case .alwaysHidden: return visibility == .alwaysHidden
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
        guard self.visibility(for: bundleID) != visibility else { return }
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
