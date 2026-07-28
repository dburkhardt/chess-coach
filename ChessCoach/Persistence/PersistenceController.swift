import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class PersistenceController {
    let container: ModelContainer
    private(set) var games: [SavedGame] = []
    private(set) var profile: LearnerProfile

    init(inMemory: Bool = false) {
        let schema = Schema([
            SavedGame.self,
            SavedPly.self,
            SavedCoachMessage.self,
            SavedAssistanceEvent.self,
            SavedAnalysisSnapshot.self,
            LearnerProfile.self,
        ])
        let configuration = ModelConfiguration(
            "ChessCoach",
            schema: schema,
            isStoredInMemoryOnly: inMemory
        )
        do {
            container = try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Unable to initialize the local Chess Coach store: \(error)")
        }

        let descriptor = FetchDescriptor<LearnerProfile>()
        if let existing = try? container.mainContext.fetch(descriptor).first {
            profile = existing
        } else {
            let created = LearnerProfile()
            container.mainContext.insert(created)
            profile = created
            try? container.mainContext.save()
        }
        refreshGames()
    }

    func refreshGames() {
        var descriptor = FetchDescriptor<SavedGame>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 250
        games = (try? container.mainContext.fetch(descriptor)) ?? []
    }

    var pendingReviewGames: [SavedGame] {
        games.filter {
            $0.result != .inProgress &&
                $0.result != .abandoned &&
                (!$0.reviewCompleted || !$0.profileIncorporated)
        }
    }

    func createGame(configuration: NewGameConfiguration, playerSide: ChessSide, initialFEN: String) -> SavedGame {
        let game = SavedGame(
            playerSide: playerSide,
            difficulty: configuration.difficulty,
            timeControl: configuration.timeControl,
            blunderGuardEnabled: configuration.blunderGuardEnabled,
            initialFEN: initialFEN
        )
        container.mainContext.insert(game)
        save()
        refreshGames()
        return game
    }

    func append(_ ply: SavedPly, to game: SavedGame) {
        container.mainContext.insert(ply)
        game.plies.append(ply)
        save()
    }

    @discardableResult
    func append(
        _ message: CoachMessage,
        structuredReply: CoachReply? = nil,
        positionFEN: String? = nil,
        turnID: UUID? = nil,
        kind: CoachMessageKind? = nil,
        sessionID: UUID? = nil,
        to game: SavedGame
    ) -> SavedCoachMessage {
        let stored = SavedCoachMessage(
            message: message,
            structuredReply: structuredReply,
            positionFEN: positionFEN,
            turnID: turnID,
            kind: kind,
            sessionID: sessionID
        )
        container.mainContext.insert(stored)
        game.coachMessages.append(stored)
        save()
        return stored
    }

    /// Inserts a complete question/answer pair and commits it with one context
    /// save. If that save fails, both inserted rows are removed together so a
    /// half-turn cannot appear after relaunch.
    @discardableResult
    func appendCoachTurn(
        user: CoachMessage,
        assistant: CoachMessage,
        structuredReply: CoachReply,
        positionFEN: String,
        turnID: UUID,
        sessionID: UUID? = nil,
        to game: SavedGame
    ) -> Bool {
        let storedUser = SavedCoachMessage(
            message: user,
            positionFEN: positionFEN,
            turnID: turnID,
            kind: .question,
            sessionID: sessionID
        )
        let storedAssistant = SavedCoachMessage(
            message: assistant,
            structuredReply: structuredReply,
            positionFEN: positionFEN,
            turnID: turnID,
            kind: assistant.kind ?? .answer,
            sessionID: sessionID
        )
        let inserted = [storedUser, storedAssistant]
        for message in inserted {
            container.mainContext.insert(message)
            game.coachMessages.append(message)
        }

        do {
            try container.mainContext.save()
            return true
        } catch {
            let insertedIDs = Set(inserted.map(\.id))
            game.coachMessages.removeAll { insertedIDs.contains($0.id) }
            for message in inserted {
                container.mainContext.delete(message)
            }
            assertionFailure("Unable to save a complete coach turn: \(error)")
            return false
        }
    }

    @discardableResult
    func recordAssistance(
        _ kind: AssistanceKind,
        atPly ply: Int,
        detail: String = "",
        in game: SavedGame
    ) -> SavedAssistanceEvent {
        let event = SavedAssistanceEvent(kind: kind, ply: ply, detail: detail)
        container.mainContext.insert(event)
        game.assistanceEvents.append(event)
        game.assistanceUsed = true
        save()
        return event
    }

    @discardableResult
    func recordAnalysis(
        _ analysis: PositionAnalysis,
        purpose: String,
        atPly ply: Int,
        in game: SavedGame
    ) -> SavedAnalysisSnapshot {
        if let existing = game.analysisSnapshots.first(where: {
            $0.ply == ply && $0.purpose == purpose
        }) {
            existing.update(from: analysis)
            save()
            return existing
        }

        let snapshot = SavedAnalysisSnapshot(
            ply: ply,
            purpose: purpose,
            analysis: analysis
        )
        container.mainContext.insert(snapshot)
        game.analysisSnapshots.append(snapshot)
        save()
        return snapshot
    }

    func truncate(game: SavedGame, toPlyCount count: Int) {
        let discardedPlies = game.plies.filter { $0.index >= count }
        for ply in discardedPlies {
            container.mainContext.delete(ply)
        }
        game.plies.removeAll { $0.index >= count }

        let discardedMessages = game.coachMessages.filter { $0.ply > count }
        for message in discardedMessages {
            container.mainContext.delete(message)
        }
        game.coachMessages.removeAll { $0.ply > count }

        let discardedEvents = game.assistanceEvents.filter { $0.ply > count }
        for event in discardedEvents {
            container.mainContext.delete(event)
        }
        game.assistanceEvents.removeAll { $0.ply > count }

        let discardedSnapshots = game.analysisSnapshots.filter { $0.ply > count }
        for snapshot in discardedSnapshots {
            container.mainContext.delete(snapshot)
        }
        game.analysisSnapshots.removeAll { $0.ply > count }
        save()
    }

    func delete(_ game: SavedGame) {
        container.mainContext.delete(game)
        save()
        refreshGames()
    }

    func save() {
        do {
            try container.mainContext.save()
        } catch {
            assertionFailure("Unable to save Chess Coach data: \(error)")
        }
    }

    func resetProfile(preservingOnboarding: Bool = true) {
        let onboardingComplete = preservingOnboarding && profile.onboardingComplete
        let experience = profile.experience
        container.mainContext.delete(profile)
        let replacement = LearnerProfile(
            onboardingComplete: onboardingComplete,
            experience: experience
        )
        container.mainContext.insert(replacement)
        profile = replacement
        save()
    }

    /// Rebuilds derived coaching metrics from the games that still own a
    /// completed profile contribution.
    ///
    /// This is intentionally used when a completed game is reopened from an
    /// earlier move. Rolling aggregates are not safely reversible one field at
    /// a time, so replaying the remaining reviewed games is the deterministic
    /// way to remove the abandoned result without losing onboarding or the
    /// learner's own notes.
    func rebuildProfileFromIncorporatedGames() {
        let onboardingComplete = profile.onboardingComplete
        let experience = profile.experience
        let userNotes = profile.userNotes

        var descriptor = FetchDescriptor<SavedGame>(
            sortBy: [SortDescriptor(\.startedAt, order: .forward)]
        )
        descriptor.fetchLimit = nil
        let incorporatedGames = (
            (try? container.mainContext.fetch(descriptor)) ?? []
        ).filter {
            $0.reviewCompleted &&
                $0.profileIncorporated &&
                $0.result != .inProgress &&
                $0.result != .abandoned
        }

        container.mainContext.delete(profile)
        let replacement = LearnerProfile(
            onboardingComplete: onboardingComplete,
            experience: experience
        )
        replacement.userNotes = userNotes
        container.mainContext.insert(replacement)
        profile = replacement

        let service = LearnerProfileService()
        for game in incorporatedGames {
            service.incorporate(game: game, into: replacement)
        }
        save()
    }
}
