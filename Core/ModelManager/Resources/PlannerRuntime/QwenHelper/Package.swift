// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "LocalFlowQwenHelper", platforms: [.macOS("26.0")],
    products: [.executable(name: "localflow-qwen", targets: ["QwenHelper"]), .executable(name: "localflow-workflow-guard", targets: ["WorkflowGuard"])],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", exact: "3.32.3", traits: []),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.3.0")
    ],
    targets: [.target(name: "PlannerReplyProtocol"), .executableTarget(name: "WorkflowGuard"), .executableTarget(name: "QwenHelper", dependencies: [
        "PlannerReplyProtocol",
        .product(name: "MLXLLM", package: "mlx-swift-lm"),
        .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "Tokenizers", package: "swift-transformers")
    ])])
