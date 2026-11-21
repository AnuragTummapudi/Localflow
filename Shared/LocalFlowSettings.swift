import Foundation
import Combine

/// A UserDefaults-backed settings store shared by every LocalFlow module.
public final class LocalFlowSettings: ObservableObject, @unchecked Sendable {
    /// The single shared settings instance used by production code.
    public static let shared = LocalFlowSettings()

    private let defaults: UserDefaults

    public var dictationSource: DictationSource {
        get {
            if let raw = defaults.string(forKey: "dictationSource"), let value = DictationSource(rawValue: raw) { return value }
            return modelOverride != nil && modelOverride != .automatic ? .local : .apple
        }
        set { objectWillChange.send(); defaults.set(newValue.rawValue, forKey: "dictationSource") }
    }

    public var transcriptionProvider: CloudProvider {
        get { CloudProvider(rawValue: defaults.string(forKey: "transcriptionProvider") ?? "") ?? .groq }
        set { objectWillChange.send(); defaults.set(newValue.rawValue, forKey: "transcriptionProvider") }
    }

    /// Provider model IDs change often, so users can override the built-in defaults.
    public func speechModel(for provider: CloudProvider) -> String {
        modelID(defaults.string(forKey: "speechModel.\(provider.rawValue)")) ?? provider.speechModel
    }
    public func setSpeechModel(_ id: String, for provider: CloudProvider) {
        objectWillChange.send(); defaults.set(modelID(id), forKey: "speechModel.\(provider.rawValue)")
    }
    public func polishModel(for provider: CloudProvider) -> String {
        modelID(defaults.string(forKey: "polishModel.\(provider.rawValue)")) ?? provider.polishModel
    }
    public func setPolishModel(_ id: String, for provider: CloudProvider) {
        objectWillChange.send(); defaults.set(modelID(id), forKey: "polishModel.\(provider.rawValue)")
    }
    /// Model IDs go into a URL path (Gemini), so only allow the characters providers use.
    private func modelID(_ raw: String?) -> String? {
        guard let id = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty, id.count <= 128,
              id.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "-._:/".unicodeScalars.contains($0) }),
              !id.contains("..") else { return nil }
        return id
    }

    /// Nil keeps Smart Polish on this Mac.
    public var polishProvider: CloudProvider? {
        get { defaults.string(forKey: "polishProvider").flatMap(CloudProvider.init(rawValue:)) }
        set { objectWillChange.send(); defaults.set(newValue?.rawValue, forKey: "polishProvider") }
    }

    /// Optional on-device semantic rewriting for Option+1. No cloud fallback.
    public var localRewriteEnabled: Bool {
        // Deep polish should work out of the box on a supported Mac. An explicit user
        // choice to turn it off remains respected.
        get { defaults.object(forKey: Keys.localRewriteEnabled) as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Keys.localRewriteEnabled) }
    }

    /// Saved tone used by the explicit Option + 1 Smart Polish action.
    public var smartPolishTone: String {
        get { defaults.string(forKey: Keys.smartPolishTone) ?? "natural" }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Keys.smartPolishTone) }
    }

    /// Creates a settings store backed by the supplied defaults suite.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        registerDefaults()
    }

    /// The selected global hotkey descriptor.
    public var hotkey: HotkeyDescriptor {
        get { codableValue(forKey: Keys.hotkey, defaultValue: .rightOption) }
        set { setCodableValue(newValue, forKey: Keys.hotkey) }
    }

    /// Whether the unreliable Fn trigger is offered as the active hotkey.
    public var useFnAsAlternateHotkey: Bool {
        get { defaults.bool(forKey: Keys.useFnAsAlternateHotkey) }
        set {
            guard newValue != defaults.bool(forKey: Keys.useFnAsAlternateHotkey) else { return }
            objectWillChange.send()
            defaults.set(newValue, forKey: Keys.useFnAsAlternateHotkey)
        }
    }

    /// Whether advanced engine and model settings are visible.
    public var showAdvancedOptions: Bool {
        get { defaults.bool(forKey: Keys.showAdvancedOptions) }
        set { defaults.set(newValue, forKey: Keys.showAdvancedOptions) }
    }

    /// An optional model override for advanced users.
    public var modelOverride: ModelTier? {
        get { optionalCodableValue(forKey: Keys.modelOverride) }
        set { setOptionalCodableValue(newValue, forKey: Keys.modelOverride) }
    }

    /// Whether all network access should be blocked after required models are present.
    public var hardBlockNetworkAfterModelsDownloaded: Bool {
        get { defaults.bool(forKey: Keys.hardBlockNetworkAfterModelsDownloaded) }
        set { defaults.set(newValue, forKey: Keys.hardBlockNetworkAfterModelsDownloaded) }
    }

    /// Whether LocalFlow should launch when the user logs in.
    public var launchAtLogin: Bool {
        get { defaults.bool(forKey: Keys.launchAtLogin) }
        set { defaults.set(newValue, forKey: Keys.launchAtLogin) }
    }

    /// Whether first-run onboarding has completed.
    public var didCompleteOnboarding: Bool {
        get { defaults.bool(forKey: Keys.didCompleteOnboarding) }
        set { defaults.set(newValue, forKey: Keys.didCompleteOnboarding) }
    }

    /// Whether the launch logo animation has already played.
    public var didPlayLaunchAnimation: Bool {
        get { defaults.bool(forKey: Keys.didPlayLaunchAnimation) }
        set { defaults.set(newValue, forKey: Keys.didPlayLaunchAnimation) }
    }

    /// User-added words and phrases used during local post-processing.
    public var customVocabulary: [VocabularyEntry] {
        get { codableValue(forKey: Keys.customVocabulary, defaultValue: []) }
        set { setCodableValue(newValue, forKey: Keys.customVocabulary) }
    }

    /// Whether deterministic speech cleanup pass is active.
    public var cleanSpeechEnabled: Bool {
        get { defaults.object(forKey: Keys.cleanSpeechEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.cleanSpeechEnabled) }
    }

    /// Whether filler words (um, uh, etc.) should be removed.
    public var removeFillerWords: Bool {
        get { defaults.object(forKey: Keys.removeFillerWords) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.removeFillerWords) }
    }

    /// Whether repeated words (the the) should be collapsed.
    public var collapseRepeatedWords: Bool {
        get { defaults.object(forKey: Keys.collapseRepeatedWords) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.collapseRepeatedWords) }
    }

    /// Whether explicit self-correction triggers ("no wait", "scratch that") should be handled.
    public var handleSelfCorrections: Bool {
        get { defaults.object(forKey: Keys.handleSelfCorrections) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.handleSelfCorrections) }
    }

    /// Whether smart formatting is enabled.
    public var smartFormattingEnabled: Bool {
        get { defaults.object(forKey: Keys.smartFormattingEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.smartFormattingEnabled) }
    }

    /// Whether spelling and typo autocorrection (via NSSpellChecker) is enabled.
    public var smartFormattingAutocorrect: Bool {
        get { defaults.object(forKey: Keys.smartFormattingAutocorrect) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.smartFormattingAutocorrect) }
    }

    /// Whether smart punctuation (curly quotes, em dashes, question marks) is enabled.
    public var smartFormattingSmartPunctuation: Bool {
        get { defaults.object(forKey: Keys.smartFormattingSmartPunctuation) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.smartFormattingSmartPunctuation) }
    }

    /// Whether the Option+1 Smart Polish shortcut is enabled.
    public var smartPolishShortcutEnabled: Bool {
        get { defaults.object(forKey: Keys.smartPolishShortcutEnabled) as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Keys.smartPolishShortcutEnabled) }
    }

    private func registerDefaults() {
        defaults.register(defaults: [
            Keys.hotkey: encodedDefault(HotkeyDescriptor.rightOption),
            Keys.useFnAsAlternateHotkey: false,
            Keys.showAdvancedOptions: false,
            Keys.hardBlockNetworkAfterModelsDownloaded: false,
            Keys.launchAtLogin: false,
            Keys.didCompleteOnboarding: false,
            Keys.didPlayLaunchAnimation: false,
            Keys.customVocabulary: encodedDefault([VocabularyEntry]()),
            Keys.cleanSpeechEnabled: true,
            Keys.removeFillerWords: true,
            Keys.collapseRepeatedWords: true,
            Keys.handleSelfCorrections: true,
            Keys.smartFormattingEnabled: true,
            Keys.smartFormattingAutocorrect: true,
            Keys.smartFormattingSmartPunctuation: true,
            Keys.smartPolishShortcutEnabled: true,
            Keys.smartPolishTone: "natural",
            Keys.localRewriteEnabled: true,
        ])
    }

    private func codableValue<T: Codable>(forKey key: String, defaultValue: T) -> T {
        guard let data = defaults.data(forKey: key) else { return defaultValue }
        return (try? JSONDecoder().decode(T.self, from: data)) ?? defaultValue
    }

    private func optionalCodableValue<T: Codable>(forKey key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func setCodableValue<T: Codable>(_ value: T, forKey key: String) {
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private func setOptionalCodableValue<T: Codable>(_ value: T?, forKey key: String) {
        guard let value else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(try? JSONEncoder().encode(value), forKey: key)
    }

    private func encodedDefault<T: Codable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }

    private enum Keys {
        static let hotkey = "hotkey"
        static let useFnAsAlternateHotkey = "useFnAsAlternateHotkey"
        static let showAdvancedOptions = "showAdvancedOptions"
        static let modelOverride = "modelOverride"
        static let hardBlockNetworkAfterModelsDownloaded = "hardBlockNetworkAfterModelsDownloaded"
        static let launchAtLogin = "launchAtLogin"
        static let didCompleteOnboarding = "didCompleteOnboarding"
        static let didPlayLaunchAnimation = "didPlayLaunchAnimation"
        static let customVocabulary = "customVocabulary"
        static let cleanSpeechEnabled = "cleanSpeechEnabled"
        static let removeFillerWords = "removeFillerWords"
        static let collapseRepeatedWords = "collapseRepeatedWords"
        static let handleSelfCorrections = "handleSelfCorrections"
        static let smartFormattingEnabled = "smartFormattingEnabled"
        static let smartFormattingAutocorrect = "smartFormattingAutocorrect"
        static let smartFormattingSmartPunctuation = "smartFormattingSmartPunctuation"
        static let smartPolishShortcutEnabled = "smartPolishShortcutEnabled"
        static let smartPolishTone = "smartPolishTone"
        static let localRewriteEnabled = "localRewriteEnabled"
    }
}
