import Foundation

public struct LayaRuntimeMetrics: Codable, Sendable {
    public let coldLoadMilliseconds: Double
    public let residentBytes: UInt64
}

private struct LayaRequest: Encodable {
    let id: String
    let state: DecisionState
    let questions: [String]
}
private struct NarrowLayaResponse: Decodable { let id: String; let decisions: NarrowSpeechDecisions }
private struct LayaResponse: Decodable { let id: String; let decisions: SpeechDecisions }
private struct LayaReady: Decodable { let ready: Bool; let protocolVersion: Int; let coldLoadMilliseconds: Double; let residentBytes: UInt64 }

/// A single isolated process. Blocking pipe I/O runs on a worker, never on the main actor.
/// Stop is synchronized and can interrupt a blocked ONNX call independently of actor reentrancy.
private final class LayaPipe: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffered = Data() // one worker owns reads

    init(directory: URL) throws {
        process.executableURL = directory.appendingPathComponent("localflow-laya")
        process.arguments = [directory.path]
        process.currentDirectoryURL = directory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.qualityOfService = .userInitiated
        // Inference receives no network credentials or Python environment from the app.
        process.environment = ["PATH": "/usr/bin:/bin", "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1"]
        try process.run()
        try? output.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
    }
    deinit { stop() }
    func stop() {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        if process.isRunning { process.terminate() }
        try? input.fileHandleForWriting.close()
    }
    func readLine() throws -> Data {
        while true {
            if let index = buffered.firstIndex(of: 10) {
                let line = buffered.prefix(upTo: index)
                buffered.removeSubrange(...index)
                return Data(line)
            }
            guard buffered.count < 65536 else { throw DecisionError.invalidResponse }
            let data = output.fileHandleForReading.availableData
            guard !data.isEmpty else { throw DecisionError.invalidResponse }
            buffered.append(data)
        }
    }
    func exchange(_ request: Data?) throws -> Data {
        if let request {
            lock.lock(); let isStopped = stopped; lock.unlock()
            guard !isStopped else { throw DecisionError.unavailable }
            try input.fileHandleForWriting.write(contentsOf: request + Data([10]))
        }
        return try readLine()
    }
    func boundedExchange(_ request: Data?, seconds: Double) async throws -> Data {
        let timeout = DispatchWorkItem { [weak self] in self?.stop() }
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timeout)
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            let response = try await Task.detached(priority: .userInitiated) { try self.exchange(request) }.value
            try Task.checkCancellation()
            return response
        } onCancel: { self.stop() }
    }
}

/// Full-precision ONNX inference through a preinstalled native helper; this type never downloads.
public actor LayaDecisionEngine: DecisionEngine {
    private var pipe: LayaPipe?
    private var busy = false
    private var unloading = false
    public private(set) var protocolVersion = 1
    public private(set) var metrics: LayaRuntimeMetrics?
    public init() {}

    public func loadInstalled(directory: URL) async throws -> LayaRuntimeMetrics {
        guard !busy, !unloading else { throw DecisionError.unavailable }
        busy = true
        defer { busy = false }
        pipe?.stop(); pipe = nil; metrics = nil
        let connection = try LayaPipe(directory: directory)
        pipe = connection
        do {
            let response = try await connection.boundedExchange(nil, seconds: 30)
            let ready = try JSONDecoder().decode(LayaReady.self, from: response)
            guard pipe === connection, ready.ready, [1, 2].contains(ready.protocolVersion), ready.coldLoadMilliseconds.isFinite else { throw DecisionError.invalidResponse }
            try Task.checkCancellation()
            pipe = connection
            let result = LayaRuntimeMetrics(coldLoadMilliseconds: ready.coldLoadMilliseconds, residentBytes: ready.residentBytes)
            protocolVersion = ready.protocolVersion; metrics = result
            return result
        } catch {
            connection.stop()
            if pipe === connection { pipe = nil; metrics = nil }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
    public func unload() async {
        if unloading {
            while unloading { await Self.drainPause() }
            return
        }
        unloading = true
        defer { unloading = false }
        pipe?.stop(); pipe = nil; metrics = nil
        // The actor is reentrant during IPC. Do not permit a new connection until
        // the old call's deferred busy release has returned.
        while busy { await Self.drainPause() }
    }
    private static func drainPause() async {
        // Cleanup must still yield when its calling task has been cancelled.
        await Task.detached { try? await Task.sleep(for: .milliseconds(5)) }.value
    }

    public func evaluate(_ state: DecisionState, questions: Set<DecisionQuestion> = Set(DecisionQuestion.allCases)) async throws -> SpeechDecisions {
        try Task.checkCancellation()
        guard state.languageCode == "en", !state.text.unicodeScalars.contains(where: { $0.properties.isAlphabetic && $0.value > 0x024F }) else { throw DecisionError.unsupportedLanguage }
        guard state.text.utf8.count <= 16384, !questions.isEmpty else { throw DecisionError.invalidResponse }
        guard protocolVersion == 1, let connection = pipe, !busy, !unloading else { throw DecisionError.unavailable }
        busy = true; defer { busy = false }
        let id = UUID().uuidString
        let request = LayaRequest(id: id, state: state, questions: questions.map(\.rawValue).sorted())
        do {
            let bytes = try JSONEncoder().encode(request)
            let reply = try await connection.boundedExchange(bytes, seconds: 2)
            let response = try JSONDecoder().decode(LayaResponse.self, from: reply)
            let result = response.decisions
            guard response.id == id, result.inferenceMilliseconds.isFinite, result.inferenceMilliseconds >= 0,
                  questions.contains(.intent) == (result.intent != nil),
                  questions.contains(.risk) == (result.risk != nil),
                  questions.contains(.requiresMoreSpeech) == (result.requiresMoreSpeech != nil) else { throw DecisionError.invalidResponse }
            return result
        } catch {
            connection.stop()
            if pipe === connection { pipe = nil; metrics = nil }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
    public func evaluateNarrow(_ state: DecisionState, questions: Set<NarrowDecisionQuestion>) async throws -> NarrowSpeechDecisions {
        try Task.checkCancellation()
        guard state.languageCode == "en", !state.text.unicodeScalars.contains(where: { $0.properties.isAlphabetic && $0.value > 0x024F }) else { throw DecisionError.unsupportedLanguage }
        guard state.text.utf8.count <= 16384, !questions.isEmpty else { throw DecisionError.invalidResponse }
        guard protocolVersion == 2, let connection = pipe, !busy, !unloading else { throw DecisionError.unavailable }
        busy = true; defer { busy = false }
        let id = UUID().uuidString
        do {
            let bytes = try JSONEncoder().encode(LayaRequest(id: id, state: state, questions: questions.map(\.rawValue).sorted()))
            let response = try JSONDecoder().decode(NarrowLayaResponse.self, from: await connection.boundedExchange(bytes, seconds: 2))
            let result = response.decisions
            guard response.id == id, result.inferenceMilliseconds.isFinite, result.inferenceMilliseconds >= 0,
                  questions.contains(.actionableCommand) == (result.actionableCommand != nil),
                  questions.contains(.needsMoreSpeech) == (result.needsMoreSpeech != nil),
                  questions.contains(.correctionOrReplacement) == (result.correctionOrReplacement != nil),
                  questions.contains(.coarseFamily) == (result.coarseFamily != nil) else { throw DecisionError.invalidResponse }
            return result
        } catch {
            connection.stop()
            if pipe === connection { pipe = nil; metrics = nil }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

}
