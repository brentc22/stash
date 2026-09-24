import Foundation

/// A `major.minor.patch` version. Tags like `v0.2.0` parse too; missing parts count as 0.
public struct AppVersion: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    public init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        // Pre-release suffixes (`1.0.0-beta.2`) are not something we publish; ignore them.
        if let dash = s.firstIndex(of: "-") { s = String(s[..<dash]) }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.count <= 3, !parts.contains(nil) else { return nil }
        self.parts = parts.compactMap { $0 } + Array(repeating: 0, count: 3 - parts.count)
    }

    public static func < (a: AppVersion, b: AppVersion) -> Bool { a.parts.lexicographicallyPrecedes(b.parts) }
    public var description: String { parts.map(String.init).joined(separator: ".") }
}

/// The fields of GitHub's `releases/latest` response that the updater needs.
public struct Release: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public let name: String
        public let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey { case name, browserDownloadURL = "browser_download_url" }
    }

    public let tagName: String
    public let htmlURL: URL
    public let body: String?
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name", htmlURL = "html_url", body, draft, prerelease, assets
    }

    public var version: AppVersion? { AppVersion(tagName) }

    /// The app zip: `Stash-0.2.0.zip` (or plain `Stash.zip`).
    public func zipURL(appName: String) -> URL? {
        assets.first { $0.name.hasPrefix(appName) && $0.name.hasSuffix(".zip") }?.browserDownloadURL
    }

    public static func decode(_ data: Data) throws -> Release {
        try JSONDecoder().decode(Release.self, from: data)
    }
}

public enum UpdatePolicy {
    public static let checkInterval: TimeInterval = 24 * 60 * 60

    /// Whether to offer `release`. A skipped version is only offered again when the
    /// user asks for a check themselves.
    public static func shouldOffer(_ release: Release, current: AppVersion,
                                   skipped: String?, userInitiated: Bool) -> Bool {
        guard !release.draft, !release.prerelease, let latest = release.version, latest > current else { return false }
        return userInitiated || skipped != latest.description
    }

    public static func isCheckDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= checkInterval
    }
}

public enum UpdateError: LocalizedError, Equatable {
    case noAppInArchive
    case wrongApp(bundleID: String?)
    case wrongVersion(found: String?, expected: String)
    case invalidSignature(String)
    case command(String, status: Int32)

    public var errorDescription: String? {
        switch self {
        case .noAppInArchive: "De download bevat geen app."
        case .wrongApp(let id): "De download bevat een andere app (\(id ?? "onbekend"))."
        case .wrongVersion(let found, let expected): "De download is versie \(found ?? "onbekend"), verwacht was \(expected)."
        case .invalidSignature(let detail): "De handtekening van de gedownloade app klopt niet: \(detail)"
        case .command(let cmd, let status): "\(cmd) mislukte (exitcode \(status))."
        }
    }
}

/// Unpacks and checks a downloaded update, and swaps it in once the app has quit.
public enum UpdateInstaller {
    /// Unzips `zip` into `workDir` and returns the app inside it, after checking it is
    /// the same app (bundle id), the promised version, and intact (code signature).
    public static func prepare(zip: URL, in workDir: URL, bundleID: String, version: AppVersion) throws -> URL {
        let unpacked = workDir.appendingPathComponent("unpacked")
        try? FileManager.default.removeItem(at: unpacked)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])

        let contents = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else { throw UpdateError.noAppInArchive }

        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        let foundID = info?["CFBundleIdentifier"] as? String
        guard foundID == bundleID else { throw UpdateError.wrongApp(bundleID: foundID) }
        let foundVersion = info?["CFBundleShortVersionString"] as? String
        guard foundVersion.flatMap(AppVersion.init) == version else {
            throw UpdateError.wrongVersion(found: foundVersion, expected: version.description)
        }
        do {
            try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        } catch {
            throw UpdateError.invalidSignature(error.localizedDescription)
        }
        return app
    }

    /// A shell script that waits for `pid` to exit, moves `newApp` over `destination`
    /// (restoring the old copy if that fails) and relaunches it with `--after-update`, so the
    /// new copy can tell it was just installed. Run it detached, then quit.
    public static func swapScript(pid: Int32, newApp: URL, destination: URL, relaunch: Bool = true) -> String {
        let backup = newApp.deletingLastPathComponent().appendingPathComponent("previous.app")
        return """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf \(quote(backup.path))
        mv \(quote(destination.path)) \(quote(backup.path)) || exit 1
        if ! mv \(quote(newApp.path)) \(quote(destination.path)); then
          mv \(quote(backup.path)) \(quote(destination.path)); exit 1
        fi
        xattr -dr com.apple.quarantine \(quote(destination.path)) 2>/dev/null
        rm -rf \(quote(backup.path))
        \(relaunch ? "open \(quote(destination.path)) --args --after-update" : "")
        """
    }

    static func quote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    public static func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.command((tool as NSString).lastPathComponent, status: process.terminationStatus)
        }
    }
}
