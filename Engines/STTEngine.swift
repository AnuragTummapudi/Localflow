import Foundation
import Shared

/// A speech-to-text result with model-supplied confidence when available.
public struct STTResult: Equatable, Sendable {
    /// The recognized transcript text.
    public let text: String

    /// A normalized confidence score from 0 to 1, when supplied or derived by the engine.
    public let confidence: Float?

    /// Creates a transcription result.
    public init(text: String, confidence: Float? = nil) {
        self.text = text
        self.confidence = confidence
    }
}

/// A speech-to-text engine that converts captured audio into text.
public protocol STTEngine: Sendable {
    /// Transcribes captured audio into text.
    func transcribe(audio: CapturedAudio) async throws -> STTResult
}

/// Metadata describing the engine currently selected by LocalFlow.
public struct STTEngineDescriptor: Codable, Equatable, Sendable {
    /// The broad engine family.
    public var kind: EngineKind

    /// The selected model tier.
    public var modelTier: ModelTier

    /// A human-readable status message.
    public var detail: String

    /// Creates an engine descriptor.
    public init(kind: EngineKind, modelTier: ModelTier, detail: String) {
        self.kind = kind
        self.modelTier = modelTier
        self.detail = detail
    }
}

/// A lightweight engine used when no production model is loaded yet.
public struct UnavailableEngine: STTEngine {
    private let message: String

    /// Creates an unavailable-engine placeholder.
    public init(message: String) {
        self.message = message
    }

    /// Throws because no production engine is loaded.
    public func transcribe(audio: CapturedAudio) async throws -> STTResult {
        throw LocalFlowError.modelUnavailable(message)
    }
}
