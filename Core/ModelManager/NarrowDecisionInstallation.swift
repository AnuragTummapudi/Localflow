import CryptoKit
import Foundation
import CommandMode

/// A separate v2 provenance gate. Disabled policies may be imported for explicit
/// local inspection; enabling authority requires reviewed data and native parity.
enum NarrowDecisionInstallation {
    struct Manifest: Decodable {
        let checkpoint: String; let revision: String; let protocolVersion: Int
        let validated: Bool; let checkpointSHA256: String; let files: [String: String]
    }
    struct Policy: Decodable, Equatable { let temperature: Double; let threshold: Double?; let enabled: Bool }
    struct Evidence: Decodable {
        let checkpointSHA256: String; let questionsSHA256: String
        let baseRevision: String; let baseSHA256: String
        let trainingCount: Int; let calibrationCount: Int; let heldoutCount: Int
        let humanReviewed: Bool; let parity: Parity; let policies: [String: Policy]
        let quality: [String: Quality]
        struct Parity: Decodable { let passed: Bool; let decisions: Int; let maxAbsoluteLogitDifference: Double }
        struct Quality: Decodable { let calibrationWilsonLower: Double?; let heldoutWilsonLower: Double?; let precision: Double?; let recall: Double?; let f1: Double? }
    }
    static func validate(_ root: URL) throws {
        func invalid() -> DecisionError { .invalidInstallation }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
        let required: Set<String> = ["localflow-laya", "laya.onnx", "laya.onnx.data", "tokenizer/tokenizer.json", "tokenizer/tokenizer_config.json", "questions.json", "option-order.json", "calibration.json", "validation.json", "runtime-spec.json", "training-provenance.json"]
        guard manifest.protocolVersion == 2, manifest.checkpoint == "LocalFlow-Laya-v2", manifest.validated,
              manifest.revision == "e4e9ddf21a7b1903b7acffd8814ad4307bf63a67", manifest.checkpointSHA256.count == 64,
              Set(manifest.files.keys) == required else { throw invalid() }
        // Fixed relative paths; reject symlinked parent components as well as files.
        guard (try root.appendingPathComponent("tokenizer").resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw invalid() }
        for (relative, expected) in manifest.files {
            let file = root.appendingPathComponent(relative)
            guard expected.count == 64, (try file.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw invalid() }
            let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
            var hash = SHA256()
            while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { hash.update(data: bytes) }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == expected else { throw invalid() }
        }
        let schemaHash = SHA256.hash(data: try NarrowDecisionSchema.data()).map { String(format: "%02x", $0) }.joined()
        let evidence = try JSONDecoder().decode(Evidence.self, from: Data(contentsOf: root.appendingPathComponent("validation.json")))
        let policies = try JSONDecoder().decode([String: Policy].self, from: Data(contentsOf: root.appendingPathComponent("calibration.json")))
        let names = Set(NarrowDecisionQuestion.allCases.map(\.rawValue))
        guard manifest.files["questions.json"] == schemaHash, evidence.questionsSHA256 == schemaHash,
              evidence.checkpointSHA256 == manifest.checkpointSHA256, evidence.baseRevision == manifest.revision,
              evidence.baseSHA256 == "9d628fd971b700382ac6f65920a86f149777b2e748e0c955fb3b19695aa8f204",
              manifest.files["tokenizer/tokenizer.json"] == "609d8f4c067cd3950f88594c5a802616cea245823836ef5848ee4fc40aab5b6f",
              manifest.files["tokenizer/tokenizer_config.json"] == "424b69444bf7b5809dc2cd2e36d0bd71b8055124dd24274d6db3c655d38205e7",
              evidence.trainingCount >= 2000, evidence.calibrationCount >= 300, evidence.heldoutCount >= 500,
              evidence.parity.passed, evidence.parity.decisions >= 100,
              evidence.parity.maxAbsoluteLogitDifference.isFinite, (0...0.003).contains(evidence.parity.maxAbsoluteLogitDifference),
              Set(policies.keys) == names, evidence.policies == policies else { throw invalid() }
        for (name, policy) in policies {
            guard policy.temperature.isFinite, (0.1...10).contains(policy.temperature),
                  policy.threshold.map({ $0.isFinite && (0...1).contains($0) }) ?? !policy.enabled else { throw invalid() }
            if policy.enabled {
                guard evidence.humanReviewed, let quality = evidence.quality[name],
                      let cal = quality.calibrationWilsonLower, let held = quality.heldoutWilsonLower,
                      cal.isFinite, held.isFinite, (0.95...1).contains(cal), (0.95...1).contains(held) else { throw invalid() }
                if name == "needs_more_speech" {
                    guard let p = quality.precision, let r = quality.recall, let f = quality.f1,
                          [p, r, f].allSatisfy({ $0.isFinite && (0.9...1).contains($0) }) else { throw invalid() }
                }
            }
        }
        let order = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: root.appendingPathComponent("option-order.json")))
        guard order == ["actionable_command": ["false", "true"], "needs_more_speech": ["false", "true"], "correction_or_replacement": ["false", "true"], "coarse_family": CoarseCommandFamily.allCases.map(\.rawValue)],
              FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("localflow-laya").path) else { throw invalid() }
    }
}
