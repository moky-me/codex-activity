// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodexActivity",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "CodexActivity", targets: ["ActivityPanel"]),
        .executable(name: "ActivityLauncher", targets: ["ActivityLauncher"]),
        .executable(name: "ActivityDiagnostics", targets: ["ActivityDiagnostics"]),
        .executable(name: "ActivityCoreTests", targets: ["ActivityCoreTests"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "ActivityCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "ActivityPanel", dependencies: ["ActivityCore"]),
        .executableTarget(name: "ActivityLauncher", dependencies: ["ActivityCore"]),
        .executableTarget(name: "ActivityDiagnostics", dependencies: ["ActivityCore"]),
        .executableTarget(name: "ActivityCoreTests", dependencies: ["ActivityCore"], path: "Tests/ActivityCoreTests")
    ],
    swiftLanguageModes: [.v5]
)
