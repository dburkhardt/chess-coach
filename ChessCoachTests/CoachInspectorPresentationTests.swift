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

        let reviewing = resolver.resolve(
            snapshot(isHistoryPreviewActive: true)
        )
        #expect(reviewing.scene == .reviewing)

        let live = resolver.resolve(snapshot())
        #expect(live.scene == .live)

        for presentation in [
            neutral, empty, completed, warning, lesson, reviewing, live,
        ] {
            #expect(
                presentation.commands.filter { $0.style == .primary }.count <= 1
            )
        }
    }

    @Test func historyReviewSuppressesActionsAndComposer() {
        let reviewing = resolver.resolve(
            snapshot(
                isHistoryPreviewActive: true,
                preparationState: .ready(
                    prepared(
                        anchor: anchor(),
                        enhancement: .ready
                    )
                ),
                canTakeBack: true
            )
        )

        #expect(reviewing.scene == .reviewing)
        #expect(reviewing.header.status == "Reviewing earlier position")
        #expect(!reviewing.header.showsTakeBack)
        #expect(reviewing.commands.isEmpty)
        #expect(!reviewing.showsComposer)
    }

    @Test func completedGameKeepsTranscriptBehindHistory() {
        let completed = resolver.resolve(
            snapshot(
                gameResult: .draw,
                earlierItemCount: 8
            )
        )

        #expect(completed.scene == .completed)
        #expect(completed.header.status == "Game complete")
        #expect(completed.header.showsHistory)
        #expect(completed.earlierItemCount == 8)
        #expect(completed.commands.isEmpty)
        #expect(!completed.showsComposer)
    }

    @Test func liveReadinessUsesOneQuietHintAction() throws {
        let anchor = anchor()
        let analyzing = resolver.resolve(
            snapshot(preparationState: .analyzing(anchor))
        )
        #expect(analyzing.header.status == nil)
        #expect(analyzing.commands.map(\.label) == ["Hint"])
        #expect(analyzing.primaryCommand?.isEnabled == false)

        let polishing = resolver.resolve(
            snapshot(
                preparationState: .ready(
                    prepared(anchor: anchor, enhancement: .preparing)
                )
            )
        )
        #expect(polishing.header.status == nil)
        #expect(polishing.primaryCommand?.action == .openHint)
        #expect(polishing.primaryCommand?.label == "Hint")
        #expect(polishing.commands.count == 1)

        let coachReady = resolver.resolve(
            snapshot(
                preparationState: .ready(
                    prepared(anchor: anchor, enhancement: .ready)
                )
            )
        )
        #expect(coachReady.header.status == nil)

        let stockfishReady = resolver.resolve(
            snapshot(
                preparationState: .ready(
                    prepared(anchor: anchor, enhancement: .unavailable)
                )
            )
        )
        #expect(stockfishReady.header.status == nil)

        let failed = resolver.resolve(
            snapshot(
                preparationState: .failed(anchor, message: "engine exited")
            )
        )
        #expect(failed.header.status == nil)
        #expect(failed.primaryCommand?.action == .retryAnalysis)
        #expect(failed.primaryCommand?.label == "Hint")

        let unavailable = resolver.resolve(
            snapshot(
                chatState: .unavailable(issue: .missingKey)
            )
        )
        #expect(unavailable.header.status == nil)
    }

    @Test func teachingPresentationAdaptsToClockWithoutGlobalShelf() {
        let unclocked = resolver.resolve(
            snapshot(
                usesClock: false,
                teachingMoment: teachingMoment()
            )
        )
        #expect(unclocked.header.status == nil)
        #expect(unclocked.header.trailingAction?.label == "Done")
        #expect(
            unclocked.header.trailingAction?.style == .neutral
        )
        #expect(unclocked.commands.isEmpty)

        let clocked = resolver.resolve(
            snapshot(
                usesClock: true,
                teachingMoment: teachingMoment()
            )
        )
        #expect(clocked.header.status == "Teaching moment · paused")
        #expect(clocked.header.trailingAction?.label == "Continue")
        #expect(clocked.header.trailingAction?.style == .resume)
        #expect(clocked.commands.isEmpty)

        var revealedMoment = teachingMoment()
        revealedMoment.phase = .revealed(hint())
        let revealed = resolver.resolve(
            snapshot(
                usesClock: true,
                teachingMoment: revealedMoment,
                hasPrincipalVariation: true
            )
        )
        #expect(revealed.commands.isEmpty)
        #expect(revealed.header.trailingAction?.label == "Continue")

        revealedMoment.phase = .previewing(
            hint(),
            variationRank: 1,
            step: 0
        )
        let preview = resolver.resolve(
            snapshot(teachingMoment: revealedMoment)
        )
        #expect(preview.commands.isEmpty)
        #expect(preview.header.trailingAction?.label == "Done")
    }

    @Test func dialogueFooterNeverSilentlyDisappearsDuringLiveOrLesson() {
        let liveReady = resolver.resolve(
            snapshot(chatState: .ready)
        )
        #expect(liveReady.footer == .composer(notice: nil))
        #expect(liveReady.showsComposer)

        let lessonWorking = resolver.resolve(
            snapshot(
                teachingMoment: teachingMoment(),
                chatState: .working
            )
        )
        #expect(lessonWorking.footer == .composer(notice: nil))
        #expect(lessonWorking.showsComposer)

        let failed = resolver.resolve(
            snapshot(
                chatState: .failed(message: "Connection interrupted.")
            )
        )
        #expect(
            failed.footer ==
                .composer(notice: "Connection interrupted.")
        )
        #expect(failed.showsComposer)

        let missing = resolver.resolve(
            snapshot(
                teachingMoment: teachingMoment(),
                chatState: .unavailable(issue: .missingKey)
            )
        )
        #expect(
            missing.footer == .providerSetup(issue: .missingKey)
        )
        #expect(!missing.showsComposer)

        let warning = resolver.resolve(
            snapshot(
                hasBlunderWarning: true,
                chatState: .ready
            )
        )
        #expect(warning.footer == .hidden)

        let completed = resolver.resolve(
            snapshot(
                gameResult: .draw,
                chatState: .ready
            )
        )
        #expect(completed.footer == .hidden)
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
        isHistoryPreviewActive: Bool = false,
        usesClock: Bool = false,
        preparationState: CoachPreparationState = .idle,
        teachingMoment: TeachingMomentState? = nil,
        canTakeBack: Bool = false,
        chatState: CoachChatState = .ready,
        hasPrincipalVariation: Bool = false,
        earlierItemCount: Int = 0
    ) -> CoachInspectorSnapshot {
        CoachInspectorSnapshot(
            isCurrentGameVisible: isCurrentGameVisible,
            hasActiveGame: hasActiveGame,
            gameResult: gameResult,
            isEngineThinking: isEngineThinking,
            hasBlunderWarning: hasBlunderWarning,
            isHistoryPreviewActive: isHistoryPreviewActive,
            usesClock: usesClock,
            preparationState: preparationState,
            teachingMoment: teachingMoment,
            canTakeBack: canTakeBack,
            chatState: chatState,
            earlierItemCount: earlierItemCount,
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
