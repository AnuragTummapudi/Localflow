@preconcurrency import AVFoundation
import Foundation

/// A supported transcription engine family.
public enum EngineKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case appleSpeech
    case parakeet
    case whisper

    /// The stable identifier for UI lists and persistence.
    public var id: String { rawValue }

    /// A user-facing engine name for display in Settings.
    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .appleSpeech: "Apple Speech"
        case .parakeet: "Parakeet"
        case .whisper: "Whisper"
        }
    }
}

/// A model tier LocalFlow can download and load.
public enum ModelTier: String, Codable, CaseIterable, Identifiable, Sendable {
    case automatic
    case parakeetTDT
    case whisperLargeV3Turbo

    /// The stable identifier for UI lists and persistence.
    public var id: String { rawValue }

    /// A human-readable model name.
    public var displayName: String {
        switch self {
        case .automatic: "Automatic"
        case .parakeetTDT: "Parakeet TDT"
        case .whisperLargeV3Turbo: "Whisper Large v3 Turbo"
        }
    }
}

/// Captured speech audio preserved in the native audio form expected by engine SDKs.
public struct CapturedAudio: @unchecked Sendable {
    /// The original captured PCM buffer, when capture came from AVAudioEngine.
    public let buffer: AVAudioPCMBuffer?

    /// Mono floating-point samples captured from the first input channel.
    public let samples: [Float]

    /// The sample rate associated with `samples`.
    public let sampleRate: Double

    /// Creates captured audio metadata.
    public init(buffer: AVAudioPCMBuffer?, samples: [Float], sampleRate: Double) {
        self.buffer = buffer
        self.samples = samples
        self.sampleRate = sampleRate
    }

    /// Returns true when no usable audio samples were captured.
    public var isEmpty: Bool {
        samples.isEmpty || samples.allSatisfy { abs($0) < .ulpOfOne }
    }

    /// Returns true when meaningful audio energy was detected (not silence or low-level background noise).
    public var hasMeaningfulAudio: Bool {
        guard !isEmpty else { return false }
        var sumSquares: Float = 0
        var peak: Float = 0
        let strideBy = max(1, samples.count / 12_000)
        var count = 0
        for i in stride(from: 0, to: samples.count, by: strideBy) {
            let val = abs(samples[i])
            if val > peak { peak = val }
            sumSquares += val * val
            count += 1
        }
        guard count > 0 else { return false }
        let rms = sqrt(sumSquares / Float(count))
        return peak >= 0.015 || rms >= 0.003
    }

    /// A legacy byte representation of the captured float samples.
    public var rawFloatData: Data {
        var mutable = samples
        return Data(bytes: &mutable, count: mutable.count * MemoryLayout<Float>.size)
    }
}

/// A persisted description of a global hotkey.
public struct HotkeyDescriptor: Codable, Equatable, Sendable {
    /// The key code or virtual modifier-code associated with the trigger.
    public var keyCode: Int

    /// Modifier flags required for the trigger.
    public var modifiers: Int

    /// Whether this descriptor represents an Fn-key trigger.
    public var isFunctionKey: Bool

    /// A display name suitable for settings UI.
    public var displayName: String

    /// Creates a hotkey descriptor.
    public init(keyCode: Int, modifiers: Int, isFunctionKey: Bool, displayName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isFunctionKey = isFunctionKey
        self.displayName = displayName
    }

    /// The shipped safe default: hold Right Option.
    public static let rightOption = HotkeyDescriptor(keyCode: 61, modifiers: 0, isFunctionKey: false, displayName: "Right Option")

    /// The opt-in alternate Fn trigger.
    public static let functionKey = HotkeyDescriptor(keyCode: 63, modifiers: 0, isFunctionKey: true, displayName: "Fn")
}

/// A SmartFormatting profile applied before text injection.
public enum SmartFormattingProfile: String, Codable, CaseIterable, Identifiable, Sendable {
    case generic
    case chat
    case mail
    case code
    case prompt
    case notes

    /// The stable identifier for UI lists and persistence.
    public var id: String { rawValue }

    /// A user-facing profile name.
    public var displayName: String {
        switch self {
        case .generic: "Generic"
        case .chat: "Chat"
        case .mail: "Mail"
        case .code: "Code"
        case .prompt: "AI Prompt"
        case .notes: "Notes"
        }
    }
}

/// A local vocabulary correction, custom word, or shortcut rule.
public struct VocabularyEntry: Codable, Equatable, Identifiable, Sendable {
    /// The stable identifier for this entry.
    public var id: UUID

    /// The word, name, or shortcut trigger phrase.
    public var phrase: String

    /// The replacement phrase (empty if this is a custom word/name to preserve).
    public var replacement: String

    /// Whether this entry is favorited / priority boosted.
    public var isFavorite: Bool

    /// Whether this entry uses smart phonetic recognition (✨).
    public var hasSparkle: Bool

    /// True if this entry expands or replaces a shortcut into another text.
    public var isShortcut: Bool {
        let trimmedPhrase = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedReplacement = replacement.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedReplacement.isEmpty && trimmedPhrase.lowercased() != trimmedReplacement.lowercased()
    }

    /// The display text formatted for lists (e.g. "btw -> by the way" or "Anurag Tummapudi").
    public var displayText: String {
        if isShortcut {
            return "\(phrase) -> \(replacement)"
        }
        return phrase
    }

    /// Creates a vocabulary entry.
    public init(
        id: UUID = UUID(),
        phrase: String,
        replacement: String = "",
        isFavorite: Bool = false,
        hasSparkle: Bool = false
    ) {
        self.id = id
        self.phrase = phrase
        self.replacement = replacement
        self.isFavorite = isFavorite
        self.hasSparkle = hasSparkle
    }

    public enum CodingKeys: String, CodingKey {
        case id, phrase, replacement, isFavorite, hasSparkle
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        phrase = try container.decode(String.self, forKey: .phrase)
        replacement = try container.decodeIfPresent(String.self, forKey: .replacement) ?? ""
        isFavorite = try container.decodeIfPresent(Bool.self, forKey: .isFavorite) ?? false
        hasSparkle = try container.decodeIfPresent(Bool.self, forKey: .hasSparkle) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(phrase, forKey: .phrase)
        try container.encode(replacement, forKey: .replacement)
        try container.encode(isFavorite, forKey: .isFavorite)
        try container.encode(hasSparkle, forKey: .hasSparkle)
    }
}

/// A single locally stored transcription history item.
public struct DictationHistoryItem: Codable, Equatable, Identifiable, Sendable {
    /// The stable identifier for this history item.
    public var id: UUID

    /// The date the transcription was produced.
    public var createdAt: Date

    /// The raw transcription text before injection.
    public var text: String

    /// The frontmost application bundle identifier, if known.
    public var bundleIdentifier: String?

    /// Creates a history item.
    public init(id: UUID = UUID(), createdAt: Date = Date(), text: String, bundleIdentifier: String?) {
        self.id = id
        self.createdAt = createdAt
        self.text = text
        self.bundleIdentifier = bundleIdentifier
    }
}

/// Runtime status for the menu bar icon and overlay.
public enum LocalFlowActivityState: String, Codable, Sendable {
    case idle
    case listening
    case processing
    case error
}

/// The mode of an active dictation session.
public enum DictationSessionMode: String, Codable, Sendable {
    /// Traditional push-to-talk: user holds the hotkey and releases when done speaking.
    case pushToTalk
    /// Hands-free mode: user double-taps to lock recording, then taps again or presses Escape when done.
    case handsFree
}

/// A typed LocalFlow error suitable for user-visible recovery.
public enum LocalFlowError: Error, LocalizedError, Equatable {
    case microphonePermissionDenied
    case accessibilityPermissionMissing
    case networkBlocked
    case modelUnavailable(String)
    case transcriptionFailed(String)
    case textInjectionFailed
    case audioCaptureFailed(String)

    /// A localized error description.
    public var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied: "Microphone permission is required to capture dictation."
        case .accessibilityPermissionMissing: "Accessibility permission is required to insert text into other apps."
        case .networkBlocked: "Network access is blocked by privacy settings."
        case .modelUnavailable(let detail): "The speech model is unavailable: \(detail)"
        case .transcriptionFailed(let detail): "Transcription failed: \(detail)"
        case .textInjectionFailed: "LocalFlow could not insert text into the focused field."
        case .audioCaptureFailed(let detail): "Audio capture failed: \(detail)"
        }
    }
}
