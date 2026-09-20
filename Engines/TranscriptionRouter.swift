import Foundation
import Shared

/// Routes transcription requests to the currently selected speech engine.
public actor TranscriptionRouter {
    private var engine: any STTEngine
    private(set) var activeEngineName: String = "Not loaded"

    /// Creates a router with an initial engine.
    public init(engine: any STTEngine) {
        self.engine = engine
    }

    /// Replaces the active engine and records its display name.
    public func updateEngine(_ engine: any STTEngine, name: String) {
        self.engine = engine
        self.activeEngineName = name
    }

    /// Transcribes audio using the active engine.
    public func transcribe(audio: CapturedAudio) async throws -> STTResult {
        try await engine.transcribe(audio: audio)
    }
}
