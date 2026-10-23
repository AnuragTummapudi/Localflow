import AVFoundation
import CoreMedia
import Foundation
import Shared
import Speech

public struct AppleSpeechReadiness: Equatable, Sendable {
    public enum Status: String, Sendable { case ready, actionRequired, unavailable }
    public let status: Status
    public let localeIdentifier: String
    public let detail: String
    public init(status: Status, localeIdentifier: String, detail: String) {
        self.status = status; self.localeIdentifier = localeIdentifier; self.detail = detail
    }
}

/// One owner for Apple-managed locale reservations. Never evicts an unrelated reservation.
public actor AppleSpeechAssets {
    public static let shared = AppleSpeechAssets()
    private var ownedLocale: Locale?
    private var preparing = false

    public static func transcriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [],
                          reportingOptions: [.volatileResults, .alternativeTranscriptions],
                          attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    }
    public func supportedLocales() async -> [Locale] { await SpeechTranscriber.supportedLocales }
    public func readiness(localeIdentifier: String) async -> AppleSpeechReadiness {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier)) else {
            return AppleSpeechReadiness(status: .unavailable, localeIdentifier: localeIdentifier,
                detail: "Apple Speech is unsupported on this Mac or for this language. Select a supported language in Settings.")
        }
        let status = await AssetInventory.status(forModules: [Self.transcriber(locale: locale)])
        return AppleSpeechReadiness(status: status == .installed ? .ready : status == .unsupported ? .unavailable : .actionRequired,
            localeIdentifier: locale.identifier, detail: status == .installed ? "Apple Speech ready" : status == .downloading ? "Apple is installing speech assets" : "Install Apple Speech assets")
    }
    public func prepare(localeIdentifier: String, allowInstallation: Bool,
                        progress: @escaping @Sendable (Double?, String) -> Void = { _, _ in }) async throws -> Locale {
        guard !preparing else { throw LocalFlowError.modelUnavailable("Apple Speech setup is already in progress.") }
        preparing = true; defer { preparing = false }
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier)) else {
            throw LocalFlowError.modelUnavailable("Apple Speech is unavailable for this device or language (\(localeIdentifier)). LocalFlow requires macOS 26+ and a supported SpeechTranscriber locale.")
        }
        let modules: [any SpeechModule] = [Self.transcriber(locale: locale)]
        let status = await AssetInventory.status(forModules: modules)
        guard status != .unsupported else { throw LocalFlowError.modelUnavailable("Apple Speech does not support \(locale.identifier).") }
        if status != .installed && !allowInstallation {
            throw LocalFlowError.modelUnavailable("Install Apple Speech assets in Settings → Speech before recording.")
        }
        let previous = ownedLocale
        if previous?.identifier != locale.identifier {
            if let previous { await AssetInventory.release(reservedLocale: previous) }
            do {
                _ = try await AssetInventory.reserve(locale: locale)
                ownedLocale = locale
            } catch {
                if let previous { _ = try? await AssetInventory.reserve(locale: previous) }
                throw LocalFlowError.modelUnavailable("Apple Speech could not reserve \(locale.identifier): \(error.localizedDescription)")
            }
        }
        if status != .installed {
            progress(nil, "Requesting Apple Speech assets")
            if let request = try await AssetInventory.assetInstallationRequest(supporting: modules) {
                let observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { value, _ in
                    progress(value.totalUnitCount > 0 ? value.fractionCompleted : nil, "Installing Apple Speech assets")
                }
                defer { observation.invalidate() }
                try await request.downloadAndInstall()
            }
        }
        guard await AssetInventory.status(forModules: modules) == .installed else {
            throw LocalFlowError.modelUnavailable("Apple Speech assets are not ready. Retry setup in Settings → Speech.")
        }
        progress(1, "Apple Speech ready")
        return locale
    }
}

/// The only speech implementation. Batch callers feed this same streaming analyzer.
/// Each invocation owns its analyzer, converter and result ledger; sessions never share mutable decoding state.
public struct AppleSpeechEngine: STTEngine, StreamingSTTEngine, Sendable {
    public let localeIdentifier: String
    public init(localeIdentifier: String = Locale.current.identifier) { self.localeIdentifier = localeIdentifier }

    /// Setup warms the system-managed model before the microphone path starts.
    public func prepare() async throws {
        let ready = await AppleSpeechAssets.shared.readiness(localeIdentifier: localeIdentifier)
        guard ready.status == .ready else { throw LocalFlowError.modelUnavailable(ready.detail) }
        let transcriber = AppleSpeechAssets.transcriber(locale: Locale(identifier: ready.localeIdentifier))
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        await analyzer.cancelAndFinishNow()
    }

    public func transcribe(audio: CapturedAudio) async throws -> STTResult {
        let chunks = AsyncThrowingStream<PCMChunk, Error> { continuation in
            for start in stride(from: 0, to: audio.samples.count, by: 4096) {
                continuation.yield(PCMChunk(samples: Array(audio.samples[start..<min(start + 4096, audio.samples.count)]), sampleRate: audio.sampleRate))
            }
            continuation.finish()
        }
        return try await transcribe(chunks: chunks, onPartial: { _ in })
    }

    public func transcribe(chunks: AsyncThrowingStream<PCMChunk, Error>,
                           onPartial: @escaping @Sendable (PartialTranscript) -> Void) async throws -> STTResult {
        let readiness = await AppleSpeechAssets.shared.readiness(localeIdentifier: localeIdentifier)
        guard readiness.status == .ready else { throw LocalFlowError.modelUnavailable(readiness.detail) }
        let transcriber = AppleSpeechAssets.transcriber(locale: Locale(identifier: readiness.localeIdentifier))
        let modules: [any SpeechModule] = [transcriber]
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw LocalFlowError.transcriptionFailed("Apple Speech has no compatible audio format.")
        }
        let analyzer = SpeechAnalyzer(modules: modules, options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        let converter = SpeechPCMConverter(outputFormat: format)
        // Let SpeechTranscriber finalize its own ranges during capture. The real
        // multi-pause fixture showed forced finalize(through:nil) losing later
        // speech on this system. Finalization at stop still drains the whole input.
        // Consume results before supplying audio. Range revisions replace old hypotheses.
        let results = Task<STTResult, Error> {
            var ledger = SpeechPhraseLedger()
            for try await result in transcriber.results {
                try Task.checkCancellation()
                let confidences = result.text.runs.compactMap { $0.transcriptionConfidence }
                let confidence = confidences.isEmpty ? nil : Float(confidences.reduce(0, +) / Double(confidences.count))
                let phrase = SpeechPhrase(startNanoseconds: Self.nanoseconds(result.range.start),
                    endNanoseconds: Self.nanoseconds(CMTimeRangeGetEnd(result.range)),
                    finalizationNanoseconds: Self.nanoseconds(result.resultsFinalizationTime),
                    text: String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines),
                    isFinal: result.isFinal, confidence: confidence,
                    alternatives: result.alternatives.map { String($0.characters).trimmingCharacters(in: .whitespacesAndNewlines) })
                if ledger.replace(phrase) { onPartial(ledger.partial) }
            }
            try Task.checkCancellation()
            guard ledger.phrases.allSatisfy(\.isFinal) else {
                throw LocalFlowError.transcriptionFailed("Apple Speech ended before all speech ranges finalized. No partial text was used.")
            }
            let scores = ledger.phrases.compactMap(\.confidence)
            return STTResult(text: ledger.finalizedText,
                confidence: scores.isEmpty ? nil : scores.reduce(0, +) / Float(scores.count), phrases: ledger.phrases)
        }
        return try await withTaskCancellationHandler {
            do {
                try await analyzer.prepareToAnalyze(in: format)
                // Conversion is lazy and sequential on the analyzer's input consumer.
                let inputs = SpeechInputSequence(chunks: chunks, converter: converter)
                _ = try await analyzer.analyzeSequence(inputs)
                try Task.checkCancellation()
                // A bounded stop deadline cancels the actual analyzer, not just a waiting task.
                let deadline = Task {
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    await analyzer.cancelAndFinishNow(); results.cancel()
                }
                defer { deadline.cancel() }
                try await analyzer.finalizeAndFinishThroughEndOfInput()
                let result = try await results.value
                try Task.checkCancellation()
                return result
            } catch {
                await analyzer.cancelAndFinishNow(); results.cancel()
                _ = try? await results.value
                throw error
            }
        } onCancel: {
            results.cancel()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
    private static func nanoseconds(_ time: CMTime) -> Int64 {
        guard time.isNumeric else { return 0 }
        return CMTimeConvertScale(time, timescale: 1_000_000_000, method: .roundHalfAwayFromZero).value
    }
}

/// Sole input iterator owns converter state. Borrowed microphone buffers are never retained.
private final class SpeechPCMConverter: @unchecked Sendable {
    let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var inputRate: Double?
    private var frames: Int64 = 0
    init(outputFormat: AVAudioFormat) { self.outputFormat = outputFormat }
    func input(_ chunk: PCMChunk) throws -> AnalyzerInput? {
        try Task.checkCancellation()
        guard !chunk.samples.isEmpty else { return nil }
        guard chunk.sampleRate.isFinite, chunk.sampleRate > 0,
              let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: chunk.sampleRate, channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(chunk.samples.count)) else {
            throw LocalFlowError.transcriptionFailed("Invalid microphone PCM format.")
        }
        input.frameLength = input.frameCapacity
        chunk.samples.withUnsafeBufferPointer { samples in
            input.floatChannelData![0].update(from: samples.baseAddress!, count: samples.count)
        }
        if inputRate == nil { inputRate = chunk.sampleRate; converter = AVAudioConverter(from: inputFormat, to: outputFormat) }
        guard inputRate == chunk.sampleRate else { throw LocalFlowError.transcriptionFailed("Microphone sample rate changed during recording. Restart recording.") }
        let output: AVAudioPCMBuffer
        if inputFormat == outputFormat { output = input }
        else {
            guard let converter,
                  let converted = AVAudioPCMBuffer(pcmFormat: outputFormat,
                    frameCapacity: AVAudioFrameCount(ceil(Double(input.frameLength) * outputFormat.sampleRate / chunk.sampleRate)) + 256) else {
                throw LocalFlowError.transcriptionFailed("Cannot convert microphone audio for Apple Speech.")
            }
            var consumed = false
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, state in
                if consumed { state.pointee = .noDataNow; return nil }
                consumed = true; state.pointee = .haveData; return input
            }
            if let error { throw error }
            guard status != .error else { throw LocalFlowError.transcriptionFailed("Apple Speech PCM conversion failed.") }
            output = converted
        }
        guard output.frameLength > 0 else { return nil }
        let start = CMTime(value: frames, timescale: CMTimeScale(outputFormat.sampleRate))
        frames += Int64(output.frameLength)
        return AnalyzerInput(buffer: output, bufferStartTime: start)
    }
    func finish() throws -> AnalyzerInput? {
        guard let converter,
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 512) else { return nil }
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in state.pointee = .endOfStream; return nil }
        if let error { throw error }
        guard status != .error, output.frameLength > 0 else { return nil }
        let start = CMTime(value: frames, timescale: CMTimeScale(outputFormat.sampleRate))
        frames += Int64(output.frameLength)
        return AnalyzerInput(buffer: output, bufferStartTime: start)
    }

}


/// Lazy conversion retains bounded PCM and drains the converter after input closure.
private struct SpeechInputSequence: AsyncSequence, Sendable {
    typealias Element = AnalyzerInput
    let chunks: AsyncThrowingStream<PCMChunk, Error>
    let converter: SpeechPCMConverter
    func makeAsyncIterator() -> Iterator { Iterator(input: chunks.makeAsyncIterator(), converter: converter) }
    struct Iterator: AsyncIteratorProtocol {
        var input: AsyncThrowingStream<PCMChunk, Error>.Iterator
        let converter: SpeechPCMConverter
        var ended = false
        mutating func next() async throws -> AnalyzerInput? {
            guard !ended else { return nil }
            while let chunk = try await input.next() {
                if let converted = try converter.input(chunk) { return converted }
            }
            ended = true
            return try converter.finish()
        }
    }
}
