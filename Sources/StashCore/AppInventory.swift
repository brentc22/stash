import AppKit

public struct KnownApp: Identifiable, Hashable {
    public let id: String       // bundle identifier
    public let name: String
    public let isRunning: Bool

    public init(id: String, name: String, isRunning: Bool) {
        self.id = id
        self.name = name
        self.isRunning = isRunning
    }
}

extension KnownApp {
    /// The settings search field's predicate: name or bundle id, case-insensitive.
    /// Lives here (not in `SettingsView`) so it stays a plain, testable function instead
    /// of logic buried in a SwiftUI view body.
    public func matches(searchQuery query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(query)
            || id.localizedCaseInsensitiveContains(query)
    }

    /// Whether this app survives the "only apps with a menu bar icon" filter.
    ///
    /// `owners == nil` means the Accessibility sweep is unavailable or has never run —
    /// "unknown", not "none" — so every app passes. An empty, non-`nil` set is treated the
    /// same way: a real sweep on this app (Stash always owns its own item) can never come
    /// back genuinely empty, so an empty result also means "not meaningful", never "hide
    /// everything". This is the rule the whole feature hinges on: a wrong read here empties
    /// the settings list and the user can no longer configure anything.
    public func hasMenuBarIcon(owners: Set<String>?) -> Bool {
        guard let owners, !owners.isEmpty else { return true }
        return owners.contains(id)
    }
}

extension Array where Element == KnownApp {
    /// The settings list's combined filter, in the fixed order the brief specifies: first
    /// menu bar ownership, then the search query. A free function (not view logic) so it
    /// stays testable without a running app or granted permission.
    public func filtered(owners: Set<String>?, query: String) -> [KnownApp] {
        filter { $0.hasMenuBarIcon(owners: owners) && $0.matches(searchQuery: query) }
    }
}

/// Tracks which apps are running and which ones we have ever seen.
///
/// Exists for one reason: the allowlist is a snapshot of bundle identifiers. Start an app
/// after we have passed that list to the menu bar, and it is not in the list, so it silently
/// vanishes from the menu bar. The app looks like it randomly eats programs. Every launch
/// must therefore trigger a recomputation.
/// - Note: Marked `@unchecked Sendable` because all mutations occur on the main thread:
///   observers deliver on `.main`, and the app accesses this class only from the main thread
///   (status item, app delegate, settings view).
public final class AppInventory: @unchecked Sendable {

    private static let namesKey = "knownAppNames"

    private let defaults: UserDefaults
    private var names: [String: String]
    private var observers: [NSObjectProtocol] = []
    private var cachedMenuBarOwners: Set<String>?

    public var onChange: (() -> Void)?

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.names = defaults.dictionary(forKey: Self.namesKey) as? [String: String] ?? [:]
        rememberRunningNames()
    }

    deinit { stop() }

    public func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            }
            observers.append(token)
        }
    }

    public func stop() {
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach { center.removeObserver($0) }
        observers.removeAll()
    }

    public func refresh() {
        rememberRunningNames()
        refreshMenuBarOwners()
        onChange?()
    }

    /// Re-sweeps which running apps currently own a menu bar item and caches the result.
    /// The sweep costs ~263 ms (measured in menubar-detection-research.md), so it must
    /// never run on every UI render — only here, which fires on launch/terminate via
    /// `start()`'s observers, and explicitly when the settings window opens.
    public func refreshMenuBarOwners() {
        cachedMenuBarOwners = MenuBarOwners.sweep()
    }

    /// `nil` when Accessibility is not granted or no sweep has run yet — callers must
    /// treat that the same as an empty result: "unknown", show everything.
    public var menuBarOwners: Set<String>? { cachedMenuBarOwners }

    public var runningBundleIDs: Set<String> {
        Set(eligibleApplications().compactMap(\.bundleIdentifier))
    }

    public var knownApps: [KnownApp] {
        let running = runningBundleIDs
        let ids = Set(names.keys).union(running)
        return ids
            .map { KnownApp(id: $0, name: names[$0] ?? $0, isRunning: running.contains($0)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func icon(for bundleID: String) -> NSImage? {
        NSWorkspace.shared.runningApplications
            .first { $0.bundleIdentifier == bundleID }?
            .icon
    }

    /// Apps that could have a status item. Which ones actually have one is impossible
    /// to know without Accessibility, so we show the larger set.
    private func eligibleApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0.bundleIdentifier != nil
                && ($0.activationPolicy == .regular || $0.activationPolicy == .accessory)
        }
    }

    private func rememberRunningNames() {
        var changed = false
        for app in eligibleApplications() {
            guard let id = app.bundleIdentifier else { continue }
            let name = app.localizedName ?? id
            if names[id] != name {
                names[id] = name
                changed = true
            }
        }
        if changed { defaults.set(names, forKey: Self.namesKey) }
    }
}
