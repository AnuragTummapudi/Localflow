import Foundation
import Shared

/// Routes transcription requests to the currently selected speech engine.
public actor TranscriptionRouter {
    private var engine: any STTEngine
    private(set) var activeEngineName: String = "Not loaded"
    private var tail: Task<STTResult, Error>?
    private var invocationID = UUID()

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
        try Task.checkCancellation()
        let previous = tail
        let selected = engine
        let id = UUID()
        let job = Task {
            // Actor isolation alone does not serialize a suspended SDK call.
            // Even a cancelled, non-cooperative prediction retains ownership
            // until it returns; queued cancellation never enters the engine.
            if let previous { _ = try? await previous.value }
            try Task.checkCancellation()
            let result = try await selected.transcribe(audio: audio)
            try Task.checkCancellation()
            return result
        }
        tail = job; invocationID = id
        defer { if invocationID == id { tail = nil } }
        return try await withTaskCancellationHandler {
            try await job.value
        } onCancel: { job.cancel() }
    }
}
