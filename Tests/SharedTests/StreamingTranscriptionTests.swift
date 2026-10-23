import XCTest
import Shared
@testable import Engines
import CommandMode
import ModelManager

final class StreamingTranscriptionTests: XCTestCase {
    private let audio = CapturedAudio(buffer: nil, samples: [0.2, 0.3], sampleRate: 16_000)

    func testPartialReplacementDuplicateSuppressionAndAuthoritativeFinal() {
        var state = TranscriptState()
        XCTAssertTrue(state.apply(.partial(PartialTranscript(text: "open not"))))
        XCTAssertTrue(state.apply(.partial(PartialTranscript(text: "open Notes"))))
        XCTAssertEqual(state.partial?.text, "open Notes")
        XCTAssertFalse(state.apply(.partial(PartialTranscript(text: "open Notes"))))
        let final = FinalTranscript(text: "Open Notes.", source: .streaming)
        XCTAssertTrue(state.apply(.final(final)))
        XCTAssertNil(state.partial)
        XCTAssertEqual(state.final, final)
        XCTAssertFalse(state.apply(.partial(PartialTranscript(text: "late"))))
        XCTAssertFalse(state.apply(.cancelled))
    }

    func testSameTextAcousticBoundaryIsDeliveredWithoutChangingPayload() {
        var state = TranscriptState()
        XCTAssertTrue(state.apply(.partial(PartialTranscript(text: "open Notes"))))
        XCTAssertTrue(state.apply(.partial(PartialTranscript(text: "open Notes", isUtteranceBoundary: true))))
        XCTAssertEqual(state.partial?.text, "open Notes")
        XCTAssertEqual(state.partial?.isUtteranceBoundary, true)
        XCTAssertFalse(state.apply(.partial(PartialTranscript(text: "open Notes", isUtteranceBoundary: true))))
    }

    func testCancellationAndNewStateReset() {
        var state = TranscriptState()
        state.apply(.partial(PartialTranscript(text: "old")))
        XCTAssertTrue(state.apply(.cancelled))
        XCTAssertNil(state.partial)
        XCTAssertFalse(state.apply(.final(FinalTranscript(text: "late", source: .streaming))))
        state = TranscriptState()
        XCTAssertFalse(state.isCancelled)
        XCTAssertTrue(state.apply(.partial(PartialTranscript(text: "new"))))
        XCTAssertEqual(state.partial?.text, "new")
    }

    func testStreamingPartialsArriveBeforeInputClosesAndFinalWins() async throws {
        let partialArrived = expectation(description: "partial while microphone is open")
        let engine = ScriptedStreamingEngine(partials: ["turn", "turn on", "turn on", "turn off"], result: "Turn off.")
        let router = StreamingTranscriptionRouter(engine: engine)
        let (chunks, input) = AsyncThrowingStream<PCMChunk, Error>.makeStream()
        let session = await router.start(chunks: chunks)
        let collector = Task {
            var events: [TranscriptionEvent] = []
            for await event in session.events {
                events.append(event)
                if event == .partial(PartialTranscript(text: "turn off")) { partialArrived.fulfill() }
            }
            return events
        }
        await fulfillment(of: [partialArrived], timeout: 3)
        input.yield(PCMChunk(samples: [0.2], sampleRate: 48_000))
        input.finish()
        let result = try await router.finish(sessionID: session.id)
        XCTAssertEqual(result.text, "Turn off.")
        let events = await collector.value
        XCTAssertEqual(events, [
            .partial(PartialTranscript(text: "turn")), .partial(PartialTranscript(text: "turn on")),
            .partial(PartialTranscript(text: "turn off")), .final(FinalTranscript(text: "Turn off.", source: .streaming))
        ])
        let chunkRates = await engine.chunkRates
        XCTAssertEqual(chunkRates, [48_000])
    }







    func testUnavailableAndOverflowFailClosedWithoutPromotingPartials() async {
        for missing in [true, false] {
            let router = StreamingTranscriptionRouter(engine: missing ? nil : ScriptedStreamingEngine(partials: ["unsafe partial"], result: "wrong"))
            let (chunks, input) = AsyncThrowingStream<PCMChunk, Error>.makeStream()
            let session = await router.start(chunks: chunks)
            if missing { input.finish() } else { input.finish(throwing: LiveAudioError.bufferOverflow) }
            do { _ = try await router.finish(sessionID: session.id); XCTFail("Must fail closed") } catch { }
            var events: [TranscriptionEvent] = []
            for await event in session.events { events.append(event) }
            XCTAssertTrue(events.contains { if case .failed = $0 { return true }; return false })
            XCTAssertFalse(events.contains { if case .final = $0 { return true }; return false })
        }
    }

    func testCancelStopsWorkerWithoutBatchAndIgnoresLateCallbacks() async throws {
        let engine = SuspendedStreamingEngine()
        let started = expectation(description: "worker started")
        let router = StreamingTranscriptionRouter(engine: engine)
        let (chunks, input) = AsyncThrowingStream<PCMChunk, Error>.makeStream()
        let session = await router.start(chunks: chunks)
        let collector = Task {
            var events: [TranscriptionEvent] = []
            for await event in session.events {
                events.append(event)
                if case .partial = event { started.fulfill() }
            }
            return events
        }
        await fulfillment(of: [started], timeout: 3)
        await router.cancel(sessionID: session.id)
        let events = await collector.value
        XCTAssertEqual(events.last, .cancelled)
        do {
            _ = try await router.finish(sessionID: session.id)
            XCTFail("Cancelled session must throw")
        } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        await engine.release()
        input.finish()
    }

    func testNewSessionIsIsolatedFromCancelledInference() async throws {
        let oldEngine = SuspendedStreamingEngine()
        let router = StreamingTranscriptionRouter(engine: oldEngine)
        let (oldChunks, oldInput) = AsyncThrowingStream<PCMChunk, Error>.makeStream()
        let old = await router.start(chunks: oldChunks)
        // Waiting for the first event proves that the old inference is suspended.
        var oldIterator = old.events.makeAsyncIterator()
        let first = await oldIterator.next()
        XCTAssertEqual(first, .partial(PartialTranscript(text: "old")))
        await router.updateEngine(ScriptedStreamingEngine(partials: ["new"], result: "New session."))
        let (chunks, input) = AsyncThrowingStream<PCMChunk, Error>.makeStream()
        let new = await router.start(chunks: chunks)
        XCTAssertNotEqual(old.id, new.id)
        await router.cancel(sessionID: old.id) // Stale cancellation must not cancel the new session.
        await oldEngine.release()
        oldInput.finish()
        input.finish()
        let result = try await router.finish(sessionID: new.id)
        XCTAssertEqual(result.text, "New session.")
        var events: [TranscriptionEvent] = []
        for await event in new.events { events.append(event) }
        XCTAssertEqual(events, [.partial(PartialTranscript(text: "new")), .final(FinalTranscript(text: "New session.", source: .streaming))])
        let oldLast = await oldIterator.next()
        XCTAssertEqual(oldLast, .cancelled)
        let oldEnd = await oldIterator.next()
        XCTAssertNil(oldEnd)
    }


    func testCancelledQueuedStartDoesNotReplaceActiveSession() async throws {
        let router = StreamingTranscriptionRouter(engine: ScriptedStreamingEngine(partials: ["active"], result: "active final"))
        let (chunks, input) = AsyncThrowingStream<PCMChunk, Error>.makeStream()
        let active = await router.start(chunks: chunks)
        let queued = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await router.start(chunks: AsyncThrowingStream { $0.finish() })
        }
        let cancelled = await queued.value
        var events: [TranscriptionEvent] = []
        for await event in cancelled.events { events.append(event) }
        XCTAssertEqual(events, [.cancelled])
        input.finish()
        let result = try await router.finish(sessionID: active.id)
        XCTAssertEqual(result.text, "active final")
    }

    func testModelPreparationDoesNotInterruptCurrentRecording() async throws {
        let router = StreamingTranscriptionRouter(engine: ScriptedStreamingEngine(partials: ["current"], result: "current final"))
        let (chunks, input) = AsyncThrowingStream<PCMChunk, Error>.makeStream()
        let session = await router.start(chunks: chunks)
        await router.updateEngine(ScriptedStreamingEngine(partials: ["next"], result: "next final"))
        input.finish()
        let current = try await router.finish(sessionID: session.id)
        XCTAssertEqual(current.text, "current final")
        let next = await router.start(chunks: AsyncThrowingStream { $0.finish() })
        let nextFinal = try await router.finish(sessionID: next.id)
        XCTAssertEqual(nextFinal.text, "next final")
    }

    func testCancellingFinalizationCancelsInferencePromptlyAndSkipsBatch() async throws {
        let stopped = expectation(description: "inference cancelled promptly")
        let engine = CancellationObservingEngine(onCancel: { stopped.fulfill() })
        let router = StreamingTranscriptionRouter(engine: engine)
        let (chunks, input) = AsyncThrowingStream<PCMChunk, Error>.makeStream()
        let session = await router.start(chunks: chunks)
        var iterator = session.events.makeAsyncIterator()
        _ = await iterator.next()
        let finalization = Task {
            try await router.finish(sessionID: session.id)
        }
        finalization.cancel()
        do {
            _ = try await finalization.value
            XCTFail("Cancelled finalization must throw")
        } catch is CancellationError {} catch { XCTFail("Unexpected \(error)") }
        await fulfillment(of: [stopped], timeout: 3)
        input.finish()
    }

}

private actor ScriptedStreamingEngine: StreamingSTTEngine {
    enum Failure: Error { case inference }
    let partials: [String]
    let result: String
    let fails: Bool
    private(set) var chunkRates: [Double] = []
    init(partials: [String], result: String, fails: Bool = false) { self.partials = partials; self.result = result; self.fails = fails }


    func transcribe(chunks: AsyncThrowingStream<PCMChunk, Error>, onPartial: @escaping @Sendable (PartialTranscript) -> Void) async throws -> STTResult {
        for text in partials { onPartial(PartialTranscript(text: text)) }
        for try await chunk in chunks {
            try Task.checkCancellation()
            chunkRates.append(chunk.sampleRate)
        }
        if fails { throw Failure.inference }
        return STTResult(text: result)
    }
}

/// Models a non-interruptible in-flight SDK prediction; deliberately emits after cancel.
private actor SuspendedStreamingEngine: StreamingSTTEngine {
    private var gate: CheckedContinuation<Void, Never>?
    func transcribe(chunks: AsyncThrowingStream<PCMChunk, Error>, onPartial: @escaping @Sendable (PartialTranscript) -> Void) async throws -> STTResult {
        await withCheckedContinuation { continuation in
            gate = continuation
            onPartial(PartialTranscript(text: "old"))
        }
        onPartial(PartialTranscript(text: "late old"))
        return STTResult(text: "late final")
    }
    func release() { gate?.resume(); gate = nil }
}

private actor CancellationObservingEngine: StreamingSTTEngine {
    let onCancel: @Sendable () -> Void
    init(onCancel: @escaping @Sendable () -> Void) { self.onCancel = onCancel }
    func transcribe(chunks: AsyncThrowingStream<PCMChunk, Error>, onPartial: @escaping @Sendable (PartialTranscript) -> Void) async throws -> STTResult {
        onPartial(PartialTranscript(text: "listening"))
        do {
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return STTResult(text: "unexpected")
        } catch {
            onCancel()
            throw error
        }
    }
}
