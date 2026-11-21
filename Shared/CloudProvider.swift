import Foundation
import Security

public enum DictationSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case apple, local, cloud
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .apple: "Apple Speech"
        case .local: "Local models"
        case .cloud: "Your API key"
        }
    }
}

public enum CloudProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case groq, openAI, claude, gemini
    public var id: String { rawValue }
    public var displayName: String {
        switch self {
        case .groq: "Groq"
        case .openAI: "OpenAI"
        case .claude: "Claude"
        case .gemini: "Gemini"
        }
    }
    public static var transcriptionProviders: [Self] { [.groq, .openAI, .gemini] }
    public var speechModel: String {
        switch self {
        case .groq: "whisper-large-v3-turbo"
        case .openAI: "gpt-transcribe"
        case .gemini: "gemini-3.5-flash-lite"
        case .claude: ""
        }
    }
    public var polishModel: String {
        switch self {
        case .groq: "llama-3.3-70b-versatile"
        case .openAI: "gpt-4.1-mini"
        case .claude: "claude-haiku-5-5"
        case .gemini: "gemini-3.5-flash-lite"
        }
    }
    public var keyURL: URL {
        switch self {
        case .groq: URL(string: "https://console.groq.com/keys")!
        case .openAI: URL(string: "https://platform.openai.com/api-keys")!
        case .claude: URL(string: "https://platform.claude.com/settings/keys")!
        case .gemini: URL(string: "https://aistudio.google.com/apikey")!
        }
    }
}

/// Keys remain in this Mac's Keychain, never in preferences or exported settings.
public struct ProviderKeyStore: Sendable {
    private let service: String
    public init(service: String = "dev.localflow.provider-keys") { self.service = service }

    private func query(_ provider: CloudProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: provider.rawValue]
    }
    public func read(_ provider: CloudProvider) throws -> String? {
        var request = query(provider)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8) else { throw keychainError(status) }
        return key
    }
    public func save(_ key: String, for provider: CloudProvider) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, key.utf8.count <= 4096,
              !key.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else {
            throw LocalFlowError.providerFailed("Enter a valid API key without spaces.")
        }
        let values = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(query(provider) as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(provider).merging(values) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw keychainError(added) }
        } else if status != errSecSuccess { throw keychainError(status) }
    }
    public func delete(_ provider: CloudProvider) throws {
        let status = SecItemDelete(query(provider) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw keychainError(status) }
    }
    private func keychainError(_ status: OSStatus) -> LocalFlowError {
        .providerFailed("Keychain could not access the API key (\(status)). Unlock your login keychain and try again.")
    }
}
