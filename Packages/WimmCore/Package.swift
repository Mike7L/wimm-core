// swift-tools-version: 6.0
import Foundation
import PackageDescription

let enableLocalAI: Bool = {
    guard let raw = ProcessInfo.processInfo.environment["ENABLE_LOCAL_AI"]?.lowercased() else {
        return false
    }
    return raw == "1" || raw == "true" || raw == "yes"
}()

// Mirror the root manifest so the core package cannot pull Whisper back
// into otherwise light app/CLI builds.
let enableWhisperKit: Bool = {
    let env = ProcessInfo.processInfo.environment
    let enabled = ["1", "true", "yes"].contains(env["WIMM_ENABLE_WHISPERKIT"]?.lowercased() ?? "")
    let light = ["1", "true", "yes"].contains(env["WIMM_FAST_LIGHT_TRANSCRIPTION"]?.lowercased() ?? "")
    return enabled && !light
}()

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
    // On-device Parakeet ASR, including Ultra.
    .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.7"),
]
var infrastructureDependencies: [Target.Dependency] = [
    "WimmDomain",
    .product(name: "FluidAudio", package: "FluidAudio"),
]
if enableWhisperKit {
    packageDependencies.append(.package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.14.0"))
    infrastructureDependencies.append(.product(name: "WhisperKit", package: "WhisperKit", condition: .when(platforms: [.macOS])))
}
let whisperSettings: [SwiftSetting] = enableWhisperKit ? [] : [.define("WIMM_DISABLE_WHISPERKIT")]

let localAISettings: [SwiftSetting] = enableLocalAI ? [.define("ENABLE_LOCAL_AI")] : []

let package = Package(
    name: "WimmCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .executable(name: "wimm-tui", targets: ["WimmTUIMain"]),
        .library(name: "WimmTUI", targets: ["WimmTUI"]),
        .library(name: "WimmDomain", targets: ["WimmDomain"]),
        .library(name: "WimmInfrastructure", targets: ["WimmInfrastructure"]),
        .library(name: "WimmSecretary", targets: ["WimmSecretary"]),
    ],
    dependencies: packageDependencies,
    targets: [
        // MARK: - Core Domain (entities, ports, use cases — pure Swift)
        .target(
            name: "WimmDomain",
            dependencies: [],
            path: "Sources/WimmDomain",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - Infrastructure (Adapters)
        .target(
            name: "WimmInfrastructure",
            dependencies: infrastructureDependencies,
            path: "Sources/WimmInfrastructure",
            resources: [
                .process("Resources")
            ],
            // SWIFTDATA_ENABLED mirrors the root manifest (release-only),
            // keep both in sync.
            swiftSettings: [
                .swiftLanguageMode(.v6),
                .define("SWIFTDATA_ENABLED", .when(configuration: .release)),
            ] + localAISettings + whisperSettings,
            linkerSettings: [
                .linkedFramework("SwiftData", .when(platforms: [.macOS])),
            ]
        ),

        // Secretary edits must not rebuild transcription, sync, or import.
        // Receipts and review paging stay in WimmInfrastructure: MCP get_note writes them.
        .target(
            name: "WimmSecretary",
            dependencies: ["WimmDomain", "WimmInfrastructure"],
            path: "Sources/WimmSecretary",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - Presentation (TUI / Composition Root)
        .target(
            name: "WimmTUI",
            dependencies: [
                "WimmInfrastructure",
                "WimmDomain",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/WimmTUI",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Thin executable wrapper; all logic lives in the WimmTUI library
        // so WimmCLI can call commands in-process.
        .executableTarget(
            name: "WimmTUIMain",
            dependencies: ["WimmTUI"],
            path: "Sources/WimmTUIMain",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - Tests
        // The root package exposes the same tests as WimmCoreTests to share
        // its build cache. Xcode loads both packages in one graph and requires
        // target names to be unique, even for test-only targets.
        .testTarget(
            name: "WimmCorePackageTests",
            dependencies: ["WimmDomain", "WimmInfrastructure", "WimmSecretary", "WimmTUI"],
            path: "Tests/WimmCoreTests",
            exclude: ["Fixtures/sample.enex"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
