// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Mirror the root manifest so the core package cannot pull Whisper back
// into otherwise light app/CLI builds.
let enableWhisperKit: Bool = {
    let env = ProcessInfo.processInfo.environment
    let enabled = ["1", "true", "yes"].contains(env["WIMM_ENABLE_WHISPERKIT"]?.lowercased() ?? "")
    let light = ["1", "true", "yes"].contains(env["WIMM_FAST_LIGHT_TRANSCRIPTION"]?.lowercased() ?? "")
    return enabled && !light
}()

var packageDependencies: [Package.Dependency] = [
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

let package = Package(
    name: "WimmCore",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
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
            swiftSettings: [.swiftLanguageMode(.v6)] + whisperSettings
        ),

        // Secretary edits must not rebuild transcription, sync, or import.
        // Receipts and review paging stay in WimmInfrastructure: MCP get_note writes them.
        .target(
            name: "WimmSecretary",
            dependencies: ["WimmDomain", "WimmInfrastructure"],
            path: "Sources/WimmSecretary",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // MARK: - Tests
        // The root package exposes the same tests as WimmCoreTests to share
        // its build cache. Xcode loads both packages in one graph and requires
        // target names to be unique, even for test-only targets.
        .testTarget(
            name: "WimmCorePackageTests",
            dependencies: ["WimmDomain", "WimmInfrastructure", "WimmSecretary"],
            path: "Tests/WimmCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
