import Foundation
import Observation

enum InferenceProviderKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case openAI
    case customOpenAICompatible

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openAI:
            "OpenAI"
        case .customOpenAICompatible:
            "Custom OpenAI-compatible"
        }
    }

    var requiresCredential: Bool {
        self == .openAI
    }

    var defaultBaseURL: String? {
        switch self {
        case .openAI:
            "https://api.openai.com"
        case .customOpenAICompatible:
            nil
        }
    }
}

enum InferenceAPIMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case responses
    case chatCompletions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic:
            "Automatic"
        case .responses:
            "Responses API"
        case .chatCompletions:
            "Chat Completions"
        }
    }
}

enum InferenceCredentialState: Equatable, Sendable {
    case missing
    case sessionOnly
    case stored
}

enum InferenceConfigurationIssue: Equatable, Sendable {
    case missingKey
    case missingEndpoint
    case missingModel

    var message: String {
        switch self {
        case .missingKey:
            "No inference key configured."
        case .missingEndpoint:
            "No inference endpoint configured."
        case .missingModel:
            "No inference model configured."
        }
    }
}

struct InferenceConfiguration: Equatable, Sendable {
    var provider: InferenceProviderKind
    var baseURL: String
    var modelID: String
    var apiMode: InferenceAPIMode

    var trimmedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedModelID: String {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@MainActor
@Observable
final class InferenceSettings {
    private enum Keys {
        static let provider = "ai.provider"
        static let customEndpoint = "ai.customEndpoint"
        static let modelID = "ai.modelID"
        static let apiMode = "ai.apiMode"
    }

    var provider: InferenceProviderKind {
        didSet {
            defaults.set(provider.rawValue, forKey: Keys.provider)
            loadStoredKeyIfNeeded(for: provider)
        }
    }
    var customEndpoint: String {
        didSet { defaults.set(customEndpoint, forKey: Keys.customEndpoint) }
    }
    var modelID: String {
        didSet { defaults.set(modelID, forKey: Keys.modelID) }
    }
    var apiMode: InferenceAPIMode {
        didSet { defaults.set(apiMode.rawValue, forKey: Keys.apiMode) }
    }
    var discoveredModels: [String] = []
    var statusMessage = ""
    var isWorking = false

    private(set) var credentialPersistenceAvailability:
        CredentialPersistenceAvailability
    private(set) var credentialStoreError: String?

    private let defaults: UserDefaults
    private let keychain: any KeychainStoring
    private var storedKeys: [InferenceProviderKind: String] = [:]
    private var sessionKeys: [InferenceProviderKind: String] = [:]
    private var loadedProviders: Set<InferenceProviderKind> = []

    init(
        defaults: UserDefaults = .standard,
        keychain: any KeychainStoring = KeychainStore()
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.credentialPersistenceAvailability =
            keychain.persistenceAvailability
        self.provider = InferenceProviderKind(
            rawValue: defaults.string(forKey: Keys.provider) ?? ""
        ) ?? .openAI
        self.customEndpoint = defaults.string(forKey: Keys.customEndpoint) ?? ""
        self.modelID = defaults.string(forKey: Keys.modelID) ?? ""
        self.apiMode = InferenceAPIMode(
            rawValue: defaults.string(forKey: Keys.apiMode) ?? ""
        ) ?? .automatic
        loadStoredKeyIfNeeded(for: provider)
    }

    var configuration: InferenceConfiguration {
        InferenceConfiguration(
            provider: provider,
            baseURL: provider.defaultBaseURL ?? customEndpoint,
            modelID: modelID,
            apiMode: apiMode
        )
    }

    var credentialState: InferenceCredentialState {
        credentialState(for: provider)
    }

    func credentialState(
        for provider: InferenceProviderKind
    ) -> InferenceCredentialState {
        loadStoredKeyIfNeeded(for: provider)
        if !(sessionKeys[provider] ?? "").isEmpty {
            return .sessionOnly
        }
        if !(storedKeys[provider] ?? "").isEmpty {
            return .stored
        }
        return .missing
    }

    func existingKey(
        for provider: InferenceProviderKind? = nil
    ) -> String {
        let selectedProvider = provider ?? self.provider
        loadStoredKeyIfNeeded(for: selectedProvider)
        let session = sessionKeys[selectedProvider] ?? ""
        return session.isEmpty
            ? storedKeys[selectedProvider] ?? ""
            : session
    }

    var hasStoredKey: Bool {
        loadStoredKeyIfNeeded(for: provider)
        return !(storedKeys[provider] ?? "").isEmpty
    }

    var hasSessionKey: Bool {
        !(sessionKeys[provider] ?? "").isEmpty
    }

    var configurationIssue: InferenceConfigurationIssue? {
        if provider.requiresCredential, existingKey().isEmpty {
            return .missingKey
        }
        let configuration = configuration
        if configuration.trimmedBaseURL.isEmpty {
            return .missingEndpoint
        }
        if configuration.trimmedModelID.isEmpty {
            return .missingModel
        }
        return nil
    }

    var isConfigured: Bool {
        configurationIssue == nil
    }

    func useKeyForSession(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        sessionKeys[provider] = trimmed.isEmpty ? nil : trimmed
        credentialStoreError = nil
    }

    func clearSessionKey() {
        sessionKeys[provider] = nil
    }

    func savePersistentKey(_ key: String) throws {
        guard credentialPersistenceAvailability == .persistent else {
            throw KeychainError.installedSignedAppRequired
        }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try keychain.delete(account: provider.rawValue)
            storedKeys[provider] = nil
        } else {
            try keychain.save(trimmed, account: provider.rawValue)
            storedKeys[provider] = trimmed
        }
        sessionKeys[provider] = nil
        loadedProviders.insert(provider)
        credentialStoreError = nil
    }

    /// Compatibility entry point. Development and relocated builds retain the
    /// key for this process only; the installed signed app stores it in Keychain.
    func saveKey(_ key: String) throws {
        if credentialPersistenceAvailability == .persistent {
            try savePersistentKey(key)
        } else {
            useKeyForSession(key)
        }
    }

    func removeKey() throws {
        if credentialPersistenceAvailability == .persistent {
            try keychain.delete(account: provider.rawValue)
        }
        storedKeys[provider] = nil
        sessionKeys[provider] = nil
        loadedProviders.insert(provider)
        credentialStoreError = nil
    }

    /// A newly typed key wins over the session key, which wins over the stored
    /// key. This lets Settings and onboarding test credentials without saving.
    func keyForRequest(typedKey: String) -> String {
        let trimmed = typedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? existingKey() : trimmed
    }

    private func loadStoredKeyIfNeeded(
        for provider: InferenceProviderKind
    ) {
        guard loadedProviders.insert(provider).inserted else { return }
        guard credentialPersistenceAvailability == .persistent else { return }
        do {
            storedKeys[provider] =
                (try keychain.read(account: provider.rawValue)) ?? ""
        } catch {
            storedKeys[provider] = nil
            credentialStoreError = error.localizedDescription
            credentialPersistenceAvailability = .sessionOnly
        }
    }
}
