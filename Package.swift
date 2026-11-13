// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Execution filters do not limit SwiftPM's build graph. The core check uses
// this same checkout/cache while omitting unrelated app and test targets.
let testScope = ProcessInfo.processInfo.environment["WIMM_TEST_SCOPE"] ?? "all"
precondition(["all", "core"].contains(testScope), "WIMM_TEST_SCOPE must be all or core")

// Whisper is a legacy, opt-in backend. The fast flag remains an override
// for existing local scripts; WimmCore must use the identical decision.
let enableWhisperKit: Bool = {
    let env = ProcessInfo.processInfo.environment
    let enabled = ["1", "true", "yes"].contains(env["WIMM_ENABLE_WHISPERKIT"]?.lowercased() ?? "")
    let light = ["1", "true", "yes"].contains(env["WIMM_FAST_LIGHT_TRANSCRIPTION"]?.lowercased() ?? "")
    return enabled && !light
}()


var products: [Product] = [
    .library(name: "WimmDocumentUI", targets: ["WimmDocumentUI"]),
    .library(name: "WimmTranscription", targets: ["WimmTranscription"]),
    .library(name: "WimmRecording", targets: ["WimmRecording"]),
    .executable(name: "wimm-studio", targets: ["WimmStudio"]),
    .executable(name: "WimmCLI", targets: ["WimmCLI"]),
]

var packageDependencies: [Package.Dependency] = [
    .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.2.0"),
    .package(path: "Packages/WimmCore"),
]

if enableWhisperKit {
    packageDependencies.append(.package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.14.0"))
}

// Keep the compatible transformers range only for consumers that need it.
// The normal Parakeet/cloud/native graph does not use Hub/Tokenizers/Jinja.
if enableWhisperKit {
    packageDependencies.append(
        .package(
            url: "https://github.com/huggingface/swift-transformers.git",
            .upToNextMinor(from: "0.1.13")))
}

var transcriptionDependencies: [Target.Dependency] = [
    .product(name: "WimmDomain", package: "WimmCore"),
    .product(name: "WimmInfrastructure", package: "WimmCore"),
]
if enableWhisperKit {
    transcriptionDependencies.append(.product(name: "WhisperKit", package: "WhisperKit", condition: .when(platforms: [.macOS])))
}
var transcriptionSwiftSettings: [SwiftSetting] = [
    .unsafeFlags(
        ["-Xfrontend", "-warn-long-function-bodies=200"], .when(configuration: .release)),
    .unsafeFlags(
        ["-Xfrontend", "-warn-long-expression-type-checking=200"],
        .when(configuration: .release)),
]
if !enableWhisperKit {
    transcriptionSwiftSettings.append(.define("WIMM_DISABLE_WHISPERKIT"))
}
transcriptionSwiftSettings.append(.define("WIMM_DISABLE_WHISPERKIT", .when(platforms: [.iOS])))

var targetDefinitions: [Target] = [
    .target(name: "WimmDocumentUI", dependencies: [.product(name: "WimmDomain", package: "WimmCore"), .product(name: "WimmInfrastructure", package: "WimmCore"), .product(name: "WimmSecretary", package: "WimmCore")], swiftSettings: [.swiftLanguageMode(.v6)]),
    .target(
        name: "WimmTranscription",
        dependencies: transcriptionDependencies,
        path: "Sources/WimmTranscription",
        swiftSettings: transcriptionSwiftSettings + [.swiftLanguageMode(.v6)],
        linkerSettings: [
            .linkedFramework("AVFoundation"),
            .linkedFramework("Speech"),
        ]
    ),
    .target(
        name: "WimmRecording",
        dependencies: [
            "WimmTranscription",
            .product(name: "WimmDomain", package: "WimmCore"),
        ],
        path: "Sources/WimmRecording",
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .systemLibrary(
        name: "CNcurses"
    ),
    .executableTarget(
        name: "WimmCLI",
        dependencies: [
            "WimmTranscription",
            "CNcurses",
            .product(name: "ArgumentParser", package: "swift-argument-parser"),
            .product(name: "WimmTUI", package: "WimmCore"),
            .product(name: "WimmSecretary", package: "WimmCore"),
        ],
        path: "Sources/WimmCLI",
        exclude: [
            "Info.plist",
            "entitlements.plist",
        ],
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
        name: "WimmRecordingTests",
        dependencies: ["WimmRecording"],
        swiftSettings: [
            .swiftLanguageMode(.v6),
            .define("WIMM_TEST_MODE"),
            .define("SWIFTDATA_ENABLED", .when(configuration: .release))
        ]
    ),
    // WimmCore's own tests, compiled against the WimmCore modules this build already has.
    // Running them from Packages/WimmCore instead builds the whole dependency graph a second
    // time in a separate .build (~1.6 GB per checkout). The nested package keeps its own target
    // so `swift test` there still works.
    .testTarget(
        name: "WimmCoreTests",
        dependencies: [
            .product(name: "WimmDomain", package: "WimmCore"),
            .product(name: "WimmInfrastructure", package: "WimmCore"),
            .product(name: "WimmSecretary", package: "WimmCore"),
            .product(name: "WimmTUI", package: "WimmCore"),
        ],
        path: "Packages/WimmCore/Tests/WimmCoreTests",
        exclude: ["Fixtures/sample.enex"],
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
        name: "WimmServicesTests",
        dependencies: [
            "WimmTestSupport",
            .product(name: "WimmDomain", package: "WimmCore"),
            .product(name: "WimmInfrastructure", package: "WimmCore"),
        ],
        path: "Tests/WimmServicesTests",
        exclude: [
            "HeadlessImportServiceTests.swift",
        ],
        resources: [
            .process("Resources")
        ],
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .testTarget(
        name: "WimmCLITests",
        dependencies: [
            .product(name: "WimmDomain", package: "WimmCore"),
            .product(name: "WimmInfrastructure", package: "WimmCore"),
        ],
        path: "Tests/WimmCLITests",
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    .target(
        name: "WimmTestSupport",
        dependencies: [
            "WimmTranscription",
            "WimmRecording",
            .product(name: "WimmDomain", package: "WimmCore"),
        ],
        path: "Sources/WimmTestSupport",
        swiftSettings: [
            .swiftLanguageMode(.v6),
            .define("SWIFTDATA_ENABLED", .when(configuration: .release)),
        ]
    ),
    .executableTarget(
        name: "WimmStudio",
        dependencies: [
            "WimmDocumentUI",
            "WimmTranscription",
            .product(name: "WimmDomain", package: "WimmCore"),
            .product(name: "WimmInfrastructure", package: "WimmCore"),
            .product(name: "WimmSecretary", package: "WimmCore"),
        ],
        path: "Apps/WimmStudio/Sources/WimmStudio",
        swiftSettings: [.swiftLanguageMode(.v5)],
        linkerSettings: [
            .unsafeFlags(
                [
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "AppBundle/DevInfo.plist",
                ], .when(configuration: .debug)),
            .linkedFramework("AppKit"),
            .linkedFramework("AVFoundation"),
        ]
    ),
    .testTarget(
        name: "WimmStudioTests",
        dependencies: [
            "WimmStudio",
            "WimmTranscription",
            .product(name: "WimmDomain", package: "WimmCore"),
            .product(name: "WimmInfrastructure", package: "WimmCore"),
        ],
        path: "Apps/WimmStudio/Tests/WimmStudioTests",
        swiftSettings: [
            .swiftLanguageMode(.v5),
            .define("WIMM_TEST_MODE"),
        ]
    ),
]

if testScope == "core" {
    products = []
    targetDefinitions = targetDefinitions.filter { $0.name == "WimmCoreTests" }
}

let package = Package(
    name: "Wimm",
    defaultLocalization: "en",
    platforms: [
        .macOS("14.0"),
        .iOS("17.0"),
    ],
    products: products,
    dependencies: packageDependencies,
    targets: targetDefinitions
)
