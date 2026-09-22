import Foundation

/// MenuBarAgent logs how many items are in the bar itself. That is the only
/// reliable oracle we have without comparing screenshots:
///
///   [com.apple.menubar:analytics] MenuBar.trailingItems.count payload=["count": 12]
///
/// Test-target only: it shells out to `log show`, which has no place in the shipped app.
enum MenuBarProbe {

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
    /// apart between attempts — **not** a 5 s wall-clock budget: `/usr/bin/log show` itself
    /// can cost well over a second per call once the unified log has enough volume behind
    /// `--start` to scan (measured 1.3 s+ per call in a log-heavy session on 2026-09-22), so
    /// the real budget is closer to four attempts than fifty in that case. Returns nil only
    /// once all attempts are exhausted.
    /// `--info --debug` is required: without those flags `log show` omits these lines entirely.
    static func lastTrailingItemsCount(since: Date) -> Int? {
        // Floor to whole milliseconds — the same precision `log show`'s compact style
        // prints and `lineTimestampFormatter` re-parses. Comparing a sub-millisecond
        // `Date()` against a millisecond-truncated log timestamp let a genuinely later
        // line lose the `timestamp >= since` check by a fraction of a millisecond after
        // truncation, and because the same (correctly logged, but now-mislabelled-as-stale)
        // line is the only candidate on every retry, no amount of polling could recover
        // from it (measured: a real line 1.6 ms "before" a since a fraction later, rejected
        // on all 50 attempts). Flooring `since` down can only ever admit a line that is
        // truly at most one millisecond early; it can never let through one that is
        // genuinely stale, so this loses no precision that mattered.
        let flooredSince = Date(timeIntervalSince1970: (since.timeIntervalSince1970 * 1000).rounded(.down) / 1000)
        for _ in 0..<50 {
            if let count = queryOnce(since: flooredSince) {
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
