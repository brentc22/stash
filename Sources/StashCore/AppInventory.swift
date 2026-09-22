import AppKit

public struct KnownApp: Identifiable, Hashable {
    public let id: String       // bundle identifier
    public let name: String
    public var isRunning: Bool
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
        onChange?()
    }

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
