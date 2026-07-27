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
        didSet { defaults.set(provider.rawValue, forKey: Keys.provider) }
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

    private let defaults: UserDefaults
    private let keychain: any KeychainStoring

    init(
        defaults: UserDefaults = .standard,
        keychain: any KeychainStoring = KeychainStore()
    ) {
        self.defaults = defaults
        self.keychain = keychain
        self.provider = InferenceProviderKind(
            rawValue: defaults.string(forKey: Keys.provider) ?? ""
        ) ?? .openAI
        self.customEndpoint = defaults.string(forKey: Keys.customEndpoint) ?? ""
        self.modelID = defaults.string(forKey: Keys.modelID) ?? ""
        self.apiMode = InferenceAPIMode(
            rawValue: defaults.string(forKey: Keys.apiMode) ?? ""
        ) ?? .automatic
    }

    var configuration: InferenceConfiguration {
        InferenceConfiguration(
            provider: provider,
            baseURL: provider.defaultBaseURL ?? customEndpoint,
            modelID: modelID,
            apiMode: apiMode
        )
    }

    func existingKey(for provider: InferenceProviderKind? = nil) -> String {
        let selectedProvider = provider ?? self.provider
        return (try? keychain.read(account: selectedProvider.rawValue)) ?? ""
    }

    var hasStoredKey: Bool {
        !existingKey().isEmpty
    }

    var isConfigured: Bool {
        let configuration = configuration
        guard !configuration.trimmedBaseURL.isEmpty,
              !configuration.trimmedModelID.isEmpty
        else {
            return false
        }
        return !provider.requiresCredential || hasStoredKey
    }

    func saveKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try keychain.delete(account: provider.rawValue)
        } else {
            try keychain.save(trimmed, account: provider.rawValue)
        }
    }

    func removeKey() throws {
        try keychain.delete(account: provider.rawValue)
    }

    /// A newly typed key wins over the stored key. This lets Settings and
    /// onboarding validate credentials before saving them to Keychain.
    func keyForRequest(typedKey: String) -> String {
        let trimmed = typedKey.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? existingKey() : trimmed
    }
}
