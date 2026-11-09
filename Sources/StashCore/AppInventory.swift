import AppKit

public struct KnownApp: Identifiable, Hashable {
    public let id: String       // bundle identifier
    public let name: String
    public let isRunning: Bool
    /// A Control Center control rather than an app; `id` is its extension's bundle id.
    public let isControl: Bool

    public init(id: String, name: String, isRunning: Bool, isControl: Bool = false) {
        self.id = id
        self.name = name
        self.isRunning = isRunning
        self.isControl = isControl
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
    ///
    /// Controls always pass: the Accessibility sweep only sees apps, so a control would
    /// otherwise vanish from the list exactly when the filter is on.
    public func hasMenuBarIcon(owners: Set<String>?) -> Bool {
        if isControl { return true }
        guard let owners, !owners.isEmpty else { return true }
        return owners.contains(id)
    }
}

extension Array where Element == KnownApp {
    /// The Apps tab's combined filter: menu bar ownership, the Alles/Verborgen/Altijd
    /// segment and the search query. A free function (not view logic) so it stays testable
    /// without a running app or granted permission. All three narrow cumulatively, in the fixed order ownership → visibility → query, so
    /// picking "Hidden" and then typing never widens the result again. `visibility`
    /// is a closure rather than a dictionary so this stays independent of how the caller
    /// stores state.
    public func filtered(owners: Set<String>?,
                         query: String,
                         filter: AppListFilter,
                         visibility: (String) -> AppVisibility) -> [KnownApp] {
        self.filter {
            $0.hasMenuBarIcon(owners: owners)
                && filter.matches(visibility($0.id))
                && $0.matches(searchQuery: query)
        }
    }
}

/// Tracks which apps are running and which ones we have ever seen.
///
/// Exists for one reason: the allowlist is a snapshot of bundle identifiers. Start an app
/// after we have passed that list to the menu bar, and it is not in the list, so it silently
/// vanishes from the menu bar. The app looks like it randomly eats programs. Every launch
/// must therefore trigger a recomputation.
/// - Note: Marked `@unchecked Sendable` because all mutations occur on the main thread. The
///   KVO callback in `start()` arrives on whichever thread changed `runningApplications`, so
///   it only hops to main and touches nothing itself; the app accesses this class only from
///   the main thread (status item, app delegate, settings view).
public final class AppInventory: @unchecked Sendable {

    private static let namesKey = "knownAppNames"

    private let defaults: UserDefaults
    private var names: [String: String]
    private var observation: NSKeyValueObservation?
    private var cachedMenuBarOwners: Set<String>?
    private var controls: [MenuBarControl]
    private var controlsTimer: Timer?
    private let readControls: () -> [MenuBarControl]

    public var onChange: (() -> Void)?

    /// - Parameter readControls: where the Control Center controls come from; injectable
    ///   so tests don't depend on what this Mac has in its menu bar.
    public init(defaults: UserDefaults = .standard,
                readControls: @escaping () -> [MenuBarControl] = MenuBarControls.current) {
        self.defaults = defaults
        self.names = defaults.dictionary(forKey: Self.namesKey) as? [String: String] ?? [:]
        self.readControls = readControls
        self.controls = readControls()
        rememberRunningNames()
    }

    deinit { stop() }

    /// Observes `runningApplications` via KVO instead of `didLaunchApplicationNotification`:
    /// that notification only fires for apps with a Dock icon, and menu bar apps
    /// (`LSUIElement`) have none — precisely the apps Stash exists for. Measured
    /// 24-09-2026: launching Portside fired the KVO change, not the notification.
    public func start() {
        observation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            DispatchQueue.main.async {
                // A change queued before `stop()` must not still fire after it.
                guard let self, self.observation != nil else { return }
                self.refresh()
            }
        }
        // Adding a control to the menu bar changes no running app and posts no
        // notification, so Control Center's preference is polled. A cheap read.
        controlsTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshControlsIfChanged()
        }
        controlsTimer?.tolerance = 2
    }

    public func stop() {
        observation = nil
        controlsTimer?.invalidate()
        controlsTimer = nil
    }

    /// Re-reads the controls and calls `onChange` only when they changed.
    public func refreshControlsIfChanged() {
        let fresh = readControls()
        guard fresh != controls else { return }
        controls = fresh
        refresh()
    }

    public func refresh() {
        rememberRunningNames()
        onChange?()
    }

    /// Re-sweeps which running apps currently own a menu bar item and caches the result.
    /// The sweep costs ~263 ms on the main thread (measured in menubar-detection-research.md),
    /// so it runs only on demand — from `SettingsModel.refreshTrust()`, and only while the
    /// filter is wanted. Not from `refresh()`: that fires on every change to the running
    /// apps, and nothing reads this cache without sweeping first anyway.
    public func refreshMenuBarOwners() {
        cachedMenuBarOwners = MenuBarOwners.sweep()
    }

    /// `nil` when Accessibility is not granted or no sweep has run yet — callers must
    /// treat that the same as an empty result: "unknown", show everything.
    public var menuBarOwners: Set<String>? { cachedMenuBarOwners }

    /// Running apps plus Control Center's controls: both can own an item in the bar, and
    /// anything missing here is kept out of it while the restriction is active.
    public var runningBundleIDs: Set<String> {
        Set(eligibleApplications().compactMap(\.bundleIdentifier))
            .union(controls.map(\.extensionID))
    }

    public var knownApps: [KnownApp] {
        // One pass over the running apps for both the running set and their live names.
        var live: [String: String] = [:]
        for app in eligibleApplications() {
            guard let id = app.bundleIdentifier else { continue }
            live[id] = app.localizedName ?? id
        }
        let controlNames = Dictionary(controls.map { ($0.extensionID, $0.name) }) { first, _ in first }
        return Set(names.keys).union(live.keys).union(controlNames.keys)
            .map { id in
                if let name = controlNames[id] {
                    return KnownApp(id: id, name: name, isRunning: true, isControl: true)
                }
                return KnownApp(id: id, name: names[id] ?? live[id] ?? id, isRunning: live[id] != nil)
            }
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
