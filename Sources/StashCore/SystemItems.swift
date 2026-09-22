import Foundation

/// System items are passed as numeric ids. Known ids: clock 2, sound 5,
/// wifi 6, Control Center 8. The range demonstrably needs to go above 63:
/// with only 0...63, Screen Mirroring silently disappeared from the bar.
/// Hence the wide margin.
public enum SystemItems {
    public static let all: [NSNumber] = (0...255).map { NSNumber(value: $0) }
}
