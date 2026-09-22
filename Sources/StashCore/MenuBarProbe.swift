import Foundation

/// MenuBarAgent logs how many items are in the bar itself. That is the only
/// reliable oracle we have without comparing screenshots:
///
///   [com.apple.menubar:analytics] MenuBar.trailingItems.count payload=["count": 12]
///
/// Intended for tests only, not for the app itself.
public enum MenuBarProbe {

    /// `log show --start` only accepts second-granularity local timestamps (no fractional
    /// seconds) in one of a few fixed formats. en_US_POSIX so the locale never swaps digits,
    /// separators, or calendar.
    private static let startArgumentFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    /// The compact style prints each line's own timestamp with millisecond precision. We
    /// re-parse it so a reading can be pinned to "at or after `since`" exactly — `--start`'s
    /// second-level rounding alone could still let a stale line from earlier in the same
    /// second through, which is exactly the false-pass this oracle exists to rule out.
    private static let lineTimestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private static let linePattern =
        #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}).*trailingItems\.count payload=\["count": (\d+)\]"#

    /// Polls for a trailingItems.count line logged at or after `since`, so a reading is
    /// provably caused by whatever ran at or after that moment — not a stale count that
    /// happened to still sit inside some fixed lookback window. Polls up to 50 times, 100 ms
    /// apart (5 s total budget); returns nil only once that budget is exhausted.
    /// `--info --debug` is required: without those flags `log show` omits these lines entirely.
    public static func lastTrailingItemsCount(since: Date) -> Int? {
        for _ in 0..<50 {
            if let count = queryOnce(since: since) {
                return count
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return nil
    }

    private static func queryOnce(since: Date) -> Int? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = [
            "show", "--start", startArgumentFormatter.string(from: since),
            "--info", "--debug", "--style", "compact",
            "--predicate", "subsystem == \"com.apple.menubar\" AND category == \"analytics\"",
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let output = String(data: data, encoding: .utf8) else { return nil }
        guard let regex = try? NSRegularExpression(pattern: linePattern, options: [.anchorsMatchLines]) else {
            return nil
        }
        let matches = regex.matches(in: output, range: NSRange(output.startIndex..., in: output))

        // Walk from the newest match backward and take the first one that is genuinely at
        // or after `since` — the `--start` argument above only narrowed things down to the
        // whole second, this is the precise check.
        for match in matches.reversed() {
            guard let timestampRange = Range(match.range(at: 1), in: output),
                  let countRange = Range(match.range(at: 2), in: output),
                  let timestamp = lineTimestampFormatter.date(from: String(output[timestampRange])),
                  timestamp >= since,
                  let count = Int(output[countRange])
            else { continue }
            return count
        }
        return nil
    }
}
