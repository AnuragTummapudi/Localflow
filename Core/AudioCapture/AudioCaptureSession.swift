@preconcurrency import AVFoundation
import Foundation
import Combine
import OSLog
import Shared

/// Captures microphone audio and emits waveform levels while recording.
public final class AudioCaptureSession: ObservableObject, @unchecked Sendable {
    /// Whether the capture session is actively recording.
    @Published public private(set) var isRecording = false

    /// Recent normalized waveform levels suitable for overlay display.
    @Published public private(set) var waveformLevels: [Float] = Array(repeating: 0.12, count: 32)

    private var engine = AVAudioEngine()
    private var capturedSamples: [Float] = []
    private var captureSampleRate: Double = 16_000
    private var silenceSeconds: Double = 0
    private var speechFrameCount = 0
    private var peakLevel: Float = 0
    private let silenceThreshold: Float = 0.015
    private let sampleLock = NSLock()
    private var configurationObserver: (any NSObjectProtocol)?
    private var startedAt: ContinuousClock.Instant?
    private static let log = Logger(subsystem: "dev.localflow.LocalFlow", category: "AudioCapture")

    /// Called on the main thread when the input device changes mid-recording (AirPods connect, headset unplugged).
    /// Capture has stopped by then; the samples recorded so far are still returned by `stop()`.
    public var onInterrupted: (() -> Void)?

    /// Longest recording kept in memory (10 min at 48 kHz ≈ 115 MB). Dictation auto-stops and transcribes here.
    public static let maxRecordingSeconds: Double = 600

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
        return speechFrameCount >= 2 && !capturedSamples.isEmpty
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
        return silenceSeconds
    }

    /// Starts microphone capture.
    public func start() throws {
        // Tear down any previous session cleanly — HAL -10877 often follows a
        // half-stopped engine reused without reset.
        stopEngineIfNeeded()

        sampleLock.lock()
        capturedSamples = []
        silenceSeconds = 0
        speechFrameCount = 0
        peakLevel = 0
        sampleLock.unlock()

        waveformLevels = Array(repeating: 0.12, count: 32)

        // Fresh engine per session avoids stale I/O context after stop().
        engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else {
            throw LocalFlowError.audioCaptureFailed("Microphone input format is unavailable.")
        }
        captureSampleRate = format.sampleRate

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.consume(buffer: buffer)
        }

        // AVAudioEngine stops itself when the input device changes; without this the UI keeps "listening" to nothing.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            guard let self, self.isRecording else { return }
            Self.log.notice("input device changed mid-recording; stopping capture")
            self.stopEngineIfNeeded()
            self.onInterrupted?()
        }

        engine.prepare()
        startedAt = .now
        try engine.start()
        // Set synchronously so a fast key-up never races past an async flag.
        isRecording = true
    }

    /// Stops capture and returns the captured audio.
    public func stop() -> CapturedAudio {
        guard isRecording else {
            return CapturedAudio(buffer: nil, samples: [], sampleRate: captureSampleRate)
        }
        isRecording = false
        stopEngineIfNeeded()

        sampleLock.lock()
        let samples = capturedSamples
        sampleLock.unlock()

        // The engine buffer is built lazily by CapturedAudio, so stop() holds only one copy.
        return CapturedAudio(buffer: nil, samples: samples, sampleRate: captureSampleRate)
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
        capturedSamples.removeAll(keepingCapacity: false)
        silenceSeconds = 0
        speechFrameCount = 0
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

    private func stopEngineIfNeeded() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        if engine.isRunning {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        } else {
            engine.inputNode.removeTap(onBus: 0)
        }
        engine.reset()
    }

    private func consume(buffer: AVAudioPCMBuffer) {
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
        if capturedSamples.isEmpty, let startedAt {
            // Evidence for first-word clipping: how long the mic took to deliver audio after the hotkey.
            Self.log.notice("first audio buffer after \(String(describing: ContinuousClock.now - startedAt), privacy: .public)")
        }
        // Backstop for the coordinator's auto-stop: never grow past the recording limit.
        let room = Int(captureSampleRate * Self.maxRecordingSeconds) - capturedSamples.count
        if room > 0 { capturedSamples.append(contentsOf: chunk.prefix(room)) }
        let level = min(1, sum / Float(count) * 12)
        if level < silenceThreshold {
            // Measured in seconds: macOS taps often deliver ~4,800 frames, not the 1,024 requested.
            silenceSeconds += Double(count) / captureSampleRate
        } else {
            silenceSeconds = 0
            speechFrameCount += 1
            if level > peakLevel {
                peakLevel = level
            }
        }
        sampleLock.unlock()

        DispatchQueue.main.async {
            self.waveformLevels.append(level)
            if self.waveformLevels.count > 32 {
                self.waveformLevels.removeFirst(self.waveformLevels.count - 32)
            }
        }
    }
}
