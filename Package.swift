// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "LocalFlow",
    defaultLocalization: "en",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "localflow-planner-setup", targets: ["PlannerSetup"]),
        .executable(name: "localflow-workflow-guard", targets: ["LocalFlowWorkflowGuard"]),
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
    dependencies: [],
    targets: [
        .target(name: "PlannerReplyProtocol", path: "Core/ModelManager/Resources/PlannerRuntime/QwenHelper/Sources/PlannerReplyProtocol"),
        .executableTarget(name: "PlannerSetup", dependencies: ["ModelManager", "CommandMode"], path: "Runtime/PlannerSetup"),
        .executableTarget(name: "LocalFlowWorkflowGuard", path: "Core/ModelManager/Resources/PlannerRuntime/QwenHelper/Sources/WorkflowGuard"),
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
        .target(name: "ModelManager", dependencies: ["Shared", "Engines", "CommandMode"], path: "Core/ModelManager", resources: [.copy("Resources/DecisionPreparation"), .copy("Resources/PlannerRuntime")]),
        .target(name: "TextInjection", dependencies: ["Shared"], path: "Core/TextInjection"),
        .target(
            name: "Engines",
            dependencies: [
                "Shared"
            ],
            path: "Engines",
            linkerSettings: [
                .linkedFramework("Speech")
            ]
        ),
        .target(name: "CommandMode", dependencies: ["Shared", "TextInjection"], path: "Features/CommandMode", resources: [.copy("Resources/laya-questions.json"), .copy("Resources/laya-v2-questions.json"), .copy("Resources/voice-agent-stability.json"), .copy("Resources/workflow-guard.json")]),
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
        .testTarget(name: "SharedTests", dependencies: ["Shared", "AudioCapture", "HotkeyManager", "ModelManager", "Engines", "CommandMode"], path: "Tests/SharedTests"),
        .testTarget(
            name: "FeaturesTests",
            dependencies: ["Shared", "CommandMode", "SpeechCleanup", "SmartFormatting", "TextInjection", "PlannerReplyProtocol"],
            path: "Tests/FeaturesTests"
        )
    ]
)
