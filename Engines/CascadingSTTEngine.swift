import Foundation
import Shared

/// Tries a primary STT engine, then falls back when it fails or returns empty text.
public struct CascadingSTTEngine: STTEngine {
    private let primary: any STTEngine
    private let fallback: any STTEngine

    /// Creates a cascading engine.
    public init(primary: any STTEngine, fallback: any STTEngine) {
        self.primary = primary
        self.fallback = fallback
    }

    /// Transcribes with the primary engine, falling back on failure or empty output.
    public func transcribe(audio: CapturedAudio) async throws -> STTResult {
        do {
            let result = try await primary.transcribe(audio: audio)
            if !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return result
            }
        } catch {
            // Fall through to the local model.
        }
        return try await fallback.transcribe(audio: audio)
    }
}
