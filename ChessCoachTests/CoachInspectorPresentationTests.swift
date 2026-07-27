import Foundation
import Testing
@testable import ChessCoach

struct CoachInspectorPresentationTests {
    private let resolver = CoachInspectorPresentationResolver()

    @Test func resolverChoosesExactlyOneSceneByContext() {
        let neutral = resolver.resolve(
            snapshot(isCurrentGameVisible: false, hasActiveGame: true)
        )
        #expect(neutral.scene == .neutral)

        let empty = resolver.resolve(
            snapshot(isCurrentGameVisible: true, hasActiveGame: false)
        )
        #expect(empty.scene == .empty)

        let completed = resolver.resolve(
            snapshot(gameResult: .whiteWon)
        )
        #expect(completed.scene == .completed)

        let warning = resolver.resolve(
            snapshot(hasBlunderWarning: true)
        )
        #expect(warning.scene == .warning)

        let lesson = resolver.resolve(
            snapshot(teachingMoment: teachingMoment())
        )
        #expect(lesson.scene == .lesson)

        let live = resolver.resolve(snapshot())
        #expect(live.scene == .live)

        for presentation in [
            neutral, empty, completed, warning, lesson, live,
        ] {
            #expect(
                presentation.commands.filter { $0.style == .primary }.count <= 1
            )
        }
    }

    @Test func liveReadinessMapsToOneStatusAndOneAction() throws {
        let anchor = anchor()
        let analyzing = resolver.resolve(
            snapshot(preparationState: .analyzing(anchor))
        )
        #expect(analyzing.header.status == "Analyzing position")
        #expect(analyzing.commands.isEmpty)

        let polishing = resolver.resolve(
            snapshot(
                preparationState: .ready(
                    prepared(anchor: anchor, enhancement: .preparing)
                )
            )
        )
        #expect(polishing.header.status == "Hint ready · Coach polishing")
        #expect(polishing.primaryCommand?.action == .openHint)

        let coachReady = resolver.resolve(
            snapshot(
                preparationState: .ready(
                    prepared(anchor: anchor, enhancement: .ready)
                )
            )
        )
        #expect(coachReady.header.status == "Coach hint ready")

        let stockfishReady = resolver.resolve(
            snapshot(
                preparationState: .ready(
                    prepared(anchor: anchor, enhancement: .unavailable)
                )
            )
        )
        #expect(stockfishReady.header.status == "Stockfish hint ready")

        let failed = resolver.resolve(
            snapshot(
                preparationState: .failed(anchor, message: "engine exited")
            )
        )
        #expect(failed.header.status == "Coaching unavailable")
        #expect(failed.primaryCommand?.action == .retryAnalysis)

        let unavailable = resolver.resolve(
            snapshot(
                chatState: .unavailable(
                    message: "Configure an AI provider in Settings."
                )
            )
        )
        #expect(unavailable.header.status == "Coaching unavailable")
    }

    @Test func teachingCommandsStayFocusedByPhase() {
        let concept = resolver.resolve(
            snapshot(teachingMoment: teachingMoment())
        )
        #expect(concept.header.status == "Teaching moment · paused")
        #expect(concept.primaryCommand?.action == .revealMove)
        #expect(concept.commands.contains { $0.action == .continuePlaying })

        var revealedMoment = teachingMoment()
        revealedMoment.phase = .revealed(hint())
        let revealed = resolver.resolve(
            snapshot(
                teachingMoment: revealedMoment,
                hasPrincipalVariation: true
            )
        )
        #expect(revealed.primaryCommand?.action == .continuePlaying)
        #expect(
            revealed.commands.contains {
                $0.action == .exploreEngineLine(rank: 1)
            }
        )

        revealedMoment.phase = .previewing(
            hint(),
            variationRank: 1,
            step: 0
        )
        let preview = resolver.resolve(
            snapshot(teachingMoment: revealedMoment)
        )
        #expect(preview.primaryCommand?.action == .continuePlaying)
        #expect(
            preview.commands.first { $0.action == .previewPrevious }?
                .isEnabled == false
        )
        #expect(preview.commands.contains { $0.action == .returnToPosition })
    }

    @Test func projectionGroupsTurnsAndSeparatesSameFENAtDifferentPly() {
        let fen = ChessGameState.standardInitialFEN
        let sessionID = UUID()
        let completedTurnID = UUID()
        let pendingTurnID = UUID()
        let base = Date(timeIntervalSince1970: 1_000)
        let lesson = message(
            role: .coach,
            text: "Notice the center.",
            ply: 2,
            fen: fen,
            date: base,
            kind: .lesson,
            turnID: sessionID,
            sessionID: sessionID,
            structuredReply: .legacy(text: "Notice the center.")
        )
        let question = message(
            role: .user,
            text: "Why?",
            ply: 2,
            fen: fen,
            date: base.addingTimeInterval(1),
            kind: .question,
            turnID: completedTurnID,
            sessionID: sessionID
        )
        let answer = message(
            role: .coach,
            text: "It improves control.",
            ply: 2,
            fen: fen,
            date: base.addingTimeInterval(2),
            kind: .answer,
            turnID: completedTurnID,
            sessionID: sessionID
        )
        let sameFENDifferentPly = message(
            role: .user,
            text: "Earlier question",
            ply: 0,
            fen: fen,
            date: base.addingTimeInterval(3),
            kind: .question,
            turnID: pendingTurnID
        )
        let unanchoredLegacy = CoachMessage(
            role: .coach,
            text: "Old message",
            ply: 2,
            createdAt: base.addingTimeInterval(4)
        )

        let projection = CoachThreadProjectionBuilder().build(
            messages: [
                answer,
                sameFENDifferentPly,
                unanchoredLegacy,
                lesson,
                question,
            ],
            currentPositionFEN: fen,
            currentPly: 2
        )

        #expect(projection.currentPosition.count == 2)
        #expect(projection.currentPosition.contains { item in
            if case .lesson = item { true } else { false }
        })
        #expect(projection.currentPosition.contains { item in
            if case .turn(let turn) = item {
                turn.answer?.text == "It improves control." &&
                    turn.sessionID == sessionID
            } else {
                false
            }
        })
        #expect(projection.history.count == 2)
        #expect(projection.history.contains { item in
            item.ply == 0 && item.positionFEN == fen
        })
        #expect(projection.history.contains { item in
            if case .legacy = item { true } else { false }
        })
    }

    @Test func inferenceHistoryRequiresExactFENAndPly() {
        let fen = ChessGameState.standardInitialFEN
        let exact = message(
            role: .user,
            text: "Exact",
            ply: 4,
            fen: fen,
            kind: .question
        )
        let sameFENDifferentPly = message(
            role: .user,
            text: "Wrong ply",
            ply: 2,
            fen: fen,
            kind: .question
        )
        let lesson = message(
            role: .coach,
            text: "Delivered lesson",
            ply: 4,
            fen: fen,
            kind: .lesson
        )
        let legacyLesson = CoachMessage(
            role: .coach,
            text: "Older delivered lesson",
            ply: 4,
            structuredReply: .legacy(text: "Older delivered lesson"),
            positionFEN: fen,
            turnID: UUID()
        )

        let history = CoachThreadProjectionBuilder().inferenceHistory(
            messages: [
                sameFENDifferentPly,
                lesson,
                legacyLesson,
                exact,
            ],
            positionFEN: fen,
            ply: 4
        )

        #expect(history.map(\.text) == ["Exact"])
    }

    @Test func warningQuestionAnswerProjectsAsFocusedWarningExplanation() {
        let fen = ChessGameState.standardInitialFEN
        let turnID = UUID()
        let sessionID = UUID()
        let question = message(
            role: .user,
            text: "What did I miss?",
            ply: 1,
            fen: fen,
            kind: .question,
            turnID: turnID,
            sessionID: sessionID
        )
        let explanation = message(
            role: .coach,
            text: "The move leaves the queen undefended.",
            ply: 1,
            fen: fen,
            kind: .warningExplanation,
            turnID: turnID,
            sessionID: sessionID
        )

        let projection = CoachThreadProjectionBuilder().build(
            messages: [question, explanation],
            currentPositionFEN: fen,
            currentPly: 1
        )

        #expect(projection.currentPosition.count == 1)
        #expect(projection.currentPosition.contains { item in
            if case .warning(let message) = item {
                message.text == "The move leaves the queen undefended." &&
                    message.sessionID == sessionID
            } else {
                false
            }
        })
    }

    @MainActor
    @Test func optionalMessageMetadataPersistsAndLegacyRowsRemainReadable() throws {
        let persistence = PersistenceController(inMemory: true)
        let game = persistence.createGame(
            configuration: NewGameConfiguration(),
            playerSide: .white,
            initialFEN: ChessGameState.standardInitialFEN
        )
        let sessionID = UUID()
        let turnID = UUID()
        let reply = CoachReply.legacy(text: "Use the open file.")
        let user = CoachMessage(
            role: .user,
            text: "Why this move?",
            ply: 0,
            kind: .question,
            sessionID: sessionID
        )
        let assistant = CoachMessage(
            role: .coach,
            text: reply.plainText,
            ply: 0,
            structuredReply: reply,
            kind: .answer,
            sessionID: sessionID
        )

        #expect(
            persistence.appendCoachTurn(
                user: user,
                assistant: assistant,
                structuredReply: reply,
                positionFEN: ChessGameState.standardInitialFEN,
                turnID: turnID,
                sessionID: sessionID,
                to: game
            )
        )
        #expect(game.coachMessages.allSatisfy { $0.sessionID == sessionID })
        #expect(
            game.coachMessages.first { $0.roleRaw == "user" }?.kind == .question
        )
        #expect(
            game.coachMessages.first { $0.roleRaw == "coach" }?.kind == .answer
        )

        let legacy = persistence.append(
            CoachMessage(role: .coach, text: "**Legacy**", ply: 0),
            to: game
        )
        #expect(legacy.kind == nil)
        #expect(legacy.sessionID == nil)
        #expect(legacy.effectiveReply.plainText == "Coach: Legacy")
    }

    private func snapshot(
        isCurrentGameVisible: Bool = true,
        hasActiveGame: Bool = true,
        gameResult: GameResult = .inProgress,
        isEngineThinking: Bool = false,
        hasBlunderWarning: Bool = false,
        preparationState: CoachPreparationState = .idle,
        teachingMoment: TeachingMomentState? = nil,
        canTakeBack: Bool = false,
        chatState: CoachChatState = .ready,
        hasPrincipalVariation: Bool = false
    ) -> CoachInspectorSnapshot {
        CoachInspectorSnapshot(
            isCurrentGameVisible: isCurrentGameVisible,
            hasActiveGame: hasActiveGame,
            gameResult: gameResult,
            isEngineThinking: isEngineThinking,
            hasBlunderWarning: hasBlunderWarning,
            preparationState: preparationState,
            teachingMoment: teachingMoment,
            canTakeBack: canTakeBack,
            chatState: chatState,
            hasPrincipalVariation: hasPrincipalVariation
        )
    }

    private func anchor() -> PositionAnchor {
        PositionAnchor(
            gameID: UUID(),
            revision: 1,
            ply: 0,
            fen: ChessGameState.standardInitialFEN
        )
    }

    private func teachingMoment() -> TeachingMomentState {
        TeachingMomentState(
            id: UUID(),
            anchor: anchor(),
            pausedClockSide: .white,
            phase: .concept(hint()),
            isUpgradeEligible: false
        )
    }

    private func prepared(
        anchor: PositionAnchor,
        enhancement: CoachEnhancementState
    ) -> PreparedCoaching {
        let analysis = PositionAnalysis(
            fen: anchor.fen,
            sideToMove: .white,
            bestMove: "e2e4",
            variations: [
                PrincipalVariation(
                    index: 1,
                    depth: 16,
                    score: EngineScore(centipawns: 20),
                    wdl: WDL(win: 250, draw: 600, loss: 150),
                    moves: ["e2e4", "e7e5"]
                ),
            ]
        )
        let context = CoachContext(
            purpose: "test",
            fen: anchor.fen,
            pgn: "*",
            playerColor: "white",
            sideToMove: "white",
            whiteClock: "10:00",
            blackClock: "10:00",
            recommendedMove: "e2e4",
            variations: [
                CoachVariation(
                    rank: 1,
                    move: "e2e4",
                    sanLine: ["e4", "e5"],
                    uciLine: ["e2e4", "e7e5"],
                    centipawns: 20,
                    mate: nil,
                    expectedScore: 0.55
                ),
            ],
            positionFacts: PositionFeatures.extract(from: ChessGameState()),
            learner: LearnerSnapshot(
                experience: "Developing",
                estimatedElo: "Calibrating",
                confidence: 0,
                reviewedGames: 0,
                weaknesses: "",
                strengths: "",
                userNotes: ""
            )
        )
        return PreparedCoaching(
            anchor: anchor,
            analysis: analysis,
            context: context,
            deterministicHint: hint(),
            providerHint: enhancement == .ready ? hint() : nil,
            enhancement: enhancement
        )
    }

    private func hint() -> CoachHint {
        CoachHint(
            concept: "Improve a central piece.",
            why: "It controls useful squares.",
            plan: "Develop and castle.",
            likelyReply: "e5",
            watchFor: "A central break.",
            recommendedMove: "e2e4",
            source: "Test"
        )
    }

    private func message(
        role: CoachRole,
        text: String,
        ply: Int,
        fen: String,
        date: Date = .now,
        kind: CoachMessageKind,
        turnID: UUID? = nil,
        sessionID: UUID? = nil,
        structuredReply: CoachReply? = nil
    ) -> CoachMessage {
        CoachMessage(
            role: role,
            text: text,
            ply: ply,
            createdAt: date,
            structuredReply: structuredReply,
            positionFEN: fen,
            turnID: turnID,
            kind: kind,
            sessionID: sessionID
        )
    }
}
