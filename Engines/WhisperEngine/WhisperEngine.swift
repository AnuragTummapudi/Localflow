import Foundation
import FluidAudio
import Shared
import WhisperKit

/// A WhisperKit-backed speech engine used for Intel fallback and language fallback.
public final class WhisperEngine: STTEngine, @unchecked Sendable {
    private let modelDirectory: URL
    private let modelName: String
    private var whisperKit: WhisperKit?
    private var isLoaded = false

    /// Creates a Whisper engine.
    public init(modelDirectory: URL, modelName: String) {
        self.modelDirectory = modelDirectory
        self.modelName = modelName
    }

    /// Loads Whisper model resources into memory.
    public func load() async throws {
        guard FileManager.default.fileExists(atPath: modelDirectory.path) else {
            throw LocalFlowError.modelUnavailable("Whisper models are not downloaded.")
        }
        let config = WhisperKitConfig(
            model: modelName,
            modelFolder: modelDirectory.path,
            verbose: false,
            prewarm: true,
            load: true,
            download: false
        )
        whisperKit = try await WhisperKit(config)
        isLoaded = true
    }

    /// Unloads Whisper model resources from memory.
    public func unload() {
        whisperKit = nil
        isLoaded = false
    }

    /// Transcribes captured audio through Whisper.
    public func transcribe(audio: CapturedAudio) async throws -> STTResult {
        if !isLoaded {
            try await load()
        }
        guard let whisperKit else {
            throw LocalFlowError.modelUnavailable("WhisperKit failed to load.")
        }
        let samples = try Self.resampledSamples(from: audio)
        let results = try await whisperKit.transcribe(audioArray: samples)
        let text = results
            .map(\.text)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return STTResult(text: text, confidence: Self.confidence(from: results))
    }

    private static func resampledSamples(from audio: CapturedAudio) throws -> [Float] {
        if let buffer = audio.buffer {
            return try AudioConverter().resampleBuffer(buffer)
        }
        return audio.samples
    }

    private static func confidence(from results: [TranscriptionResult]) -> Float? {
        let segments = results.flatMap(\.segments)
        let wordProbabilities = segments.flatMap { $0.words ?? [] }.map(\.probability)
        if !wordProbabilities.isEmpty {
            return wordProbabilities.reduce(0, +) / Float(wordProbabilities.count)
        }

        let segmentScores = segments.map { segment -> Float in
            let logProbability = min(1, max(0, exp(segment.avgLogprob)))
            return min(1, max(0, logProbability * (1 - segment.noSpeechProb)))
        }
        guard !segmentScores.isEmpty else { return nil }
        return segmentScores.reduce(0, +) / Float(segmentScores.count)
    }
}
