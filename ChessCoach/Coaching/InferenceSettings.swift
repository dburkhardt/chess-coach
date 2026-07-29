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

/// A value-only view of credential availability that is safe for SwiftUI to
/// observe. It deliberately contains no credential material.
struct InferenceCredentialSnapshot: Equatable, Sendable {
    let provider: InferenceProviderKind
    let state: InferenceCredentialState
    let hasStoredKey: Bool
    let hasSessionKey: Bool
    let persistenceAvailability: CredentialPersistenceAvailability
    let storeError: String?
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
            loadStoredKey(for: provider)
            refreshCredentialSnapshot()
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

    private(set) var credentialSnapshot: InferenceCredentialSnapshot

    @ObservationIgnored
    private let defaults: UserDefaults
    @ObservationIgnored
    private let keychain: any KeychainStoring
    @ObservationIgnored
    private var persistenceAvailability: CredentialPersistenceAvailability
    @ObservationIgnored
    private var storeError: String?
    @ObservationIgnored
    private var storedKeys: [InferenceProviderKind: String] = [:]
    @ObservationIgnored
    private var sessionKeys: [InferenceProviderKind: String] = [:]
    @ObservationIgnored
    private var loadedProviders: Set<InferenceProviderKind> = []

    init(
        defaults: UserDefaults = .standard,
        keychain: any KeychainStoring = KeychainStore()
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.persistenceAvailability = keychain.persistenceAvailability
        self.storeError = nil
        let selectedProvider = InferenceProviderKind(
            rawValue: defaults.string(forKey: Keys.provider) ?? ""
        ) ?? .openAI
        self.provider = selectedProvider
        self.customEndpoint = defaults.string(forKey: Keys.customEndpoint) ?? ""
        self.modelID = defaults.string(forKey: Keys.modelID) ?? ""
        self.apiMode = InferenceAPIMode(
            rawValue: defaults.string(forKey: Keys.apiMode) ?? ""
        ) ?? .automatic
        self.credentialSnapshot = InferenceCredentialSnapshot(
            provider: selectedProvider,
            state: .missing,
            hasStoredKey: false,
            hasSessionKey: false,
            persistenceAvailability: keychain.persistenceAvailability,
            storeError: nil
        )
        loadStoredKey(for: selectedProvider)
        refreshCredentialSnapshot()
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
        credentialSnapshot.state
    }

    func credentialState(
        for provider: InferenceProviderKind
    ) -> InferenceCredentialState {
        if provider == self.provider {
            return credentialSnapshot.state
        }
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
        if selectedProvider == self.provider {
            _ = credentialSnapshot
        }
        let session = sessionKeys[selectedProvider] ?? ""
        return session.isEmpty
            ? storedKeys[selectedProvider] ?? ""
            : session
    }

    var hasStoredKey: Bool {
        credentialSnapshot.hasStoredKey
    }

    var hasSessionKey: Bool {
        credentialSnapshot.hasSessionKey
    }

    var credentialPersistenceAvailability:
        CredentialPersistenceAvailability {
        credentialSnapshot.persistenceAvailability
    }

    var credentialStoreError: String? {
        credentialSnapshot.storeError
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
        loadStoredKey(for: provider)
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        sessionKeys[provider] = trimmed.isEmpty ? nil : trimmed
        storeError = nil
        refreshCredentialSnapshot()
    }

    func clearSessionKey() {
        loadStoredKey(for: provider)
        sessionKeys[provider] = nil
        refreshCredentialSnapshot()
    }

    func savePersistentKey(_ key: String) throws {
        loadStoredKey(for: provider)
        guard persistenceAvailability == .persistent else {
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
        storeError = nil
        refreshCredentialSnapshot()
    }

    /// Compatibility entry point. Development and relocated builds retain the
    /// key for this process only; the installed signed app stores it in Keychain.
    func saveKey(_ key: String) throws {
        if persistenceAvailability == .persistent {
            try savePersistentKey(key)
        } else {
            useKeyForSession(key)
        }
    }

    func removeKey() throws {
        loadStoredKey(for: provider)
        if persistenceAvailability == .persistent {
            try keychain.delete(account: provider.rawValue)
        }
        storedKeys[provider] = nil
        sessionKeys[provider] = nil
        loadedProviders.insert(provider)
        storeError = nil
        refreshCredentialSnapshot()
    }

    /// A newly typed key wins over the session key, which wins over the stored
    /// key. This lets Settings and onboarding test credentials without saving.
    func keyForRequest(typedKey: String) -> String {
        let trimmed = typedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? existingKey() : trimmed
    }

    private func loadStoredKey(for provider: InferenceProviderKind) {
        guard loadedProviders.insert(provider).inserted else { return }
        guard persistenceAvailability == .persistent else { return }
        do {
            storedKeys[provider] =
                (try keychain.read(account: provider.rawValue)) ?? ""
        } catch {
            storedKeys[provider] = nil
            storeError = error.localizedDescription
            persistenceAvailability = .sessionOnly
        }
    }

    private func refreshCredentialSnapshot() {
        let hasSessionKey = !(sessionKeys[provider] ?? "").isEmpty
        let hasStoredKey = !(storedKeys[provider] ?? "").isEmpty
        let snapshot = InferenceCredentialSnapshot(
            provider: provider,
            state: hasSessionKey ? .sessionOnly
                : (hasStoredKey ? .stored : .missing),
            hasStoredKey: hasStoredKey,
            hasSessionKey: hasSessionKey,
            persistenceAvailability: persistenceAvailability,
            storeError: storeError
        )
        guard snapshot != credentialSnapshot else { return }
        credentialSnapshot = snapshot
    }

    /// Explicitly loads the provider credential for flows that need to inspect
    /// a non-selected provider. Ordinary body reads never call Keychain.
    func prepareCredential(for provider: InferenceProviderKind) {
        loadStoredKey(for: provider)
        if provider == self.provider {
            refreshCredentialSnapshot()
        }
    }
}
