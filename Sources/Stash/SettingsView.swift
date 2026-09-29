import AppKit
import SwiftUI
import StashCore

/// Drives the settings window's state.
// @MainActor: this is a SwiftUI `ObservableObject` whose stored properties (`AppInventory`,
// `HiddenSet`, `Preferences`) are only ever touched from the main thread — `AppInventory`
// documents that invariant itself, and `HiddenSet`/`Preferences` are plain, non-Sendable
// classes that AppDelegate (itself `@MainActor`) constructs and hands over. No `deinit`
// here, so unlike `AppInventory` and `CollapseTimer` — both of which need
// `@unchecked Sendable` because a nonisolated `deinit` may not call a `@MainActor` method —
// `@MainActor` is available and is the natural fit for a view model driving a window.
@MainActor
final class SettingsModel: ObservableObject {

    @Published var apps: [KnownApp] = []
    @Published var visibilities: [String: AppVisibility] = [:]
    /// The search field's text. Purely a view concern — never persisted, never read by
    /// `refresh()` — so it's fine that it lives here instead of `Preferences`.
    @Published var query: String = ""
    /// Which of All/Hidden/Always the Apps tab shows. A view concern like `query`:
    /// never persisted, never read by `refresh()`.
    @Published var listFilter: AppListFilter = .all
    /// Which tab the window shows. Set to `.general` after an update that lost the
    /// Accessibility grant, so the explanation is the first thing on screen.
    @Published var selectedTab: SettingsTab = .apps
    @Published var collapseDelay: CollapseDelay {
        didSet {
            preferences.collapseDelay = collapseDelay
        }
    }
    @Published var revealOnHover: Bool {
        didSet { preferences.revealOnHover = revealOnHover }
    }
    @Published var wifiOnlyWhenDisconnected: Bool {
        didSet {
            preferences.wifiOnlyWhenDisconnected = wifiOnlyWhenDisconnected
            onChange()
        }
    }
    @Published var automaticPresentationMode: Bool {
        didSet {
            preferences.automaticPresentationMode = automaticPresentationMode
            onChange()
        }
    }
    @Published var showWhenActive: Set<String> = []
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
    /// A line under the shortcut field — a refused combination or a failed
    /// registration. `nil` when there is nothing to say.
    @Published var hotKeyMessage: String?
    /// "Only show apps with a menu bar icon" — the user's *wish*, which survives a
    /// permission that is not (yet) granted.
    ///
    /// It used to snap back to `false` in that case, and that was the bug:
    /// `AXIsProcessTrustedWithOptions` returns before the user has chosen anything, so the
    /// wish was discarded a millisecond after it was made, and nothing re-read trust when
    /// the user came back from System Settings. The checkbox is not lying by staying on —
    /// `isFilterActive` and the status line right beneath it say plainly whether anything
    /// is actually being filtered, and the filter starts working by itself the moment
    /// trust arrives, with no second click.
    @Published var showOnlyMenuBarApps: Bool {
        didSet {
            // Only a real click may ask for the permission. `refresh()` assigns here too,
            // and without this guard every window open would re-open the System Settings
            // prompt for someone who has the wish on but no trust yet — the exact user
            // this change is meant to help.
            guard !isReloading else { return }
            preferences.showOnlyMenuBarApps = showOnlyMenuBarApps
            if showOnlyMenuBarApps, !MenuBarOwners.isTrusted {
                MenuBarOwners.requestTrust()
            }
            refreshTrust()
        }
    }
    /// Cached sweep result, mirrored from `AppInventory` for the view to read. `nil` means
    /// "unknown" (not granted / never swept) and must be treated as "show everything".
    @Published var menuBarOwners: Set<String>?
    /// Whether macOS currently trusts this exact binary. Re-read whenever the app becomes
    /// active — that is when the user returns from System Settings.
    @Published private(set) var isTrusted: Bool = MenuBarOwners.isTrusted

    private let inventory: AppInventory
    private let hidden: HiddenSet
    private let preferences: Preferences
    private let onChange: () -> Void
    /// Applies `preferences.hotKey` to the system and reports whether that actually
    /// worked. `false` means Carbon refused the combination.
    private let onHotKeyChanged: () -> Bool
    private var isReconcilingLaunchAtLogin = false
    private var isReloading = false

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
        self.revealOnHover = preferences.revealOnHover
        self.wifiOnlyWhenDisconnected = preferences.wifiOnlyWhenDisconnected
        self.automaticPresentationMode = preferences.automaticPresentationMode
        self.launchAtLogin = preferences.launchAtLogin
        self.showOnlyMenuBarApps = preferences.showOnlyMenuBarApps
        refresh()
    }

    /// Reloads the app list and hidden set from the source of truth. Called when the
    /// window is shown, so an app launched while the window was closed still shows up.
    /// Also where the Accessibility trust is re-read and the menu bar ownership sweep
    /// runs (via `refreshTrust()`) — the settings window opening is one of the two
    /// triggers, the app becoming active again being the other.
    func refresh() {
        apps = inventory.knownApps.filter { $0.id != ownBundleID }
        visibilities = Dictionary(uniqueKeysWithValues: apps.map { ($0.id, hidden.visibility(for: $0.id)) })
        showWhenActive = hidden.showWhenActiveBundleIDs
        collapseDelay = preferences.collapseDelay
        launchAtLogin = preferences.launchAtLogin
        isReloading = true
        showOnlyMenuBarApps = preferences.showOnlyMenuBarApps
        isReloading = false
        // `refresh()` must reload everything that is persisted, or the window shows a
        // stale value the second time it is opened. `refreshTrust()` covers the
        // Accessibility trust and the sweep result.
        hotKey = preferences.hotKey
        hotKeyMessage = nil
        refreshTrust()
    }

    /// The owners set the list should actually filter on — `nil` means "show everything".
    /// Never derived from the checkbox alone: without the permission there is nothing to
    /// filter with, and an empty list would leave the user unable to configure anything.
    var effectiveOwners: Set<String>? {
        MenuBarOwners.effectiveOwners(wanted: showOnlyMenuBarApps,
                                      trusted: isTrusted,
                                      swept: menuBarOwners)
    }

    /// Whether the wish is currently being honoured. The gap between this and
    /// `showOnlyMenuBarApps` is exactly what the status line explains.
    var isFilterActive: Bool { effectiveOwners != nil }

    /// Re-reads the Accessibility trust and, when the filter is both wanted and allowed,
    /// re-runs the ~263 ms sweep. Called from `init`/`refresh()`, from the "Check
    /// Again" button, and — the case the old flow had no answer for — every time the
    /// app becomes active again, which is the moment the user comes back from System
    /// Settings. Deliberately does not sweep when the filter is not wanted: the sweep is
    /// expensive and its result would go unused.
    func refreshTrust() {
        isTrusted = MenuBarOwners.isTrusted
        if showOnlyMenuBarApps, isTrusted {
            inventory.refreshMenuBarOwners()
        }
        menuBarOwners = inventory.menuBarOwners
    }

    func openAccessibilitySettings() {
        MenuBarOwners.openSystemSettings()
    }

    func visibility(for bundleID: String) -> AppVisibility {
        visibilities[bundleID] ?? hidden.visibility(for: bundleID)
    }

    func setVisibility(_ visibility: AppVisibility, for bundleID: String) {
        hidden.setVisibility(visibility, for: bundleID)
        visibilities[bundleID] = visibility
        onChange()
    }

    func setShowWhenActive(_ on: Bool, for bundleID: String) {
        hidden.setShowWhenActive(on, for: bundleID)
        showWhenActive = hidden.showWhenActiveBundleIDs
        onChange()
    }

    func icon(for bundleID: String) -> NSImage? { inventory.icon(for: bundleID) }

    /// Stores and registers a new shortcut, or clears it with `nil`.
    ///
    /// Same "a control must not lie" reconciliation as `launchAtLogin` and
    /// `showOnlyMenuBarApps`: the field only ends up showing a combination once Carbon has
    /// confirmed it. A combination without ⌘/⌥/⌃ is refused outright, and a registration
    /// that fails — another app holds it — puts the previous one back, re-registers it,
    /// and says so instead of failing silently.
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
            hotKeyMessage = "This combination is already in use by another app."
            return
        }
        hotKey = preferences.hotKey
        hotKeyMessage = nil
    }
}

enum SettingsTab: Hashable { case apps, general }

struct SettingsView: View {

    @ObservedObject var model: SettingsModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            AppsTab(model: model)
                .tabItem { Text("Apps") }
                .tag(SettingsTab.apps)
            GeneralTab(model: model)
                .tabItem { Text("General") }
                .tag(SettingsTab.general)
        }
        .frame(width: 460, height: 720)
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
    /// change what's on screen. Ownership first, then the All/Hidden/Always segment,
    /// then the search query; ownership only applies at all when the checkbox on the
    /// General tab is on — otherwise `owners` is `nil`, which already means "show
    /// everything".
    private var filteredApps: [KnownApp] {
        return model.apps.filtered(owners: model.effectiveOwners,
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
            TextField("Search", text: $model.query)
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
            // "shown of total": the total is the full inventory, so turning on the
            // menu bar filter on the General tab is visible here as the left number
            // dropping while the right one stays put.
            Text("\(shown) of \(model.apps.count)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func list(_ rows: [KnownApp]) -> some View {
        if rows.isEmpty {
            Text("No apps found")
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
                Text("not running")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            Spacer(minLength: 8)
            ShowWhenActiveButton(enabled: visibility == .hidden,
                                 isOn: model.showWhenActive.contains(app.id)) {
                model.setShowWhenActive($0, for: app.id)
            }
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
            Text("\(counts[.visible] ?? 0) visible · \(counts[.hidden] ?? 0) hidden "
                 + "· \(counts[.alwaysHidden] ?? 0) always hidden")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 34)
    }
}

/// "Show while this app is in front" — only meaningful for Hide: a visible app is already
/// there, and Always hide means never. Rendered but inert for those, so the column stays
/// aligned and the rule is not lost while the app is briefly switched to another state.
struct ShowWhenActiveButton: View {

    let enabled: Bool
    let isOn: Bool
    let onToggle: (Bool) -> Void

    private var hint: String {
        enabled ? "Show while this app is in front" : "Only for apps set to Hide"
    }

    var body: some View {
        Button {
            onToggle(!isOn)
        } label: {
            Image(systemName: isOn ? "macwindow.badge.plus" : "macwindow")
                .font(.system(size: 11))
                .foregroundStyle(enabled && isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(hint)
        .accessibilityLabel(hint)
        .accessibilityValue(isOn ? "On" : "Off")
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
    @ObservedObject var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            hotKeySection
            Divider()
            behaviourSection
            Divider()
            rulesSection
            Divider()
            accessibilitySection
            Divider()
            updatesSection
            Spacer(minLength: 0)
            Divider()
            footer
        }
        .padding(18)
    }

    private var hotKeySection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionHeader("SHORTCUT")
            HStack(spacing: 10) {
                Text("Hide and show")
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
            Text("Click the field and press the combination you want. Escape cancels. If "
                 + "another app already uses it, Stash tells you right away instead of "
                 + "silently doing nothing.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var behaviourSection: some View {
        VStack(alignment: .leading, spacing: 11) {
            sectionHeader("BEHAVIOUR")
            HStack(spacing: 10) {
                Text("Auto-collapse")
                Spacer()
                Picker("", selection: $model.collapseDelay) {
                    ForEach(CollapseDelay.allCases, id: \.rawValue) { delay in
                        Text(delay.label).tag(delay)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            Toggle("Expand when hovering the arrow", isOn: $model.revealOnHover)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Launch at login", isOn: $model.launchAtLogin)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionHeader("RULES")
            Toggle("Show Wi-Fi only when disconnected", isOn: $model.wifiOnlyWhenDisconnected)
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("Presentation mode during screen sharing and calls", isOn: $model.automaticPresentationMode)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Presentation mode hides everything but the arrow while this Mac is screen "
                 + "shared, mirrored to another display, or in a Zoom meeting. You can also "
                 + "switch it on by hand from the right-click menu. Per app, the window "
                 + "button on the Apps tab shows a hidden app while it is in front.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var accessibilitySection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionHeader("ACCESSIBILITY")
            Toggle("Only show apps with a menu bar icon", isOn: $model.showOnlyMenuBarApps)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("For this, macOS asks once for Accessibility. Stash only uses it to see "
                 + "which apps have an icon — hiding and showing work without it. If you "
                 + "don't grant it, the full list stays.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            permissionStatus
            if model.showOnlyMenuBarApps, !model.isTrusted {
                permissionHelp
            }
        }
    }

    /// Reports what the sweep actually found, rather than what the checkbox wishes for.
    /// With no permission there is no count to show — say that instead of showing a zero
    /// that would read as "no app has an icon".
    private var permissionStatus: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(model.isFilterActive ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            Text(statusText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Check Again") { model.refreshTrust() }
                .controlSize(.small)
        }
        .padding(.top, 2)
    }

    private var statusText: String {
        guard model.showOnlyMenuBarApps else {
            return "Filter is off — showing the full list"
        }
        if let found = model.effectiveOwners?.count {
            return "Permission granted · \(found) apps with an icon found"
        }
        return "No permission yet — the full list stays"
    }

    /// Shown only while the wish is on but trust is missing — the moment the user is
    /// actually stuck. The ad-hoc signing trap belongs here, not only in the README:
    /// nobody opens a README while staring at a switch that is already blue.
    private var permissionHelp: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("The filter turns on by itself as soon as permission is granted — you don't "
                 + "need to tick this box again.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Stash is already listed with its switch on, and it still doesn't work? "
                 + "Stash is ad-hoc signed, and for such an app macOS ties Accessibility "
                 + "to the binary's cdhash. Every new version is therefore a new "
                 + "identity: the entry you see belongs to a binary that no longer "
                 + "exists. Remove that entry with the minus button and add Stash "
                 + "again.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") { model.openAccessibilitySettings() }
                .controlSize(.small)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.accentColor.opacity(0.10))
        )
    }

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            sectionHeader("UPDATES")
            Toggle("Automatically check for updates", isOn: $updater.automaticallyChecks)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 7) {
                Text(updateStatus)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let version = updater.available?.version {
                    Button("Install Stash \(version)…") { updater.offerAvailable() }
                        .controlSize(.small)
                } else {
                    Button("Check Now") { updater.check(userInitiated: true) }
                        .controlSize(.small)
                        .disabled(updater.isBusy)
                }
            }
        }
    }

    /// "Version 0.1.0 · last checked today at 15:42", or the version that is waiting.
    private var updateStatus: String {
        if updater.isBusy { return "Version \(Self.version) · checking…" }
        if let version = updater.available?.version {
            return "Version \(Self.version) · Stash \(version) is available"
        }
        guard let last = updater.lastCheck else { return "Version \(Self.version) · not checked yet" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return "Version \(Self.version) · last checked \(formatter.string(from: last))"
    }

    private var footer: some View {
        HStack {
            Text("Stash \(Self.version)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Link("Source on GitHub", destination: URL(string: "https://github.com/brentc22/stash")!)
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
