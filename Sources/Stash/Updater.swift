import AppKit
import StashCore

/// Checks GitHub Releases once a day and offers to install a newer version, the way
/// Sparkle-based apps do (Installeren / Later / Deze versie overslaan), without the
/// dependency.
// @MainActor: an `ObservableObject` the settings window reads, driven by timers and
// button actions on the main thread. No `deinit`, so no `@unchecked Sendable` needed.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    private let feed = URL(string: "https://api.github.com/repos/brentc22/stash/releases/latest")!
    private let appName = "Stash"
    private let defaults = UserDefaults.standard
    private enum Key {
        static let automatic = "automaticallyChecksForUpdates"
        static let lastCheck = "lastUpdateCheck"
        static let skipped = "skippedUpdateVersion"
    }

    /// A newer release found by the last check; settings and the right-click menu show it.
    @Published private(set) var available: Release?
    @Published private(set) var isBusy = false
    @Published private(set) var lastCheck: Date?
    @Published var automaticallyChecks: Bool {
        didSet { defaults.set(automaticallyChecks, forKey: Key.automatic) }
    }

    /// Whether the offer should warn about Accessibility — only relevant when the
    /// menu bar filter is on, since hiding itself works without the permission.
    var usesAccessibility: () -> Bool = { false }

    private var timer: Timer?
    private var progress: NSPanel?

    private init() {
        automaticallyChecks = defaults.object(forKey: Key.automatic) as? Bool ?? true
        lastCheck = defaults.object(forKey: Key.lastCheck) as? Date
    }

    var currentVersion: AppVersion {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
            ?? AppVersion("0.0.0")!
    }

    /// Checks shortly after launch and then hourly whether a day has passed since the last check.
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkIfDue() }
        }
        timer?.tolerance = 5 * 60
    }

    private func checkIfDue() {
        guard automaticallyChecks, UpdatePolicy.isCheckDue(lastCheck: lastCheck) else { return }
        check(userInitiated: false)
    }

    func check(userInitiated: Bool) {
        guard !isBusy else { return }
        isBusy = true
        Task {
            defer { isBusy = false }
            do {
                var request = URLRequest(url: feed, timeoutInterval: 20)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                let release = try Release.decode(data)
                let now = Date()
                defaults.set(now, forKey: Key.lastCheck)
                lastCheck = now
                let skipped = defaults.string(forKey: Key.skipped)
                let newer = release.version.map { $0 > currentVersion } ?? false
                available = newer ? release : nil
                if UpdatePolicy.shouldOffer(release, current: currentVersion, skipped: skipped, userInitiated: userInitiated) {
                    offer(release)
                } else if userInitiated {
                    inform("Je hebt de nieuwste versie", "Stash \(currentVersion) is de laatste versie.")
                }
            } catch {
                NSLog("Stash: controleren op updates mislukt: \(error)")
                if userInitiated {
                    inform("Kon niet controleren op updates", error.localizedDescription, style: .warning)
                }
            }
        }
    }

    /// Opens the offer again from settings or the right-click menu.
    func offerAvailable() {
        if let available { offer(available) }
    }

    // MARK: - Offer

    private func offer(_ release: Release) {
        guard let version = release.version else { return }
        let alert = NSAlert()
        alert.icon = NSApp.applicationIconImage
        alert.messageText = "Stash \(version) is beschikbaar"
        var text = "Je hebt nu \(currentVersion). Nu installeren? Stash start daarna vanzelf opnieuw."
        if usesAccessibility() {
            // Release builds are ad-hoc signed: macOS ties the grant to the binary's hash,
            // so a new version is a new identity and the old grant no longer applies.
            text += "\n\nMacOS vraagt daarna mogelijk opnieuw om Toegankelijkheid voor het "
                + "menubalk-filter. Stash opent dan zelf de instellingen om je erdoor te loodsen."
        }
        alert.informativeText = text
        alert.accessoryView = notesView(release.body)
        alert.addButton(withTitle: "Installeren en herstarten")
        alert.addButton(withTitle: "Later")
        alert.addButton(withTitle: "Deze versie overslaan")

        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: install(release, version: version)
        case .alertThirdButtonReturn:
            defaults.set(version.description, forKey: Key.skipped)
            available = nil
        default: break
        }
    }

    private func notesView(_ body: String?) -> NSView? {
        guard let body, !body.isEmpty else { return nil }
        let notes = (try? NSAttributedString(
            markdown: body,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? NSAttributedString(string: body)
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 360, height: 160)
        scroll.borderType = .bezelBorder
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.textStorage?.setAttributedString(notes)
        text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        text.textColor = .labelColor
        return scroll
    }

    // MARK: - Install

    private func install(_ release: Release, version: AppVersion) {
        let destination = Bundle.main.bundleURL
        let parentIsWritable = FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path)
        // From `swift run`, or an /Applications we can't write to: hand over to the browser.
        guard destination.pathExtension == "app", parentIsWritable, let zipURL = release.zipURL(appName: appName) else {
            NSWorkspace.shared.open(release.htmlURL)
            return
        }

        showProgress("Stash \(version) downloaden…")
        Task {
            do {
                let (download, _) = try await URLSession.shared.download(from: zipURL)
                let workDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("StashUpdate-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
                let zip = workDir.appendingPathComponent("\(appName).zip")
                try FileManager.default.moveItem(at: download, to: zip)

                let bundleID = Bundle.main.bundleIdentifier ?? ownBundleID
                let newApp = try await Task.detached {
                    try UpdateInstaller.prepare(zip: zip, in: workDir, bundleID: bundleID, version: version)
                }.value

                let script = UpdateInstaller.swapScript(pid: ProcessInfo.processInfo.processIdentifier,
                                                        newApp: newApp, destination: destination)
                let swap = Process()
                swap.executableURL = URL(fileURLWithPath: "/bin/sh")
                swap.arguments = ["-c", script]
                try swap.run()  // outlives us: it waits for this process to exit
                // Through the delegate, so `applicationWillTerminate` lifts the menu bar
                // restriction before the old copy goes away.
                NSApp.terminate(nil)
            } catch {
                hideProgress()
                NSLog("Stash: update installeren mislukt: \(error)")
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Kon de update niet installeren"
                alert.informativeText = "\(error.localizedDescription)\n\nJe kan hem ook zelf downloaden op GitHub."
                alert.addButton(withTitle: "Open downloadpagina")
                alert.addButton(withTitle: "Annuleren")
                NSApp.activate(ignoringOtherApps: true)
                if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(release.htmlURL) }
            }
        }
    }

    private func showProgress(_ message: String) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 76),
                            styleMask: [.titled], backing: .buffered, defer: false)
        panel.title = "Stash-update"
        let label = NSTextField(labelWithString: message)
        let bar = NSProgressIndicator()
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        let stack = NSStackView(views: [label, bar])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        bar.widthAnchor.constraint(equalToConstant: 260).isActive = true
        panel.contentView = stack
        panel.center()
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        progress = panel
    }

    private func hideProgress() {
        progress?.close()
        progress = nil
    }

    private func inform(_ title: String, _ text: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
