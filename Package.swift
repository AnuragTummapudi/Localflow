// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "LocalFlow",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "LocalFlow", targets: ["LocalFlowApp"]),
        .library(name: "Shared", targets: ["Shared"]),
        .library(name: "AudioCapture", targets: ["AudioCapture"]),
        .library(name: "HotkeyManager", targets: ["HotkeyManager"]),
        .library(name: "ModelManager", targets: ["ModelManager"]),
        .library(name: "TextInjection", targets: ["TextInjection"]),
        .library(name: "Engines", targets: ["Engines"]),
        .library(name: "CommandMode", targets: ["CommandMode"]),
        .library(name: "SmartFormatting", targets: ["SmartFormatting"]),
        .library(name: "SpeechCleanup", targets: ["SpeechCleanup"]),
        .library(name: "PrivacyDashboard", targets: ["PrivacyDashboard"])
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "0.9.0")
    ],
    targets: [
        .executableTarget(
            name: "LocalFlowApp",
            dependencies: [
                "Shared",
                "AudioCapture",
                "HotkeyManager",
                "ModelManager",
                "TextInjection",
                "Engines",
                "CommandMode",
                "SpeechCleanup",
                "SmartFormatting",
                "PrivacyDashboard"
            ],
            path: "App",
            exclude: [
                "Info.plist",
                "LocalFlow.entitlements",
                "ExportOptions.plist"
            ],
            resources: [
                .process("../Resources")
            ],
            swiftSettings: [
                .enableUpcomingFeature("ExistentialAny")
            ]
        ),
        .target(name: "Shared", path: "Shared"),
        .target(name: "AudioCapture", dependencies: ["Shared"], path: "Core/AudioCapture"),
        .target(name: "HotkeyManager", dependencies: ["Shared"], path: "Core/HotkeyManager"),
        .target(name: "ModelManager", dependencies: ["Shared", "Engines"], path: "Core/ModelManager"),
        .target(name: "TextInjection", dependencies: ["Shared"], path: "Core/TextInjection"),
        .target(
            name: "Engines",
            dependencies: [
                "Shared",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift")
            ],
            path: "Engines",
            linkerSettings: [
                .linkedFramework("Speech")
            ]
        ),
        .target(name: "CommandMode", dependencies: ["Shared"], path: "Features/CommandMode"),
        .target(
            name: "SpeechCleanup",
            dependencies: ["Shared"],
            path: "Features/SpeechCleanup",
            resources: [
                .process("Resources")
            ]
        ),
        .target(name: "SmartFormatting", dependencies: ["Shared"], path: "Features/SmartFormatting"),
        .target(name: "PrivacyDashboard", dependencies: ["Shared", "ModelManager"], path: "Features/PrivacyDashboard"),
        .testTarget(name: "SharedTests", dependencies: ["Shared", "AudioCapture", "HotkeyManager", "ModelManager", "Engines"], path: "Tests/SharedTests"),
        .testTarget(
            name: "FeaturesTests",
            dependencies: ["Shared", "CommandMode", "SpeechCleanup", "SmartFormatting", "TextInjection"],
            path: "Tests/FeaturesTests"
        )
    ]
)
