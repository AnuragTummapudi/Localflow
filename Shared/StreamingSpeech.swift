import Foundation

/// Owned mono PCM copied from the microphone tap. Never retains an AVAudioEngine buffer.
public struct PCMChunk: Sendable, Equatable {
    public let samples: [Float]
    public let sampleRate: Double

    public init(samples: [Float], sampleRate: Double) {
        self.samples = samples
        self.sampleRate = sampleRate
    }
}

public enum LiveAudioError: Error, LocalizedError, Sendable {
    /// Inference fell behind capture. Fail closed rather than treating a gapped stream as final.
    case bufferOverflow
    public var errorDescription: String? { "Apple Speech could not keep up with microphone audio. Stop and restart recording. Incomplete speech was not used as a final transcript." }
}

/// Apple audio identity survives text revisions; nanoseconds are normalized from CMTime.
public struct SpeechPhrase: Equatable, Sendable {
    public let startNanoseconds: Int64
    public let endNanoseconds: Int64
    public let finalizationNanoseconds: Int64
    public let text: String
    public let isFinal: Bool
    public let confidence: Float?
    public let alternatives: [String]
    public var id: Int64 { startNanoseconds }
    public init(startNanoseconds: Int64, endNanoseconds: Int64, finalizationNanoseconds: Int64 = 0,
                text: String, isFinal: Bool, confidence: Float? = nil, alternatives: [String] = []) {
        self.startNanoseconds = startNanoseconds; self.endNanoseconds = endNanoseconds
        self.finalizationNanoseconds = finalizationNanoseconds; self.text = text
        self.isFinal = isFinal; self.confidence = confidence; self.alternatives = alternatives
    }
}

/// Range replacement rather than append. Overlapping volatile ranges can merge or split.
/// Final ranges never become volatile again. Empty text still replaces its old hypothesis.
public struct SpeechPhraseLedger: Sendable {
    public private(set) var phrases: [SpeechPhrase] = []
    public private(set) var revision: UInt64 = 0
    public init() {}
    @discardableResult public mutating func replace(_ next: SpeechPhrase) -> Bool {
        guard next.endNanoseconds >= next.startNanoseconds else { return false }
        let overlaps: (SpeechPhrase) -> Bool = {
            $0.startNanoseconds == next.startNanoseconds ||
            ($0.startNanoseconds < next.endNanoseconds && next.startNanoseconds < $0.endNanoseconds)
        }
        if !next.isFinal && phrases.contains(where: { $0.isFinal && overlaps($0) }) { return false }
        if phrases.contains(next) { return false }
        phrases.removeAll(where: overlaps); phrases.append(next)
        phrases.sort { $0.startNanoseconds < $1.startNanoseconds }; revision += 1
        return true
    }
    public var text: String { phrases.map(\.text).filter { !$0.isEmpty }.joined(separator: " ") }
    public var finalizedText: String { phrases.filter(\.isFinal).map(\.text).filter { !$0.isEmpty }.joined(separator: " ") }
    public var finalizedWordCount: Int {
        phrases.prefix(while: { $0.isFinal }).reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }
    public var partial: PartialTranscript {
        PartialTranscript(text: text, isUtteranceBoundary: phrases.last?.isFinal == true,
                          revision: revision, phrases: phrases)
    }
}

/// Complete current session text, plus Apple's original range/finalization evidence.
public struct PartialTranscript: Equatable, Sendable {
    public let text: String
    public let isUtteranceBoundary: Bool
    public let revision: UInt64?
    public let phrases: [SpeechPhrase]
    public var finalizedText: String { phrases.filter(\.isFinal).map(\.text).joined(separator: " ") }
    public var finalizedWordCount: Int {
        phrases.prefix(while: { $0.isFinal }).reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }
    }
    public init(text: String, isUtteranceBoundary: Bool = false, revision: UInt64? = nil, phrases: [SpeechPhrase] = []) {
        self.text = text; self.isUtteranceBoundary = isUtteranceBoundary
        self.revision = revision; self.phrases = phrases
    }
}

/// Produced only after the analyzer authoritatively finalizes through end of input.
public struct FinalTranscript: Equatable, Sendable {
    public enum Source: String, Equatable, Sendable { case streaming }
    public let text: String
    public let confidence: Float?
    public let source: Source
    public let phrases: [SpeechPhrase]
    public init(text: String, confidence: Float? = nil, source: Source = .streaming, phrases: [SpeechPhrase] = []) {
        self.text = text; self.confidence = confidence; self.source = source; self.phrases = phrases
    }
}

public enum TranscriptionEvent: Equatable, Sendable {
    case partial(PartialTranscript)
    case final(FinalTranscript)
    case failed(String)
    case cancelled
}
public struct TranscriptState: Equatable, Sendable {
    public private(set) var partial: PartialTranscript?
    public private(set) var final: FinalTranscript?
    public private(set) var failure: String?
    public private(set) var isCancelled = false
    public init() {}
    @discardableResult public mutating func apply(_ event: TranscriptionEvent) -> Bool {
        guard final == nil, !isCancelled, failure == nil else { return false }
        switch event {
        case .partial(let next):
            guard partial != next else { return false }; partial = next
        case .final(let result): final = result; partial = nil
        case .failed(let message): failure = message; partial = nil
        case .cancelled: isCancelled = true; partial = nil
        }
        return true
    }
}
