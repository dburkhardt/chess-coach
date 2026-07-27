import Foundation

enum CoachInspectorScene: String, Equatable, Sendable {
    case neutral
    case empty
    case live
    case warning
    case lesson
    case completed
}

enum CoachConversationScope: Hashable, Sendable {
    case currentPosition
    case lesson(sessionID: UUID)
    case warning
}

enum CoachInspectorRoute: Hashable, Sendable {
    case conversation(CoachConversationScope)
    case history
    case variation(rank: Int)
}

enum CoachChatState: Equatable, Sendable {
    case unavailable(message: String)
    case ready
    case working
    case failed(message: String)

    var isCapable: Bool {
        if case .unavailable = self { false } else { true }
    }
}

enum CoachHeaderStyle: Equatable, Sendable {
    case neutral
    case progress
    case ready
    case teaching
    case warning
    case unavailable
    case completed
}

struct CoachHeaderPresentation: Equatable, Sendable {
    var title: String
    var status: String?
    var style: CoachHeaderStyle
    var showsHistory: Bool
    var showsTakeBack: Bool
    var showsSettings: Bool
}

enum CoachCommandAction: Hashable, Sendable {
    case openHint
    case retryAnalysis
    case revealMove
    case exploreEngineLine(rank: Int)
    case previewPrevious
    case previewNext
    case returnToPosition
    case continuePlaying
    case takeBack
    case playOn
    case askCoach
}

enum CoachCommandStyle: Equatable, Sendable {
    case primary
    case secondary
    case quiet
    case destructive
}

struct CoachCommandPresentation: Identifiable, Equatable, Sendable {
    var action: CoachCommandAction
    var label: String
    var systemImage: String?
    var style: CoachCommandStyle
    var isEnabled: Bool

    var id: CoachCommandAction { action }
}

struct CoachInspectorSnapshot: Equatable, Sendable {
    var isCurrentGameVisible: Bool
    var hasActiveGame: Bool
    var gameResult: GameResult
    var isEngineThinking: Bool
    var hasBlunderWarning: Bool
    var preparationState: CoachPreparationState
    var teachingMoment: TeachingMomentState?
    var canTakeBack: Bool
    var chatState: CoachChatState
    var currentPositionTurnCount: Int
    var earlierItemCount: Int
    var hasPrincipalVariation: Bool
    var principalVariationMoveCount: Int

    init(
        isCurrentGameVisible: Bool,
        hasActiveGame: Bool,
        gameResult: GameResult = .inProgress,
        isEngineThinking: Bool = false,
        hasBlunderWarning: Bool = false,
        preparationState: CoachPreparationState = .idle,
        teachingMoment: TeachingMomentState? = nil,
        canTakeBack: Bool = false,
        chatState: CoachChatState = .ready,
        currentPositionTurnCount: Int = 0,
        earlierItemCount: Int = 0,
        hasPrincipalVariation: Bool = false,
        principalVariationMoveCount: Int = 0
    ) {
        self.isCurrentGameVisible = isCurrentGameVisible
        self.hasActiveGame = hasActiveGame
        self.gameResult = gameResult
        self.isEngineThinking = isEngineThinking
        self.hasBlunderWarning = hasBlunderWarning
        self.preparationState = preparationState
        self.teachingMoment = teachingMoment
        self.canTakeBack = canTakeBack
        self.chatState = chatState
        self.currentPositionTurnCount = currentPositionTurnCount
        self.earlierItemCount = earlierItemCount
        self.hasPrincipalVariation = hasPrincipalVariation
        self.principalVariationMoveCount = principalVariationMoveCount
    }
}

struct CoachInspectorPresentation: Equatable, Sendable {
    var scene: CoachInspectorScene
    var header: CoachHeaderPresentation
    var commands: [CoachCommandPresentation]
    var showsComposer: Bool
    var currentPositionTurnCount: Int
    var earlierItemCount: Int

    var primaryCommand: CoachCommandPresentation? {
        commands.first { $0.style == .primary }
    }
}

struct CoachInspectorPresentationResolver {
    func resolve(
        _ snapshot: CoachInspectorSnapshot
    ) -> CoachInspectorPresentation {
        let scene = scene(for: snapshot)
        assert(
            !(snapshot.hasBlunderWarning && snapshot.teachingMoment != nil),
            "Blunder Guard and a teaching moment must not be active together."
        )

        return CoachInspectorPresentation(
            scene: scene,
            header: header(for: scene, snapshot: snapshot),
            commands: commands(for: scene, snapshot: snapshot),
            showsComposer: showsComposer(for: scene, snapshot: snapshot),
            currentPositionTurnCount: snapshot.currentPositionTurnCount,
            earlierItemCount: snapshot.earlierItemCount
        )
    }

    private func scene(
        for snapshot: CoachInspectorSnapshot
    ) -> CoachInspectorScene {
        if !snapshot.isCurrentGameVisible { return .neutral }
        if !snapshot.hasActiveGame { return .empty }
        if snapshot.gameResult != .inProgress { return .completed }
        if snapshot.hasBlunderWarning { return .warning }
        if snapshot.teachingMoment != nil { return .lesson }
        return .live
    }

    private func header(
        for scene: CoachInspectorScene,
        snapshot: CoachInspectorSnapshot
    ) -> CoachHeaderPresentation {
        let status: String?
        let style: CoachHeaderStyle

        switch scene {
        case .neutral:
            status = nil
            style = .neutral
        case .empty:
            status = nil
            style = .neutral
        case .completed:
            status = "Game complete"
            style = .completed
        case .warning:
            status = "Blunder Guard"
            style = .warning
        case .lesson:
            status = "Teaching moment · paused"
            style = .teaching
        case .live:
            (status, style) = liveStatus(snapshot)
        }

        return CoachHeaderPresentation(
            title: "Coach",
            status: status,
            style: style,
            showsHistory: scene != .neutral &&
                scene != .empty &&
                snapshot.earlierItemCount > 0,
            showsTakeBack: scene == .live && snapshot.canTakeBack,
            showsSettings: scene != .neutral
        )
    }

    private func liveStatus(
        _ snapshot: CoachInspectorSnapshot
    ) -> (String?, CoachHeaderStyle) {
        if snapshot.isEngineThinking {
            return ("Computer thinking", .progress)
        }

        switch snapshot.preparationState {
        case .idle:
            if case .unavailable = snapshot.chatState {
                return ("Coaching unavailable", .unavailable)
            }
            return (nil, .neutral)
        case .analyzing:
            return ("Analyzing position", .progress)
        case .failed:
            return ("Coaching unavailable", .unavailable)
        case .ready(let prepared):
            switch prepared.enhancement {
            case .preparing:
                return ("Hint ready · Coach polishing", .progress)
            case .ready:
                return ("Coach hint ready", .ready)
            case .notConfigured, .unavailable:
                return ("Stockfish hint ready", .ready)
            }
        }
    }

    private func commands(
        for scene: CoachInspectorScene,
        snapshot: CoachInspectorSnapshot
    ) -> [CoachCommandPresentation] {
        switch scene {
        case .neutral, .empty, .completed:
            return []
        case .live:
            switch snapshot.preparationState {
            case .ready:
                return [
                    command(
                        .openHint,
                        "Open Hint",
                        systemImage: "lightbulb",
                        style: .primary
                    ),
                ]
            case .failed:
                return [
                    command(
                        .retryAnalysis,
                        "Retry Analysis",
                        systemImage: "arrow.clockwise",
                        style: .primary
                    ),
                ]
            case .idle, .analyzing:
                return []
            }
        case .warning:
            return [
                command(
                    .takeBack,
                    "Take Back",
                    systemImage: "arrow.uturn.backward",
                    style: .primary
                ),
                command(.playOn, "Play On", style: .secondary),
                command(
                    .askCoach,
                    "Ask Coach",
                    systemImage: "bubble.left.and.bubble.right",
                    style: .quiet
                ),
            ]
        case .lesson:
            guard let moment = snapshot.teachingMoment else { return [] }
            switch moment.phase {
            case .preparing, .failed:
                return [
                    command(
                        .continuePlaying,
                        "Continue Playing",
                        systemImage: "play.fill",
                        style: .primary
                    ),
                ]
            case .concept:
                return [
                    command(
                        .revealMove,
                        "Reveal Move",
                        systemImage: "arrow.right",
                        style: .primary
                    ),
                    command(
                        .continuePlaying,
                        "Continue Playing",
                        systemImage: "play.fill",
                        style: .secondary
                    ),
                ]
            case .revealed:
                var result: [CoachCommandPresentation] = [
                    command(
                        .continuePlaying,
                        "Continue Playing",
                        systemImage: "play.fill",
                        style: .primary
                    ),
                ]
                if snapshot.hasPrincipalVariation {
                    result.append(
                        command(
                            .exploreEngineLine(rank: 1),
                            "Explore Engine Line",
                            systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                            style: .secondary
                        )
                    )
                }
                return result
            case .previewing(_, _, let step):
                return [
                    command(
                        .continuePlaying,
                        "Continue Playing",
                        systemImage: "play.fill",
                        style: .primary
                    ),
                    command(
                        .previewPrevious,
                        "Back",
                        systemImage: "chevron.left",
                        style: .quiet,
                        isEnabled: step > 0
                    ),
                    command(
                        .previewNext,
                        "Next",
                        systemImage: "chevron.right",
                        style: .secondary,
                        isEnabled:
                            step < snapshot.principalVariationMoveCount
                    ),
                    command(
                        .returnToPosition,
                        "Return to Position",
                        systemImage: "arrow.uturn.backward",
                        style: .secondary
                    ),
                ]
            }
        }
    }

    private func showsComposer(
        for scene: CoachInspectorScene,
        snapshot: CoachInspectorSnapshot
    ) -> Bool {
        guard snapshot.chatState.isCapable else { return false }
        switch scene {
        case .live, .lesson:
            return true
        case .neutral, .empty, .warning, .completed:
            return false
        }
    }

    private func command(
        _ action: CoachCommandAction,
        _ label: String,
        systemImage: String? = nil,
        style: CoachCommandStyle,
        isEnabled: Bool = true
    ) -> CoachCommandPresentation {
        CoachCommandPresentation(
            action: action,
            label: label,
            systemImage: systemImage,
            style: style,
            isEnabled: isEnabled
        )
    }
}

struct CoachQuestionAnswerTurn: Identifiable, Equatable, Sendable {
    let id: UUID
    let sessionID: UUID?
    let positionFEN: String?
    let ply: Int
    let question: CoachMessage
    let answer: CoachMessage?
}

enum CoachThreadItem: Identifiable, Equatable, Sendable {
    case lesson(CoachMessage)
    case turn(CoachQuestionAnswerTurn)
    case pending(CoachQuestionAnswerTurn)
    case warning(CoachMessage)
    case legacy(CoachMessage)

    var id: UUID {
        switch self {
        case .lesson(let message),
             .warning(let message),
             .legacy(let message):
            message.id
        case .turn(let turn), .pending(let turn):
            turn.id
        }
    }

    var positionFEN: String? {
        switch self {
        case .lesson(let message),
             .warning(let message),
             .legacy(let message):
            message.positionFEN
        case .turn(let turn), .pending(let turn):
            turn.positionFEN
        }
    }

    var ply: Int {
        switch self {
        case .lesson(let message),
             .warning(let message),
             .legacy(let message):
            message.ply
        case .turn(let turn), .pending(let turn):
            turn.ply
        }
    }

    fileprivate var sortDate: Date {
        switch self {
        case .lesson(let message),
             .warning(let message),
             .legacy(let message):
            message.createdAt
        case .turn(let turn), .pending(let turn):
            turn.question.createdAt
        }
    }
}

struct CoachThreadProjection: Equatable, Sendable {
    var currentPosition: [CoachThreadItem]
    var history: [CoachThreadItem]

    var all: [CoachThreadItem] {
        (currentPosition + history).sorted { $0.sortDate < $1.sortDate }
    }
}

struct CoachThreadProjectionBuilder {
    func build(
        messages: [CoachMessage],
        currentPositionFEN: String,
        currentPly: Int
    ) -> CoachThreadProjection {
        let sorted = messages.sorted { $0.createdAt < $1.createdAt }
        var consumed = Set<UUID>()
        var items: [CoachThreadItem] = []

        for message in sorted {
            if let turnID = message.turnID {
                guard consumed.insert(turnID).inserted else { continue }
                let grouped = sorted.filter { $0.turnID == turnID }
                let explicitKind = message.kind

                if let warning = grouped.first(where: {
                    $0.kind == .warningExplanation
                }) {
                    items.append(.warning(warning))
                    continue
                }
                if explicitKind == .lesson ||
                    (grouped.count == 1 &&
                        grouped[0].role == .coach &&
                        grouped[0].structuredReply != nil) {
                    items.append(.lesson(grouped[0]))
                    continue
                }
                if let question = grouped.first(where: {
                    $0.kind == .question || $0.role == .user
                }) {
                    let answer = grouped.first(where: {
                        $0.kind == .answer ||
                            ($0.role == .coach && $0.id != question.id)
                    })
                    let turn = CoachQuestionAnswerTurn(
                        id: turnID,
                        sessionID: question.sessionID ?? answer?.sessionID,
                        positionFEN: question.positionFEN ?? answer?.positionFEN,
                        ply: question.ply,
                        question: question,
                        answer: answer
                    )
                    items.append(answer == nil ? .pending(turn) : .turn(turn))
                    continue
                }
            }

            switch message.kind {
            case .lesson:
                items.append(.lesson(message))
            case .warningExplanation:
                items.append(.warning(message))
            case .question:
                let turn = CoachQuestionAnswerTurn(
                    id: message.turnID ?? message.id,
                    sessionID: message.sessionID,
                    positionFEN: message.positionFEN,
                    ply: message.ply,
                    question: message,
                    answer: nil
                )
                items.append(.pending(turn))
            case .answer, .legacy, nil:
                items.append(.legacy(message))
            }
        }

        let current = items.filter {
            $0.positionFEN == currentPositionFEN && $0.ply == currentPly
        }
        let currentIDs = Set(current.map(\.id))
        let history = items.filter { !currentIDs.contains($0.id) }
        return CoachThreadProjection(
            currentPosition: current,
            history: history
        )
    }

    func inferenceHistory(
        messages: [CoachMessage],
        positionFEN: String,
        ply: Int
    ) -> [CoachMessage] {
        let exactPositionMessages = messages.filter {
            $0.positionFEN == positionFEN && $0.ply == ply
        }
        let questionTurnIDs = Set(
            exactPositionMessages
                .filter {
                    $0.kind == .question ||
                        ($0.kind == nil && $0.role == .user)
                }
                .compactMap(\.turnID)
        )

        return exactPositionMessages
            .filter {
                switch $0.kind {
                case .question, .answer:
                    return true
                case .lesson, .warningExplanation, .legacy:
                    return false
                case nil:
                    if $0.role == .user { return true }
                    guard $0.role == .coach, let turnID = $0.turnID else {
                        return false
                    }
                    return questionTurnIDs.contains(turnID)
                }
            }
            .sorted { $0.createdAt < $1.createdAt }
    }
}
