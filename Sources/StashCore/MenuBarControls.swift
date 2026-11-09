import Foundation

/// A Control Center control (Dark Mode, Stage Manager, a third-party control, …) that
/// can sit in the menu bar on its own.
///
/// These are not apps: each one comes from a control *extension*, which never shows up
/// in `NSWorkspace.runningApplications`. An allowlist built from running apps therefore
/// never contains them, and macOS keeps them out of the bar for as long as the
/// restriction is active (issue #10). Their extension bundle identifiers are read from
/// Control Center's own preferences instead.
public struct MenuBarControl: Equatable, Sendable {
    public let extensionID: String
    /// The control's display name; several controls from one extension are joined.
    public let name: String

    public init(extensionID: String, name: String) {
        self.extensionID = extensionID
        self.name = name
    }
}

public enum MenuBarControls {
    static let domain = "com.apple.controlcenter"
    static let key = "ControlCenterDisplayableChronoControlsProviderConfiguration"

    /// The controls Control Center offers right now. Empty when the preference is
    /// missing or its format changed — callers then simply behave as before.
    public static func current() -> [MenuBarControl] {
        CFPreferencesAppSynchronize(domain as CFString)
        guard let data = CFPreferencesCopyAppValue(key as CFString, domain as CFString) as? Data else { return [] }
        return parse(configuration: data)
    }

    /// The preference is JSON: `{"Controls": [{"DisplayName": …, "ControlIdentity":
    /// <base64 keyed archive of CHSControlIdentity>}, …]}`. The archive's `extId` is a
    /// `CHSExtensionIdentity` holding `extensionBundleIdentifier`.
    public static func parse(configuration data: Data) -> [MenuBarControl] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let controls = root["Controls"] as? [[String: Any]] else { return [] }

        var order: [String] = []
        var names: [String: [String]] = [:]
        for control in controls {
            guard let encoded = control["ControlIdentity"] as? String,
                  let archive = Data(base64Encoded: encoded),
                  let extensionID = extensionID(fromArchive: archive) else { continue }
            let name = (control["DisplayName"] as? String) ?? extensionID
            if names[extensionID] == nil { order.append(extensionID) }
            if !(names[extensionID] ?? []).contains(name) { names[extensionID, default: []].append(name) }
        }
        return order.map { MenuBarControl(extensionID: $0, name: names[$0]!.joined(separator: " · ")) }
    }

    static func extensionID(fromArchive data: Data) -> String? {
        guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        unarchiver.requiresSecureCoding = false
        // Stand-ins for ChronoServices' private classes, which this process doesn't load.
        unarchiver.setClass(ArchivedControlIdentity.self, forClassName: "CHSControlIdentity")
        unarchiver.setClass(ArchivedExtensionIdentity.self, forClassName: "CHSExtensionIdentity")
        defer { unarchiver.finishDecoding() }
        let root = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? ArchivedControlIdentity
        guard let id = root?.extensionID, !id.isEmpty else { return nil }
        return id
    }
}

@objc(StashArchivedControlIdentity)
private final class ArchivedControlIdentity: NSObject, NSCoding {
    let extensionID: String?

    init?(coder: NSCoder) {
        extensionID = (coder.decodeObject(forKey: "extId") as? ArchivedExtensionIdentity)?.extensionID
    }

    func encode(with coder: NSCoder) {}
}

@objc(StashArchivedExtensionIdentity)
private final class ArchivedExtensionIdentity: NSObject, NSCoding {
    let extensionID: String?

    init?(coder: NSCoder) {
        extensionID = coder.decodeObject(forKey: "extensionBundleIdentifier") as? String
    }

    func encode(with coder: NSCoder) {}
}
