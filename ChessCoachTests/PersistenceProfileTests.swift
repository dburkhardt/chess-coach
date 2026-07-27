import Foundation
import Testing
@testable import ChessCoach

@MainActor
struct PersistenceProfileTests {
    @Test func experienceAnchorsApplyBeforeCalibrationButNotAfter() {
        let profile = LearnerProfile()
        profile.experience = .advanced
        #expect(profile.estimateLow == 1_600)
        #expect(profile.estimateHigh == 2_200)

        profile.eligibleGames = 5
        profile.estimateLow = 1_700
        profile.estimateHigh = 1_900
        profile.experience = .beginner
        #expect(profile.estimateLow == 1_700)
        #expect(profile.estimateHigh == 1_900)
    }

    @Test func resettingLearnedDataPreservesOnboardingAndExperience() {
        let persistence = PersistenceController(inMemory: true)
        persistence.profile.onboardingComplete = true
        persistence.profile.experience = .intermediate
        persistence.profile.reviewedGames = 9
        persistence.profile.userNotes = "Clear this note"
        persistence.save()

        persistence.resetProfile()

        #expect(persistence.profile.onboardingComplete)
        #expect(persistence.profile.experience == .intermediate)
        #expect(persistence.profile.reviewedGames == 0)
        #expect(persistence.profile.userNotes.isEmpty)
        #expect(persistence.profile.estimateLow == 1_200)
        #expect(persistence.profile.estimateHigh == 1_700)
    }

    @Test func ratingUsesOnlyCompletedClockedUnassistedResults() {
        let persistence = PersistenceController(inMemory: true)
        let eligible = makeGame(persistence: persistence, assisted: false)
        eligible.result = .whiteWon
        LearnerProfileService().incorporate(
            game: eligible,
            into: persistence.profile
        )

        #expect(persistence.profile.eligibleGames == 1)
        #expect(persistence.profile.ratingHistory.count == 1)

        let assisted = makeGame(persistence: persistence, assisted: true)
        assisted.result = .whiteWon
        LearnerProfileService().incorporate(
            game: assisted,
            into: persistence.profile
        )
        #expect(persistence.profile.reviewedGames == 2)
        #expect(persistence.profile.eligibleGames == 1)

        let unfinished = makeGame(persistence: persistence, assisted: false)
        LearnerProfileService().incorporate(
            game: unfinished,
            into: persistence.profile
        )
        #expect(persistence.profile.reviewedGames == 3)
        #expect(persistence.profile.eligibleGames == 1)
    }

    @Test func structuredAssistanceAndAnalysisFollowTruncatedLines() {
        let persistence = PersistenceController(inMemory: true)
        let game = makeGame(persistence: persistence, assisted: false)
        persistence.recordAssistance(
            .conceptHint,
            atPly: 4,
            detail: "Look for a forcing move.",
            in: game
        )
        persistence.recordAnalysis(
            sampleAnalysis(),
            purpose: "hint",
            atPly: 4,
            in: game
        )

        #expect(game.assistanceUsed)
        #expect(game.assistanceEvents.count == 1)
        #expect(game.analysisSnapshots.count == 1)

        persistence.truncate(game: game, toPlyCount: 2)
        #expect(game.assistanceEvents.isEmpty)
        #expect(game.analysisSnapshots.isEmpty)
    }

    @Test func structuredCoachTurnPersistsAtomicallyWithLegacyTextFallback() throws {
        let persistence = PersistenceController(inMemory: true)
        let game = makeGame(persistence: persistence, assisted: false)
        let turnID = UUID()
        let user = CoachMessage(
            role: .user,
            text: "What should I notice?",
            ply: 0
        )
        let reply = CoachReply(
            summary: "Improve your least active piece before forcing play.",
            sections: [
                CoachReplySection(
                    kind: .idea,
                    title: "What to notice",
                    body: "Improve the least active piece.",
                    variationRank: nil
                ),
                CoachReplySection(
                    kind: .variation,
                    title: "Engine line",
                    body: "This continuation preserves central control.",
                    variationRank: 1
                ),
            ]
        )
        let assistant = CoachMessage(
            role: .coach,
            text: reply.plainText,
            ply: 0
        )

        #expect(
            persistence.appendCoachTurn(
                user: user,
                assistant: assistant,
                structuredReply: reply,
                positionFEN: ChessGameState.standardInitialFEN,
                turnID: turnID,
                to: game
            )
        )
        #expect(game.coachMessages.count == 2)
        let storedUser = try #require(
            game.coachMessages.first { $0.roleRaw == CoachRole.user.rawValue }
        )
        let storedAssistant = try #require(
            game.coachMessages.first { $0.roleRaw == CoachRole.coach.rawValue }
        )
        #expect(storedUser.turnID == turnID)
        #expect(storedAssistant.turnID == turnID)
        #expect(storedAssistant.positionFEN == ChessGameState.standardInitialFEN)
        #expect(storedAssistant.structuredContent == reply)
        #expect(storedAssistant.text == reply.plainText)

        let legacy = persistence.append(
            CoachMessage(
                role: .coach,
                text: "**Legacy** text remains readable.",
                ply: 0
            ),
            to: game
        )
        #expect(legacy.structuredContent == nil)
        #expect(legacy.effectiveReply.sections.count == 1)
        #expect(legacy.effectiveReply.sections[0].body == "Legacy text remains readable.")

        let oldStructured = persistence.append(
            CoachMessage(role: .coach, text: "Older structured text.", ply: 0),
            to: game
        )
        oldStructured.structuredContentJSON = Data(
            #"""
            {"version":1,"sections":[{"kind":"plan","title":"Plan","body":"Finish development.","variationRank":null}]}
            """#.utf8
        )
        #expect(oldStructured.structuredContent?.summary == "")
        #expect(oldStructured.effectiveReply.sections.first?.body == "Finish development.")
    }

    @Test func pendingReviewQueryIncludesInterruptedAndProfileOnlyWork() {
        let persistence = PersistenceController(inMemory: true)
        let game = makeGame(persistence: persistence, assisted: false)
        game.result = .whiteWon
        persistence.save()
        persistence.refreshGames()
        #expect(persistence.pendingReviewGames.map(\.id).contains(game.id))

        game.reviewCompleted = true
        game.profileIncorporated = false
        #expect(persistence.pendingReviewGames.map(\.id).contains(game.id))

        game.profileIncorporated = true
        #expect(!persistence.pendingReviewGames.map(\.id).contains(game.id))
    }

    @Test func cancelledReviewCannotMutateResumedGameOrProfile() async throws {
        let persistence = PersistenceController(inMemory: true)
        let game = makeGame(persistence: persistence, assisted: false)
        let state = ChessGameState()
        let made = try state.make(uci: "e2e4")
        persistence.append(
            SavedPly(
                index: 0,
                side: made.side,
                uci: made.uci,
                san: made.san,
                fenBefore: made.fenBefore,
                fenAfter: made.fenAfter,
                clockBefore: .initial(for: .rapid10),
                clockAfter: ClockSnapshot(
                    whiteMilliseconds: 590_000,
                    blackMilliseconds: 600_000
                )
            ),
            to: game
        )
        game.result = .whiteWon
        persistence.save()

        let engine = BlockingReviewEngine()
        let analyzer = ReviewAnalyzer(analyst: engine)
        let review = Task {
            await analyzer.review(game: game, persistence: persistence)
        }

        var started = false
        for _ in 0..<1_000 {
            if await engine.pendingAnalysisCount > 0 {
                started = true
                break
            }
            await Task.yield()
        }
        #expect(started)

        review.cancel()
        game.result = .inProgress
        await engine.completeNext(with: sampleAnalysis())
        await review.value

        #expect(!game.reviewCompleted)
        #expect(!game.profileIncorporated)
        #expect(game.analysisSnapshots.isEmpty)
        #expect(persistence.profile.reviewedGames == 0)
        #expect(persistence.profile.eligibleGames == 0)
    }

    @Test func betaReleaseMetadataStaysAligned() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = try String(
            contentsOf: repository.appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        let release = try String(
            contentsOf: repository.appendingPathComponent("scripts/release.sh"),
            encoding: .utf8
        )
        let scheme = try String(
            contentsOf: repository.appendingPathComponent(
                "ChessCoach.xcodeproj/xcshareddata/xcschemes/ChessCoach.xcscheme"
            ),
            encoding: .utf8
        )

        #expect(project.contains("MARKETING_VERSION: \"0.1.0\""))
        #expect(project.contains("CURRENT_PROJECT_VERSION: \"6\""))
        #expect(!project.contains("DEVELOPMENT_TEAM:"))
        #expect(release.contains("Chess-Coach-${VERSION}-${PRERELEASE}.dmg"))
        #expect(release.contains("PRERELEASE=\"beta.6\""))
        #expect(release.contains("DEVELOPER_ID_APPLICATION:?"))
        #expect(release.contains("DEVELOPMENT_TEAM:?"))
        #expect(release.contains("NOTARYTOOL_PROFILE:?"))
        #expect(release.contains("CODE_SIGNING_ALLOWED=NO"))
        #expect(!scheme.contains("ChessCoachUITests.xctest"))
    }

    @Test func providerConfigurationUIIsNeutralAndCoversBothFlows() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let settings = try String(
            contentsOf: repository.appendingPathComponent(
                "ChessCoach/Views/SettingsView.swift"
            ),
            encoding: .utf8
        )
        let onboarding = try String(
            contentsOf: repository.appendingPathComponent(
                "ChessCoach/Views/OnboardingView.swift"
            ),
            encoding: .utf8
        )
        for source in [settings, onboarding] {
            #expect(source.contains("InferenceProviderKind.allCases"))
            #expect(source.contains("customOpenAICompatible"))
            #expect(source.contains("https://api.openai.com"))
            #expect(source.contains("Model ID"))
            #expect(source.contains("API mode"))
            #expect(source.contains("Test Selected Model"))
        }
        #expect(settings.contains("Discover Models"))
        #expect(settings.contains("Validate Configuration"))
    }

    private func makeGame(
        persistence: PersistenceController,
        assisted: Bool
    ) -> SavedGame {
        let game = persistence.createGame(
            configuration: NewGameConfiguration(
                colorChoice: .white,
                difficulty: 4,
                timeControl: .rapid10,
                blunderGuardEnabled: false
            ),
            playerSide: .white,
            initialFEN: ChessGameState.standardInitialFEN
        )
        game.assistanceUsed = assisted
        return game
    }

    private func sampleAnalysis() -> PositionAnalysis {
        PositionAnalysis(
            fen: ChessGameState.standardInitialFEN,
            sideToMove: .white,
            bestMove: "e2e4",
            variations: [
                PrincipalVariation(
                    index: 1,
                    depth: 18,
                    score: EngineScore(centipawns: 22),
                    wdl: WDL(win: 260, draw: 610, loss: 130),
                    moves: ["e2e4", "e7e5"]
                )
            ]
        )
    }
}

private actor BlockingReviewEngine: ChessEngineServing {
    private var pending: [
        CheckedContinuation<PositionAnalysis, Error>
    ] = []

    func analyze(
        fen: String,
        multiPV: Int,
        moveTimeMilliseconds: Int
    ) async throws -> PositionAnalysis {
        try await withCheckedThrowingContinuation { continuation in
            pending.append(continuation)
        }
    }

    func opponentMove(
        fen: String,
        difficulty: Int,
        clocks: ClockSnapshot,
        timeControl: TimeControl
    ) async throws -> String {
        ChessGameState(initialFEN: fen).legalMoves.first ?? ""
    }

    var pendingAnalysisCount: Int {
        pending.count
    }

    func completeNext(with analysis: PositionAnalysis) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().resume(returning: analysis)
    }

    func stopThinking() {}
    func shutdown() {}
}
