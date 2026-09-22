import Foundation

/// MenuBarAgent logs how many items are in the bar itself. That is the only
/// reliable oracle we have without comparing screenshots:
///
///   [com.apple.menubar:analytics] MenuBar.trailingItems.count payload=["count": 12]
///
/// Intended for tests only, not for the app itself.
public enum MenuBarProbe {

    /// The last logged count, or nil when nothing was logged in that window.
    /// `--info --debug` is required: without those flags `log show` omits these lines.
    public static func lastTrailingItemsCount(withinSeconds seconds: Int = 30) -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show", "--last", "\(seconds)s", "--info", "--debug", "--style", "compact",
            "--predicate", "subsystem == \"com.apple.menubar\" AND category == \"analytics\"",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return nil }
        let pattern = #"trailingItems\.count payload=\["count": (\d+)\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let matches = regex.matches(in: output, range: NSRange(output.startIndex..., in: output))
        guard let last = matches.last, let range = Range(last.range(at: 1), in: output) else {
            return nil
        }
        return Int(output[range])
    }
}
