import Foundation
import Observation

enum PromotionRequestOrigin: Equatable {
    case live
    case teaching(PositionAnchor)
}

struct PromotionRequest: Identifiable {
    let id = UUID()
    var from: String
    var to: String
    var candidates: [String]
    var origin: PromotionRequestOrigin
}

private struct PositionRevisionToken: Equatable {
    var gameID: UUID
    var ply: Int
    var fen: String
    var revision: Int
}

private enum CoachingPreparationError: LocalizedError {
    case mismatchedAnalysis

    var errorDescription: String? {
        switch self {
        case .mismatchedAnalysis:
            "Stockfish analysis did not match the teaching position."
        }
    }
}

@MainActor
@Observable
final class GameCoordinator {
    private(set) var state = ChessGameState()
    private(set) var configuration = NewGameConfiguration()
    private(set) var playerSide: ChessSide = .white
    private(set) var clocks = ClockSnapshot.initial(for: .rapid10)
    private(set) var activeClockSide: ChessSide?
    private(set) var status = ChessGameStatus()
    private(set) var isEngineThinking = false
    private(set) var isCoachWorking = false
    private(set) var errorMessage = ""
    private(set) var activeGame: SavedGame?
    private(set) var coachMessages: [CoachMessage] = []
    private(set) var coachChatState: CoachChatState = .unavailable(
        issue: .missingModel
    )
    private(set) var currentHint: CoachHint?
    private(set) var hintRevealed = false
    private(set) var hintArrow: (from: String, to: String)?
    private(set) var blunderWarning: BlunderWarning?
    private(set) var coachPreparationState: CoachPreparationState = .idle
    private(set) var teachingMoment: TeachingMomentState?
    private(set) var historyPreview: HistoryPreviewState?

    var selectedSquare: String?
    var promotionRequest: PromotionRequest?

    private let persistence: PersistenceController
    private let opponent: any ChessEngineServing
    private let analyst: any ChessEngineServing
    private let inference: any CoachInferenceServing
    private let inferenceSettings: InferenceSettings
    private let clock: any GameClockServing
    private let contextBuilder = CoachContextBuilder()
    private let blunderDetector = BlunderDetector()
    private let reviewAnalyzer: ReviewAnalyzer
    private var baselineAnalysis: PositionAnalysis?
    private var lastAnalysis: PositionAnalysis?
    private var clockTask: Task<Void, Never>?
    private var playerMoveTask: Task<Void, Never>?
    private var engineTask: Task<Void, Never>?
    private var coachAnalysisTask: Task<Void, Never>?
    private var coachInferenceTask: Task<Void, Never>?
    private var coachTask: Task<Void, Never>?
    private var reviewTask: Task<Void, Never>?
    private var coachOperationID: UUID?
    private var positionRevision = 0
    private var lastClockTick: Date
    private var lastClockAutosave: Date

    init(
        persistence: PersistenceController,
        inferenceSettings: InferenceSettings,
        opponent: any ChessEngineServing = StockfishService(role: .opponent),
        analyst: any ChessEngineServing = StockfishService(role: .analyst),
        inference: any CoachInferenceServing = ModelInferenceClient(),
        clock: any GameClockServing = SystemGameClock()
    ) {
        self.persistence = persistence
        self.inferenceSettings = inferenceSettings
        self.opponent = opponent
        self.analyst = analyst
        self.inference = inference
        self.clock = clock
        self.lastClockTick = clock.now()
        self.lastClockAutosave = .distantPast
        self.reviewAnalyzer = ReviewAnalyzer(analyst: analyst)
        refreshCoachChatCapabilityState()
    }

    var canPlayerMove: Bool {
        activeGame != nil &&
        status.result == .inProgress &&
        state.sideToMove == playerSide &&
        blunderWarning == nil &&
        !isEngineThinking &&
        !isCoachWorking &&
        teachingMoment == nil &&
        historyPreview == nil
    }

    var canMoveFromTeachingMoment: Bool {
        guard let moment = teachingMoment,
              isCurrent(moment.anchor),
              state.sideToMove == playerSide
        else {
            return false
        }
        switch moment.phase {
        case .concept, .revealed:
            return true
        case .preparing, .previewing, .failed:
            return false
        }
    }

    var coachThreadProjection: CoachThreadProjection {
        CoachThreadProjectionBuilder().build(
            messages: coachMessages,
            currentPositionFEN: state.fen,
            currentPly: state.plyCount
        )
    }

    func coachInspectorSnapshot(
        isCurrentGameVisible: Bool
    ) -> CoachInspectorSnapshot {
        let projection = coachThreadProjection
        let hasPrincipalVariation: Bool
        let principalVariationMoveCount: Int
        if case .ready(let prepared) = coachPreparationState {
            let principal = prepared.context.variations.first {
                $0.rank == 1
            }
            hasPrincipalVariation = principal != nil
            principalVariationMoveCount = principal?.sanLine.count ?? 0
        } else {
            hasPrincipalVariation = false
            principalVariationMoveCount = 0
        }
        return CoachInspectorSnapshot(
            isCurrentGameVisible: isCurrentGameVisible,
            hasActiveGame: activeGame != nil,
            gameResult: status.result,
            isEngineThinking: isEngineThinking,
            hasBlunderWarning: blunderWarning != nil,
            isHistoryPreviewActive: historyPreview != nil,
            usesClock: configuration.timeControl.usesClock,
            preparationState: coachPreparationState,
            teachingMoment: teachingMoment,
            canTakeBack: canTakeBack,
            chatState: coachChatState,
            currentPositionTurnCount: projection.currentPosition.count,
            earlierItemCount: projection.history.count,
            hasPrincipalVariation: hasPrincipalVariation,
            principalVariationMoveCount: principalVariationMoveCount
        )
    }

    var canStartTeachingMoment: Bool {
        guard activeGame != nil,
              status.result == .inProgress,
              state.sideToMove == playerSide,
              blunderWarning == nil,
              !isEngineThinking,
              teachingMoment == nil,
              historyPreview == nil,
              let anchor = currentPositionAnchor(),
              case .ready(let prepared) = coachPreparationState
        else {
            return false
        }
        return prepared.anchor == anchor
    }

    var canTakeBack: Bool {
        guard status.result == .inProgress,
              historyPreview == nil,
              let game = activeGame
        else {
            return false
        }
        return game.plies.contains(where: { $0.side == playerSide })
    }

    var boardPositionRevision: Int {
        positionRevision
    }

    var legalDestinationSquares: Set<String> {
        guard let selectedSquare else { return [] }
        return Set(state.legalMoves(from: selectedSquare).compactMap {
            guard $0.count >= 4 else { return nil }
            return String($0.dropFirst(2).prefix(2))
        })
    }

    var moveRows: [(number: Int, white: String, black: String)] {
        let plies = activeGame?.plies.sorted(by: { $0.index < $1.index }) ?? []
        var rows: [(Int, String, String)] = []
        for index in stride(from: 0, to: plies.count, by: 2) {
            rows.append((
                index / 2 + 1,
                plies[index].san,
                index + 1 < plies.count ? plies[index + 1].san : ""
            ))
        }
        return rows
    }

    /// Selects an earlier position for read-only inspection.
    ///
    /// This intentionally does not tick or pause clocks, cancel work, mutate
    /// the legal game, or persist assistance. Reaching the current ply exits
    /// history browsing and returns to the live board.
    @discardableResult
    func selectHistoryPreview(ply: Int) -> Bool {
        guard let game = activeGame,
              teachingMoment == nil,
              blunderWarning == nil,
              promotionRequest == nil,
              let anchor = currentPositionAnchor(),
              game.id == anchor.gameID,
              game.sortedPlies.count == anchor.ply,
              (0...anchor.ply).contains(ply)
        else {
            return false
        }

        if ply == anchor.ply {
            historyPreview = nil
            return true
        }

        if var preview = historyPreview,
           preview.anchor == anchor {
            preview.selectedPly = ply
            historyPreview = preview
        } else {
            historyPreview = HistoryPreviewState(
                anchor: anchor,
                selectedPly: ply
            )
        }
        return true
    }

    /// Steps the current read-only preview without changing the live game.
    @discardableResult
    func stepHistoryPreview(by offset: Int) -> Bool {
        guard offset != 0,
              var preview = historyPreview,
              matchesCurrentPosition(preview.anchor)
        else {
            return false
        }
        let destination = min(
            preview.anchor.ply,
            max(0, preview.selectedPly + offset)
        )
        guard destination != preview.selectedPly else { return false }
        if destination == preview.anchor.ply {
            historyPreview = nil
        } else {
            preview.selectedPly = destination
            historyPreview = preview
        }
        return true
    }

    func returnToLivePosition() {
        historyPreview = nil
    }

    /// The clocks belonging to the completed-game position being presented.
    ///
    /// During a live game the authoritative clock intentionally keeps running
    /// while the player reviews history, so the strip must keep showing that
    /// live countdown. Once a game is complete, review instead projects the
    /// historical snapshot that a confirmed rewind would restore.
    var displayedClocks: ClockSnapshot {
        guard status.isFinished,
              let preview = historyPreview,
              let game = activeGame,
              preview.anchor.gameID == game.id,
              preview.anchor.ply == game.sortedPlies.count,
              (0..<preview.anchor.ply).contains(preview.selectedPly)
        else {
            return clocks
        }

        let sorted = game.sortedPlies
        if preview.selectedPly == 0 {
            return sorted.first?.clockBefore
                ?? .initial(for: game.timeControl)
        }
        return sorted[preview.selectedPly - 1].clockAfter
    }

    /// Destructively replaces the live continuation with the selected history
    /// position. Browsing alone never calls this path; callers must explicitly
    /// confirm the rewind and then invoke it.
    @discardableResult
    func rewindToHistoryPreview() -> Bool {
        guard let preview = historyPreview,
              let game = activeGame,
              teachingMoment == nil,
              blunderWarning == nil,
              matchesCurrentPosition(preview.anchor),
              game.id == preview.anchor.gameID
        else {
            return false
        }

        let sorted = game.sortedPlies
        let keep = preview.selectedPly
        guard sorted.count == preview.anchor.ply,
              keep >= 0,
              keep < sorted.count
        else {
            return false
        }

        let restoredClocks: ClockSnapshot
        if keep == 0 {
            restoredClocks = sorted.first?.clockBefore
                ?? .initial(for: game.timeControl)
        } else {
            restoredClocks = sorted[keep - 1].clockAfter
        }
        let keptMoves = sorted.prefix(keep).map(\.uci)

        advancePositionRevision()
        cancelWork()
        state = ChessGameState(
            initialFEN: game.initialFEN,
            moves: Array(keptMoves)
        )
        clocks = restoredClocks
        status = ChessGameStatus()
        blunderWarning = nil
        currentHint = nil
        hintRevealed = false
        hintArrow = nil
        coachPreparationState = .idle
        lastAnalysis = nil
        baselineAnalysis = nil
        errorMessage = ""

        game.result = .inProgress
        game.endReason = .none
        game.endedAt = nil
        let rebuildsProfile = game.profileIncorporated
        game.reviewCompleted = false
        game.profileIncorporated = false
        game.reviewAttemptedAt = nil
        game.reviewLastError = ""
        game.reviewSummary = ""
        game.averageExpectedScoreLoss = 0
        game.blunderCount = 0
        game.mistakeCount = 0
        for ply in sorted.prefix(keep) {
            ply.expectedScoreBefore = nil
            ply.expectedScoreAfter = nil
            ply.classification = nil
            ply.expectedScoreLoss = nil
            ply.bestMoveUCI = ""
            ply.bestMoveSAN = ""
            ply.principalVariationSAN = ""
        }

        persistence.truncate(game: game, toPlyCount: keep)
        persistence.recordAssistance(
            .takeBack,
            atPly: keep,
            detail: "Rewound to the selected move-history position.",
            in: game
        )
        if rebuildsProfile {
            persistence.rebuildProfileFromIncorporatedGames()
        }
        coachMessages.removeAll { $0.ply > keep }
        activeClockSide = state.sideToMove
        lastClockTick = clock.now()
        updateSavedGame()
        persistence.refreshGames()
        startClock()

        if state.sideToMove == playerSide {
            cacheBaselineAnalysis()
        } else {
            requestOpponentMove()
        }
        return true
    }

    func newGame(_ configuration: NewGameConfiguration) {
        abandonActiveGameIfNeeded()
        advancePositionRevision()
        cancelWork()
        self.configuration = configuration
        playerSide = configuration.colorChoice.resolved()
        state = ChessGameState()
        clocks = .initial(for: configuration.timeControl)
        activeClockSide = .white
        status = ChessGameStatus()
        selectedSquare = nil
        promotionRequest = nil
        coachMessages = []
        currentHint = nil
        hintRevealed = false
        hintArrow = nil
        coachPreparationState = .idle
        teachingMoment = nil
        blunderWarning = nil
        errorMessage = ""
        refreshCoachChatCapabilityState()
        baselineAnalysis = nil
        lastAnalysis = nil
        activeGame = persistence.createGame(
            configuration: configuration,
            playerSide: playerSide,
            initialFEN: state.initialFEN
        )
        startClock()
        cacheBaselineAnalysis()
        if playerSide == .black {
            requestOpponentMove()
        }
    }

    func resume(game: SavedGame) {
        if activeGame?.id != game.id {
            abandonActiveGameIfNeeded()
        }
        advancePositionRevision()
        cancelWork()
        let moves = game.plies.sorted(by: { $0.index < $1.index }).map(\.uci)
        state = ChessGameState(initialFEN: game.initialFEN, moves: moves)
        configuration = NewGameConfiguration(
            colorChoice: game.playerSide == .white ? .white : .black,
            difficulty: game.difficulty,
            timeControl: game.timeControl,
            blunderGuardEnabled: game.blunderGuardEnabled
        )
        playerSide = game.playerSide
        if game.timeControl.usesClock,
           game.currentWhiteClockMilliseconds == 0,
           game.currentBlackClockMilliseconds == 0 {
            clocks = game.plies.sorted(by: { $0.index < $1.index }).last?.clockAfter
                ?? .initial(for: game.timeControl)
        } else {
            clocks = ClockSnapshot(
                whiteMilliseconds: game.currentWhiteClockMilliseconds,
                blackMilliseconds: game.currentBlackClockMilliseconds
            )
        }
        activeGame = game
        status = game.result == .inProgress
            ? ChessGameStatus()
            : ChessGameStatus(
                result: game.result,
                reason: game.endReason,
                message: game.resultLabel
            )
        coachMessages = game.coachMessages
            .sorted(by: { $0.createdAt < $1.createdAt })
            .map {
                CoachMessage(
                    id: $0.id,
                    role: CoachRole(rawValue: $0.roleRaw) ?? .system,
                    text: $0.text,
                    ply: $0.ply,
                    createdAt: $0.createdAt,
                    structuredReply: $0.structuredContent,
                    positionFEN: $0.positionFEN,
                    turnID: $0.turnID,
                    kind: $0.kind,
                    sessionID: $0.sessionID
                )
            }
        selectedSquare = nil
        promotionRequest = nil
        currentHint = nil
        hintRevealed = false
        hintArrow = nil
        coachPreparationState = .idle
        teachingMoment = nil
        blunderWarning = nil
        errorMessage = ""
        refreshCoachChatCapabilityState()
        baselineAnalysis = nil
        lastAnalysis = nil

        guard game.result == .inProgress else {
            activeClockSide = nil
            return
        }
        activeClockSide = state.sideToMove
        startClock()
        if state.sideToMove == playerSide {
            cacheBaselineAnalysis()
        } else {
            requestOpponentMove()
        }
    }

    func resumePendingReviews() {
        guard activeGame?.result != .inProgress else { return }
        let pending = persistence.pendingReviewGames
        guard !pending.isEmpty else { return }
        reviewTask?.cancel()
        reviewTask = Task { [weak self] in
            guard let self else { return }
            for game in pending {
                guard !Task.isCancelled else { return }
                await reviewAnalyzer.review(game: game, persistence: persistence)
            }
        }
    }

    func selectOrMove(square: String) {
        guard canPlayerMove || canMoveFromTeachingMoment else { return }
        let moveOrigin: PromotionRequestOrigin
        if let anchor = teachingMoment?.anchor, canMoveFromTeachingMoment {
            moveOrigin = .teaching(anchor)
        } else {
            moveOrigin = .live
        }
        if let selectedSquare {
            if selectedSquare == square {
                self.selectedSquare = nil
                return
            }
            let candidates = state.legalMoves(from: selectedSquare).filter {
                String($0.dropFirst(2).prefix(2)) == square
            }
            if candidates.count > 1, candidates.contains(where: { $0.count > 4 }) {
                if case .teaching = moveOrigin {
                    freezeTeachingUpgrade()
                }
                promotionRequest = PromotionRequest(
                    from: selectedSquare,
                    to: square,
                    candidates: candidates,
                    origin: moveOrigin
                )
                return
            }
            if let move = candidates.first {
                self.selectedSquare = nil
                schedulePlayerMove(uci: move, origin: moveOrigin)
                return
            }
        }
        if state.piece(at: square)?.side == playerSide {
            selectedSquare = square
        } else {
            selectedSquare = nil
        }
    }

    func dragMove(from: String, to: String) {
        selectedSquare = from
        selectOrMove(square: to)
    }

    func promote(to kind: String) {
        guard let request = promotionRequest else { return }
        let move = request.candidates.first(where: { $0.lowercased().hasSuffix(kind.lowercased()) })
        promotionRequest = nil
        selectedSquare = nil
        if let move { schedulePlayerMove(uci: move, origin: request.origin) }
    }

    func takeBack() {
        guard status.result == .inProgress,
              historyPreview == nil,
              let game = activeGame
        else {
            return
        }
        let sorted = game.plies.sorted(by: { $0.index < $1.index })
        guard let playerDecisionIndex = sorted.lastIndex(where: { $0.side == playerSide }) else {
            return
        }
        let playerDecision = sorted[playerDecisionIndex]
        let keep = playerDecisionIndex
        advancePositionRevision()
        cancelWork()
        state = state.rebuilt(keeping: keep)
        clocks = playerDecision.clockBefore
        game.assistanceUsed = true
        game.currentFEN = state.fen
        game.result = .inProgress
        game.endReason = .none
        game.endedAt = nil
        game.reviewCompleted = false
        persistence.truncate(game: game, toPlyCount: keep)
        persistence.recordAssistance(
            .takeBack,
            atPly: keep,
            detail: "Returned to the previous player decision.",
            in: game
        )
        status = ChessGameStatus()
        blunderWarning = nil
        currentHint = nil
        hintRevealed = false
        hintArrow = nil
        coachMessages.removeAll { $0.ply > keep }
        lastAnalysis = nil
        baselineAnalysis = nil
        activeClockSide = state.sideToMove
        lastClockTick = clock.now()
        updateSavedGame()
        startClock()
        if state.sideToMove == playerSide {
            cacheBaselineAnalysis()
        } else {
            requestOpponentMove()
        }
    }

    func resign() {
        guard status.result == .inProgress else { return }
        // Capture any thinking time since the most recent timer callback before
        // freezing the final clock snapshot. This also keeps resignation
        // deterministic when the clock task has not yet reached its first tick.
        tickClock()
        guard status.result == .inProgress else { return }
        finish(
            result: playerSide == .white ? .blackWon : .whiteWon,
            reason: .resignation,
            message: "You resigned."
        )
    }

    func restart() {
        newGame(configuration)
    }

    func playOnAfterWarning() {
        guard blunderWarning != nil else { return }
        blunderWarning = nil
        requestOpponentMove()
    }

    func askCoachAboutWarning() {
        guard let warning = blunderWarning else { return }
        coachTask?.cancel()
        coachTask = Task { [weak self] in
            await self?.streamCoachReply(
                to: "\(warning.reason) Explain the chess idea I missed without inventing a different engine line."
            )
        }
    }

    func requestHint() {
        guard canStartTeachingMoment,
              !isCoachWorking,
              case .ready(let prepared) = coachPreparationState
        else { return }
        tickClock()
        guard canStartTeachingMoment,
              let anchor = currentPositionAnchor(),
              prepared.anchor == anchor
        else { return }

        let momentID = UUID()
        let pausedClockSide = activeClockSide
        activeClockSide = nil
        lastClockTick = clock.now()
        selectedSquare = nil
        promotionRequest = nil
        currentHint = nil
        hintRevealed = false
        hintArrow = nil
        teachingMoment = TeachingMomentState(
            id: momentID,
            anchor: anchor,
            pausedClockSide: pausedClockSide,
            phase: .concept(prepared.bestAvailableHint),
            isUpgradeEligible: prepared.providerHint == nil &&
                prepared.enhancement == .preparing
        )
        deliverTeachingHint(prepared.bestAvailableHint, momentID: momentID)
    }

    func revealHint() {
        guard var moment = teachingMoment,
              isCurrent(moment.anchor),
              case .concept(let hint) = moment.phase,
              !hintRevealed
        else { return }
        moment.phase = .revealed(hint)
        moment.isUpgradeEligible = false
        teachingMoment = moment
        hintRevealed = true
        if let game = activeGame {
            persistence.recordAssistance(
                .revealMove,
                atPly: state.plyCount,
                detail: hint.recommendedMove,
                in: game
            )
        }
        if hint.recommendedMove.count >= 4 {
            hintArrow = (
                String(hint.recommendedMove.prefix(2)),
                String(hint.recommendedMove.dropFirst(2).prefix(2))
            )
        }
    }

    func setTeachingPreview(variationRank: Int, step: Int) {
        guard variationRank > 0,
              step >= 0,
              var moment = teachingMoment,
              isCurrent(moment.anchor),
              case .ready(let prepared) = coachPreparationState,
              prepared.anchor == moment.anchor,
              let variation = prepared.context.variations.first(where: {
                  $0.rank == variationRank
              })
        else { return }
        let hint: CoachHint
        switch moment.phase {
        case .revealed(let revealedHint),
             .previewing(let revealedHint, _, _):
            hint = revealedHint
        case .preparing, .concept, .failed:
            return
        }
        let moveCount = variation.uciLine?.count
            ?? (variation.move.isEmpty ? 0 : 1)
        guard step <= moveCount else { return }
        moment.phase = .previewing(
            hint,
            variationRank: variationRank,
            step: step
        )
        moment.isUpgradeEligible = false
        teachingMoment = moment
    }

    func stepTeachingPreview(by offset: Int) {
        guard offset != 0,
              let moment = teachingMoment,
              case .previewing(_, let rank, let currentStep) = moment.phase,
              case .ready(let prepared) = coachPreparationState,
              prepared.anchor == moment.anchor,
              let variation = prepared.context.variations.first(where: {
                  $0.rank == rank
              })
        else { return }
        let moveCount = variation.uciLine?.count
            ?? (variation.move.isEmpty ? 0 : 1)
        let nextStep = min(max(0, currentStep + offset), moveCount)
        setTeachingPreview(variationRank: rank, step: nextStep)
    }

    func returnFromTeachingPreview() {
        guard var moment = teachingMoment,
              isCurrent(moment.anchor),
              case .previewing(let hint, _, _) = moment.phase
        else { return }
        moment.phase = .revealed(hint)
        teachingMoment = moment
    }

    func continueTeachingMoment() {
        freezeTeachingUpgrade()
        persistCompletedTeachingLesson()
        endTeachingMoment(resumeClock: true)
    }

    func sendChat(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !isCoachWorking,
              activeGame != nil,
              status.result == .inProgress,
              historyPreview == nil
        else { return }
        freezeTeachingUpgrade()
        coachTask?.cancel()
        coachTask = Task { [weak self] in
            await self?.streamCoachReply(to: trimmed)
        }
    }

    func clearError() {
        errorMessage = ""
        if case .failed = coachChatState {
            refreshCoachChatCapabilityState()
        }
    }

    private func makePlayerMove(
        uci: String,
        origin: PromotionRequestOrigin
    ) async {
        let teachingAnchor: PositionAnchor?
        switch origin {
        case .live:
            guard canPlayerMove else { return }
            teachingAnchor = nil
        case .teaching(let anchor):
            guard canCommitTeachingMove(uci: uci, anchor: anchor) else { return }
            teachingAnchor = anchor
        }
        guard let game = activeGame else { return }

        if let teachingAnchor {
            freezeTeachingUpgrade()
            persistCompletedTeachingLesson()
            endTeachingMoment(resumeClock: false)
            guard isCurrent(teachingAnchor) else { return }
        }

        coachTask?.cancel()
        coachTask = nil
        isCoachWorking = false
        let cachedBaseline = baselineAnalysis
        coachAnalysisTask?.cancel()
        coachAnalysisTask = nil
        coachInferenceTask?.cancel()
        coachInferenceTask = nil
        tickClock()
        guard status.result == .inProgress, activeGame?.id == game.id else {
            return
        }
        let clockBefore = clocks
        activeClockSide = nil
        var operationToken: PositionRevisionToken?
        do {
            let made = try state.make(uci: uci)
            advancePositionRevision()
            teachingMoment = nil
            coachPreparationState = .idle
            currentHint = nil
            hintRevealed = false
            hintArrow = nil
            lastAnalysis = nil
            baselineAnalysis = nil
            addIncrement(for: playerSide)
            let ply = SavedPly(
                index: state.plyCount - 1,
                side: made.side,
                uci: made.uci,
                san: made.san,
                fenBefore: made.fenBefore,
                fenAfter: made.fenAfter,
                clockBefore: clockBefore,
                clockAfter: clocks
            )
            persistence.append(ply, to: game)
            updateSavedGame()

            let gameStatus = state.status()
            if gameStatus.isFinished {
                finish(result: gameStatus.result, reason: gameStatus.reason, message: gameStatus.message)
                return
            }
            operationToken = currentPositionToken()

            if configuration.blunderGuardEnabled {
                let before: PositionAnalysis
                if let cachedBaseline, cachedBaseline.fen == made.fenBefore {
                    before = cachedBaseline
                } else {
                    before = try await analyst.analyze(
                        fen: made.fenBefore,
                        multiPV: 1,
                        moveTimeMilliseconds: 300
                    )
                }
                try Task.checkCancellation()
                guard let operationToken,
                      isCurrent(operationToken),
                      operationToken.fen == made.fenAfter
                else {
                    return
                }
                let after = try await analyst.analyze(fen: made.fenAfter, multiPV: 1, moveTimeMilliseconds: 300)
                guard isCurrent(operationToken), operationToken.fen == made.fenAfter else {
                    return
                }
                persistence.recordAnalysis(
                    before,
                    purpose: "blunder-guard-before",
                    atPly: max(0, state.plyCount - 1),
                    in: game
                )
                persistence.recordAnalysis(
                    after,
                    purpose: "blunder-guard-after",
                    atPly: state.plyCount,
                    in: game
                )
                if let warning = blunderDetector.warning(before: before, after: after, playerSide: playerSide) {
                    persistence.recordAssistance(
                        .blunderWarning,
                        atPly: state.plyCount,
                        detail: warning.reason,
                        in: game
                    )
                    blunderWarning = warning
                    activeClockSide = playerSide
                    lastClockTick = clock.now()
                    return
                }
            }
            requestOpponentMove()
        } catch {
            if let operationToken, !isCurrent(operationToken) { return }
            if error is CancellationError { return }
            errorMessage = error.localizedDescription
            activeClockSide = state.sideToMove == playerSide ? playerSide : nil
            lastClockTick = clock.now()
        }
    }

    private func schedulePlayerMove(
        uci: String,
        origin: PromotionRequestOrigin
    ) {
        if case .teaching = origin {
            freezeTeachingUpgrade()
        }
        playerMoveTask?.cancel()
        playerMoveTask = Task { [weak self] in
            await self?.makePlayerMove(uci: uci, origin: origin)
            guard let self, !Task.isCancelled else { return }
            self.playerMoveTask = nil
        }
    }

    private func requestOpponentMove() {
        guard status.result == .inProgress, state.sideToMove == playerSide.opposite else { return }
        blunderWarning = nil
        tickClock()
        guard status.result == .inProgress,
              state.sideToMove == playerSide.opposite
        else {
            isEngineThinking = false
            return
        }
        activeClockSide = nil
        lastClockTick = clock.now()
        isEngineThinking = true
        let fen = state.fen
        let currentClocks = clocks
        guard let token = currentPositionToken() else {
            isEngineThinking = false
            return
        }
        engineTask?.cancel()
        engineTask = Task {
            do {
                let move = try await opponent.opponentMove(
                    fen: fen,
                    difficulty: configuration.difficulty,
                    clocks: currentClocks,
                    timeControl: configuration.timeControl
                )
                guard !Task.isCancelled, isCurrent(token), state.fen == fen else { return }
                applyOpponentMove(move)
            } catch {
                guard isCurrent(token), !Task.isCancelled else { return }
                isEngineThinking = false
                activeClockSide = state.sideToMove == playerSide ? playerSide : nil
                lastClockTick = clock.now()
                errorMessage = error.localizedDescription
            }
        }
    }

    private func applyOpponentMove(_ uci: String) {
        guard let game = activeGame else { return }
        coachTask?.cancel()
        coachTask = nil
        isCoachWorking = false
        let clockBefore = clocks
        do {
            let made = try state.make(uci: uci)
            advancePositionRevision()
            teachingMoment = nil
            coachPreparationState = .idle
            currentHint = nil
            hintRevealed = false
            hintArrow = nil
            lastAnalysis = nil
            baselineAnalysis = nil
            addIncrement(for: playerSide.opposite)
            let ply = SavedPly(
                index: state.plyCount - 1,
                side: made.side,
                uci: made.uci,
                san: made.san,
                fenBefore: made.fenBefore,
                fenAfter: made.fenAfter,
                clockBefore: clockBefore,
                clockAfter: clocks
            )
            persistence.append(ply, to: game)
            isEngineThinking = false
            updateSavedGame()
            let gameStatus = state.status()
            if gameStatus.isFinished {
                finish(result: gameStatus.result, reason: gameStatus.reason, message: gameStatus.message)
            } else {
                activeClockSide = playerSide
                lastClockTick = clock.now()
                cacheBaselineAnalysis()
            }
        } catch {
            isEngineThinking = false
            activeClockSide = state.sideToMove == playerSide ? playerSide : nil
            lastClockTick = clock.now()
            errorMessage = error.localizedDescription
        }
    }

    private func deliverTeachingHint(_ hint: CoachHint, momentID: UUID) {
        guard var moment = teachingMoment,
              moment.id == momentID,
              isCurrent(moment.anchor),
              let game = activeGame
        else { return }
        moment.phase = .concept(hint)
        teachingMoment = moment
        currentHint = hint
        hintRevealed = false
        hintArrow = nil
        persistence.recordAssistance(
            .conceptHint,
            atPly: moment.anchor.ply,
            detail: "Concept-first hint delivered.",
            in: game
        )
    }

    private func streamCoachReply(to question: String) async {
        guard let game = activeGame, let token = currentPositionToken() else { return }
        let operationID = UUID()
        let turnID = UUID()
        let warningSessionID = blunderWarning?.id
        let sessionID = teachingMoment?.id ?? warningSessionID
        coachOperationID = operationID
        isCoachWorking = true
        coachChatState = .working
        errorMessage = ""

        let currentPositionHistory =
            CoachThreadProjectionBuilder().inferenceHistory(
                messages: coachMessages,
                positionFEN: token.fen,
                ply: token.ply
            )
        let user = CoachMessage(
            role: .user,
            text: question,
            ply: state.plyCount,
            positionFEN: token.fen,
            turnID: turnID,
            kind: .question,
            sessionID: sessionID
        )
        var assistant = CoachMessage(
            role: .coach,
            text: "",
            ply: state.plyCount,
            positionFEN: token.fen,
            turnID: turnID,
            kind: warningSessionID == nil ? .answer : .warningExplanation,
            sessionID: sessionID
        )
        coachMessages.append(user)
        coachMessages.append(assistant)
        let pendingMessageIDs = Set([user.id, assistant.id])
        var completedTurn = false

        let belongsToTeachingMoment =
            teachingMoment?.anchor.gameID == token.gameID &&
            teachingMoment?.anchor.revision == token.revision &&
            teachingMoment?.anchor.ply == token.ply &&
            teachingMoment?.anchor.fen == token.fen
        let clockSide = belongsToTeachingMoment
            ? nil
            : pauseClockForSystemWork()
        defer {
            if !completedTurn {
                coachMessages.removeAll {
                    pendingMessageIDs.contains($0.id)
                }
            }
            if coachOperationID == operationID {
                if !belongsToTeachingMoment, isCurrent(token) {
                    resumeClockAfterSystemWork(clockSide)
                }
                coachOperationID = nil
                coachTask = nil
                isCoachWorking = false
                if case .working = coachChatState {
                    refreshCoachChatCapabilityState()
                }
            }
        }
        do {
            let analysis: PositionAnalysis
            if let lastAnalysis, lastAnalysis.fen == token.fen {
                analysis = lastAnalysis
            } else {
                analysis = try await analyst.analyze(
                    fen: token.fen,
                    multiPV: 3,
                    moveTimeMilliseconds: 650
                )
            }
            guard isCurrent(token), !Task.isCancelled else { return }
            lastAnalysis = analysis
            persistence.recordAnalysis(
                analysis,
                purpose: "coach-chat",
                atPly: state.plyCount,
                in: game
            )
            let contextPurpose: String
            if let moment = teachingMoment,
               case .previewing(_, let rank, let step) = moment.phase {
                contextPurpose =
                    "follow-up coaching question while previewing Stockfish variation \(rank) after \(step) plies"
            } else if teachingMoment != nil {
                contextPurpose = "follow-up question during a paused teaching moment"
            } else {
                contextPurpose = "follow-up coaching question"
            }
            let context = contextBuilder.build(
                purpose: contextPurpose,
                state: state,
                analysis: analysis,
                playerSide: playerSide,
                clocks: clocks,
                control: configuration.timeControl,
                profile: persistence.profile
            )
            let credential = inferenceSettings.existingKey()
            guard inferenceSettings.isConfigured else {
                throw InferenceError.missingKey
            }
            let reply = try await inference.generateReply(
                configuration: inferenceSettings.configuration,
                credential: credential,
                context: context,
                history: currentPositionHistory + [user]
            )
            guard isCurrent(token), !Task.isCancelled else { return }
            assistant.text = reply.plainText
            assistant.structuredReply = reply
            guard persistence.appendCoachTurn(
                user: user,
                assistant: assistant,
                structuredReply: reply,
                positionFEN: token.fen,
                turnID: turnID,
                sessionID: sessionID,
                to: game
            ) else {
                errorMessage = "The coaching reply was ready but could not be saved."
                coachChatState = .failed(message: errorMessage)
                return
            }
            guard let pendingIndex = coachMessages.firstIndex(where: {
                $0.id == assistant.id
            }) else {
                return
            }
            coachMessages[pendingIndex] = assistant
            persistence.recordAssistance(
                .coachChat,
                atPly: token.ply,
                detail: "",
                in: game
            )
            completedTurn = true
            coachChatState = .ready
        } catch {
            guard isCurrent(token), !Task.isCancelled, !(error is CancellationError) else { return }
            errorMessage = "Natural-language coaching is unavailable: \(error.localizedDescription)"
            coachChatState = .failed(message: error.localizedDescription)
        }
    }

    private func fallbackHint(context: CoachContext) -> CoachHint {
        DeterministicHintBuilder().build(context: context)
    }

    private func pauseClockForSystemWork() -> ChessSide? {
        tickClock()
        let pausedSide = activeClockSide
        activeClockSide = nil
        lastClockTick = clock.now()
        return pausedSide
    }

    private func resumeClockAfterSystemWork(_ side: ChessSide?) {
        guard status.result == .inProgress,
              activeClockSide == nil,
              let side,
              state.sideToMove == side || (blunderWarning != nil && side == playerSide)
        else { return }
        activeClockSide = side
        lastClockTick = clock.now()
    }

    private func cacheBaselineAnalysis() {
        guard state.sideToMove == playerSide,
              status.result == .inProgress,
              teachingMoment == nil,
              let anchor = currentPositionAnchor()
        else {
            coachPreparationState = .idle
            return
        }
        reviewTask?.cancel()
        reviewTask = nil
        baselineAnalysis = nil
        coachAnalysisTask?.cancel()
        coachInferenceTask?.cancel()
        coachInferenceTask = nil
        coachPreparationState = .analyzing(anchor)
        coachAnalysisTask = Task {
            do {
                let analysis = try await analyst.analyze(
                    fen: anchor.fen,
                    multiPV: 3,
                    moveTimeMilliseconds: 650
                )
                guard !Task.isCancelled,
                      isCurrent(anchor)
                else { return }
                guard analysis.fen == anchor.fen else {
                    throw CoachingPreparationError.mismatchedAnalysis
                }
                baselineAnalysis = analysis
                lastAnalysis = analysis
                guard let game = activeGame else { return }
                persistence.recordAnalysis(
                    analysis,
                    purpose: "baseline",
                    atPly: anchor.ply,
                    in: game
                )
                let context = contextBuilder.build(
                    purpose: "prepared concept-first hint",
                    state: state,
                    analysis: analysis,
                    playerSide: playerSide,
                    clocks: clocks,
                    control: configuration.timeControl,
                    profile: persistence.profile
                )
                let credential = inferenceSettings.existingKey()
                let enhancement: CoachEnhancementState =
                    inferenceSettings.isConfigured ? .preparing : .notConfigured
                let deterministicHint = fallbackHint(context: context)
                guard !Task.isCancelled, isCurrent(anchor) else { return }
                let prepared = PreparedCoaching(
                    anchor: anchor,
                    analysis: analysis,
                    context: context,
                    deterministicHint: deterministicHint,
                    providerHint: nil,
                    enhancement: enhancement
                )
                coachPreparationState = .ready(prepared)
                coachAnalysisTask = nil
                if enhancement == .preparing {
                    launchCoachEnhancement(
                        prepared: prepared,
                        configuration: inferenceSettings.configuration,
                        credential: credential
                    )
                }
            } catch {
                guard !Task.isCancelled, isCurrent(anchor) else { return }
                coachAnalysisTask = nil
                coachPreparationState = .failed(
                    anchor,
                    message: error.localizedDescription
                )
            }
        }
    }

    private func launchCoachEnhancement(
        prepared: PreparedCoaching,
        configuration: InferenceConfiguration,
        credential: String
    ) {
        guard isCurrent(prepared.anchor) else {
            return
        }
        coachInferenceTask?.cancel()
        coachInferenceTask = Task {
            do {
                let hint = try await inference.generateHint(
                    configuration: configuration,
                    credential: credential,
                    context: prepared.context
                )
                guard !Task.isCancelled,
                      isCurrent(prepared.anchor),
                      case .ready(var current) = coachPreparationState,
                      current.anchor == prepared.anchor
                else {
                    return
                }
                guard hint.recommendedMove == prepared.analysis.bestMove else {
                    current.enhancement = .unavailable
                    coachPreparationState = .ready(current)
                    coachInferenceTask = nil
                    return
                }
                current.providerHint = hint
                current.enhancement = .ready
                coachPreparationState = .ready(current)
                coachInferenceTask = nil
                upgradeOpenTeachingConceptIfEligible(
                    hint,
                    anchor: prepared.anchor
                )
            } catch {
                guard !Task.isCancelled,
                      isCurrent(prepared.anchor),
                      case .ready(var current) = coachPreparationState,
                      current.anchor == prepared.anchor
                else {
                    return
                }
                current.enhancement = .unavailable
                coachPreparationState = .ready(current)
                coachInferenceTask = nil
            }
        }
    }

    func refreshPreparedCoachingForCurrentPosition() {
        refreshCoachChatCapabilityState()
        guard status.result == .inProgress,
              state.sideToMove == playerSide,
              let anchor = currentPositionAnchor()
        else {
            return
        }

        if case .ready(let prepared) = coachPreparationState,
           prepared.anchor == anchor {
            restartCoachEnhancement(from: prepared)
            return
        }

        guard teachingMoment == nil else { return }
        cacheBaselineAnalysis()
    }

    func retryCoachPreparation() {
        guard status.result == .inProgress,
              state.sideToMove == playerSide,
              blunderWarning == nil,
              teachingMoment == nil,
              let current = currentPositionAnchor(),
              case .failed(let failedAnchor, _) = coachPreparationState,
              current == failedAnchor
        else {
            return
        }
        cacheBaselineAnalysis()
    }

    private func restartCoachEnhancement(
        from existing: PreparedCoaching
    ) {
        var prepared = existing
        let credential = inferenceSettings.existingKey()
        guard inferenceSettings.isConfigured else {
            coachInferenceTask?.cancel()
            coachInferenceTask = nil
            prepared.providerHint = nil
            prepared.enhancement = .notConfigured
            coachPreparationState = .ready(prepared)
            return
        }
        prepared.providerHint = nil
        prepared.enhancement = .preparing
        coachPreparationState = .ready(prepared)
        launchCoachEnhancement(
            prepared: prepared,
            configuration: inferenceSettings.configuration,
            credential: credential
        )
    }

    private func upgradeOpenTeachingConceptIfEligible(
        _ hint: CoachHint,
        anchor: PositionAnchor
    ) {
        guard var moment = teachingMoment,
              moment.anchor == anchor,
              moment.isUpgradeEligible,
              case .concept = moment.phase
        else {
            return
        }
        moment.phase = .concept(hint)
        moment.isUpgradeEligible = false
        teachingMoment = moment
        currentHint = hint
    }

    private func addIncrement(for side: ChessSide) {
        guard configuration.timeControl.usesClock else { return }
        let increment = configuration.timeControl.incrementSeconds * 1_000
        if side == .white { clocks.whiteMilliseconds += increment }
        else { clocks.blackMilliseconds += increment }
    }

    private func startClock() {
        clockTask?.cancel()
        lastClockTick = clock.now()
        clockTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { break }
                await clock.sleepForTick()
                guard !Task.isCancelled else { break }
                tickClock()
            }
        }
    }

    private func tickClock() {
        guard configuration.timeControl.usesClock,
              status.result == .inProgress,
              let activeClockSide
        else {
            lastClockTick = clock.now()
            return
        }
        let now = clock.now()
        let elapsed = max(0, Int(now.timeIntervalSince(lastClockTick) * 1_000))
        lastClockTick = now
        if activeClockSide == .white {
            clocks.whiteMilliseconds = max(0, clocks.whiteMilliseconds - elapsed)
            if clocks.whiteMilliseconds == 0 {
                finish(result: .blackWon, reason: .timeout, message: "White ran out of time.")
            }
        } else {
            clocks.blackMilliseconds = max(0, clocks.blackMilliseconds - elapsed)
            if clocks.blackMilliseconds == 0 {
                finish(result: .whiteWon, reason: .timeout, message: "Black ran out of time.")
            }
        }
        if now.timeIntervalSince(lastClockAutosave) >= 1 {
            lastClockAutosave = now
            saveCurrentClocks()
        }
    }

    private func finish(result: GameResult, reason: GameEndReason, message: String) {
        guard status.result == .inProgress else { return }
        advancePositionRevision()
        status = ChessGameStatus(result: result, reason: reason, message: message)
        activeClockSide = nil
        isEngineThinking = false
        playerMoveTask?.cancel()
        engineTask?.cancel()
        coachAnalysisTask?.cancel()
        coachInferenceTask?.cancel()
        coachTask?.cancel()
        coachOperationID = nil
        isCoachWorking = false
        teachingMoment = nil
        coachPreparationState = .idle
        currentHint = nil
        hintRevealed = false
        hintArrow = nil
        clockTask?.cancel()
        playerMoveTask = nil
        coachAnalysisTask = nil
        coachInferenceTask = nil
        clockTask = nil
        guard let game = activeGame else { return }
        game.result = result
        game.endReason = reason
        game.endedAt = clock.now()
        updateSavedGame()
        reviewTask?.cancel()
        reviewTask = Task { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await reviewAnalyzer.reviewPendingGames(
                persistence: persistence
            )
        }
    }

    private func updateSavedGame() {
        guard let game = activeGame else { return }
        game.currentFEN = state.fen
        game.pgn = state.pgn(playerSide: playerSide, result: status.result)
        game.currentWhiteClockMilliseconds = clocks.whiteMilliseconds
        game.currentBlackClockMilliseconds = clocks.blackMilliseconds
        persistence.save()
    }

    private func saveCurrentClocks() {
        guard let game = activeGame else { return }
        game.currentWhiteClockMilliseconds = clocks.whiteMilliseconds
        game.currentBlackClockMilliseconds = clocks.blackMilliseconds
        persistence.save()
    }

    private func refreshCoachChatCapabilityState() {
        guard !isCoachWorking else { return }
        if inferenceSettings.isConfigured {
            coachChatState = .ready
        } else {
            coachChatState = .unavailable(
                issue: inferenceSettings.configurationIssue ?? .missingModel
            )
        }
    }

    private func currentPositionAnchor() -> PositionAnchor? {
        guard let gameID = activeGame?.id else { return nil }
        return PositionAnchor(
            gameID: gameID,
            revision: positionRevision,
            ply: state.plyCount,
            fen: state.fen
        )
    }

    /// Advances the authoritative live position and invalidates every
    /// read-only history selection made against the previous continuation.
    private func advancePositionRevision() {
        positionRevision += 1
        historyPreview = nil
    }

    private func matchesCurrentPosition(_ anchor: PositionAnchor) -> Bool {
        anchor.gameID == activeGame?.id &&
            anchor.ply == state.plyCount &&
            anchor.fen == state.fen &&
            anchor.revision == positionRevision
    }

    private func teachingHint(
        from phase: TeachingMomentPhase
    ) -> CoachHint? {
        switch phase {
        case .concept(let hint),
             .revealed(let hint),
             .previewing(let hint, _, _):
            hint
        case .preparing, .failed:
            nil
        }
    }

    private func freezeTeachingUpgrade() {
        guard var moment = teachingMoment, moment.isUpgradeEligible else {
            return
        }
        moment.isUpgradeEligible = false
        teachingMoment = moment
    }

    private func canCommitTeachingMove(
        uci: String,
        anchor: PositionAnchor
    ) -> Bool {
        guard canMoveFromTeachingMoment,
              let moment = teachingMoment,
              moment.anchor == anchor,
              isCurrent(anchor),
              state.legalMoves.contains(uci)
        else {
            return false
        }
        return true
    }

    private func persistCompletedTeachingLesson() {
        guard let moment = teachingMoment,
              let hint = teachingHint(from: moment.phase),
              isCurrent(moment.anchor),
              let game = activeGame,
              game.id == moment.anchor.gameID,
              !coachMessages.contains(where: { $0.turnID == moment.id }),
              !game.coachMessages.contains(where: { $0.turnID == moment.id })
        else {
            return
        }

        var sections: [CoachReplySection] = []
        switch moment.phase {
        case .revealed, .previewing:
            sections = [
                CoachReplySection(
                    kind: .explanation,
                    title: "Why it works",
                    body: hint.why,
                    variationRank: nil
                ),
                CoachReplySection(
                    kind: .plan,
                    title: "Plan",
                    body: hint.plan,
                    variationRank: nil
                ),
            ]
            if case .ready(let prepared) = coachPreparationState,
               prepared.anchor == moment.anchor,
               prepared.context.variations.contains(where: { $0.rank == 1 }) {
                sections.append(
                    CoachReplySection(
                        kind: .variation,
                        title: "Engine line",
                        body: "Review the authoritative continuation from this position.",
                        variationRank: 1
                    )
                )
            }
        case .concept:
            break
        case .preparing, .failed:
            return
        }

        let reply = CoachReply(
            summary: hint.concept,
            sections: sections
        )
        let message = CoachMessage(
            role: .coach,
            text: reply.plainText,
            ply: moment.anchor.ply,
            structuredReply: reply,
            positionFEN: moment.anchor.fen,
            turnID: moment.id,
            kind: .lesson,
            sessionID: moment.id
        )
        coachMessages.append(message)
        persistence.append(
            message,
            structuredReply: reply,
            positionFEN: moment.anchor.fen,
            turnID: moment.id,
            kind: .lesson,
            sessionID: moment.id,
            to: game
        )
    }

    private func isCurrent(_ anchor: PositionAnchor) -> Bool {
        matchesCurrentPosition(anchor) &&
            status.result == .inProgress
    }

    private func isCurrentTeachingMoment(
        id: UUID,
        anchor: PositionAnchor
    ) -> Bool {
        teachingMoment?.id == id &&
            teachingMoment?.anchor == anchor &&
            isCurrent(anchor)
    }

    private func endTeachingMoment(resumeClock: Bool) {
        guard let moment = teachingMoment else { return }
        coachTask?.cancel()
        coachTask = nil
        coachOperationID = nil
        isCoachWorking = false
        teachingMoment = nil
        selectedSquare = nil
        promotionRequest = nil
        currentHint = nil
        hintRevealed = false
        hintArrow = nil

        guard resumeClock,
              isCurrent(moment.anchor),
              activeClockSide == nil,
              let side = moment.pausedClockSide,
              state.sideToMove == side
        else { return }
        activeClockSide = side
        lastClockTick = clock.now()
    }

    private func currentPositionToken() -> PositionRevisionToken? {
        guard let gameID = activeGame?.id else { return nil }
        return PositionRevisionToken(
            gameID: gameID,
            ply: state.plyCount,
            fen: state.fen,
            revision: positionRevision
        )
    }

    private func isCurrent(_ token: PositionRevisionToken) -> Bool {
        token.gameID == activeGame?.id &&
            token.ply == state.plyCount &&
            token.fen == state.fen &&
            token.revision == positionRevision &&
            status.result == .inProgress
    }

    private func abandonActiveGameIfNeeded() {
        guard let game = activeGame, game.result == .inProgress else { return }
        game.result = .abandoned
        game.endReason = .restarted
        game.endedAt = clock.now()
        game.currentFEN = state.fen
        game.pgn = state.pgn(playerSide: playerSide, result: .abandoned)
        game.currentWhiteClockMilliseconds = clocks.whiteMilliseconds
        game.currentBlackClockMilliseconds = clocks.blackMilliseconds
        game.reviewCompleted = false
        persistence.save()
        persistence.refreshGames()
    }

    private func cancelWork() {
        playerMoveTask?.cancel()
        engineTask?.cancel()
        coachAnalysisTask?.cancel()
        coachInferenceTask?.cancel()
        coachTask?.cancel()
        reviewTask?.cancel()
        clockTask?.cancel()
        playerMoveTask = nil
        engineTask = nil
        coachAnalysisTask = nil
        coachInferenceTask = nil
        coachTask = nil
        reviewTask = nil
        clockTask = nil
        coachOperationID = nil
        isEngineThinking = false
        isCoachWorking = false
        refreshCoachChatCapabilityState()
        teachingMoment = nil
        selectedSquare = nil
        promotionRequest = nil
        coachPreparationState = .idle
    }
}
