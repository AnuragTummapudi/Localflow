import Foundation
@preconcurrency import AVFoundation
import FluidAudio
import Shared

/// Downloads Parakeet CoreML assets using FluidAudio's Hugging Face tree walker.
///
/// LocalFlow's old flat `type == "file"` scrape failed because HF lists `.mlmodelc`
/// bundles as directories (zero files returned).
public enum ParakeetModelDownloader {
    /// Returns true when a usable Parakeet v3 model is present at `directory`.
    public static func modelsExist(at directory: URL) -> Bool {
        AsrModels.modelsExist(at: directory, version: .v3)
    }

    /// Downloads Parakeet v3 into `directory` (FluidAudio folder `parakeet-tdt-0.6b-v3`).
    public static func download(
        to directory: URL,
        onProgress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        _ = try await AsrModels.download(to: directory, version: .v3) { progress in
            onProgress?(progress.fractionCompleted)
        }
    }
}

/// A FluidAudio-backed Parakeet TDT speech engine for Apple Silicon Macs.
public final class ParakeetEngine: STTEngine, @unchecked Sendable {
    private let modelDirectory: URL
    private let asrManager = AsrManager(config: .default)
    private let modelVersion: AsrModelVersion = .v3
    private var isLoaded = false

    /// Creates a Parakeet engine using models stored at the supplied directory.
    public init(modelDirectory: URL) {
        self.modelDirectory = modelDirectory
    }

    /// Loads Parakeet model resources into memory.
    public func load() async throws {
        guard FileManager.default.fileExists(atPath: modelDirectory.path) else {
            throw LocalFlowError.modelUnavailable("Parakeet models are not downloaded.")
        }
        let models = try await AsrModels.load(
            from: modelDirectory,
            configuration: AsrModels.defaultConfiguration(),
            version: modelVersion
        )
        try await asrManager.loadModels(models)
        isLoaded = true
    }

    /// Unloads Parakeet model resources from memory.
    public func unload() {
        isLoaded = false
    }

    /// Transcribes captured audio through Parakeet.
    public func transcribe(audio: CapturedAudio) async throws -> STTResult {
        if !isLoaded {
            try await load()
        }
        guard let buffer = audio.buffer else {
            throw LocalFlowError.transcriptionFailed("Parakeet requires a captured PCM buffer.")
        }
        var decoderState = TdtDecoderState.make(decoderLayers: modelVersion.decoderLayers)
        let result = try await asrManager.transcribe(buffer, decoderState: &decoderState)
        return STTResult(text: result.text, confidence: result.confidence)
    }
}
