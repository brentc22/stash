import AppKit
import SwiftUI
import StashCore

/// Drives the settings window's state.
// @MainActor: this is a SwiftUI `ObservableObject` whose stored properties (`AppInventory`,
// `HiddenSet`, `Preferences`) are only ever touched from the main thread — `AppInventory`
// documents that invariant itself, and `HiddenSet`/`Preferences` are plain, non-Sendable
// classes that AppDelegate (itself `@MainActor`) constructs and hands over. No `deinit`
// here, so unlike `AppInventory` (Task 4) and `CollapseTimer` (Task 6) — both of which need
// `@unchecked Sendable` because a nonisolated `deinit` may not call a `@MainActor` method —
// `@MainActor` is available and is the natural fit for a view model driving a window.
@MainActor
final class SettingsModel: ObservableObject {

    @Published var apps: [KnownApp] = []
    @Published var visibilities: [String: AppVisibility] = [:]
    /// The search field's text. Purely a view concern — never persisted, never read by
    /// `refresh()` — so it's fine that it lives here instead of `Preferences`.
    @Published var query: String = ""
    @Published var collapseDelay: CollapseDelay {
        didSet {
            preferences.collapseDelay = collapseDelay
        }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            guard !isReconcilingLaunchAtLogin else { return }
            preferences.launchAtLogin = launchAtLogin
            // `Preferences.launchAtLogin`'s setter swallows a failing
            // `SMAppService.register()`/`unregister()` and just logs it — the checkbox
            // must not keep showing a value the system never actually adopted. Read
            // the real state back and, if it disagrees, correct the published value.
            let actual = preferences.launchAtLogin
            if actual != launchAtLogin {
                isReconcilingLaunchAtLogin = true
                launchAtLogin = actual
                isReconcilingLaunchAtLogin = false
            }
        }
    }
    @Published var useGlobalHotKey: Bool {
        didSet {
            guard !isReconcilingHotKeyPreference else { return }
            preferences.useGlobalHotKey = useGlobalHotKey
            // May itself flip the preference back to `false` — `AppDelegate`'s
            // `syncHotKeyRegistration` does exactly that when Carbon registration fails
            // (the combination is already taken by another app). Read the real value
            // back afterwards so this checkbox never keeps claiming a hotkey that isn't
            // actually active. Same reconciliation pattern as `launchAtLogin` above.
            onHotKeyPreferenceChanged()
            let actual = preferences.useGlobalHotKey
            if actual != useGlobalHotKey {
                isReconcilingHotKeyPreference = true
                useGlobalHotKey = actual
                isReconcilingHotKeyPreference = false
            }
        }
    }
    /// "Toon alleen apps met een menubalk-icoon". Turning this on for the first time
    /// requests the Accessibility permission; `AXIsProcessTrustedWithOptions` returns
    /// immediately without waiting for the user, so right after asking, trust is still
    /// whatever it was before. If that isn't `true`, the checkbox must not keep claiming
    /// an "on" state the system never granted — same reconciliation pattern as
    /// `launchAtLogin` and `useGlobalHotKey` above, and the same mistake (F18, F12) this
    /// whole house pattern exists to avoid repeating.
    @Published var showOnlyMenuBarApps: Bool {
        didSet {
            guard !isReconcilingMenuBarFilter else { return }
            if showOnlyMenuBarApps, !MenuBarOwners.isTrusted {
                MenuBarOwners.requestTrust()
                if !MenuBarOwners.isTrusted {
                    isReconcilingMenuBarFilter = true
                    showOnlyMenuBarApps = false
                    isReconcilingMenuBarFilter = false
                }
            }
            preferences.showOnlyMenuBarApps = showOnlyMenuBarApps
            // Re-sweep whenever this changes, and (via `refresh()`, which also assigns
            // here) every time the settings window opens — never per render or keystroke.
            inventory.refreshMenuBarOwners()
            menuBarOwners = inventory.menuBarOwners
        }
    }
    /// Cached sweep result, mirrored from `AppInventory` for the view to read. `nil` means
    /// "unknown" (not granted / never swept) and must be treated as "show everything".
    @Published var menuBarOwners: Set<String>?

    private let inventory: AppInventory
    private let hidden: HiddenSet
    private let preferences: Preferences
    private let onChange: () -> Void
    private let onHotKeyPreferenceChanged: () -> Void
    private var isReconcilingLaunchAtLogin = false
    private var isReconcilingHotKeyPreference = false
    private var isReconcilingMenuBarFilter = false

    init(inventory: AppInventory,
         hidden: HiddenSet,
         preferences: Preferences,
         onChange: @escaping () -> Void,
         onHotKeyPreferenceChanged: @escaping () -> Void) {
        self.inventory = inventory
        self.hidden = hidden
        self.preferences = preferences
        self.onChange = onChange
        self.onHotKeyPreferenceChanged = onHotKeyPreferenceChanged
        self.collapseDelay = preferences.collapseDelay
        self.launchAtLogin = preferences.launchAtLogin
        self.useGlobalHotKey = preferences.useGlobalHotKey
        self.showOnlyMenuBarApps = preferences.showOnlyMenuBarApps
        refresh()
    }

    /// Reloads the app list and hidden set from the source of truth. Called when the
    /// window is shown, so an app launched while the window was closed still shows up.
    /// Also where the menu bar ownership sweep runs (via `showOnlyMenuBarApps`'s
    /// `didSet`) — the settings window opening is one of the two triggers the brief
    /// specifies, launch/terminate (inside `AppInventory`) being the other.
    func refresh() {
        apps = inventory.knownApps.filter { $0.id != ownBundleID }
        visibilities = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, hidden.visibility(for: $0.id)) })
        collapseDelay = preferences.collapseDelay
        launchAtLogin = preferences.launchAtLogin
        useGlobalHotKey = preferences.useGlobalHotKey
        showOnlyMenuBarApps = preferences.showOnlyMenuBarApps
        menuBarOwners = inventory.menuBarOwners
    }

    func visibility(for bundleID: String) -> AppVisibility {
        visibilities[bundleID] ?? hidden.visibility(for: bundleID)
    }

    func setVisibility(_ visibility: AppVisibility, for bundleID: String) {
        hidden.setVisibility(visibility, for: bundleID)
        visibilities[bundleID] = visibility
        onChange()
    }

    func icon(for bundleID: String) -> NSImage? { inventory.icon(for: bundleID) }
}

struct SettingsView: View {

    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView {
            AppsTab(model: model)
                .tabItem { Text("Apps") }
            GeneralTab(model: model)
                .tabItem { Text("Algemeen") }
        }
        .frame(width: 460, height: 640)
    }
}

/// The per-app list and the filters that only narrow what it shows. Everything that is
/// not per-app now lives on `GeneralTab` — before this split the list was wedged between
/// four lines of explanation and a block of global checkboxes, and got the least room of
/// the three.
struct AppsTab: View {

    @ObservedObject var model: SettingsModel

    /// Filters the app list for display only — never touches the hidden set. An app
    /// filtered out of view stays hidden or visible exactly as it was; the search field
    /// only changes what's on screen. Ownership filters first, then the search query
    /// (`KnownApp.filtered(owners:query:)`); ownership only applies at all when the
    /// checkbox is on — otherwise `owners` is `nil`, which already means "show everything".
    private var filteredApps: [KnownApp] {
        let owners = model.showOnlyMenuBarApps ? model.menuBarOwners : nil
        return model.apps.filtered(owners: owners, query: model.query)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            searchField
            Divider()
            list
        }
    }

    private var searchField: some View {
        TextField("Zoeken", text: $model.query)
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
    }

    private var list: some View {
        Group {
            if filteredApps.isEmpty {
                Text("Geen apps gevonden")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredApps) { app in
                    HStack(spacing: 8) {
                        if let icon = model.icon(for: app.id) {
                            Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                        } else {
                            Image(systemName: "app.dashed").frame(width: 16, height: 16)
                        }
                        Text(app.name)
                        if !app.isRunning {
                            Text("niet actief").font(.caption).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { model.visibility(for: app.id) },
                            set: { model.setVisibility($0, for: app.id) }
                        )) {
                            ForEach(AppVisibility.allCases, id: \.rawValue) { visibility in
                                Text(visibility.label).tag(visibility)
                            }
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .frame(width: 150)
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

/// Everything that is not per-app: collapse behaviour, login item, the global hotkey and
/// the optional Accessibility-backed filter whose *effect* you see on the Apps tab.
struct GeneralTab: View {

    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            hotKeySection
            Divider()
            behaviourSection
            Divider()
            accessibilitySection
            Spacer(minLength: 0)
            Divider()
            footer
        }
        .padding(18)
    }

    private var hotKeySection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionHeader("SNELTOETS")
            Toggle("Sneltoets ⌃⌥S gebruiken", isOn: $model.useGlobalHotKey)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var behaviourSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionHeader("GEDRAG")
            HStack(spacing: 10) {
                Text("Automatisch inklappen")
                Spacer()
                Picker("", selection: $model.collapseDelay) {
                    ForEach(CollapseDelay.allCases, id: \.rawValue) { delay in
                        Text(delay.label).tag(delay)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            Toggle("Starten bij inloggen", isOn: $model.launchAtLogin)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var accessibilitySection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionHeader("TOEGANKELIJKHEID")
            Toggle("Alleen apps met een menubalk-icoon tonen", isOn: $model.showOnlyMenuBarApps)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Hiervoor vraagt macOS eenmalig Toegankelijkheid. Stash gebruikt dat "
                 + "alleen om te zien wélke apps een icoon hebben — verbergen en tonen "
                 + "werkt ook zonder. Geef je geen toestemming, dan blijft de volledige "
                 + "lijst staan.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Text("Stash \(Self.version)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Link("Broncode op GitHub", destination: URL(string: "https://github.com/brentc22/stash")!)
                .font(.caption)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .bold))
            .kerning(0.4)
            .foregroundStyle(.secondary)
    }

    /// Read from the bundle rather than hardcoded, so the footer can never drift from the
    /// version that was actually shipped. `swift run` has no bundle version — fall back to
    /// a dash instead of printing a number that would be a guess.
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}
