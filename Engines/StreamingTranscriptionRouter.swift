import Foundation
import Shared

public struct StreamingTranscriptionSession: Sendable {
    public let id: UUID
    public let events: AsyncStream<TranscriptionEvent>
}

/// One session owns one analyzer task. Errors fail closed; no second speech implementation.
public actor StreamingTranscriptionRouter {
    private struct Session {
        let id: UUID
        let relay: TranscriptRelay
        let worker: Task<STTResult, Error>
    }
    private var engine: (any StreamingSTTEngine)?
    private var session: Session?
    private var finishingID: UUID?
    public init(engine: (any StreamingSTTEngine)? = nil) { self.engine = engine }
    public func updateEngine(_ engine: (any StreamingSTTEngine)?) { self.engine = engine }
    public func start(chunks: AsyncThrowingStream<PCMChunk, Error>) -> StreamingTranscriptionSession {
        let (events, continuation) = AsyncStream<TranscriptionEvent>.makeStream(bufferingPolicy: .bufferingNewest(32))
        let id = UUID(), relay = TranscriptRelay(continuation: continuation)
        guard !Task.isCancelled else { relay.cancel(); return .init(id: id, events: events) }
        cancelCurrentSession()
        let selected = engine
        let worker = Task<STTResult, Error> {
            do {
                guard let selected else { throw LocalFlowError.modelUnavailable("Apple Speech is not ready. Open Settings → Speech.") }
                let result = try await selected.transcribe(chunks: chunks) { relay.send(.partial($0)) }
                try Task.checkCancellation()
                return result
            } catch {
                if !Task.isCancelled { relay.send(.failed(error.localizedDescription)); relay.finish() }
                throw error
            }
        }
        session = Session(id: id, relay: relay, worker: worker)
        return .init(id: id, events: events)
    }
    /// Capture must close input first. Only the analyzer's final can reach execution/insertion.
    public func finish(sessionID: UUID) async throws -> FinalTranscript {
        guard let current = session, current.id == sessionID else { throw CancellationError() }
        guard finishingID != sessionID else { throw LocalFlowError.transcriptionFailed("Speech is already finalizing.") }
        finishingID = sessionID
        defer {
            if finishingID == sessionID { finishingID = nil }
            if session?.id == sessionID { current.relay.finish(); session = nil }
        }
        return try await withTaskCancellationHandler {
            let result = try await current.worker.value
            try Task.checkCancellation()
            guard session?.id == sessionID, !current.relay.isCancelled else { throw CancellationError() }
            let final = FinalTranscript(text: result.text, confidence: result.confidence, phrases: result.phrases)
            current.relay.send(.final(final)); current.relay.finish()
            return final
        } onCancel: { current.relay.cancel(); current.worker.cancel() }
    }
    public func cancel(sessionID: UUID) {
        guard session?.id == sessionID else { return }; cancelCurrentSession()
    }
    private func cancelCurrentSession() {
        session?.relay.cancel(); session?.worker.cancel(); session = nil
    }
}

/// Synchronous callbacks are ordered under a lock; cancellation gates late results immediately.
private final class TranscriptRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var state = TranscriptState()
    private let continuation: AsyncStream<TranscriptionEvent>.Continuation
    init(continuation: AsyncStream<TranscriptionEvent>.Continuation) { self.continuation = continuation }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return state.isCancelled }
    func send(_ event: TranscriptionEvent) {
        lock.lock(); defer { lock.unlock() }
        if state.apply(event) { continuation.yield(event) }
    }
    func finish() { continuation.finish() }
    func cancel() { send(.cancelled); continuation.finish() }
}
