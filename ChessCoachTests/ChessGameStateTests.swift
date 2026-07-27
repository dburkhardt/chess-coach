import Testing
@testable import ChessCoach

struct ChessGameStateTests {
    @Test func openingMoveRoundTripProducesSANFENAndPGN() throws {
        let game = ChessGameState()
        let move = try game.make(uci: "e2e4")

        #expect(move.san == "e4")
        #expect(game.fen.contains(" b KQkq e3 "))
        #expect(game.pgn(playerSide: .white, result: .inProgress).contains("1. e4 *"))
    }

    @Test func castlingIsLegalAndSerialized() throws {
        let game = ChessGameState(
            initialFEN: "r3k2r/8/8/8/8/8/8/R3K2R w KQkq - 0 1"
        )
        let move = try game.make(uci: "e1g1")
        #expect(move.san == "O-O")
        #expect(game.piece(at: "g1")?.kind == "k")
        #expect(game.piece(at: "f1")?.kind == "r")
    }

    @Test func enPassantAndPromotionAreSupported() throws {
        let enPassant = ChessGameState(
            initialFEN: "8/8/8/3pP3/8/8/8/K6k w - d6 0 1"
        )
        #expect(enPassant.legalMoves.contains("e5d6"))
        _ = try enPassant.make(uci: "e5d6")
        #expect(enPassant.piece(at: "d5") == nil)

        let promotion = ChessGameState(
            initialFEN: "7k/P7/8/8/8/8/8/K7 w - - 0 1"
        )
        #expect(promotion.legalMoves.contains("a7a8q"))
        _ = try promotion.make(uci: "a7a8q")
        #expect(promotion.piece(at: "a8")?.kind == "q")
    }

    @Test func checkmateStalemateAndInsufficientMaterial() {
        let mate = ChessGameState(
            initialFEN: "7k/6Q1/6K1/8/8/8/8/8 b - - 0 1"
        )
        #expect(mate.status().reason == .checkmate)
        #expect(mate.status().result == .whiteWon)

        let stalemate = ChessGameState(
            initialFEN: "7k/5Q2/6K1/8/8/8/8/8 b - - 0 1"
        )
        #expect(stalemate.status().reason == .stalemate)
        #expect(stalemate.status().result == .draw)

        let kings = ChessGameState(
            initialFEN: "7k/8/8/8/8/8/8/K7 w - - 0 1"
        )
        #expect(kings.status().reason == .insufficientMaterial)
    }

    @Test func repeatableRebuildTruncatesTheLine() throws {
        let game = ChessGameState()
        for move in ["e2e4", "e7e5", "g1f3", "b8c6"] {
            _ = try game.make(uci: move)
        }
        let rebuilt = game.rebuilt(keeping: 2)
        #expect(rebuilt.uciMoves == ["e2e4", "e7e5"])
        #expect(rebuilt.sideToMove == .white)
    }

    @Test func detectsThreefoldRepetitionAndFiftyMoveRule() throws {
        let repetition = ChessGameState()
        for move in [
            "g1f3", "g8f6", "f3g1", "f6g8",
            "g1f3", "g8f6", "f3g1", "f6g8",
        ] {
            _ = try repetition.make(uci: move)
        }
        #expect(repetition.status().reason == .repetition)

        let fiftyMove = ChessGameState(
            initialFEN: "8/8/8/8/8/8/R7/K6k w - - 100 51"
        )
        #expect(fiftyMove.status().reason == .fiftyMoveRule)
    }

    @MainActor
    @Test func coachingContextContainsAuthoritativePositionAndProfile() {
        let persistence = PersistenceController(inMemory: true)
        let state = ChessGameState()
        let analysis = PositionAnalysis(
            fen: state.fen,
            sideToMove: .white,
            bestMove: "e2e4",
            variations: [
                PrincipalVariation(
                    index: 1,
                    depth: 18,
                    score: EngineScore(centipawns: 24),
                    wdl: WDL(win: 260, draw: 610, loss: 130),
                    moves: ["e2e4", "e7e5", "g1f3"]
                )
            ]
        )
        let context = CoachContextBuilder().build(
            purpose: "test",
            state: state,
            analysis: analysis,
            playerSide: .white,
            clocks: .initial(for: .rapid10),
            control: .rapid10,
            profile: persistence.profile
        )

        #expect(context.version == 2)
        #expect(context.fen == state.fen)
        #expect(context.pgn.contains("[White \"You\"]"))
        #expect(context.recommendedMove == "e2e4")
        #expect(context.recommendedMoveFacts?.san == "e4")
        #expect(context.recommendedMoveFacts?.isCentralPawnMove == true)
        #expect(context.recommendedMoveFacts?.givesCheck == false)
        #expect(context.variations.first?.sanLine == ["e4", "e5", "Nf3"])
        #expect(context.variations.first?.expectedScore == 0.565)
        #expect(context.learner.estimatedElo == "Calibrating")
        #expect(context.whiteClock == "10:00")
    }

    @MainActor
    @Test func h3HintChallengesBishopInsteadOfSuggestingUnrelatedChecks() throws {
        let state = ChessGameState()
        for move in [
            "e2e4", "d7d5",
            "e4d5", "g8f6",
            "g1f3", "c8g4",
            "f1b5", "b8d7",
        ] {
            _ = try state.make(uci: move)
        }
        let analysis = PositionAnalysis(
            fen: state.fen,
            sideToMove: .white,
            bestMove: "h2h3",
            variations: [
                PrincipalVariation(
                    index: 1,
                    depth: 20,
                    score: EngineScore(centipawns: 100),
                    wdl: WDL(win: 370, draw: 520, loss: 110),
                    moves: ["h2h3", "g4h5"]
                )
            ]
        )
        let persistence = PersistenceController(inMemory: true)
        let context = CoachContextBuilder().build(
            purpose: "exact h3 screenshot regression",
            state: state,
            analysis: analysis,
            playerSide: .white,
            clocks: .initial(for: .none),
            control: .none,
            profile: persistence.profile
        )

        let facts = try #require(context.recommendedMoveFacts)
        #expect(facts.uci == "h2h3")
        #expect(facts.san == "h3")
        #expect(facts.newlyAttackedPieces.contains {
            $0.contains("black bishop")
        })
        #expect(!facts.givesCheck)
        #expect(!facts.isCapture)

        let hint = DeterministicHintBuilder().build(context: context)
        let concept = hint.concept.lowercased()
        #expect(concept.contains("bishop"))
        #expect(concept.contains("challenge"))
        #expect(!concept.contains("check"))
        #expect(hint.why.lowercased().contains("bishop"))
        #expect(hint.plan.lowercased().contains("tempo"))
        #expect(hint.recommendedMove == "h2h3")
    }

    @MainActor
    @Test func coachingContextExpectedScoresUseBlackPlayerPerspective() throws {
        let persistence = PersistenceController(inMemory: true)
        let state = ChessGameState()
        _ = try state.make(uci: "e2e4")
        let analysis = PositionAnalysis(
            fen: state.fen,
            sideToMove: .black,
            bestMove: "e7e5",
            variations: [
                PrincipalVariation(
                    index: 1,
                    depth: 18,
                    score: EngineScore(centipawns: 40),
                    wdl: WDL(win: 650, draw: 200, loss: 150),
                    moves: ["e7e5", "g1f3"]
                ),
                PrincipalVariation(
                    index: 2,
                    depth: 18,
                    score: EngineScore(centipawns: 20),
                    wdl: WDL(win: 500, draw: 300, loss: 200),
                    moves: ["c7c5", "g1f3"]
                ),
                PrincipalVariation(
                    index: 3,
                    depth: 18,
                    score: EngineScore(centipawns: 10),
                    wdl: nil,
                    moves: ["e7e6", "d2d4"]
                ),
            ]
        )

        let context = CoachContextBuilder().build(
            purpose: "black perspective test",
            state: state,
            analysis: analysis,
            playerSide: .black,
            clocks: .initial(for: .rapid10),
            control: .rapid10,
            profile: persistence.profile
        )

        #expect(context.playerColor == "black")
        #expect(context.sideToMove == "black")
        #expect(context.variations.map(\.expectedScore) == [0.25, 0.35, nil])
    }

    @MainActor
    @Test func persistenceTruncatesPositionChatAndExcludesAssistedRating() {
        let persistence = PersistenceController(inMemory: true)
        let configuration = NewGameConfiguration(
            colorChoice: .white,
            difficulty: 4,
            timeControl: .rapid10,
            blunderGuardEnabled: false
        )
        let game = persistence.createGame(
            configuration: configuration,
            playerSide: .white,
            initialFEN: ChessGameState.standardInitialFEN
        )
        let clock = ClockSnapshot.initial(for: .rapid10)
        let ply = SavedPly(
            index: 0,
            side: .white,
            uci: "e2e4",
            san: "e4",
            fenBefore: ChessGameState.standardInitialFEN,
            fenAfter: ChessGameState(initialFEN: ChessGameState.standardInitialFEN, moves: ["e2e4"]).fen,
            clockBefore: clock,
            clockAfter: clock
        )
        ply.classification = .good
        persistence.append(ply, to: game)
        persistence.append(
            CoachMessage(role: .coach, text: "Position-specific", ply: 1),
            to: game
        )
        persistence.truncate(game: game, toPlyCount: 0)
        #expect(game.plies.isEmpty)
        #expect(game.coachMessages.isEmpty)

        game.result = .whiteWon
        game.assistanceUsed = true
        LearnerProfileService().incorporate(game: game, into: persistence.profile)
        #expect(persistence.profile.reviewedGames == 1)
        #expect(persistence.profile.eligibleGames == 0)

        game.assistanceUsed = false
        LearnerProfileService().incorporate(game: game, into: persistence.profile)
        #expect(persistence.profile.reviewedGames == 2)
        #expect(persistence.profile.eligibleGames == 1)
    }
}
