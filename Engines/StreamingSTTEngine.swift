import Foundation
import Shared

/// Streaming boundary implemented only by Apple Speech in production.
/// One invocation owns its decoder state until input closes or the task is cancelled.
public protocol StreamingSTTEngine: Sendable {
    func transcribe(
        chunks: AsyncThrowingStream<PCMChunk, Error>,
        onPartial: @escaping @Sendable (PartialTranscript) -> Void
    ) async throws -> STTResult
}
