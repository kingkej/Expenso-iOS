import Foundation
import Observation
import Security

/// The secret is device-only and never stored in defaults, backups, or observable UI state.
@MainActor
protocol OpenRouterKeyStore {
    func read() throws -> String?
    func save(_ value: String) throws
    func delete() throws
}

struct OpenRouterKeychain: OpenRouterKeyStore {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "Expenso") + ".openrouter",
         kSecAttrAccount as String: "api-key",
         kSecAttrSynchronizable as String: false]
    }

    func read() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { throw OpenRouterSettingsError.keychain }
        return value
    }

    func save(_ value: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw OpenRouterSettingsError.keychain }
        } else if status != errSecSuccess { throw OpenRouterSettingsError.keychain }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw OpenRouterSettingsError.keychain }
    }
}

enum OpenRouterSettingsError: LocalizedError {
    case keychain, invalidKey, invalidModel, consentRequired, missingKey
    var errorDescription: String? {
        switch self {
        case .keychain: return "The API key couldn't be accessed securely. Unlock your device and try again."
        case .invalidKey: return "Enter an OpenRouter key without spaces or line breaks."
        case .invalidModel: return "Choose a valid OpenRouter model."
        case .consentRequired: return "Allow OpenRouter processing in Settings → AI → AI Provider before using remote chat or image import."
        case .missingKey: return "Add your OpenRouter API key in Settings → AI → AI Provider."
        }
    }
}

@MainActor @Observable
final class OpenRouterSettings {
    enum Provider: String, Codable, CaseIterable, Identifiable {
        case onDevice, openRouter
        var id: String { rawValue }
        var title: String { self == .onDevice ? "Apple Intelligence" : "OpenRouter" }
    }
    static let shared = OpenRouterSettings()
    private(set) var hasKey = false
    private(set) var modelID: String
    private(set) var allowsRemoteData: Bool
    private(set) var allowsLedgerExploration: Bool
    private(set) var provider: Provider
    /// Any credentials, model or privacy change invalidates in-flight answers.
    private(set) var revision = UUID()
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keychain: any OpenRouterKeyStore
    static let modelKey = "chat.openrouter.model"
    static let consentKey = "chat.openrouter.consent"
    static let explorationConsentKey = "chat.openrouter.explorationConsent"
    static let explorationConsentVersion = 2
    static let providerKey = "chat.provider"

    init(defaults: UserDefaults = .standard, keychain: (any OpenRouterKeyStore)? = nil) {
        self.defaults = defaults
        self.keychain = keychain ?? OpenRouterKeychain()
        modelID = defaults.string(forKey: Self.modelKey) ?? OpenRouterClient.defaultModelID
        allowsRemoteData = defaults.bool(forKey: Self.consentKey)
        allowsLedgerExploration = defaults.integer(forKey: Self.explorationConsentKey) >= Self.explorationConsentVersion
            && defaults.bool(forKey: Self.consentKey)
        provider = Provider(rawValue: defaults.string(forKey: Self.providerKey) ?? "") ?? .onDevice
        refreshKeyStatus()
    }

    func refreshKeyStatus() { hasKey = !((try? keychain.read()) ?? "").isEmpty }

    func credentials() throws -> String {
        guard provider == .openRouter, allowsRemoteData else { throw OpenRouterSettingsError.consentRequired }
        guard let key = try keychain.read(), !key.isEmpty else { throw OpenRouterSettingsError.missingKey }
        return key
    }

    /// Classification has its own explicit opt-in, independent of the Chat provider.
    /// Only the classification coordinator may call this after checking that opt-in.
    func classificationCredentials() throws -> String {
        guard let key = try keychain.read(), !key.isEmpty else { throw OpenRouterSettingsError.missingKey }
        return key
    }

    func save(key: String, model: String, consent: Bool, provider: Provider) throws {
        // Saving credentials is not authorization to upload. credentials() still
        // requires explicit consent before chat or image import can use them.
        guard !model.isEmpty, model.utf8.count <= 256, !model.contains(where: \.isWhitespace) else { throw OpenRouterSettingsError.invalidModel }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            guard trimmed.hasPrefix("sk-or-"), trimmed.utf8.count <= 512,
                  !trimmed.contains(where: { $0.isWhitespace || $0.isNewline }) else { throw OpenRouterSettingsError.invalidKey }
            try keychain.save(trimmed)
        } else if provider == .openRouter && !hasKey { throw OpenRouterSettingsError.missingKey }
        modelID = model
        allowsRemoteData = consent
        allowsLedgerExploration = consent
        self.provider = provider
        defaults.set(model, forKey: Self.modelKey)
        defaults.set(consent, forKey: Self.consentKey)
        defaults.set(consent ? Self.explorationConsentVersion : 0, forKey: Self.explorationConsentKey)
        defaults.set(provider.rawValue, forKey: Self.providerKey)
        refreshKeyStatus()
        revision = UUID()
    }

    func disable(removeKey: Bool) throws {
        if removeKey { try keychain.delete() }
        allowsRemoteData = false
        allowsLedgerExploration = false
        provider = .onDevice
        defaults.set(false, forKey: Self.consentKey)
        defaults.set(false, forKey: Self.explorationConsentKey)
        defaults.set(provider.rawValue, forKey: Self.providerKey)
        refreshKeyStatus()
        revision = UUID()
    }
}
