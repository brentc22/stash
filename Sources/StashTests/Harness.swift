import Foundation

/// Minimale testharness. XCTest en swift-testing zijn niet beschikbaar zonder Xcode,
/// dus tests draaien als gewoon programma: `swift run StashTests`.
enum T {
    nonisolated(unsafe) private static var failures: [String] = []
    nonisolated(unsafe) private static var passed = 0
    nonisolated(unsafe) private static var current = ""

    static func test(_ name: String, _ body: () throws -> Void) {
        current = name
        let before = failures.count
        do {
            try body()
        } catch {
            failures.append("\(name): wierp \(error)")
            print("  FAIL \(name): wierp \(error)")
            return
        }
        if failures.count == before {
            passed += 1
            print("  ok   \(name)")
        }
    }

    static func expect(_ condition: Bool, _ message: String,
                       file: StaticString = #filePath, line: UInt = #line) {
        guard !condition else { return }
        let entry = "\(current): \(message)  (\(file):\(line))"
        failures.append(entry)
        print("  FAIL \(entry)")
    }

    static func equal<V: Equatable>(_ actual: V, _ expected: V, _ message: String = "",
                                    file: StaticString = #filePath, line: UInt = #line) {
        expect(actual == expected, "\(message) verwacht \(expected), kreeg \(actual)",
               file: file, line: line)
    }

    static func finish() -> Never {
        print("\n\(passed) geslaagd, \(failures.count) gefaald")
        for f in failures { print("  - \(f)") }
        exit(failures.isEmpty ? 0 : 1)
    }
}
