import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    let persistence: PersistenceController
    let inferenceSettings: InferenceSettings
    let coordinator: GameCoordinator
    var selection: AppSection = .newGame

    init(inMemory: Bool = false) {
        let persistence = PersistenceController(inMemory: inMemory)
        let inferenceSettings = InferenceSettings()
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
}
