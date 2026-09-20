import Foundation
import Combine

/// A UserDefaults-backed settings store shared by every LocalFlow module.
public final class LocalFlowSettings: ObservableObject, @unchecked Sendable {
    /// The single shared settings instance used by production code.
    public static let shared = LocalFlowSettings()

    private let defaults: UserDefaults

    /// Explicit opt-in: turn dictation into an AI prompt instead of ordinary text.
    public var promptModeEnabled: Bool {
        get { defaults.bool(forKey: "promptModeEnabled") }
        set { objectWillChange.send(); defaults.set(newValue, forKey: "promptModeEnabled") }
    }

    /// Optional on-device semantic rewriting for Option+1. No cloud fallback.
    public var localRewriteEnabled: Bool {
        // Deep polish should work out of the box on a supported Mac. An explicit user
        // choice to turn it off remains respected.
        get { defaults.object(forKey: Keys.localRewriteEnabled) as? Bool ?? true }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Keys.localRewriteEnabled) }
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

    /// User overrides from bundle identifier to formatting profile.
    public var formattingProfileOverrides: [String: SmartFormattingProfile] {
        get { codableValue(forKey: Keys.formattingProfileOverrides, defaultValue: [:]) }
        set { setCodableValue(newValue, forKey: Keys.formattingProfileOverrides) }
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
        set { defaults.set(newValue, forKey: Keys.smartPolishShortcutEnabled) }
    }

    /// Whether native Apple Intelligence Writing Tools integration is enabled.
    public var appleIntelligenceIntegrationEnabled: Bool {
        get { defaults.object(forKey: Keys.appleIntelligenceIntegrationEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.appleIntelligenceIntegrationEnabled) }
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
            Keys.formattingProfileOverrides: encodedDefault([String: SmartFormattingProfile]()),
            Keys.customVocabulary: encodedDefault([VocabularyEntry]()),
            Keys.cleanSpeechEnabled: true,
            Keys.removeFillerWords: true,
            Keys.collapseRepeatedWords: true,
            Keys.handleSelfCorrections: true,
            Keys.smartFormattingEnabled: true,
            Keys.smartFormattingAutocorrect: true,
            Keys.smartFormattingSmartPunctuation: true,
            Keys.smartPolishShortcutEnabled: true,
            Keys.localRewriteEnabled: true,
            Keys.appleIntelligenceIntegrationEnabled: true
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
        static let formattingProfileOverrides = "formattingProfileOverrides"
        static let customVocabulary = "customVocabulary"
        static let cleanSpeechEnabled = "cleanSpeechEnabled"
        static let removeFillerWords = "removeFillerWords"
        static let collapseRepeatedWords = "collapseRepeatedWords"
        static let handleSelfCorrections = "handleSelfCorrections"
        static let smartFormattingEnabled = "smartFormattingEnabled"
        static let smartFormattingAutocorrect = "smartFormattingAutocorrect"
        static let smartFormattingSmartPunctuation = "smartFormattingSmartPunctuation"
        static let smartPolishShortcutEnabled = "smartPolishShortcutEnabled"
        static let localRewriteEnabled = "localRewriteEnabled"
        static let appleIntelligenceIntegrationEnabled = "appleIntelligenceIntegrationEnabled"
    }
}
