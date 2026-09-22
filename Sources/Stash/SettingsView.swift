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
    /// Which of Alles/Verborgen/Altijd the Apps tab shows. A view concern like `query`:
    /// never persisted, never read by `refresh()`.
    @Published var listFilter: AppListFilter = .all
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
    /// The recorded global shortcut, or `nil` for none. Read-only from the view: it is
    /// only ever changed through `setHotKey(_:)`, which refuses to show a combination the
    /// system did not actually hand us.
    @Published private(set) var hotKey: HotKeyCombo?
    /// A Dutch line under the shortcut field — a refused combination or a failed
    /// registration. `nil` when there is nothing to say.
    @Published var hotKeyMessage: String?
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
    /// Applies `preferences.hotKey` to the system and reports whether that actually
    /// worked. `false` means Carbon refused the combination.
    private let onHotKeyChanged: () -> Bool
    private var isReconcilingLaunchAtLogin = false
    private var isReconcilingMenuBarFilter = false

    init(inventory: AppInventory,
         hidden: HiddenSet,
         preferences: Preferences,
         onChange: @escaping () -> Void,
         onHotKeyChanged: @escaping () -> Bool) {
        self.inventory = inventory
        self.hidden = hidden
        self.preferences = preferences
        self.onChange = onChange
        self.onHotKeyChanged = onHotKeyChanged
        self.collapseDelay = preferences.collapseDelay
        self.launchAtLogin = preferences.launchAtLogin
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
        showOnlyMenuBarApps = preferences.showOnlyMenuBarApps
        // `refresh()` must reload everything that is persisted, or the window shows a
        // stale value the second time it is opened.
        hotKey = preferences.hotKey
        hotKeyMessage = nil
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

    /// Stores and registers a new shortcut, or clears it with `nil`.
    ///
    /// Same "a control must not lie" reconciliation as `launchAtLogin` and
    /// `showOnlyMenuBarApps`: the field only ends up showing a combination once Carbon has
    /// confirmed it. A combination without ⌘/⌥/⌃ is refused outright, and a registration
    /// that fails — another app holds it — puts the previous one back, re-registers it,
    /// and says so in Dutch instead of failing silently.
    func setHotKey(_ combo: HotKeyCombo?) {
        if let combo, let reason = combo.rejectionReason {
            hotKeyMessage = reason
            return
        }

        let previous = preferences.hotKey
        guard combo != previous else {
            hotKeyMessage = nil
            return
        }

        preferences.hotKey = combo
        guard onHotKeyChanged() else {
            preferences.hotKey = previous
            _ = onHotKeyChanged()
            hotKey = preferences.hotKey
            hotKeyMessage = "Deze combinatie is al in gebruik door een andere app."
            return
        }
        hotKey = preferences.hotKey
        hotKeyMessage = nil
    }
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
    /// filtered out of view stays hidden or visible exactly as it was; the filters only
    /// change what's on screen. Ownership first, then the Alles/Verborgen/Altijd segment,
    /// then the search query; ownership only applies at all when the checkbox on the
    /// Algemeen tab is on — otherwise `owners` is `nil`, which already means "show
    /// everything".
    private var filteredApps: [KnownApp] {
        let owners = model.showOnlyMenuBarApps ? model.menuBarOwners : nil
        return model.apps.filtered(owners: owners,
                                   query: model.query,
                                   filter: model.listFilter) { model.visibility(for: $0) }
    }

    var body: some View {
        let rows = filteredApps
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 9) {
                searchField
                filterBar(shown: rows.count)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 10)

            list(rows)

            Divider()
            statusLine(rows)
        }
    }

    private var searchField: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Zoeken", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
        }
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(nsColor: .textBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color(nsColor: .separatorColor))
        )
    }

    private func filterBar(shown: Int) -> some View {
        HStack(spacing: 7) {
            Picker("", selection: $model.listFilter) {
                ForEach(AppListFilter.allCases, id: \.rawValue) { filter in
                    Text(filter.label).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            // "getoond van totaal": the total is the full inventory, so turning on the
            // menu bar filter on the Algemeen tab is visible here as the left number
            // dropping while the right one stays put.
            Text("\(shown) van \(model.apps.count)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func list(_ rows: [KnownApp]) -> some View {
        if rows.isEmpty {
            Text("Geen apps gevonden")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(rows) { app in
                        row(app)
                    }
                }
                .padding(.vertical, 2)
            }
            .padding(.horizontal, 10)
        }
    }

    private func row(_ app: KnownApp) -> some View {
        let visibility = model.visibility(for: app.id)
        return HStack(spacing: 10) {
            icon(for: app)
            // `.lineLimit(1)` + tail truncation, not wrapping: a single long identifier
            // like BackgroundTaskManagementAgent otherwise makes its one row taller than
            // all the others and the list stops looking like a list.
            Text(app.name)
                .font(.system(size: 12.5))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(visibility == .alwaysHidden ? AnyShapeStyle(.secondary)
                                                             : AnyShapeStyle(.primary))
            if !app.isRunning {
                Text("niet actief")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            Spacer(minLength: 8)
            VisibilityPicker(selection: visibility) {
                model.setVisibility($0, for: app.id)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 40)
        // A row that is not on the default value gets a faint accent wash, so with fifty
        // rows you can see at a glance which handful you actually changed.
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(visibility == .visible ? Color.clear : Color.accentColor.opacity(0.10))
        )
    }

    @ViewBuilder
    private func icon(for app: KnownApp) -> some View {
        if let image = model.icon(for: app.id) {
            Image(nsImage: image)
                .resizable()
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: "app.dashed")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
        }
    }

    private func statusLine(_ rows: [KnownApp]) -> some View {
        let counts = Dictionary(grouping: rows) { model.visibility(for: $0.id) }
            .mapValues(\.count)
        return HStack {
            Text("\(counts[.visible] ?? 0) zichtbaar · \(counts[.hidden] ?? 0) verborgen "
                 + "· \(counts[.alwaysHidden] ?? 0) altijd verborgen")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
    }
}

/// The three states as three real buttons instead of a `Picker`. Only the active one is
/// tinted: with fifty rows nearly all sitting on the default, the default must not draw
/// the eye. Each is a `Button` with its own accessibility label, not a tappable `Image`.
struct VisibilityPicker: View {

    let selection: AppVisibility
    let onSelect: (AppVisibility) -> Void

    var body: some View {
        HStack(spacing: 1) {
            ForEach(AppVisibility.allCases, id: \.rawValue) { visibility in
                Button {
                    onSelect(visibility)
                } label: {
                    Image(systemName: visibility.symbolName)
                        .font(.system(size: 11))
                        .foregroundStyle(visibility == selection
                                         ? AnyShapeStyle(Color.white)
                                         : AnyShapeStyle(.secondary))
                        .frame(width: 30, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(visibility == selection ? Color.accentColor : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(visibility.hint)
                .accessibilityLabel(visibility.hint)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
        )
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
            HStack(spacing: 10) {
                Text("Verbergen en tonen")
                    .font(.system(size: 12.5))
                Spacer()
                HotKeyRecorderField(
                    combo: model.hotKey,
                    onRecord: { model.setHotKey($0) },
                    onClear: { model.setHotKey(nil) }
                )
            }
            if let message = model.hotKeyMessage {
                Text(message)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Klik op het veld en druk de combinatie die je wil. Escape annuleert. Is "
                 + "hij al door een andere app bezet, dan zegt Stash dat meteen in plaats "
                 + "van stil niets te doen.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
            permissionStatus
        }
    }

    /// Reports what the sweep actually found, rather than what the checkbox claims. With
    /// no permission there is no count to show — say that instead of showing a zero that
    /// would read as "no app has an icon".
    private var permissionStatus: some View {
        let trusted = MenuBarOwners.isTrusted
        let found = model.menuBarOwners?.count
        return HStack(spacing: 7) {
            Circle()
                .fill(trusted ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text(trusted && found != nil
                 ? "Toestemming verleend · \(found!) apps met een icoon gevonden"
                 : "Geen toestemming — de volledige lijst blijft staan")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.top, 2)
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
