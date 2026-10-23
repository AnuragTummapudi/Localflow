// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "LocalFlowLayaHelper", platforms: [.macOS("26.0")],
    products: [.executable(name: "localflow-laya", targets: ["LayaHelper"])],
    dependencies: [
        .package(url: "https://github.com/microsoft/onnxruntime-swift-package-manager", exact: "1.24.2"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "1.1.9")
    ],
    targets: [.executableTarget(name: "LayaHelper", dependencies: [
        .product(name: "onnxruntime", package: "onnxruntime-swift-package-manager"),
        .product(name: "Tokenizers", package: "swift-transformers")
    ])])
