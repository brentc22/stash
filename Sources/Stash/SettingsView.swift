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
    @Published var hiddenIDs: Set<String> = []
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

    private let inventory: AppInventory
    private let hidden: HiddenSet
    private let preferences: Preferences
    private let onChange: () -> Void
    private var isReconcilingLaunchAtLogin = false

    init(inventory: AppInventory,
         hidden: HiddenSet,
         preferences: Preferences,
         onChange: @escaping () -> Void) {
        self.inventory = inventory
        self.hidden = hidden
        self.preferences = preferences
        self.onChange = onChange
        self.collapseDelay = preferences.collapseDelay
        self.launchAtLogin = preferences.launchAtLogin
        refresh()
    }

    /// Reloads the app list and hidden set from the source of truth. Called when the
    /// window is shown, so an app launched while the window was closed still shows up.
    func refresh() {
        apps = inventory.knownApps.filter { $0.id != ownBundleID }
        hiddenIDs = hidden.bundleIDs
        collapseDelay = preferences.collapseDelay
        launchAtLogin = preferences.launchAtLogin
    }

    func setHidden(_ isHidden: Bool, for bundleID: String) {
        hidden.setHidden(isHidden, for: bundleID)
        hiddenIDs = hidden.bundleIDs
        onChange()
    }

    func icon(for bundleID: String) -> NSImage? { inventory.icon(for: bundleID) }
}

struct SettingsView: View {

    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(width: 420, height: 520)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Verbergen").font(.headline)
            Text("Vink aan wat achter het pijltje verdwijnt. Een app met meerdere iconen "
                 + "gaat als geheel weg — dat is een beperking van macOS, niet van Stash.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }

    private var list: some View {
        List(model.apps) { app in
            Toggle(isOn: Binding(
                get: { model.hiddenIDs.contains(app.id) },
                set: { model.setHidden($0, for: app.id) }
            )) {
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
                }
            }
            .toggleStyle(.checkbox)
        }
        .listStyle(.inset)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Automatisch inklappen")
                Spacer()
                Picker("", selection: $model.collapseDelay) {
                    ForEach(CollapseDelay.allCases, id: \.rawValue) { delay in
                        Text(delay.label).tag(delay)
                    }
                }
                .labelsHidden()
                .frame(width: 180)
            }
            Toggle("Starten bij inloggen", isOn: $model.launchAtLogin)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
    }
}
