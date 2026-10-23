import Combine
import CryptoKit
import Foundation
import CommandMode
import Shared

public enum DecisionModelStatus: Equatable, Sendable {
    case notInstalled, verifying, loading, ready, failed
    public var description: String {
        switch self {
        case .notInstalled: return "Not installed — deterministic commands"
        case .verifying: return "Verifying local assets…"
        case .loading: return "Loading local Laya…"
        case .ready: return "Laya ready on device"
        case .failed: return "Laya unavailable — deterministic commands"
        }
    }
}

/// Owns explicit local installation and readiness. Inference has no download path.
@MainActor
public final class DecisionModelManager: ObservableObject {
    public static let shared = DecisionModelManager()
    nonisolated public static let checkpointRevision = "55cf4c4ebb4ebe31b2550e8bdf3bd21b99753851"
    @Published public private(set) var status: DecisionModelStatus = .notInstalled
    @Published public private(set) var progress: ModelDownloadProgress?
    @Published public private(set) var metrics: LayaRuntimeMetrics?
    public let directory: URL
    public let engine = LayaDecisionEngine()
    private var generation = UUID()
    private var operation: Task<Void, Never>?
    private var isInstalling = false
    @Published public private(set) var isRemoving = false
    public var isBusy: Bool { operation != nil || isInstalling || isRemoving }
    public var isInstalled: Bool { FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) }
    public func diskUsage() async -> Int64 {
        let root = directory
        return await Task.detached { Self.measureDiskUsage(root) }.value
    }
    nonisolated private static func measureDiskUsage(_ root: URL) -> Int64 {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { return 0 }
        var bytes: Int64 = 0
        for case let url as URL in files {
            if let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]), values.isRegularFile == true, values.isSymbolicLink != true { bytes += Int64(values.fileSize ?? 0) }
        }
        return bytes
    }
    nonisolated static var preparationScriptURL: URL? { Bundle.module.url(forResource: "prepare-laya", withExtension: "sh", subdirectory: "DecisionPreparation") }

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            // Keep the previous model intact while v2 quality/human review is pending.
            .appendingPathComponent("LocalFlow/Models/laya-v2", isDirectory: true)
    }

    /// Startup warm-up only opens verified installed files. Missing assets return immediately.
    public func prepareInstalled() {
        guard operation == nil, !isInstalling, !isRemoving, status != .ready else { return }
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path) else {
            status = .notInstalled; return
        }
        let id = UUID(); generation = id
        status = .verifying
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                let directory = self.directory
                // A preserved v1 installation is not the specialized System-1 model.
                // Keep its files intact until replacement, but never load it into production.
                try await Task.detached { try NarrowDecisionInstallation.validate(directory) }.value
                try Task.checkCancellation()
                guard generation == id else { return }
                status = .loading
                let loaded = try await engine.loadInstalled(directory: directory)
                guard generation == id else { return }
                metrics = loaded; status = .ready
            } catch {
                guard generation == id else { return }
                metrics = nil; status = .failed
            }
            if generation == id { operation = nil }
        }
    }

    /// Imports an explicitly prepared, pinned and SHA-256 validated native model package.
    /// A failed reinstallation leaves the previous package intact.
    public func install(from source: URL) async throws {
        guard operation == nil, !isInstalling, !isRemoving else { throw DecisionError.unavailable }
        try await Task.detached { try NarrowDecisionInstallation.validate(source) }.value
        isInstalling = true
        generation = UUID()
        defer { isInstalling = false }
        try await installPreparedDirectory(from: source)
        isInstalling = false
        prepareInstalled()
    }

    private func installPreparedDirectory(from source: URL) async throws {
        status = .verifying
        progress = ModelDownloadProgress(completedBytes: 0, totalBytes: 1, stage: "Verifying prepared Laya package")
        let destination = directory
        let staging = directory.deletingLastPathComponent().appendingPathComponent(".laya-install-" + UUID().uuidString)
        do {
            try await Task.detached {
                try Self.validate(source)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: staging)
                try Self.validate(staging)
            }.value
            try Task.checkCancellation()
            await engine.unload()
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } else { try FileManager.default.moveItem(at: staging, to: destination) }
            progress = nil; operation = nil
            status = .notInstalled
        } catch {
            try? FileManager.default.removeItem(at: staging)
            progress = nil; status = .failed
            throw error
        }
    }

    public func remove() async throws {
        guard !isInstalling, !isRemoving else { throw DecisionError.unavailable }
        isRemoving = true
        defer { isRemoving = false }
        generation = UUID()
        let retired = operation
        retired?.cancel()
        // Stop IPC first to wake a suspended load, then drain its ownership before
        // deleting assets or advertising that a new preparation may start.
        await engine.unload()
        await retired?.value
        operation = nil
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        metrics = nil; progress = nil; status = .notInstalled
    }

    /// Failure never disables deterministic commands. Inference uses already installed assets only.
    public func evaluate(_ state: DecisionState, fallback: SpeechDecisions) async -> SpeechDecisions {
        await evaluateForAgent(state, fallback: fallback).decisions
    }

    /// Optional evidence for uncertain parsed targets, with explicit failure provenance.
    /// The caller bypasses this for clear commands; model scores never relax confirmation.
    public func evaluateForAgent(_ state: DecisionState, fallback: SpeechDecisions) async -> AgentDecisionEvaluation {
        guard status == .ready else { return AgentDecisionEvaluation(decisions: fallback, source: .deterministic) }
        let id = generation
        do {
            // Legacy v1 risk/flat intent scores have no production authority.
            guard await engine.protocolVersion == 2 else { return AgentDecisionEvaluation(decisions: fallback, source: .deterministic) }
            let began = ContinuousClock.now
            let first = try await engine.evaluateNarrow(state, questions: [.actionableCommand])
            var more: ScoredDecision<Bool>?, correction: ScoredDecision<Bool>?, family: ScoredDecision<CoarseCommandFamily>?
            if first.actionableCommand?.accepted == true, first.actionableCommand?.value == true {
                // Missing deterministic intent or volatile speech may need another observation.
                if !state.isFinal || fallback.intent == nil {
                    more = try await engine.evaluateNarrow(state, questions: [.needsMoreSpeech]).needsMoreSpeech
                }
                if more?.value != true {
                    if state.text.range(of: "(?i)\\b(?:actually|scratch that|no wait|correction|I mean|instead)\\b", options: .regularExpression) != nil {
                        correction = try await engine.evaluateNarrow(state, questions: [.correctionOrReplacement]).correctionOrReplacement
                    }
                    if fallback.intent == nil {
                        family = try await engine.evaluateNarrow(state, questions: [.coarseFamily]).coarseFamily
                    }
                }
            }
            let elapsed = began.duration(to: .now).components
            let narrow = NarrowSpeechDecisions(actionableCommand: first.actionableCommand, needsMoreSpeech: more,
                correctionOrReplacement: correction, coarseFamily: family,
                inferenceMilliseconds: Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            let decisions = SpeechDecisions(intent: nil, risk: nil, requiresMoreSpeech: nil,
                                            inferenceMilliseconds: narrow.inferenceMilliseconds, narrow: narrow)
            return generation == id ? AgentDecisionEvaluation(decisions: decisions, source: .laya)
                : AgentDecisionEvaluation(decisions: fallback, source: .fallback)
        } catch {
            guard generation == id else { return AgentDecisionEvaluation(decisions: fallback, source: .fallback) }
            // Cancelling inference stops the IPC helper. Mark it unavailable so the
            // next explicit session warm-up reloads installed assets instead of advertising readiness.
            if error as? DecisionError != .unsupportedLanguage {
                metrics = nil; status = .failed
            }
            return AgentDecisionEvaluation(decisions: fallback, source: .fallback)
        }
    }

    private struct Manifest: Decodable {
        let checkpoint: String
        let revision: String
        let protocolVersion: Int
        let validated: Bool
        let checkpointSHA256: String
        let files: [String: String]
    }
    private struct CalibrationPolicy: Decodable, Equatable { let temperature: Double; let threshold: Double?; let enabled: Bool }
    private struct ValidationReport: Decodable {
        let checkpoint: String
        let revision: String
        let fixtureSHA256: String
        let fixtureCount: Int
        let questionsSHA256: String
        let parity: Parity
        let questions: [String: QuestionReport]
        struct QuestionReport: Decodable {
            let policy: CalibrationPolicy
            let calibration: Quality
            let evaluation: Quality
        }
        struct Quality: Decodable { let accepted: Int; let selectiveAccuracy: Double? }
        struct Parity: Decodable { let passed: Bool; let comparedQuestions: Int; let maxAbsoluteLogitDifference: Double }
    }

    nonisolated public static func validate(_ directory: URL) throws {
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        if manifest.protocolVersion == 2 { try NarrowDecisionInstallation.validate(directory); return }
        let required: Set<String> = ["localflow-laya", "laya.onnx", "laya.onnx.data", "tokenizer/tokenizer.json", "tokenizer/tokenizer_config.json", "questions.json", "option-order.json", "calibration.json", "validation.json"]
        guard manifest.checkpoint == "convaiinnovations/laya", manifest.revision == checkpointRevision,
              manifest.protocolVersion == 1, manifest.validated,
              manifest.checkpointSHA256 == "891102d372688fc2a094dac56a384bc537b87c63f21f9f3dac0be2b7cbc8d86c",
              manifest.files["tokenizer/tokenizer.json"] == "6c8aaa9a542084f2457eab775d4eeb51f92a70c0fd9de28d5edb0ddec3c08d30",
              manifest.files["tokenizer/tokenizer_config.json"] == "50044de60daaa73df97d262e15a40d4faf0160e7d742df64b377877a1320dd12",
              Set(manifest.files.keys) == required else { throw DecisionError.invalidInstallation }
        for (relativePath, digest) in manifest.files {
            let file = directory.appendingPathComponent(relativePath)
            guard (try file.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true, digest.count == 64 else { throw DecisionError.invalidInstallation }
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hash = SHA256()
            while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
            guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == digest else { throw DecisionError.invalidInstallation }
        }
        let schemaHash = SHA256.hash(data: try DecisionQuestionSchema.data()).map { String(format: "%02x", $0) }.joined()
        guard manifest.files["questions.json"] == schemaHash else { throw DecisionError.invalidInstallation }
        guard let fixtures = Bundle.module.url(forResource: "utterances", withExtension: "json", subdirectory: "DecisionPreparation/Laya") else { throw DecisionError.invalidInstallation }
        let fixtureHash = SHA256.hash(data: try Data(contentsOf: fixtures)).map { String(format: "%02x", $0) }.joined()
        let report = try JSONDecoder().decode(ValidationReport.self, from: Data(contentsOf: directory.appendingPathComponent("validation.json")))
        guard report.checkpoint == manifest.checkpoint, report.revision == manifest.revision,
              report.questionsSHA256 == schemaHash, report.fixtureSHA256 == fixtureHash,
              report.fixtureCount >= 100, report.parity.passed, report.parity.comparedQuestions >= 42,
              report.parity.maxAbsoluteLogitDifference.isFinite, report.parity.maxAbsoluteLogitDifference <= 0.003 else { throw DecisionError.invalidInstallation }
        let policies = try JSONDecoder().decode([String: CalibrationPolicy].self, from: Data(contentsOf: directory.appendingPathComponent("calibration.json")))
        guard Set(policies.keys) == Set(DecisionQuestion.allCases.map(\.rawValue)), policies.values.allSatisfy({ policy in
            policy.temperature.isFinite && policy.temperature > 0 &&
            (policy.threshold.map { $0.isFinite && (0...1).contains($0) } ?? !policy.enabled)
        }) else { throw DecisionError.invalidInstallation }
        for (question, policy) in policies {
            guard let evidence = report.questions[question], evidence.policy == policy else { throw DecisionError.invalidInstallation }
            if policy.enabled {
                guard evidence.calibration.accepted >= 8, evidence.evaluation.accepted >= 4,
                      let calibrationAccuracy = evidence.calibration.selectiveAccuracy,
                      let evaluationAccuracy = evidence.evaluation.selectiveAccuracy,
                      calibrationAccuracy.isFinite, evaluationAccuracy.isFinite,
                      (0.95...1).contains(calibrationAccuracy), (0.95...1).contains(evaluationAccuracy) else { throw DecisionError.invalidInstallation }
            }
        }
        let order = try JSONDecoder().decode([String: [String]].self, from: Data(contentsOf: directory.appendingPathComponent("option-order.json")))
        guard order == ["intent": VoiceIntent.allCases.map(\.rawValue), "risk": DecisionRisk.allCases.map(\.rawValue), "requires_more_speech": ["A", "B"]] else { throw DecisionError.invalidInstallation }
        guard FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent("localflow-laya").path) else { throw DecisionError.invalidInstallation }
    }
}
