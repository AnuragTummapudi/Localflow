import XCTest
import Engines
import Shared

final class BatchOwnershipTests: XCTestCase {
    private let audio = CapturedAudio(buffer: nil, samples: [0.1], sampleRate: 16_000)
    func testCancelledPredictionDrainsBeforeNextInvocation() async throws {
        let engine = SuspendedBatchEngine(), router = TranscriptionRouter(engine: engine)
        let first = Task { try await router.transcribe(audio: audio) }
        try await waitForCalls(1, engine)
        let second = Task { try await router.transcribe(audio: audio) }
        for _ in 0..<20 { await Task.yield() }
        let before = await engine.calls; XCTAssertEqual(before, 1)
        first.cancel(); await engine.release()
        do { _ = try await first.value; XCTFail("Cancelled prediction cannot publish a result") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await waitForCalls(2, engine)
        await engine.release(); _ = try await second.value
        let maximum = await engine.maximumConcurrent; XCTAssertEqual(maximum, 1)
    }
    func testCancelledQueuedInvocationNeverEntersEngine() async throws {
        let engine = SuspendedBatchEngine(), router = TranscriptionRouter(engine: engine)
        let first = Task { try await router.transcribe(audio: audio) }
        try await waitForCalls(1, engine)
        let queued = Task { try await router.transcribe(audio: audio) }
        for _ in 0..<20 { await Task.yield() }
        queued.cancel(); await engine.release(); _ = try await first.value
        do { _ = try await queued.value; XCTFail("Queued cancellation must stop before inference") }
        catch { XCTAssertTrue(error is CancellationError) }
        let calls = await engine.calls; XCTAssertEqual(calls, 1)
    }
    private func waitForCalls(_ count: Int, _ engine: SuspendedBatchEngine) async throws {
        for _ in 0..<100 {
            if await engine.calls == count { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Batch invocation did not acquire ownership")
    }
}

/// Deliberately ignores task cancellation while suspended, like an SDK prediction.
private actor SuspendedBatchEngine: STTEngine {
    private(set) var calls = 0
    private(set) var maximumConcurrent = 0
    private var active = 0
    private var gate: CheckedContinuation<Void, Never>?
    func transcribe(audio: CapturedAudio) async throws -> STTResult {
        calls += 1; active += 1; maximumConcurrent = max(maximumConcurrent, active)
        defer { active -= 1 }
        await withCheckedContinuation { gate = $0 }
        return STTResult(text: "test-owned result")
    }
    func release() { gate?.resume(); gate = nil }
}
