import AVFoundation
import Foundation
import Shared
import Speech

// MARK: - Availability check

/// Returns true when the Apple Speech engine API is available on this OS.
public func appleSpeechEngineIsAvailable() -> Bool {
    if #available(macOS 26, *) {
        return true
    }
    return false
}

// MARK: - AppleSpeechEngine

/// An STT engine backed by Apple's on-device SpeechAnalyzer (macOS 26+).
///
/// Critical: do **not** call `start(inputSequence:)` and then yield into that
/// stream on the same task — `start` can wait for the stream and deadlock
/// (LocalFlow stuck on blue "Transcribing…" forever; logs stop after convert).
///
/// Working path: convert mic PCM → `bestAvailableAudioFormat`, write a temp
/// CAF, then `start(inputAudioFile:finishAfterFile: true)` (same pattern as
/// production SpeechAnalyzer helpers). Hard timeout so UI never hangs.
public final class AppleSpeechEngine: STTEngine, @unchecked Sendable {

    /// Creates an Apple Speech engine.
    public init() {}

    /// Transcribes captured audio using SpeechAnalyzer.
    public func transcribe(audio: CapturedAudio) async throws -> STTResult {
        if #available(macOS 26, *) {
            return try await withTimeout(seconds: 20) {
                try await self.transcribeOnMacOS26(audio: audio)
            }
        } else {
            throw LocalFlowError.modelUnavailable("Apple Speech requires macOS 26 or later.")
        }
    }

    private func withTimeout<T: Sendable>(
        seconds: Double,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw LocalFlowError.transcriptionFailed(
                    "Apple Speech timed out. Try again — if this keeps happening, download Parakeet in Settings as a fallback."
                )
            }
            let value = try await group.next()!
            group.cancelAll()
            return value
        }
    }
}

// MARK: - macOS 26 implementation

@available(macOS 26, *)
private extension AppleSpeechEngine {
    static var cachedAnalyzerFormat: AVAudioFormat?
    static var cachedLocale: Locale?

    func transcribeOnMacOS26(audio: CapturedAudio) async throws -> STTResult {
        guard SpeechTranscriber.isAvailable else {
            throw LocalFlowError.modelUnavailable(
                "Apple Speech is unavailable on this Mac. Download Parakeet in Settings as a fallback."
            )
        }

        guard let buffer = audio.buffer, buffer.frameLength > 0 else {
            throw LocalFlowError.transcriptionFailed(
                "AppleSpeechEngine requires a captured PCM buffer."
            )
        }

        let seconds = Double(buffer.frameLength) / max(buffer.format.sampleRate, 1)
        guard seconds >= 0.12 else {
            throw LocalFlowError.transcriptionFailed(
                "No speech captured. Hold the hotkey while you speak."
            )
        }

        // #region agent log
        AgentDebugLog.write(
            hypothesisId: "B",
            location: "AppleSpeechEngine.swift:transcribeOnMacOS26",
            message: "speech begin",
            data: [
                "frames": Int(buffer.frameLength),
                "sampleRate": buffer.format.sampleRate,
                "seconds": seconds,
                "channels": Int(buffer.format.channelCount)
            ],
            runId: "apple-first"
        )
        // #endregion

        let locale = await preferredLocale()
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .transcription
        )
        let modules: [any SpeechModule] = [transcriber]
        try await ensureAssetsReadyFast(modules: modules, locale: locale)

        let analyzerFormat: AVAudioFormat
        if let cached = Self.cachedAnalyzerFormat {
            analyzerFormat = cached
        } else if let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) {
            Self.cachedAnalyzerFormat = format
            analyzerFormat = format
        } else {
            throw LocalFlowError.transcriptionFailed(
                "Apple Speech could not provide a compatible audio format."
            )
        }

        let converted = try convert(buffer, to: analyzerFormat)

        // #region agent log
        AgentDebugLog.write(
            hypothesisId: "B",
            location: "AppleSpeechEngine.swift:transcribeOnMacOS26",
            message: "converted — starting file analysis",
            data: [
                "outSampleRate": converted.format.sampleRate,
                "outFrames": Int(converted.frameLength),
                "outChannels": Int(converted.format.channelCount)
            ],
            runId: "apple-first"
        )
        // #endregion

        let fileURL = try writeTemporaryAudioFile(from: converted, format: analyzerFormat)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let audioFile = try AVAudioFile(forReading: fileURL)
        let analyzer = SpeechAnalyzer(modules: modules)

        let resultsTask = Task<String, Error> {
            var best = ""
            var lastPartial = ""
            for try await result in transcriber.results {
                let plain = String(result.text.characters)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !plain.isEmpty else { continue }
                if result.isFinal {
                    if !best.isEmpty { best.append(" ") }
                    best.append(plain)
                } else {
                    lastPartial = plain
                }
            }
            let trimmed = best.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
            return lastPartial
        }

        do {
            // #region agent log
            AgentDebugLog.write(
                hypothesisId: "B",
                location: "AppleSpeechEngine.swift:transcribeOnMacOS26",
                message: "calling start(inputAudioFile:)",
                data: [:],
                runId: "apple-first"
            )
            // #endregion

            try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
            let fullText: String = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask {
                    try await resultsTask.value
                }
                group.addTask {
                    // Safety deadline: after analyzer completes reading the file,
                    // results should finalize promptly.
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    return ""
                }
                let first = try await group.next() ?? ""
                group.cancelAll()
                return first
            }.trimmingCharacters(in: .whitespacesAndNewlines)

            // #region agent log
            AgentDebugLog.write(
                hypothesisId: "B",
                location: "AppleSpeechEngine.swift:transcribeOnMacOS26",
                message: "speech success",
                data: ["textLen": fullText.count],
                runId: "apple-first"
            )
            // #endregion

            guard !fullText.isEmpty else {
                throw LocalFlowError.transcriptionFailed(
                    "Apple Speech returned empty text. Try speaking a bit longer."
                )
            }
            return STTResult(text: fullText, confidence: 1.0)
        } catch let error as LocalFlowError {
            resultsTask.cancel()
            // #region agent log
            AgentDebugLog.write(
                hypothesisId: "B",
                location: "AppleSpeechEngine.swift:transcribeOnMacOS26",
                message: "speech LocalFlowError",
                data: ["error": error.localizedDescription],
                runId: "apple-first"
            )
            // #endregion
            throw error
        } catch {
            resultsTask.cancel()
            // #region agent log
            AgentDebugLog.write(
                hypothesisId: "B",
                location: "AppleSpeechEngine.swift:transcribeOnMacOS26",
                message: "speech analyzer error",
                data: ["error": error.localizedDescription],
                runId: "apple-first"
            )
            // #endregion
            throw LocalFlowError.transcriptionFailed(
                "Apple SpeechAnalyzer failed: \(error.localizedDescription)"
            )
        }
    }

    func preferredLocale() async -> Locale {
        if let cached = Self.cachedLocale { return cached }
        let supported = await SpeechTranscriber.supportedLocales
        let systemLocale = Locale.current
        let resolved: Locale
        if let match = await SpeechTranscriber.supportedLocale(equivalentTo: systemLocale) {
            resolved = match
        } else {
            let enUS = Locale(identifier: "en-US")
            if let match = await SpeechTranscriber.supportedLocale(equivalentTo: enUS) {
                resolved = match
            } else {
                resolved = supported.first ?? enUS
            }
        }
        Self.cachedLocale = resolved
        return resolved
    }

    func ensureAssetsReadyFast(modules: [any SpeechModule], locale: Locale) async throws {
        let status = await AssetInventory.status(forModules: modules)
        if status == .installed { return }
        try await installAssetsIfNeeded(modules: modules, locale: locale)
    }

    func installAssetsIfNeeded(modules: [any SpeechModule], locale: Locale) async throws {
        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(where: { $0.identifier == locale.identifier }),
           reserved.count >= AssetInventory.maximumReservedLocales,
           let oldest = reserved.last {
            await AssetInventory.release(reservedLocale: oldest)
        }
        _ = try await AssetInventory.reserve(locale: locale)

        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            try await request.downloadAndInstall()
        }

        let status = await AssetInventory.status(forModules: modules)
        guard status == .installed else {
            throw LocalFlowError.modelUnavailable(
                "Apple Speech model is not installed for \(locale.identifier). Check System Settings, then retry."
            )
        }
    }

    func convert(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        if buffer.format == format { return buffer }
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            throw LocalFlowError.transcriptionFailed("Could not create AVAudioConverter for Apple Speech.")
        }

        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = max(1, AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else {
            throw LocalFlowError.transcriptionFailed("Could not allocate converted PCM buffer.")
        }

        var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let conversionError {
            throw LocalFlowError.transcriptionFailed(
                "Audio conversion failed: \(conversionError.localizedDescription)"
            )
        }
        guard status != .error, output.frameLength > 0 else {
            throw LocalFlowError.transcriptionFailed("Audio conversion failed or produced empty audio.")
        }
        return output
    }

    func writeTemporaryAudioFile(from buffer: AVAudioPCMBuffer, format: AVAudioFormat) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("localflow-apple-speech-\(UUID().uuidString).caf")
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try file.write(from: buffer)
        return url
    }
}

// MARK: - Asset readiness helpers

/// Checks whether the Apple Speech on-device model is installed and ready.
public func appleSpeechModelIsInstalled() async -> Bool {
    if #available(macOS 26, *) {
        guard SpeechTranscriber.isAvailable else { return false }
        let locale = await resolvePreferredAppleSpeechLocale()
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let status = await AssetInventory.status(forModules: [transcriber])
        return status == .installed
    }
    return false
}

/// Downloads and installs Apple's on-device speech asset when missing.
public func ensureAppleSpeechModelInstalled() async throws {
    if #available(macOS 26, *) {
        guard SpeechTranscriber.isAvailable else {
            throw LocalFlowError.modelUnavailable(
                "Apple Speech is unavailable on this Mac. Download Parakeet in Settings as a fallback."
            )
        }
        let locale = await resolvePreferredAppleSpeechLocale()
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let modules: [any SpeechModule] = [transcriber]

        let reserved = await AssetInventory.reservedLocales
        if !reserved.contains(where: { $0.identifier == locale.identifier }),
           reserved.count >= AssetInventory.maximumReservedLocales,
           let oldest = reserved.last {
            await AssetInventory.release(reservedLocale: oldest)
        }
        _ = try await AssetInventory.reserve(locale: locale)

        if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
            try await request.downloadAndInstall()
        }
        let status = await AssetInventory.status(forModules: modules)
        guard status == .installed else {
            throw LocalFlowError.modelUnavailable(
                "Apple Speech model is not installed yet. Check System Settings → Apple Intelligence / Language, then retry."
            )
        }
        return
    }
    throw LocalFlowError.modelUnavailable("Apple Speech requires macOS 26 or later.")
}

/// Triggers Apple's own on-device model download for the preferred locale (best-effort).
public func requestAppleSpeechModelInstallation() async {
    try? await ensureAppleSpeechModelInstalled()
}

@available(macOS 26, *)
private func resolvePreferredAppleSpeechLocale() async -> Locale {
    let systemLocale = Locale.current
    if let match = await SpeechTranscriber.supportedLocale(equivalentTo: systemLocale) {
        return match
    }
    let enUS = Locale(identifier: "en-US")
    if let match = await SpeechTranscriber.supportedLocale(equivalentTo: enUS) {
        return match
    }
    let supported = await SpeechTranscriber.supportedLocales
    return supported.first ?? enUS
}
