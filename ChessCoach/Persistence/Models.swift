import Foundation
import SwiftData

@Model
final class SavedGame {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var playerSideRaw: String
    var difficulty: Int
    var timeControlRaw: String
    var blunderGuardEnabled: Bool
    var resultRaw: String
    var endReasonRaw: String
    var initialFEN: String
    var currentFEN: String
    var pgn: String
    var assistanceUsed: Bool
    var reviewCompleted: Bool
    var reviewAttemptedAt: Date?
    var reviewLastError: String = ""
    var profileIncorporated: Bool = false
    var reviewSummary: String
    var averageExpectedScoreLoss: Double
    var blunderCount: Int
    var mistakeCount: Int
    var currentWhiteClockMilliseconds: Int = 0
    var currentBlackClockMilliseconds: Int = 0
    @Relationship(deleteRule: .cascade) var plies: [SavedPly]
    @Relationship(deleteRule: .cascade) var coachMessages: [SavedCoachMessage]
    @Relationship(deleteRule: .cascade) var assistanceEvents: [SavedAssistanceEvent]
    @Relationship(deleteRule: .cascade) var analysisSnapshots: [SavedAnalysisSnapshot]

    init(
        id: UUID = UUID(),
        startedAt: Date = .now,
        playerSide: ChessSide,
        difficulty: Int,
        timeControl: TimeControl,
        blunderGuardEnabled: Bool,
        initialFEN: String
    ) {
        self.id = id
        self.startedAt = startedAt
        self.playerSideRaw = playerSide.rawValue
        self.difficulty = difficulty
        self.timeControlRaw = timeControl.rawValue
        self.blunderGuardEnabled = blunderGuardEnabled
        self.resultRaw = GameResult.inProgress.rawValue
        self.endReasonRaw = GameEndReason.none.rawValue
        self.initialFEN = initialFEN
        self.currentFEN = initialFEN
        self.pgn = "*"
        self.assistanceUsed = false
        self.reviewCompleted = false
        self.reviewAttemptedAt = nil
        self.reviewLastError = ""
        self.profileIncorporated = false
        self.reviewSummary = ""
        self.averageExpectedScoreLoss = 0
        self.blunderCount = 0
        self.mistakeCount = 0
        let initialClock = ClockSnapshot.initial(for: timeControl)
        self.currentWhiteClockMilliseconds = initialClock.whiteMilliseconds
        self.currentBlackClockMilliseconds = initialClock.blackMilliseconds
        self.plies = []
        self.coachMessages = []
        self.assistanceEvents = []
        self.analysisSnapshots = []
    }

    var playerSide: ChessSide {
        get { ChessSide(rawValue: playerSideRaw) ?? .white }
        set { playerSideRaw = newValue.rawValue }
    }
    var timeControl: TimeControl {
        get { TimeControl(rawValue: timeControlRaw) ?? .rapid10 }
        set { timeControlRaw = newValue.rawValue }
    }
    var result: GameResult {
        get { GameResult(rawValue: resultRaw) ?? .inProgress }
        set { resultRaw = newValue.rawValue }
    }
    var endReason: GameEndReason {
        get { GameEndReason(rawValue: endReasonRaw) ?? .none }
        set { endReasonRaw = newValue.rawValue }
    }
}

@Model
final class SavedPly {
    @Attribute(.unique) var id: UUID
    var index: Int
    var sideRaw: String
    var uci: String
    var san: String
    var fenBefore: String
    var fenAfter: String
    var whiteClockBefore: Int
    var blackClockBefore: Int
    var whiteClockAfter: Int
    var blackClockAfter: Int
    var expectedScoreBefore: Double?
    var expectedScoreAfter: Double?
    var classificationRaw: String?
    var expectedScoreLoss: Double?
    var bestMoveUCI: String
    var bestMoveSAN: String
    var principalVariationSAN: String
    var createdAt: Date

    init(
        index: Int,
        side: ChessSide,
        uci: String,
        san: String,
        fenBefore: String,
        fenAfter: String,
        clockBefore: ClockSnapshot,
        clockAfter: ClockSnapshot
    ) {
        self.id = UUID()
        self.index = index
        self.sideRaw = side.rawValue
        self.uci = uci
        self.san = san
        self.fenBefore = fenBefore
        self.fenAfter = fenAfter
        self.whiteClockBefore = clockBefore.whiteMilliseconds
        self.blackClockBefore = clockBefore.blackMilliseconds
        self.whiteClockAfter = clockAfter.whiteMilliseconds
        self.blackClockAfter = clockAfter.blackMilliseconds
        self.bestMoveUCI = ""
        self.bestMoveSAN = ""
        self.principalVariationSAN = ""
        self.createdAt = .now
    }

    var side: ChessSide { ChessSide(rawValue: sideRaw) ?? .white }
    var clockBefore: ClockSnapshot {
        ClockSnapshot(whiteMilliseconds: whiteClockBefore, blackMilliseconds: blackClockBefore)
    }
    var clockAfter: ClockSnapshot {
        ClockSnapshot(whiteMilliseconds: whiteClockAfter, blackMilliseconds: blackClockAfter)
    }
    var classification: MoveClassification? {
        get { classificationRaw.flatMap(MoveClassification.init(rawValue:)) }
        set { classificationRaw = newValue?.rawValue }
    }

    func moveTimeMilliseconds(control: TimeControl) -> Int {
        guard control.usesClock else { return 0 }
        let before = clockBefore.value(for: side)
        let after = clockAfter.value(for: side)
        return max(0, before + control.incrementSeconds * 1_000 - after)
    }
}

@Model
final class SavedCoachMessage {
    @Attribute(.unique) var id: UUID
    var roleRaw: String
    var text: String
    var ply: Int
    var createdAt: Date
    /// Versioned `CoachReply` JSON. Optional preserves existing text-only rows.
    var structuredContentJSON: Data? = nil
    /// Exact position this turn explains, independent of later game rewinds.
    var positionFEN: String? = nil
    /// Shared by the user question and coach answer persisted in one turn.
    var turnID: UUID? = nil
    /// Optional additive metadata keeps the existing SwiftData store eligible
    /// for automatic lightweight migration.
    var kindRaw: String? = nil
    /// Groups a lesson and all questions asked within that teaching session.
    var sessionID: UUID? = nil

    init(
        message: CoachMessage,
        structuredReply: CoachReply? = nil,
        positionFEN: String? = nil,
        turnID: UUID? = nil,
        kind: CoachMessageKind? = nil,
        sessionID: UUID? = nil
    ) {
        self.id = message.id
        self.roleRaw = message.role.rawValue
        self.text = structuredReply?.plainText ?? message.text
        self.ply = message.ply
        self.createdAt = message.createdAt
        self.structuredContentJSON = structuredReply.flatMap {
            try? JSONEncoder().encode($0)
        }
        self.positionFEN = positionFEN ?? message.positionFEN
        self.turnID = turnID ?? message.turnID
        self.kindRaw = (kind ?? message.kind)?.rawValue
        self.sessionID = sessionID ?? message.sessionID
    }

    var kind: CoachMessageKind? {
        get { kindRaw.flatMap(CoachMessageKind.init(rawValue:)) }
        set { kindRaw = newValue?.rawValue }
    }

    var structuredContent: CoachReply? {
        get {
            guard let structuredContentJSON else { return nil }
            return try? JSONDecoder().decode(
                CoachReply.self,
                from: structuredContentJSON
            )
        }
        set {
            structuredContentJSON = newValue.flatMap {
                try? JSONEncoder().encode($0)
            }
            if let newValue {
                text = newValue.plainText
            }
        }
    }

    /// Text-only rows remain fully readable without a migration or API call.
    var effectiveReply: CoachReply {
        structuredContent ?? .legacy(text: text)
    }
}

@Model
final class SavedAssistanceEvent {
    @Attribute(.unique) var id: UUID
    var kindRaw: String
    var ply: Int
    var detail: String
    var createdAt: Date

    init(
        kind: AssistanceKind,
        ply: Int,
        detail: String = "",
        createdAt: Date = .now
    ) {
        self.id = UUID()
        self.kindRaw = kind.rawValue
        self.ply = ply
        self.detail = detail
        self.createdAt = createdAt
    }

    var kind: AssistanceKind {
        get { AssistanceKind(rawValue: kindRaw) ?? .coachChat }
        set { kindRaw = newValue.rawValue }
    }
}

enum AssistanceKind: String, Codable, CaseIterable, Sendable {
    case conceptHint
    case revealMove
    case blunderWarning
    case takeBack
    case coachChat
}

@Model
final class SavedAnalysisSnapshot {
    @Attribute(.unique) var id: UUID
    var ply: Int
    var purpose: String
    var fen: String
    var bestMove: String
    var expectedScoreWhite: Double?
    var variationsJSON: Data
    var createdAt: Date

    init(
        ply: Int,
        purpose: String,
        analysis: PositionAnalysis,
        createdAt: Date = .now
    ) {
        self.id = UUID()
        self.ply = ply
        self.purpose = purpose
        self.fen = analysis.fen
        self.bestMove = analysis.bestMove
        self.expectedScoreWhite = analysis.expectedScore(for: .white)
        self.variationsJSON = (try? JSONEncoder().encode(analysis.variations)) ?? Data()
        self.createdAt = createdAt
    }

    func update(from analysis: PositionAnalysis, at date: Date = .now) {
        fen = analysis.fen
        bestMove = analysis.bestMove
        expectedScoreWhite = analysis.expectedScore(for: .white)
        variationsJSON = (try? JSONEncoder().encode(analysis.variations)) ?? Data()
        createdAt = date
    }

    var variations: [PrincipalVariation] {
        (try? JSONDecoder().decode([PrincipalVariation].self, from: variationsJSON)) ?? []
    }
}

@Model
final class LearnerProfile {
    @Attribute(.unique) var id: UUID
    var onboardingComplete: Bool
    var experienceRaw: String
    var estimateLow: Int
    var estimateHigh: Int
    var confidence: Double
    var eligibleGames: Int
    var reviewedGames: Int
    var openingScore: Double
    var middlegameScore: Double
    var endgameScore: Double
    var blunderRate: Double
    var mistakeRate: Double
    var timePressureRate: Double
    var weaknessSummary: String
    var strengthsSummary: String
    var userNotes: String
    var ratingHistoryRaw: String = ""
    var updatedAt: Date

    init(
        onboardingComplete: Bool = false,
        experience: ExperienceLevel = .beginner
    ) {
        self.id = UUID()
        self.onboardingComplete = onboardingComplete
        self.experienceRaw = experience.rawValue
        self.estimateLow = experience.initialRange.lowerBound
        self.estimateHigh = experience.initialRange.upperBound
        self.confidence = 0
        self.eligibleGames = 0
        self.reviewedGames = 0
        self.openingScore = 0
        self.middlegameScore = 0
        self.endgameScore = 0
        self.blunderRate = 0
        self.mistakeRate = 0
        self.timePressureRate = 0
        self.weaknessSummary = "The coach is still learning your patterns."
        self.strengthsSummary = "Complete reviewed games to identify strengths."
        self.userNotes = ""
        self.ratingHistoryRaw = ""
        self.updatedAt = .now
    }

    var experience: ExperienceLevel {
        get { ExperienceLevel(rawValue: experienceRaw) ?? .beginner }
        set {
            experienceRaw = newValue.rawValue
            if eligibleGames == 0 {
                estimateLow = newValue.initialRange.lowerBound
                estimateHigh = newValue.initialRange.upperBound
            }
            updatedAt = .now
        }
    }

    var estimateLabel: String {
        eligibleGames >= 5 ? "\(estimateLow)–\(estimateHigh)" : "Calibrating"
    }

    var ratingHistory: [Int] {
        get {
            ratingHistoryRaw
                .split(separator: ",")
                .compactMap { Int($0) }
        }
        set {
            ratingHistoryRaw = newValue.suffix(12).map(String.init).joined(separator: ",")
        }
    }

    var recentTrendLabel: String {
        guard ratingHistory.count >= 2,
              let first = ratingHistory.first,
              let last = ratingHistory.last
        else { return "Not enough eligible games" }
        let change = last - first
        if change >= 25 { return "Improving · +\(change)" }
        if change <= -25 { return "Cooling · \(change)" }
        return "Steady"
    }
}

extension SavedGame {
    var sortedPlies: [SavedPly] {
        plies.sorted(by: { $0.index < $1.index })
    }

    var title: String {
        "You (\(playerSide.displayName)) vs Stockfish \(difficulty)"
    }

    var resultLabel: String {
        switch result {
        case .inProgress: "In progress"
        case .whiteWon: "White won · \(endReason.rawValue.humanized)"
        case .blackWon: "Black won · \(endReason.rawValue.humanized)"
        case .draw: "Draw · \(endReason.rawValue.humanized)"
        case .resigned: "Resigned"
        case .timeout: "Timeout"
        default: "Abandoned"
        }
    }
}

private extension String {
    var humanized: String {
        unicodeScalars.reduce(into: "") { result, scalar in
            if CharacterSet.uppercaseLetters.contains(scalar), !result.isEmpty {
                result.append(" ")
            }
            result.append(Character(String(scalar)))
        }.capitalized
    }
}
