@preconcurrency import AVFoundation
import Foundation
import Combine
import Shared

/// Captures microphone audio and emits waveform levels while recording.
public final class AudioCaptureSession: ObservableObject, @unchecked Sendable {
    /// Whether the capture session is actively recording.
    @Published public private(set) var isRecording = false

    /// Recent normalized waveform levels suitable for overlay display.
    @Published public private(set) var waveformLevels: [Float] = Array(repeating: 0.12, count: 32)

    // Engine/tap lifecycle is owned by the main-thread coordinator. Audio callbacks
    // touch only sampleLock-protected fields; UI delivery is generation-gated.
    private var engine = AVAudioEngine()
    private var tapInstalled = false
    private var captureGeneration = UUID()
    private var capturedSamples: [Float] = []
    private var retainRecording = true
    private var captureSampleRate: Double = 16_000
    private var silenceFrameCount = 0
    private var speechFrameCount = 0
    private var peakLevel: Float = 0
    private var speechOnset: TimeInterval?
    private let silenceThreshold: Float = 0.015
    private let silenceFrameLimit = 45
    private let sampleLock = NSLock()
    // Protected by sampleLock, including yield/finish ordering with the audio tap.
    private var chunkContinuation: AsyncThrowingStream<PCMChunk, Error>.Continuation?

    /// Creates an audio capture session.
    public init() {}

    /// Requests microphone access from macOS.
    public func requestMicrophonePermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// Whether meaningful speech energy was observed during this capture session.
    public var hasMeaningfulAudio: Bool {
        sampleLock.lock()
        defer { sampleLock.unlock() }
        return speechFrameCount >= 2
    }

    /// Monotonic onset of speech-like energy, using the same gate as silence detection.
    public var speechOnsetUptime: TimeInterval? {
        sampleLock.lock()
        defer { sampleLock.unlock() }
        return speechOnset
    }

    /// Highest normalized level observed during the session.
    public var peakCapturedLevel: Float {
        sampleLock.lock()
        defer { sampleLock.unlock() }
        return peakLevel
    }

    /// Uninterrupted duration of silence observed in seconds (resets to 0 whenever speech is detected).
    public var continuousSilenceDurationSeconds: Double {
        sampleLock.lock()
        defer { sampleLock.unlock() }
        guard isRecording else { return 0 }
        return Double(silenceFrameCount) * (1024.0 / max(captureSampleRate, 16_000))
    }

    /// Starts microphone capture.
    public func start() throws {
        _ = try start(streaming: false, retainRecording: true)
    }

    /// Starts the same capture path with a bounded live PCM feed for local inference.
    /// Overflow terminates the live feed with a specific error; no gapped speech is finalized.
    public func startStreaming(retainRecording: Bool = true) throws -> AsyncThrowingStream<PCMChunk, Error> {
        return try start(streaming: true, retainRecording: retainRecording)
    }

    private func start(streaming: Bool, retainRecording: Bool) throws -> AsyncThrowingStream<PCMChunk, Error> {
        // Tear down any previous session cleanly — HAL -10877 often follows a
        // half-stopped engine reused without reset.
        stopEngineIfNeeded()

        sampleLock.lock()
        self.retainRecording = retainRecording
        chunkContinuation?.finish()
        let (chunks, continuation) = AsyncThrowingStream<PCMChunk, Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        chunkContinuation = streaming ? continuation : nil
        if !streaming { continuation.finish() }
        captureGeneration = UUID()
        let generation = captureGeneration
        capturedSamples = []
        silenceFrameCount = 0
        speechFrameCount = 0
        speechOnset = nil
        peakLevel = 0
        sampleLock.unlock()

        waveformLevels = Array(repeating: 0.12, count: 32)

        // Fresh engine per session avoids stale I/O context after stop().
        engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            reset()
            throw LocalFlowError.audioCaptureFailed("Microphone input format is unavailable.")
        }
        captureSampleRate = format.sampleRate

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.consume(buffer: buffer, generation: generation)
        }

        tapInstalled = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            reset()
            throw error
        }
        // Set synchronously so a fast key-up never races past an async flag.
        isRecording = true
        return chunks
    }

    /// Stops capture and returns the captured audio.
    public func stop() -> CapturedAudio {
        guard isRecording else {
            return CapturedAudio(buffer: nil, samples: [], sampleRate: captureSampleRate)
        }
        isRecording = false
        stopEngineIfNeeded()

        sampleLock.lock()
        chunkContinuation?.finish()
        chunkContinuation = nil
        let samples = capturedSamples
        sampleLock.unlock()

        return CapturedAudio(
            buffer: Self.buffer(from: samples, sampleRate: captureSampleRate),
            samples: samples,
            sampleRate: captureSampleRate
        )
    }

    /// Explicitly cancels capture and tears down all audio resources cleanly.
    public func cancel() {
        reset()
    }

    /// Resets all capture state and ensures the audio engine is fully stopped.
    public func reset() {
        isRecording = false
        stopEngineIfNeeded()
        sampleLock.lock()
        chunkContinuation?.finish(throwing: CancellationError())
        chunkContinuation = nil
        capturedSamples.removeAll(keepingCapacity: false)
        silenceFrameCount = 0
        speechFrameCount = 0
        speechOnset = nil
        peakLevel = 0
        sampleLock.unlock()

        if Thread.isMainThread {
            waveformLevels = Array(repeating: 0.12, count: 32)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.waveformLevels = Array(repeating: 0.12, count: 32)
            }
        }
    }

    /// Returns true when enough silence has been observed to stop automatically.
    public func shouldStopForSilence() -> Bool {
        sampleLock.lock()
        defer { sampleLock.unlock() }
        return silenceFrameCount >= silenceFrameLimit
    }

    private func stopEngineIfNeeded() {
        sampleLock.lock(); captureGeneration = UUID(); sampleLock.unlock()
        // Accessing inputNode creates the hardware I/O unit. Idle reset must never
        // instantiate it (including on machines with no microphone permission).
        guard tapInstalled else { return }
        engine.inputNode.removeTap(onBus: 0)
        tapInstalled = false
        engine.stop()
        engine.reset()
    }

    private func consume(buffer: AVAudioPCMBuffer, generation: UUID) {
        guard let channel = buffer.floatChannelData?[0] else { return }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return }

        var sum: Float = 0
        var chunk: [Float] = []
        chunk.reserveCapacity(count)
        for index in 0..<count {
            let sample = channel[index]
            sum += abs(sample)
            chunk.append(sample)
        }

        sampleLock.lock()
        guard captureGeneration == generation else { sampleLock.unlock(); return }
        if retainRecording { capturedSamples.append(contentsOf: chunk) }
        if let continuation = chunkContinuation {
            switch continuation.yield(PCMChunk(samples: chunk, sampleRate: buffer.format.sampleRate)) {
            case .dropped:
                continuation.finish(throwing: LiveAudioError.bufferOverflow)
                chunkContinuation = nil
            case .terminated:
                chunkContinuation = nil
            case .enqueued:
                break
            @unknown default:
                continuation.finish(throwing: LiveAudioError.bufferOverflow)
                chunkContinuation = nil
            }
        }
        let level = min(1, sum / Float(count) * 12)
        if level < silenceThreshold {
            silenceFrameCount += 1
        } else {
            silenceFrameCount = 0
            speechFrameCount += 1
            if speechOnset == nil { speechOnset = ProcessInfo.processInfo.systemUptime }
            if level > peakLevel {
                peakLevel = level
            }
        }
        sampleLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.sampleLock.lock()
            let current = self.captureGeneration == generation
            self.sampleLock.unlock()
            guard current else { return }
            self.waveformLevels.append(level)
            if self.waveformLevels.count > 32 {
                self.waveformLevels.removeFirst(self.waveformLevels.count - 32)
            }
        }
    }

    private static func buffer(from samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer? {
        guard !samples.isEmpty,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channel = buffer.floatChannelData?[0]
        else { return nil }

        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            if let baseAddress = pointer.baseAddress {
                channel.update(from: baseAddress, count: samples.count)
            }
        }
        return buffer
    }
}
