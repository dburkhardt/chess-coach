import Foundation
import Testing
@testable import ChessCoach

@MainActor
@Suite(.serialized)
struct GameCoordinatorTests {
    @Test func blackGameStartsWithStockfishWhiteMove() async throws {
        let opponent = ScriptedEngine(opponentMoves: ["e2e4"])
        let harness = try makeHarness(opponent: opponent)

        harness.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .black,
                difficulty: 4,
                timeControl: .none,
                blunderGuardEnabled: false
            )
        )

        try await eventually { harness.coordinator.state.plyCount == 1 }
        #expect(harness.coordinator.playerSide == .black)
        #expect(harness.coordinator.state.sideToMove == .black)
        #expect(harness.coordinator.activeGame?.sortedPlies.map(\.uci) == ["e2e4"])
    }

    @Test func takeBackBeforeReplyRestoresClockAndRejectsLateMove() async throws {
        let opponent = BlockingOpponentEngine()
        let clock = ManualGameClock()
        let harness = try makeHarness(opponent: opponent, clock: clock)
        harness.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 4,
                timeControl: .rapid10,
                blunderGuardEnabled: false
            )
        )

        await drainTasks()
        await clock.advance(by: 2_000)
        try await eventually {
            abs(harness.coordinator.clocks.whiteMilliseconds - 598_000) <= 1
        }
        play("e2", "e4", on: harness.coordinator)
        try await eventually { harness.coordinator.state.plyCount == 1 }
        #expect(harness.coordinator.canTakeBack)

        harness.coordinator.takeBack()
        #expect(harness.coordinator.state.plyCount == 0)
        #expect(harness.coordinator.clocks.whiteMilliseconds == 598_000)
        let restoredPGN = try #require(harness.coordinator.activeGame?.pgn)
        #expect(restoredPGN.contains(#"[Result "*"]"#))
        #expect(!restoredPGN.contains("e4"))
        #expect(
            harness.coordinator.activeGame?.currentFEN
                == ChessGameState.standardInitialFEN
        )
        #expect(harness.coordinator.activeGame?.assistanceUsed == true)
        #expect(
            harness.coordinator.activeGame?.assistanceEvents.contains {
                $0.kind == .takeBack
            } == true
        )

        await opponent.completeNext(with: "e7e5")
        await drainTasks()
        #expect(harness.coordinator.state.plyCount == 0)
        #expect(harness.coordinator.state.fen == ChessGameState.standardInitialFEN)
    }

    @Test func repeatedTakeBackRemovesEachPlayerDecisionAndReply() async throws {
        let opponent = ScriptedEngine(opponentMoves: ["e7e5", "b8c6"])
        let harness = try makeHarness(opponent: opponent)
        harness.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 4,
                timeControl: .none,
                blunderGuardEnabled: false
            )
        )

        play("e2", "e4", on: harness.coordinator)
        try await eventually { harness.coordinator.state.plyCount == 2 }
        play("g1", "f3", on: harness.coordinator)
        try await eventually { harness.coordinator.state.plyCount == 4 }

        harness.coordinator.takeBack()
        #expect(harness.coordinator.state.uciMoves == ["e2e4", "e7e5"])
        harness.coordinator.takeBack()
        #expect(harness.coordinator.state.uciMoves.isEmpty)
        #expect(!harness.coordinator.canTakeBack)
    }

    @Test func restartMarksPreviousGameAbandonedAndSkipsReview() async throws {
        let opponent = BlockingOpponentEngine()
        let harness = try makeHarness(opponent: opponent)
        harness.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 4,
                timeControl: .none,
                blunderGuardEnabled: false
            )
        )
        let previous = try #require(harness.coordinator.activeGame)
        play("e2", "e4", on: harness.coordinator)
        try await eventually { harness.coordinator.state.plyCount == 1 }

        harness.coordinator.restart()
        #expect(previous.result == .abandoned)
        #expect(previous.endReason == .restarted)
        #expect(!harness.persistence.pendingReviewGames.map(\.id).contains(previous.id))

        await opponent.completeNext(with: "e7e5")
        await drainTasks()
        #expect(harness.coordinator.activeGame?.id != previous.id)
        #expect(harness.coordinator.state.plyCount == 0)
    }

    @Test func finishingAGameResumesEarlierPendingReviews() async throws {
        let harness = try makeHarness()
        let configuration = NewGameConfiguration(
            colorChoice: .white,
            difficulty: 4,
            timeControl: .none,
            blunderGuardEnabled: false
        )
        let earlier = harness.persistence.createGame(
            configuration: configuration,
            playerSide: .white,
            initialFEN: ChessGameState.standardInitialFEN
        )
        earlier.result = .whiteWon
        earlier.endReason = .checkmate
        earlier.endedAt = Date(timeIntervalSince1970: 100)
        harness.persistence.save()
        harness.persistence.refreshGames()

        harness.coordinator.newGame(configuration)
        harness.coordinator.resign()

        try await eventually {
            earlier.reviewCompleted && earlier.profileIncorporated
        }
        #expect(
            !harness.persistence.pendingReviewGames.map(\.id)
                .contains(earlier.id)
        )
    }

    @Test func timeoutEndsGameAndPreventsFurtherMoves() async throws {
        let clock = ManualGameClock()
        let harness = try makeHarness(clock: clock)
        harness.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 4,
                timeControl: .rapid10,
                blunderGuardEnabled: false
            )
        )

        await drainTasks()
        await clock.advance(by: 600_100)
        try await eventually { harness.coordinator.status.reason == .timeout }
        #expect(harness.coordinator.status.result == .blackWon)
        #expect(harness.coordinator.activeClockSide == nil)

        play("e2", "e4", on: harness.coordinator)
        await drainTasks()
        #expect(harness.coordinator.state.plyCount == 0)
    }

    @Test func moveAtDeadlineCannotPersistAfterTimeout() async throws {
        let clock = ManualGameClock()
        let harness = try makeHarness(clock: clock)
        harness.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 4,
                timeControl: .rapid10,
                blunderGuardEnabled: false
            )
        )
        await drainTasks()

        clock.elapseWithoutTick(by: 600_100)
        play("e2", "e4", on: harness.coordinator)

        try await eventually { harness.coordinator.status.reason == .timeout }
        #expect(harness.coordinator.state.plyCount == 0)
        #expect(harness.coordinator.activeGame?.sortedPlies.isEmpty == true)
        let timeoutPGN = try #require(harness.coordinator.activeGame?.pgn)
        #expect(timeoutPGN.contains(#"[Result "0-1"]"#))
        #expect(!timeoutPGN.contains("e4"))
    }

    @Test func opponentFailureDoesNotRunPlayerClockOutOfTurn() async throws {
        let harness = try makeHarness(opponent: FailingOpponentEngine())
        harness.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 4,
                timeControl: .rapid10,
                blunderGuardEnabled: false
            )
        )

        play("e2", "e4", on: harness.coordinator)
        try await eventually { !harness.coordinator.errorMessage.isEmpty }
        #expect(harness.coordinator.state.sideToMove == .black)
        #expect(harness.coordinator.activeClockSide == nil)
        #expect(!harness.coordinator.isEngineThinking)
        #expect(harness.coordinator.canTakeBack)
    }

    @Test func blunderWarningRunsPlayerClockAndTakeBackRefundsWarningTime() async throws {
        let opponent = BlockingOpponentEngine()
        let clock = ManualGameClock()
        let analyst = ScriptedEngine(
            analysisScores: [
                ChessGameState.standardInitialFEN: 0.80,
            ],
            defaultAnalysisScore: 0.45
        )
        let harness = try makeHarness(
            opponent: opponent,
            analyst: analyst,
            clock: clock
        )
        harness.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 4,
                timeControl: .rapid10,
                blunderGuardEnabled: true
            )
        )
        await drainTasks()

        play("e2", "e4", on: harness.coordinator)
        try await eventually { harness.coordinator.blunderWarning != nil }
        let preWarningClock = harness.coordinator.clocks.whiteMilliseconds
        #expect(harness.coordinator.activeClockSide == .white)

        await clock.advance(by: 1_500)
        try await eventually {
            abs(
                harness.coordinator.clocks.whiteMilliseconds
                    - (preWarningClock - 1_500)
            ) <= 1
        }
        harness.coordinator.takeBack()
        #expect(harness.coordinator.clocks.whiteMilliseconds == preWarningClock)
        #expect(harness.coordinator.blunderWarning == nil)
        #expect(harness.coordinator.state.plyCount == 0)
    }

    @Test func blunderWarningCanAskCoachThenPlayOn() async throws {
        let opponent = BlockingOpponentEngine()
        let analyst = ScriptedEngine(
            analysisScores: [
                ChessGameState.standardInitialFEN: 0.80,
            ],
            defaultAnalysisScore: 0.45
        )
        let harness = try makeHarness(
            opponent: opponent,
            analyst: analyst,
            inference: StubInference(),
            keychain: MemoryCoordinatorKeychain(value: "placeholder-key")
        )
        harness.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 4,
                timeControl: .rapid10,
                blunderGuardEnabled: true
            )
        )
        await drainTasks()

        play("e2", "e4", on: harness.coordinator)
        try await eventually { harness.coordinator.blunderWarning != nil }
        harness.coordinator.askCoachAboutWarning()
        try await eventually {
            harness.coordinator.coachMessages.last?.text
                == "Coach: Control the center."
        }
        #expect(harness.coordinator.blunderWarning != nil)

        harness.coordinator.playOnAfterWarning()
        #expect(harness.coordinator.blunderWarning == nil)
        #expect(harness.coordinator.isEngineThinking)
        await opponent.completeNext(with: "e7e5")
        try await eventually { harness.coordinator.state.plyCount == 2 }
        #expect(harness.coordinator.state.uciMoves == ["e2e4", "e7e5"])
        #expect(harness.coordinator.activeClockSide == .white)
        #expect(
            harness.coordinator.activeGame?.assistanceEvents.map(\.kind)
                .contains(.coachChat) == true
        )
    }

    @Test func warningTimeoutDoesNotLaunchLateOpponentSearch() async throws {
        let opponent = BlockingOpponentEngine()
        let clock = ManualGameClock()
        let analyst = ScriptedEngine(
            analysisScores: [
                ChessGameState.standardInitialFEN: 0.80,
            ],
            defaultAnalysisScore: 0.45
        )
        let harness = try makeHarness(
            opponent: opponent,
            analyst: analyst,
            clock: clock
        )
        harness.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 4,
                timeControl: .rapid10,
                blunderGuardEnabled: true
            )
        )
        await drainTasks()

        play("e2", "e4", on: harness.coordinator)
        try await eventually { harness.coordinator.blunderWarning != nil }
        clock.elapseWithoutTick(
            by: harness.coordinator.clocks.whiteMilliseconds + 100
        )
        harness.coordinator.playOnAfterWarning()

        try await eventually { harness.coordinator.status.reason == .timeout }
        #expect(!harness.coordinator.isEngineThinking)
        #expect(await opponent.pendingRequestCount == 0)
        #expect(harness.coordinator.state.plyCount == 1)
        #expect(!harness.coordinator.canTakeBack)
    }

    @Test func injectedInferenceProducesHintAndStreamedChat() async throws {
        let keychain = MemoryCoordinatorKeychain(value: "placeholder-key")
        let inference = StubInference()
        let harness = try makeHarness(
            inference: inference,
            keychain: keychain
        )
        harness.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 4,
                timeControl: .none,
                blunderGuardEnabled: false
            )
        )

        try await eventually {
            if case .ready = harness.coordinator.coachPreparationState {
                return true
            }
            return false
        }
        harness.coordinator.requestHint()
        try await eventually { harness.coordinator.currentHint != nil }
        #expect(harness.coordinator.currentHint?.recommendedMove == "e2e4")
        harness.coordinator.revealHint()
        #expect(harness.coordinator.hintArrow?.from == "e2")
        #expect(harness.coordinator.hintArrow?.to == "e4")

        harness.coordinator.sendChat("Why control the center?")
        try await eventually {
            harness.coordinator.coachMessages.last?.text
                == "Coach: Control the center."
        }
        #expect(
            harness.coordinator.activeGame?.assistanceEvents.map(\.kind)
                .contains(.coachChat) == true
        )
    }

    @Test func preparesAnchoredCoachingForEachPlayerTurn() async throws {
        let harness = try makeHarness(
            keychain: MemoryCoordinatorKeychain(value: "placeholder-key")
        )
        harness.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 4,
                timeControl: .none,
                blunderGuardEnabled: false
            )
        )

        try await eventually {
            if case .ready = harness.coordinator.coachPreparationState {
                return true
            }
            return false
        }
        guard case .ready(let prepared) =
                harness.coordinator.coachPreparationState
        else {
            Issue.record("Expected prepared coaching for the player turn.")
            return
        }
        #expect(prepared.anchor.gameID == harness.coordinator.activeGame?.id)
        #expect(prepared.anchor.revision == 1)
        #expect(prepared.anchor.ply == 0)
        #expect(prepared.anchor.fen == harness.coordinator.state.fen)
        #expect(prepared.analysis.fen == prepared.anchor.fen)
        #expect(prepared.context.fen == prepared.anchor.fen)
        #expect(prepared.context.variations.count == 1)
        #expect(prepared.hint.recommendedMove == prepared.analysis.bestMove)
        #expect(
            harness.coordinator.activeGame?.assistanceEvents.isEmpty == true
        )
        #expect(harness.coordinator.activeGame?.assistanceUsed == false)
    }

    @Test func stockfishHintIsActionableWhileProviderIsStillPreparing() async throws {
        let inference = BlockingHintInference()
        let harness = try makeHarness(
            inference: inference,
            keychain: MemoryCoordinatorKeychain(value: "placeholder-key")
        )
        harness.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 4,
                timeControl: .rapid10,
                blunderGuardEnabled: false
            )
        )

        try await eventually {
            guard case .ready(let prepared) =
                    harness.coordinator.coachPreparationState
            else {
                return false
            }
            return prepared.enhancement == .preparing
        }
        try await eventually { inference.requestCount == 1 }
        #expect(inference.requestCount == 1)
        #expect(harness.coordinator.canStartTeachingMoment)
        #expect(harness.coordinator.activeClockSide == .white)
        #expect(harness.coordinator.currentHint == nil)

        harness.coordinator.requestHint()
        let fallback = try #require(harness.coordinator.currentHint)
        #expect(fallback.source == "Stockfish fallback")
        #expect(harness.coordinator.activeClockSide == nil)
        #expect(!harness.coordinator.isCoachWorking)
        #expect(inference.requestCount == 1)

        inference.complete(
            recommendedMove: fallback.recommendedMove,
            source: "Provider prepared"
        )
        try await eventually {
            harness.coordinator.currentHint?.source == "Provider prepared"
        }
        guard case .ready(let upgraded) =
                harness.coordinator.coachPreparationState
        else {
            Issue.record("Expected upgraded prepared coaching.")
            return
        }
        #expect(upgraded.enhancement == .ready)
        #expect(upgraded.providerHint?.source == "Provider prepared")
        #expect(inference.requestCount == 1)
    }

    @Test func revealedLessonDoesNotHotSwapWhenProviderFinishes() async throws {
        let inference = BlockingHintInference()
        let harness = try makeHarness(
            inference: inference,
            keychain: MemoryCoordinatorKeychain(value: "placeholder-key")
        )
        harness.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 4,
                timeControl: .none,
                blunderGuardEnabled: false
            )
        )
        try await eventually {
            guard case .ready(let prepared) =
                    harness.coordinator.coachPreparationState
            else {
                return false
            }
            return prepared.enhancement == .preparing
        }
        try await eventually { inference.requestCount == 1 }

        harness.coordinator.requestHint()
        let fallback = try #require(harness.coordinator.currentHint)
        harness.coordinator.revealHint()
        #expect(harness.coordinator.teachingMoment?.isUpgradeEligible == false)

        inference.complete(
            recommendedMove: fallback.recommendedMove,
            source: "Late Provider"
        )
        try await eventually {
            guard case .ready(let prepared) =
                    harness.coordinator.coachPreparationState
            else {
                return false
            }
            return prepared.enhancement == .ready
        }
        #expect(harness.coordinator.currentHint?.source == "Stockfish fallback")
        guard case .revealed(let shownHint) =
                harness.coordinator.teachingMoment?.phase
        else {
            Issue.record("Expected the revealed lesson to remain visible.")
            return
        }
        #expect(shownHint.source == "Stockfish fallback")
    }

    @Test func completedProviderPreparationIsUsedWhenHintOpens() async throws {
        let inference = BlockingHintInference()
        let harness = try makeHarness(
            inference: inference,
            keychain: MemoryCoordinatorKeychain(value: "placeholder-key")
        )
        harness.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 4,
                timeControl: .none,
                blunderGuardEnabled: false
            )
        )
        try await eventually { inference.requestCount == 1 }
        guard case .ready(let initial) =
                harness.coordinator.coachPreparationState
        else {
            Issue.record("Expected deterministic coaching to be ready.")
            return
        }

        inference.complete(
            recommendedMove: initial.deterministicHint.recommendedMove,
            source: "Provider before click"
        )
        try await eventually {
            guard case .ready(let prepared) =
                    harness.coordinator.coachPreparationState
            else {
                return false
            }
            return prepared.enhancement == .ready
        }

        harness.coordinator.requestHint()
        #expect(
            harness.coordinator.currentHint?.source == "Provider before click"
        )
        guard case .concept(let hint) =
                harness.coordinator.teachingMoment?.phase
        else {
            Issue.record("Expected a prepared Provider concept.")
            return
        }
        #expect(hint.source == "Provider before click")
    }

    @Test func restartRejectsLateProviderEnhancementFromPreviousGame() async throws {
        let inference = BlockingHintInference()
        let harness = try makeHarness(
            inference: inference,
            keychain: MemoryCoordinatorKeychain(value: "placeholder-key")
        )
        harness.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 4,
                timeControl: .none,
                blunderGuardEnabled: false
            )
        )
        try await eventually { inference.requestCount == 1 }
        guard case .ready(let original) =
                harness.coordinator.coachPreparationState
        else {
            Issue.record("Expected original preparation.")
            return
        }

        harness.coordinator.restart()
        try await eventually { inference.requestCount == 2 }
        guard case .ready(let restarted) =
                harness.coordinator.coachPreparationState
        else {
            Issue.record("Expected restarted preparation.")
            return
        }
        #expect(restarted.anchor.gameID != original.anchor.gameID)

        inference.complete(
            requestNumber: 1,
            recommendedMove: original.deterministicHint.recommendedMove,
            source: "Stale Provider"
        )
        await drainTasks()
        guard case .ready(let afterStaleCompletion) =
                harness.coordinator.coachPreparationState
        else {
            Issue.record("Expected current preparation to remain ready.")
            return
        }
        #expect(afterStaleCompletion.anchor == restarted.anchor)
        #expect(afterStaleCompletion.providerHint == nil)
        #expect(afterStaleCompletion.enhancement == .preparing)

        inference.complete(
            requestNumber: 2,
            recommendedMove: restarted.deterministicHint.recommendedMove,
            source: "Current Provider"
        )
        try await eventually {
            guard case .ready(let prepared) =
                    harness.coordinator.coachPreparationState
            else {
                return false
            }
            return prepared.providerHint?.source == "Current Provider"
        }
    }

    @Test func teachingMomentPausesClockAndCommitsLegalMoveForFree() async throws {
        let opponent = BlockingOpponentEngine()
        let clock = ManualGameClock()
        let harness = try makeHarness(
            opponent: opponent,
            clock: clock,
            keychain: MemoryCoordinatorKeychain(value: "placeholder-key")
        )
        harness.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 4,
                timeControl: .rapid10,
                blunderGuardEnabled: false
            )
        )
        try await eventually {
            if case .ready = harness.coordinator.coachPreparationState {
                return true
            }
            return false
        }

        harness.coordinator.requestHint()
        try await eventually { harness.coordinator.currentHint != nil }
        #expect(harness.coordinator.activeClockSide == nil)
        #expect(!harness.coordinator.canPlayerMove)
        guard case .concept =
                harness.coordinator.teachingMoment?.phase
        else {
            Issue.record("Expected the concept phase.")
            return
        }

        let pausedClock = harness.coordinator.clocks.whiteMilliseconds
        await clock.advance(by: 5_000)
        await drainTasks()
        #expect(harness.coordinator.clocks.whiteMilliseconds == pausedClock)
        play("e2", "e4", on: harness.coordinator)
        try await eventually { harness.coordinator.state.plyCount == 1 }
        #expect(harness.coordinator.teachingMoment == nil)
        #expect(harness.coordinator.currentHint == nil)
        #expect(harness.coordinator.clocks.whiteMilliseconds == pausedClock)
        #expect(harness.coordinator.state.uciMoves == ["e2e4"])
        #expect(harness.coordinator.activeGame?.coachMessages.count == 1)
        #expect(
            harness.coordinator.activeGame?.assistanceEvents.map(\.kind)
                == [.conceptHint]
        )
        #expect(harness.coordinator.isEngineThinking)
        #expect(harness.coordinator.activeClockSide == nil)
    }

    @Test func revealedTeachingMomentCommitsAnAlternateLegalMove() async throws {
        let opponent = BlockingOpponentEngine()
        let harness = try makeHarness(opponent: opponent)
        harness.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 4,
                timeControl: .none,
                blunderGuardEnabled: false
            )
        )
        try await eventually {
            if case .ready = harness.coordinator.coachPreparationState {
                return true
            }
            return false
        }

        harness.coordinator.requestHint()
        harness.coordinator.revealHint()
        guard case .revealed =
                harness.coordinator.teachingMoment?.phase
        else {
            Issue.record("Expected a revealed teaching moment.")
            return
        }

        play("d2", "d4", on: harness.coordinator)
        try await eventually { harness.coordinator.state.plyCount == 1 }
        #expect(harness.coordinator.state.uciMoves == ["d2d4"])
        #expect(harness.coordinator.teachingMoment == nil)
        #expect(harness.coordinator.activeGame?.coachMessages.count == 1)
        #expect(
            harness.coordinator.activeGame?.coachMessages.first?
                .structuredContent?.sections.isEmpty == false
        )
        #expect(
            harness.coordinator.activeGame?.assistanceEvents.map(\.kind)
                == [.conceptHint, .revealMove]
        )
    }

    @Test func teachingPromotionWaitsForChoiceThenCommits() async throws {
        let opponent = BlockingOpponentEngine()
        let harness = try makeHarness(opponent: opponent)
        let configuration = NewGameConfiguration(
            colorChoice: .white,
            difficulty: 4,
            timeControl: .none,
            blunderGuardEnabled: false
        )
        let game = harness.persistence.createGame(
            configuration: configuration,
            playerSide: .white,
            initialFEN: "7k/P7/8/8/8/8/8/7K w - - 0 1"
        )
        harness.coordinator.resume(game: game)
        try await eventually {
            if case .ready = harness.coordinator.coachPreparationState {
                return true
            }
            return false
        }
        harness.coordinator.requestHint()

        play("a7", "a8", on: harness.coordinator)
        let promotion = try #require(harness.coordinator.promotionRequest)
        #expect(promotion.candidates.sorted() == [
            "a7a8b", "a7a8n", "a7a8q", "a7a8r",
        ])
        #expect(harness.coordinator.state.plyCount == 0)
        #expect(harness.coordinator.teachingMoment != nil)

        harness.coordinator.promote(to: "q")
        try await eventually { harness.coordinator.state.plyCount == 1 }
        #expect(harness.coordinator.state.uciMoves == ["a7a8q"])
        #expect(harness.coordinator.state.piece(at: "a8")?.kind == "q")
        #expect(harness.coordinator.promotionRequest == nil)
        #expect(harness.coordinator.teachingMoment == nil)
        #expect(game.coachMessages.count == 1)
    }

    @Test func stalePromotionIntentCannotMutateANewTeachingGame() async throws {
        let harness = try makeHarness()
        let configuration = NewGameConfiguration(
            colorChoice: .white,
            difficulty: 4,
            timeControl: .none,
            blunderGuardEnabled: false
        )
        let promotionGame = harness.persistence.createGame(
            configuration: configuration,
            playerSide: .white,
            initialFEN: "7k/P7/8/8/8/8/8/7K w - - 0 1"
        )
        harness.coordinator.resume(game: promotionGame)
        try await eventually {
            if case .ready = harness.coordinator.coachPreparationState {
                return true
            }
            return false
        }
        harness.coordinator.requestHint()
        play("a7", "a8", on: harness.coordinator)
        let stalePromotion = try #require(
            harness.coordinator.promotionRequest
        )

        harness.coordinator.restart()
        try await eventually {
            if case .ready = harness.coordinator.coachPreparationState {
                return true
            }
            return false
        }
        harness.coordinator.requestHint()
        let currentLessonID = try #require(
            harness.coordinator.teachingMoment?.id
        )
        harness.coordinator.promotionRequest = stalePromotion
        harness.coordinator.promote(to: "q")
        await drainTasks()

        #expect(harness.coordinator.state.plyCount == 0)
        #expect(harness.coordinator.teachingMoment?.id == currentLessonID)
        #expect(harness.coordinator.currentHint != nil)
        #expect(harness.coordinator.coachMessages.isEmpty)
    }

    @Test func illegalTeachingMoveLeavesLessonAndPositionUntouched() async throws {
        let harness = try makeHarness()
        harness.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 4,
                timeControl: .none,
                blunderGuardEnabled: false
            )
        )
        try await eventually {
            if case .ready = harness.coordinator.coachPreparationState {
                return true
            }
            return false
        }
        harness.coordinator.requestHint()
        let lesson = try #require(harness.coordinator.teachingMoment)
        let hint = try #require(harness.coordinator.currentHint)
        let fen = harness.coordinator.state.fen

        harness.coordinator.dragMove(from: "e2", to: "e5")
        await drainTasks()

        #expect(harness.coordinator.state.fen == fen)
        #expect(harness.coordinator.state.plyCount == 0)
        #expect(harness.coordinator.teachingMoment == lesson)
        #expect(harness.coordinator.currentHint == hint)
        #expect(harness.coordinator.coachMessages.isEmpty)
    }

    @Test func playingDuringPendingCoachReplyRemovesOrphanTurn() async throws {
        let inference = ControlledReplyInference()
        let opponent = BlockingOpponentEngine()
        let harness = try makeHarness(
            opponent: opponent,
            inference: inference,
            keychain: MemoryCoordinatorKeychain(value: "placeholder-key")
        )
        harness.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 4,
                timeControl: .none,
                blunderGuardEnabled: false
            )
        )
        try await eventually {
            if case .ready = harness.coordinator.coachPreparationState {
                return true
            }
            return false
        }
        harness.coordinator.requestHint()
        harness.coordinator.sendChat("What if I play now?")
        try await eventually { inference.isWaitingForReply }
        #expect(harness.coordinator.coachMessages.count == 2)

        play("e2", "e4", on: harness.coordinator)
        try await eventually { harness.coordinator.state.plyCount == 1 }
        inference.complete(
            with: CoachReply(
                summary: "This reply should be discarded.",
                sections: []
            )
        )
        try await eventually {
            harness.coordinator.coachMessages.count == 1
        }

        #expect(harness.coordinator.coachMessages.first?.role == .coach)
        #expect(
            harness.coordinator.coachMessages.first?.structuredReply?
                .summary != "This reply should be discarded."
        )
        #expect(harness.coordinator.activeGame?.coachMessages.count == 1)
        #expect(
            harness.coordinator.activeGame?.assistanceEvents.map(\.kind)
                == [.conceptHint]
        )
    }

    @Test func teachingModeCommitsCanonicalKingsideCastle() async throws {
        let opponent = BlockingOpponentEngine()
        let harness = try makeHarness(opponent: opponent)
        let configuration = NewGameConfiguration(
            colorChoice: .white,
            difficulty: 4,
            timeControl: .none,
            blunderGuardEnabled: false
        )
        let game = harness.persistence.createGame(
            configuration: configuration,
            playerSide: .white,
            initialFEN: "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1"
        )
        harness.coordinator.resume(game: game)
        try await eventually {
            if case .ready = harness.coordinator.coachPreparationState {
                return true
            }
            return false
        }
        harness.coordinator.requestHint()

        play("e1", "g1", on: harness.coordinator)
        try await eventually { harness.coordinator.state.plyCount == 1 }

        #expect(harness.coordinator.state.uciMoves == ["e1g1"])
        #expect(harness.coordinator.state.piece(at: "g1")?.kind == "k")
        #expect(harness.coordinator.state.piece(at: "f1")?.kind == "r")
        #expect(game.sortedPlies.first?.san == "O-O")
        #expect(harness.coordinator.teachingMoment == nil)
    }

    @Test func previewSteppingDoesNotMutateTheGamePosition() async throws {
        let harness = try makeHarness(
            keychain: MemoryCoordinatorKeychain(value: "placeholder-key")
        )
        harness.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 4,
                timeControl: .none,
                blunderGuardEnabled: false
            )
        )
        try await eventually {
            if case .ready = harness.coordinator.coachPreparationState {
                return true
            }
            return false
        }
        harness.coordinator.requestHint()
        try await eventually { harness.coordinator.currentHint != nil }
        harness.coordinator.revealHint()
        let originalFEN = harness.coordinator.state.fen

        harness.coordinator.setTeachingPreview(variationRank: 1, step: 1)
        guard case .previewing(_, let rank, let step) =
                harness.coordinator.teachingMoment?.phase
        else {
            Issue.record("Expected variation preview state.")
            return
        }
        #expect(rank == 1)
        #expect(step == 1)
        #expect(harness.coordinator.state.fen == originalFEN)
        #expect(harness.coordinator.state.plyCount == 0)

        harness.coordinator.stepTeachingPreview(by: -1)
        guard case .previewing(_, _, let rewoundStep) =
                harness.coordinator.teachingMoment?.phase
        else {
            Issue.record("Expected rewound variation preview state.")
            return
        }
        #expect(rewoundStep == 0)
        #expect(harness.coordinator.state.fen == originalFEN)

        harness.coordinator.returnFromTeachingPreview()
        guard case .revealed =
                harness.coordinator.teachingMoment?.phase
        else {
            Issue.record("Expected return to the revealed hint.")
            return
        }
        #expect(harness.coordinator.state.fen == originalFEN)
    }

    @Test func mainBoardSnapshotUsesDisposableLessonClone() async throws {
        let harness = try makeHarness(
            keychain: MemoryCoordinatorKeychain(value: "placeholder-key")
        )
        harness.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 4,
                timeControl: .none,
                blunderGuardEnabled: false
            )
        )
        try await eventually {
            if case .ready = harness.coordinator.coachPreparationState {
                return true
            }
            return false
        }
        let liveGameID = try #require(harness.coordinator.activeGame?.id)
        let liveFEN = harness.coordinator.state.fen

        harness.coordinator.requestHint()
        try await eventually { harness.coordinator.currentHint != nil }
        harness.coordinator.revealHint()
        harness.coordinator.setTeachingPreview(variationRank: 1, step: 1)

        let preview = harness.coordinator.chessBoardSnapshot
        #expect(preview.gameID != liveGameID)
        #expect(preview.plyCount == 1)
        #expect(preview.piece(at: "e2") == nil)
        #expect(preview.piece(at: "e4")?.kind == "p")
        #expect(!preview.inputAvailable)
        #expect(harness.coordinator.state.fen == liveFEN)
        #expect(harness.coordinator.state.plyCount == 0)

        #expect(harness.coordinator.handleBoardEscape())
        #expect(harness.coordinator.chessBoardSnapshot.gameID != liveGameID)
        #expect(harness.coordinator.chessBoardSnapshot.inputAvailable)
        #expect(harness.coordinator.state.fen == liveFEN)
        #expect(harness.coordinator.teachingMoment != nil)
        #expect(harness.coordinator.activeClockSide == nil)
    }

    @Test func completedLessonPersistsPerGameAndRestartStartsBlank() async throws {
        let harness = try makeHarness(
            keychain: MemoryCoordinatorKeychain(value: "placeholder-key")
        )
        harness.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 4,
                timeControl: .none,
                blunderGuardEnabled: false
            )
        )
        try await eventually {
            if case .ready = harness.coordinator.coachPreparationState {
                return true
            }
            return false
        }
        let taughtGame = try #require(harness.coordinator.activeGame)
        let taughtFEN = harness.coordinator.state.fen

        harness.coordinator.requestHint()
        try await eventually { harness.coordinator.currentHint != nil }
        harness.coordinator.revealHint()
        harness.coordinator.continueTeachingMoment()

        #expect(harness.coordinator.coachMessages.count == 1)
        let lesson = try #require(
            harness.coordinator.coachMessages.first
        )
        #expect(lesson.role == .coach)
        #expect(lesson.positionFEN == taughtFEN)
        #expect(lesson.structuredReply != nil)
        #expect(taughtGame.coachMessages.count == 1)
        #expect(taughtGame.coachMessages.first?.positionFEN == taughtFEN)
        #expect(taughtGame.coachMessages.first?.structuredContent != nil)

        harness.coordinator.restart()
        #expect(harness.coordinator.coachMessages.isEmpty)
        #expect(harness.coordinator.activeGame?.id != taughtGame.id)

        harness.coordinator.resume(game: taughtGame)
        #expect(harness.coordinator.coachMessages.count == 1)
        #expect(
            harness.coordinator.coachMessages.first?.id == lesson.id
        )
        #expect(
            harness.coordinator.coachMessages.first?.structuredReply
                == lesson.structuredReply
        )

        harness.coordinator.sendChat("Can this abandoned game answer?")
        await drainTasks()
        #expect(harness.coordinator.coachMessages.count == 1)
    }

    @Test func conceptOnlyLessonPersistsWhenContinuingWithoutReveal() async throws {
        let harness = try makeHarness(
            keychain: MemoryCoordinatorKeychain(value: "placeholder-key")
        )
        harness.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 4,
                timeControl: .none,
                blunderGuardEnabled: false
            )
        )
        try await eventually {
            if case .ready = harness.coordinator.coachPreparationState {
                return true
            }
            return false
        }
        let game = try #require(harness.coordinator.activeGame)
        let anchoredFEN = harness.coordinator.state.fen

        harness.coordinator.requestHint()
        try await eventually { harness.coordinator.currentHint != nil }
        guard case .concept =
                harness.coordinator.teachingMoment?.phase
        else {
            Issue.record("Expected a concept-only teaching moment.")
            return
        }

        harness.coordinator.continueTeachingMoment()

        #expect(harness.coordinator.teachingMoment == nil)
        #expect(harness.coordinator.coachMessages.count == 1)
        let lesson = try #require(
            harness.coordinator.coachMessages.first?.structuredReply
        )
        #expect(!lesson.summary.isEmpty)
        #expect(lesson.sections.isEmpty)
        #expect(game.coachMessages.count == 1)
        #expect(game.coachMessages.first?.positionFEN == anchoredFEN)
        #expect(
            game.assistanceEvents.map(\.kind) == [.conceptHint]
        )
    }

    @Test func retryAnalysisAndOfflineInferenceKeepsFallbackReady() async throws {
        let analyst = RetryOnceAnalyst()
        let harness = try makeHarness(
            analyst: analyst,
            inference: ThrowingHintInference(),
            keychain: MemoryCoordinatorKeychain(value: "placeholder-key")
        )
        harness.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 4,
                timeControl: .none,
                blunderGuardEnabled: false
            )
        )
        try await eventually {
            if case .failed = harness.coordinator.coachPreparationState {
                return true
            }
            return false
        }

        harness.coordinator.requestHint()
        #expect(harness.coordinator.teachingMoment == nil)
        harness.coordinator.retryCoachPreparation()
        try await eventually {
            guard case .ready(let prepared) =
                    harness.coordinator.coachPreparationState
            else {
                return false
            }
            return prepared.enhancement == .unavailable
        }
        harness.coordinator.requestHint()
        try await eventually { harness.coordinator.currentHint != nil }

        let hint = try #require(harness.coordinator.currentHint)
        #expect(hint.source == "Stockfish fallback")
        #expect(hint.recommendedMove == "e2e4")
        guard case .concept =
                harness.coordinator.teachingMoment?.phase
        else {
            Issue.record("Expected deterministic concept fallback.")
            return
        }
        #expect(
            harness.coordinator.activeGame?.assistanceEvents.map(\.kind)
                == [.conceptHint]
        )
    }

    @Test func restartInvalidatesPreparedAndActiveTeachingState() async throws {
        let harness = try makeHarness(
            keychain: MemoryCoordinatorKeychain(value: "placeholder-key")
        )
        harness.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 4,
                timeControl: .none,
                blunderGuardEnabled: false
            )
        )
        try await eventually {
            if case .ready = harness.coordinator.coachPreparationState {
                return true
            }
            return false
        }
        let originalGameID = try #require(harness.coordinator.activeGame?.id)
        harness.coordinator.requestHint()
        try await eventually { harness.coordinator.currentHint != nil }

        harness.coordinator.restart()
        #expect(harness.coordinator.activeGame?.id != originalGameID)
        #expect(harness.coordinator.teachingMoment == nil)
        #expect(harness.coordinator.currentHint == nil)
        #expect(harness.coordinator.hintArrow == nil)
        try await eventually {
            if case .ready(let prepared) =
                harness.coordinator.coachPreparationState {
                return prepared.anchor.gameID
                    == harness.coordinator.activeGame?.id
            }
            return false
        }
        guard case .ready(let restartedPreparation) =
                harness.coordinator.coachPreparationState
        else {
            Issue.record("Expected preparation for the restarted game.")
            return
        }
        #expect(restartedPreparation.anchor.gameID != originalGameID)
    }

    @Test func typedCoachReplyAppearsAndPersistsAtomically() async throws {
        let inference = ControlledReplyInference()
        let harness = try makeHarness(
            inference: inference,
            keychain: MemoryCoordinatorKeychain(value: "placeholder-key")
        )
        harness.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 4,
                timeControl: .none,
                blunderGuardEnabled: false
            )
        )
        try await eventually {
            if case .ready = harness.coordinator.coachPreparationState {
                return true
            }
            return false
        }

        harness.coordinator.sendChat("What is the plan?")
        try await eventually { inference.isWaitingForReply }
        #expect(harness.coordinator.coachMessages.count == 2)
        #expect(harness.coordinator.coachMessages[0].role == .user)
        #expect(harness.coordinator.coachMessages[1].role == .coach)
        #expect(harness.coordinator.coachMessages[1].text.isEmpty)
        #expect(
            harness.coordinator.activeGame?.coachMessages.isEmpty == true
        )

        inference.complete(
            with: CoachReply(
                sections: [
                    CoachReplySection(
                        kind: .plan,
                        title: "Plan",
                        body: "Develop, control the center, and castle.",
                        variationRank: nil
                    )
                ]
            )
        )
        try await eventually {
            harness.coordinator.coachMessages.last?.text
                == "Plan: Develop, control the center, and castle."
        }
        #expect(
            harness.coordinator.coachMessages.last?.text
                == "Plan: Develop, control the center, and castle."
        )
        #expect(
            harness.coordinator.activeGame?.coachMessages.contains {
                $0.text == "Plan: Develop, control the center, and castle."
            } == true
        )
    }

    @Test func historyPreviewBrowsingDoesNotMutateLiveGame() async throws {
        let opponent = ScriptedEngine(opponentMoves: ["e7e5", "b8c6"])
        let harness = try makeHarness(opponent: opponent)
        harness.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 4,
                timeControl: .none,
                blunderGuardEnabled: false
            )
        )
        play("e2", "e4", on: harness.coordinator)
        try await eventually { harness.coordinator.state.plyCount == 2 }
        play("g1", "f3", on: harness.coordinator)
        try await eventually { harness.coordinator.state.plyCount == 4 }

        let game = try #require(harness.coordinator.activeGame)
        let liveFEN = harness.coordinator.state.fen
        let liveMoves = harness.coordinator.state.uciMoves
        let liveClocks = harness.coordinator.clocks
        let liveClockSide = harness.coordinator.activeClockSide
        let livePGN = game.pgn
        let liveRevision = harness.coordinator.boardPositionRevision

        #expect(harness.coordinator.selectHistoryPreview(ply: 2))
        #expect(harness.coordinator.historyPreview?.selectedPly == 2)
        #expect(!harness.coordinator.canPlayerMove)
        #expect(harness.coordinator.stepHistoryPreview(by: -1))
        #expect(harness.coordinator.historyPreview?.selectedPly == 1)
        #expect(harness.coordinator.stepHistoryPreview(by: 1))
        #expect(harness.coordinator.historyPreview?.selectedPly == 2)

        #expect(harness.coordinator.state.fen == liveFEN)
        #expect(harness.coordinator.state.uciMoves == liveMoves)
        #expect(harness.coordinator.clocks == liveClocks)
        #expect(harness.coordinator.activeClockSide == liveClockSide)
        #expect(harness.coordinator.boardPositionRevision == liveRevision)
        #expect(game.sortedPlies.count == 4)
        #expect(game.pgn == livePGN)
        #expect(!game.assistanceUsed)
        #expect(game.assistanceEvents.isEmpty)

        harness.coordinator.returnToLivePosition()
        #expect(harness.coordinator.historyPreview == nil)
        #expect(harness.coordinator.canPlayerMove)
        #expect(game.sortedPlies.count == 4)
    }

    @Test func confirmedHistoryRewindRestoresAndPersistsSelectedPosition() async throws {
        let opponent = ScriptedEngine(opponentMoves: ["e7e5", "b8c6"])
        let clock = ManualGameClock()
        let harness = try makeHarness(opponent: opponent, clock: clock)
        harness.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 4,
                timeControl: .rapid10,
                blunderGuardEnabled: false
            )
        )
        await drainTasks()
        await clock.advance(by: 2_000)
        play("e2", "e4", on: harness.coordinator)
        try await eventually { harness.coordinator.state.plyCount == 2 }

        let game = try #require(harness.coordinator.activeGame)
        let selectedClock = try #require(game.sortedPlies.last?.clockAfter)
        let selectedFEN = try #require(game.sortedPlies.last?.fenAfter)
        await clock.advance(by: 3_000)
        play("g1", "f3", on: harness.coordinator)
        try await eventually { harness.coordinator.state.plyCount == 4 }

        let keptMessage = CoachMessage(
            role: .coach,
            text: "Keep this position note.",
            ply: 2,
            positionFEN: selectedFEN
        )
        let discardedMessage = CoachMessage(
            role: .coach,
            text: "Discard this continuation note.",
            ply: 4,
            positionFEN: harness.coordinator.state.fen
        )
        harness.persistence.append(keptMessage, to: game)
        harness.persistence.append(discardedMessage, to: game)
        harness.coordinator.resume(game: game)
        #expect(harness.coordinator.coachMessages.count == 2)

        let liveRevision = harness.coordinator.boardPositionRevision
        let liveClock = harness.coordinator.clocks
        #expect(harness.coordinator.selectHistoryPreview(ply: 2))
        // Reviewing during a live game keeps its authoritative countdown
        // visible. Confirming the rewind still restores the selected snapshot.
        #expect(harness.coordinator.displayedClocks == liveClock)
        #expect(harness.coordinator.clocks == liveClock)
        #expect(game.sortedPlies.count == 4)
        #expect(harness.coordinator.rewindToHistoryPreview())

        #expect(harness.coordinator.historyPreview == nil)
        #expect(harness.coordinator.boardPositionRevision == liveRevision + 1)
        #expect(harness.coordinator.state.plyCount == 2)
        #expect(harness.coordinator.state.uciMoves == ["e2e4", "e7e5"])
        #expect(harness.coordinator.state.fen == selectedFEN)
        #expect(harness.coordinator.clocks == selectedClock)
        #expect(harness.coordinator.activeClockSide == .white)
        #expect(harness.coordinator.status.result == .inProgress)

        #expect(game.sortedPlies.map(\.uci) == ["e2e4", "e7e5"])
        #expect(game.currentFEN == selectedFEN)
        #expect(game.result == .inProgress)
        #expect(game.endReason == .none)
        #expect(game.endedAt == nil)
        #expect(!game.reviewCompleted)
        #expect(game.assistanceUsed)
        #expect(
            game.assistanceEvents.contains {
                $0.kind == .takeBack && $0.ply == 2
            }
        )
        #expect(game.coachMessages.map(\.text) == ["Keep this position note."])
        #expect(
            harness.coordinator.coachMessages.map(\.text)
                == ["Keep this position note."]
        )
        #expect(game.pgn.contains("e4 e5"))
        #expect(!game.pgn.contains("Nf3"))
        #expect(!game.pgn.contains("Nc6"))
    }

    @Test func completedHistoryReviewProjectsSelectedClockSnapshot() async throws {
        let opponent = ScriptedEngine(opponentMoves: ["e7e5"])
        let clock = ManualGameClock()
        let harness = try makeHarness(opponent: opponent, clock: clock)
        harness.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 4,
                timeControl: .rapid10,
                blunderGuardEnabled: false
            )
        )

        await drainTasks()
        await clock.advance(by: 2_000)
        play("e2", "e4", on: harness.coordinator)
        try await eventually { harness.coordinator.state.plyCount == 2 }

        let game = try #require(harness.coordinator.activeGame)
        let selectedClock = try #require(
            game.sortedPlies.first?.clockAfter
        )
        clock.elapseWithoutTick(by: 3_000)
        harness.coordinator.resign()
        let completedClock = harness.coordinator.clocks
        #expect(completedClock != selectedClock)

        #expect(harness.coordinator.selectHistoryPreview(ply: 1))
        #expect(harness.coordinator.displayedClocks == selectedClock)
        #expect(harness.coordinator.clocks == completedClock)
    }

    @Test func historyRewindReopensCompletedGameAndRestartsOpponentTurn() async throws {
        let opponent = BlockingOpponentEngine()
        let harness = try makeHarness(opponent: opponent)
        harness.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 4,
                timeControl: .none,
                blunderGuardEnabled: false
            )
        )
        play("e2", "e4", on: harness.coordinator)
        try await eventually { harness.coordinator.state.plyCount == 1 }
        await opponent.completeNext(with: "e7e5")
        try await eventually { harness.coordinator.state.plyCount == 2 }

        let game = try #require(harness.coordinator.activeGame)
        harness.coordinator.resign()
        #expect(harness.coordinator.status.result == .blackWon)
        #expect(game.endedAt != nil)
        game.reviewCompleted = true
        game.profileIncorporated = true
        LearnerProfileService().incorporate(
            game: game,
            into: harness.persistence.profile
        )
        harness.persistence.save()
        #expect(harness.persistence.profile.reviewedGames == 1)
        #expect(harness.coordinator.selectHistoryPreview(ply: 1))
        #expect(harness.coordinator.rewindToHistoryPreview())

        #expect(harness.coordinator.state.uciMoves == ["e2e4"])
        #expect(harness.coordinator.state.sideToMove == .black)
        #expect(harness.coordinator.status.result == .inProgress)
        #expect(game.result == .inProgress)
        #expect(game.endReason == .none)
        #expect(game.endedAt == nil)
        #expect(!game.reviewCompleted)
        #expect(!game.profileIncorporated)
        #expect(harness.persistence.profile.reviewedGames == 0)
        #expect(harness.coordinator.isEngineThinking)
        #expect(harness.coordinator.activeClockSide == nil)
        #expect(harness.coordinator.historyPreview == nil)
        #expect(game.assistanceUsed)
        #expect(
            game.assistanceEvents.contains {
                $0.kind == .takeBack && $0.ply == 1
            }
        )

        try await eventually {
            harness.coordinator.isEngineThinking
        }
        await opponent.completeNext(with: "c7c5")
        try await eventually { harness.coordinator.state.plyCount == 2 }
        #expect(harness.coordinator.state.uciMoves == ["e2e4", "c7c5"])
        #expect(harness.coordinator.state.sideToMove == .white)
        #expect(harness.coordinator.activeClockSide == .white)
    }

    @Test func historyRewindRejectsInvalidAndStaleSelections() async throws {
        let opponent = BlockingOpponentEngine()
        let harness = try makeHarness(opponent: opponent)
        harness.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 4,
                timeControl: .none,
                blunderGuardEnabled: false
            )
        )

        #expect(!harness.coordinator.selectHistoryPreview(ply: -1))
        #expect(!harness.coordinator.selectHistoryPreview(ply: 1))
        #expect(harness.coordinator.selectHistoryPreview(ply: 0))
        #expect(harness.coordinator.historyPreview == nil)
        #expect(!harness.coordinator.rewindToHistoryPreview())

        play("e2", "e4", on: harness.coordinator)
        try await eventually { harness.coordinator.state.plyCount == 1 }
        #expect(harness.coordinator.selectHistoryPreview(ply: 0))
        #expect(harness.coordinator.historyPreview != nil)

        await opponent.completeNext(with: "e7e5")
        try await eventually { harness.coordinator.state.plyCount == 2 }
        #expect(harness.coordinator.historyPreview == nil)
        #expect(!harness.coordinator.rewindToHistoryPreview())
        #expect(!harness.coordinator.selectHistoryPreview(ply: -1))
        #expect(!harness.coordinator.selectHistoryPreview(ply: 3))
        #expect(harness.coordinator.selectHistoryPreview(ply: 2))
        #expect(harness.coordinator.historyPreview == nil)
        #expect(!harness.coordinator.rewindToHistoryPreview())

        #expect(harness.coordinator.selectHistoryPreview(ply: 1))
        harness.coordinator.restart()
        #expect(harness.coordinator.historyPreview == nil)
        #expect(!harness.coordinator.rewindToHistoryPreview())
    }

    private func makeHarness(
        opponent: any ChessEngineServing = ScriptedEngine(),
        analyst: any ChessEngineServing = ScriptedEngine(),
        inference: any CoachInferenceServing = StubInference(),
        clock: any GameClockServing = ManualGameClock(),
        keychain: any KeychainStoring = MemoryCoordinatorKeychain()
    ) throws -> CoordinatorHarness {
        let persistence = PersistenceController(inMemory: true)
        let suiteName = "ChessCoachTests.Coordinator.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set("test-model", forKey: "ai.modelID")
        let settings = InferenceSettings(defaults: defaults, keychain: keychain)
        let coordinator = GameCoordinator(
            persistence: persistence,
            inferenceSettings: settings,
            opponent: opponent,
            analyst: analyst,
            inference: inference,
            clock: clock
        )
        return CoordinatorHarness(
            coordinator: coordinator,
            persistence: persistence,
            defaults: defaults,
            suiteName: suiteName
        )
    }

    private func play(
        _ from: String,
        _ to: String,
        on coordinator: GameCoordinator
    ) {
        coordinator.selectOrMove(square: from)
        coordinator.selectOrMove(square: to)
    }

    private func eventually(
        _ condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<2_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Condition did not become true.")
    }

    private func drainTasks() async {
        for _ in 0..<20 {
            await Task.yield()
        }
    }
}

@MainActor
private struct CoordinatorHarness {
    let coordinator: GameCoordinator
    let persistence: PersistenceController
    let defaults: UserDefaults
    let suiteName: String

    init(
        coordinator: GameCoordinator,
        persistence: PersistenceController,
        defaults: UserDefaults,
        suiteName: String
    ) {
        self.coordinator = coordinator
        self.persistence = persistence
        self.defaults = defaults
        self.suiteName = suiteName
    }
}

private actor ScriptedEngine: ChessEngineServing {
    private var opponentMoves: [String]
    private let analysisScores: [String: Double]
    private let defaultAnalysisScore: Double

    init(
        opponentMoves: [String] = [],
        analysisScores: [String: Double] = [:],
        defaultAnalysisScore: Double = 0.55
    ) {
        self.opponentMoves = opponentMoves
        self.analysisScores = analysisScores
        self.defaultAnalysisScore = defaultAnalysisScore
    }

    func analyze(
        fen: String,
        multiPV: Int,
        moveTimeMilliseconds: Int
    ) async throws -> PositionAnalysis {
        let state = ChessGameState(initialFEN: fen)
        let preferred = state.legalMoves.first(where: { $0 == "e2e4" })
            ?? state.legalMoves.first
            ?? ""
        let expected = analysisScores[fen] ?? defaultAnalysisScore
        let win = Int((expected * 1_000).rounded())
        return PositionAnalysis(
            fen: fen,
            sideToMove: state.sideToMove,
            bestMove: preferred,
            variations: [
                PrincipalVariation(
                    index: 1,
                    depth: 18,
                    score: EngineScore(centipawns: 20),
                    wdl: WDL(win: win, draw: 0, loss: 1_000 - win),
                    moves: preferred.isEmpty ? [] : [preferred]
                )
            ]
        )
    }

    func opponentMove(
        fen: String,
        difficulty: Int,
        clocks: ClockSnapshot,
        timeControl: TimeControl
    ) async throws -> String {
        if !opponentMoves.isEmpty {
            return opponentMoves.removeFirst()
        }
        let state = ChessGameState(initialFEN: fen)
        return state.legalMoves.first ?? ""
    }

    func stopThinking() {}
    func shutdown() {}
}

private actor BlockingOpponentEngine: ChessEngineServing {
    private var pending: [CheckedContinuation<String, Error>] = []
    private var queuedMoves: [String] = []

    func analyze(
        fen: String,
        multiPV: Int,
        moveTimeMilliseconds: Int
    ) async throws -> PositionAnalysis {
        try await ScriptedEngine().analyze(
            fen: fen,
            multiPV: multiPV,
            moveTimeMilliseconds: moveTimeMilliseconds
        )
    }

    func opponentMove(
        fen: String,
        difficulty: Int,
        clocks: ClockSnapshot,
        timeControl: TimeControl
    ) async throws -> String {
        if !queuedMoves.isEmpty {
            return queuedMoves.removeFirst()
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending.append(continuation)
        }
    }

    func completeNext(with move: String) {
        if pending.isEmpty {
            queuedMoves.append(move)
        } else {
            pending.removeFirst().resume(returning: move)
        }
    }

    var pendingRequestCount: Int {
        pending.count
    }

    func stopThinking() {}
    func shutdown() {}
}

private actor FailingOpponentEngine: ChessEngineServing {
    func analyze(
        fen: String,
        multiPV: Int,
        moveTimeMilliseconds: Int
    ) async throws -> PositionAnalysis {
        try await ScriptedEngine().analyze(
            fen: fen,
            multiPV: multiPV,
            moveTimeMilliseconds: moveTimeMilliseconds
        )
    }

    func opponentMove(
        fen: String,
        difficulty: Int,
        clocks: ClockSnapshot,
        timeControl: TimeControl
    ) async throws -> String {
        throw CoordinatorEngineFailure()
    }

    func stopThinking() {}
    func shutdown() {}
}

private struct CoordinatorEngineFailure: LocalizedError {
    var errorDescription: String? {
        "The test engine stopped."
    }
}

private actor RetryOnceAnalyst: ChessEngineServing {
    private var requestCount = 0

    func analyze(
        fen: String,
        multiPV: Int,
        moveTimeMilliseconds: Int
    ) async throws -> PositionAnalysis {
        requestCount += 1
        if requestCount == 1 {
            throw CoordinatorEngineFailure()
        }
        return try await ScriptedEngine().analyze(
            fen: fen,
            multiPV: multiPV,
            moveTimeMilliseconds: moveTimeMilliseconds
        )
    }

    func opponentMove(
        fen: String,
        difficulty: Int,
        clocks: ClockSnapshot,
        timeControl: TimeControl
    ) async throws -> String {
        throw CoordinatorEngineFailure()
    }

    func stopThinking() {}
    func shutdown() {}
}

private struct ThrowingHintInference: CoachInferenceServing {
    func generateHint(
        configuration: InferenceConfiguration,
        credential: String,
        context: CoachContext
    ) async throws -> CoachHint {
        throw InferenceError.offline
    }

    func streamChat(
        configuration: InferenceConfiguration,
        credential: String,
        context: CoachContext,
        history: [CoachMessage]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: InferenceError.offline)
        }
    }
}

private final class BlockingHintInference:
    CoachInferenceServing,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var hintContinuations:
        [Int: CheckedContinuation<CoachHint, any Error>] = [:]
    private var requests = 0

    var requestCount: Int {
        lock.withLock { requests }
    }

    func generateHint(
        configuration: InferenceConfiguration,
        credential: String,
        context: CoachContext
    ) async throws -> CoachHint {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                requests += 1
                hintContinuations[requests] = continuation
            }
        }
    }

    func complete(recommendedMove: String, source: String) {
        let requestNumber = lock.withLock {
            hintContinuations.keys.min()
        }
        guard let requestNumber else { return }
        complete(
            requestNumber: requestNumber,
            recommendedMove: recommendedMove,
            source: source
        )
    }

    func complete(
        requestNumber: Int,
        recommendedMove: String,
        source: String
    ) {
        let continuation = lock.withLock {
            hintContinuations.removeValue(forKey: requestNumber)
        }
        continuation?.resume(
            returning: CoachHint(
                concept: "Use the prepared coaching idea.",
                why: "The engine line supports it.",
                plan: "Improve coordination.",
                likelyReply: "The opponent contests the idea.",
                watchFor: "Forcing replies.",
                recommendedMove: recommendedMove,
                source: source
            )
        )
    }

    func streamChat(
        configuration: InferenceConfiguration,
        credential: String,
        context: CoachContext,
        history: [CoachMessage]
    ) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { $0.finish() }
    }
}

private struct StubInference: CoachInferenceServing {
    func generateHint(
        configuration: InferenceConfiguration,
        credential: String,
        context: CoachContext
    ) async throws -> CoachHint {
        CoachHint(
            concept: "Claim central space and open lines for your pieces.",
            why: "It improves development.",
            plan: "Develop and castle.",
            likelyReply: "The opponent contests the center.",
            watchFor: "A counterattack on the center.",
            recommendedMove: context.recommendedMove,
            source: "Stub"
        )
    }

    func streamChat(
        configuration: InferenceConfiguration,
        credential: String,
        context: CoachContext,
        history: [CoachMessage]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield("Control ")
            continuation.yield("the center.")
            continuation.finish()
        }
    }
}

private final class ControlledReplyInference:
    CoachInferenceServing,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var replyContinuation:
        CheckedContinuation<CoachReply, any Error>?

    var isWaitingForReply: Bool {
        lock.withLock { replyContinuation != nil }
    }

    func generateHint(
        configuration: InferenceConfiguration,
        credential: String,
        context: CoachContext
    ) async throws -> CoachHint {
        CoachHint(
            concept: "Improve the least active piece.",
            why: "Coordination makes every later tactic stronger.",
            plan: "Develop and castle.",
            likelyReply: "The opponent contests the center.",
            watchFor: "Loose central pawns.",
            recommendedMove: context.recommendedMove,
            source: "Controlled test"
        )
    }

    func streamChat(
        configuration: InferenceConfiguration,
        credential: String,
        context: CoachContext,
        history: [CoachMessage]
    ) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func generateReply(
        configuration: InferenceConfiguration,
        credential: String,
        context: CoachContext,
        history: [CoachMessage]
    ) async throws -> CoachReply {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock {
                replyContinuation = continuation
            }
        }
    }

    func complete(with reply: CoachReply) {
        let continuation = lock.withLock {
            let continuation = replyContinuation
            replyContinuation = nil
            return continuation
        }
        continuation?.resume(returning: reply)
    }
}

private final class MemoryCoordinatorKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]

    init(value: String? = nil) {
        self.values = value.map { [InferenceProviderKind.openAI.rawValue: $0] } ?? [:]
    }

    func read(account: String) throws -> String? {
        lock.withLock { values[account] }
    }

    func save(_ value: String, account: String) throws {
        lock.withLock {
            values[account] = value
        }
    }

    func delete(account: String) throws {
        lock.withLock {
            values[account] = nil
        }
    }
}

private final class ManualGameClock: GameClockServing, @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000)
    private var sleepers: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var cancelledSleepers: Set<UUID> = []

    func now() -> Date {
        lock.withLock { current }
    }

    func sleepForTick() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeImmediately = lock.withLock {
                    if Task.isCancelled || cancelledSleepers.remove(id) != nil {
                        return true
                    }
                    sleepers[id] = continuation
                    return false
                }
                if resumeImmediately {
                    continuation.resume()
                }
            }
        } onCancel: {
            let continuation: CheckedContinuation<Void, Never>? = lock.withLock {
                if let continuation = sleepers.removeValue(forKey: id) {
                    return Optional(continuation)
                }
                cancelledSleepers.insert(id)
                return nil
            }
            continuation?.resume()
        }
    }

    deinit {
        let pending = lock.withLock {
            let pending = Array(sleepers.values)
            sleepers.removeAll()
            cancelledSleepers.removeAll()
            return pending
        }
        for continuation in pending {
            continuation.resume()
        }
    }

    func advance(by milliseconds: Int) async {
        let pending: [CheckedContinuation<Void, Never>] = lock.withLock {
            current = current.addingTimeInterval(Double(milliseconds) / 1_000)
            let pending = Array(sleepers.values)
            sleepers.removeAll()
            return pending
        }
        for continuation in pending {
            continuation.resume()
        }
        await Task.yield()
    }

    func elapseWithoutTick(by milliseconds: Int) {
        lock.withLock {
            current = current.addingTimeInterval(Double(milliseconds) / 1_000)
        }
    }
}
