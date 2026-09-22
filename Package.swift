// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Stash",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "MenuBarShim"),
        .target(name: "StashCore", dependencies: ["MenuBarShim"]),
        .executableTarget(name: "Stash", dependencies: ["StashCore"]),
        .executableTarget(name: "StashTests", dependencies: ["StashCore", "MenuBarShim"]),
    ]
)
