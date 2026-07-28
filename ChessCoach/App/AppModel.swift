import Foundation
import Observation

enum SettingsDestination: Hashable, Sendable {
    case inference
}

struct SettingsNavigationRequest: Equatable, Identifiable, Sendable {
    let id: UUID
    let destination: SettingsDestination

    init(
        id: UUID = UUID(),
        destination: SettingsDestination
    ) {
        self.id = id
        self.destination = destination
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

    func openInferenceSettings() {
        settingsNavigationRequest = SettingsNavigationRequest(
            destination: .inference
        )
        selection = .settings
    }
}
