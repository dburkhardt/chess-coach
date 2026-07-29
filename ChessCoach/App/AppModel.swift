import Foundation
import Observation

enum SettingsDestination: Hashable, Sendable {
    case inference
}

enum SettingsFocusTarget: Hashable, Sendable {
    case inferenceKey
    case endpoint
    case modelID
}

extension InferenceConfigurationIssue {
    var settingsFocusTarget: SettingsFocusTarget {
        switch self {
        case .missingKey:
            .inferenceKey
        case .missingEndpoint:
            .endpoint
        case .missingModel:
            .modelID
        }
    }
}

struct SettingsNavigationRequest: Equatable, Identifiable, Sendable {
    let id: UUID
    let destination: SettingsDestination
    let focusTarget: SettingsFocusTarget

    init(
        id: UUID = UUID(),
        destination: SettingsDestination,
        focusTarget: SettingsFocusTarget = .inferenceKey
    ) {
        self.id = id
        self.destination = destination
        self.focusTarget = focusTarget
    }
}

@MainActor
@Observable
final class AppModel {
    let persistence: PersistenceController
    let inferenceSettings: InferenceSettings
    let coordinator: GameCoordinator
    var selection: AppSection = .newGame
    private(set) var settingsNavigationRequest: SettingsNavigationRequest?

    init(
        inMemory: Bool = false,
        inferenceDefaults: UserDefaults = .standard,
        credentialStore: (any KeychainStoring)? = nil
    ) {
        let persistence = PersistenceController(inMemory: inMemory)
        let inferenceSettings = InferenceSettings(
            defaults: inferenceDefaults,
            keychain: credentialStore ?? KeychainStore()
        )
        self.persistence = persistence
        self.inferenceSettings = inferenceSettings
        self.coordinator = GameCoordinator(
            persistence: persistence,
            inferenceSettings: inferenceSettings
        )
        let isRunningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        if !isRunningTests,
           let unfinished = persistence.games.first(where: { $0.result == .inProgress }) {
            coordinator.resume(game: unfinished)
            selection = .currentGame
        }
        if !isRunningTests {
            coordinator.resumePendingReviews()
        }
    }

    func resume(game: SavedGame) {
        coordinator.resume(game: game)
        selection = .currentGame
    }

    func openInferenceSettings(
        focusTarget: SettingsFocusTarget = .inferenceKey
    ) {
        settingsNavigationRequest = SettingsNavigationRequest(
            destination: .inference,
            focusTarget: focusTarget
        )
        selection = .settings
    }
}
