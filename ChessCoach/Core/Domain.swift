import Foundation

enum ChessSide: String, Codable, CaseIterable, Identifiable, Sendable {
    case white
    case black

    var id: String { rawValue }
    var opposite: ChessSide { self == .white ? .black : .white }
    var displayName: String { rawValue.capitalized }
}

enum PlayerColorChoice: String, Codable, CaseIterable, Identifiable, Sendable {
    case white
    case black
    case random

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }

    func resolved(using random: () -> Bool = { Bool.random() }) -> ChessSide {
        switch self {
        case .white: .white
        case .black: .black
        case .random: random() ? .white : .black
        }
    }
}

enum ExperienceLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case beginner
    case developing
    case intermediate
    case advanced

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var initialRange: ClosedRange<Int> {
        switch self {
        case .beginner: 400...900
        case .developing: 800...1300
        case .intermediate: 1200...1700
        case .advanced: 1600...2200
        }
    }
}

enum TimeControl: String, Codable, CaseIterable, Identifiable, Sendable {
    case none
    case rapid10
    case rapid15Increment10
    case rapid30

    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: "No Clock"
        case .rapid10: "10+0"
        case .rapid15Increment10: "15+10"
        case .rapid30: "30+0"
        }
    }
    var initialSeconds: Int {
        switch self {
        case .none: 0
        case .rapid10: 600
        case .rapid15Increment10: 900
        case .rapid30: 1_800
        }
    }
    var incrementSeconds: Int {
        self == .rapid15Increment10 ? 10 : 0
    }
    var usesClock: Bool { self != .none }
}

struct NewGameConfiguration: Sendable {
    var colorChoice: PlayerColorChoice = .white
    var difficulty: Int = 4
    var timeControl: TimeControl = .rapid10
    var blunderGuardEnabled = false
}

enum GameResult: String, Codable, Sendable {
    case inProgress
    case whiteWon
    case blackWon
    case draw
    case resigned
    case timeout
    case abandoned

    var pgnValue: String {
        switch self {
        case .whiteWon: "1-0"
        case .blackWon: "0-1"
        case .draw: "1/2-1/2"
        default: "*"
        }
    }
}

enum GameEndReason: String, Codable, Sendable {
    case none
    case checkmate
    case stalemate
    case repetition
    case fiftyMoveRule
    case insufficientMaterial
    case resignation
    case timeout
    case restarted
}

enum MoveClassification: String, Codable, CaseIterable, Sendable {
    case best
    case good
    case inaccuracy
    case mistake
    case blunder

    static func from(expectedScoreLoss: Double) -> MoveClassification {
        switch expectedScoreLoss {
        case 0.20...: .blunder
        case 0.10...: .mistake
        case 0.05...: .inaccuracy
        case 0.015...: .good
        default: .best
        }
    }
}

struct ClockSnapshot: Codable, Equatable, Sendable {
    var whiteMilliseconds: Int
    var blackMilliseconds: Int

    static func initial(for control: TimeControl) -> ClockSnapshot {
        let value = control.initialSeconds * 1_000
        return ClockSnapshot(whiteMilliseconds: value, blackMilliseconds: value)
    }

    func value(for side: ChessSide) -> Int {
        side == .white ? whiteMilliseconds : blackMilliseconds
    }
}

struct WDL: Codable, Equatable, Sendable {
    var win: Int
    var draw: Int
    var loss: Int

    var expectedScore: Double {
        (Double(win) + 0.5 * Double(draw)) / 1_000
    }

    func inverted() -> WDL {
        WDL(win: loss, draw: draw, loss: win)
    }
}

struct EngineScore: Codable, Equatable, Sendable {
    var centipawns: Int?
    var mate: Int?

    func inverted() -> EngineScore {
        EngineScore(
            centipawns: centipawns.map(-),
            mate: mate.map(-)
        )
    }
}

struct PrincipalVariation: Codable, Equatable, Identifiable, Sendable {
    var index: Int
    var depth: Int
    var score: EngineScore
    var wdl: WDL?
    var moves: [String]

    var id: Int { index }
    var firstMove: String? { moves.first }
}

struct PositionAnalysis: Codable, Equatable, Sendable {
    var fen: String
    var sideToMove: ChessSide
    var bestMove: String
    var ponderMove: String?
    var variations: [PrincipalVariation]
    var analyzedAt: Date = .now

    var primary: PrincipalVariation? {
        variations.first(where: { $0.index == 1 }) ?? variations.first
    }

    func expectedScore(for side: ChessSide) -> Double? {
        guard let whiteWDL = primary?.wdl else { return nil }
        return side == .white ? whiteWDL.expectedScore : whiteWDL.inverted().expectedScore
    }
}

struct BlunderWarning: Identifiable, Equatable, Sendable {
    let id = UUID()
    var loss: Double
    var previousAnalysis: PositionAnalysis
    var currentAnalysis: PositionAnalysis
    var reason: String
}

struct CoachHint: Codable, Equatable, Sendable {
    var concept: String
    var why: String
    var plan: String
    var likelyReply: String
    var watchFor: String
    var recommendedMove: String
    var source: String
}

struct PositionAnchor: Equatable, Sendable {
    let gameID: UUID
    let revision: Int
    let ply: Int
    let fen: String
}

/// A read-only projection of an earlier position in the active game.
///
/// The anchor binds the selection to the exact live continuation from which
/// browsing began. Any real position revision invalidates the preview.
struct HistoryPreviewState: Identifiable, Equatable, Sendable {
    let id: UUID
    let anchor: PositionAnchor
    var selectedPly: Int

    init(
        id: UUID = UUID(),
        anchor: PositionAnchor,
        selectedPly: Int
    ) {
        self.id = id
        self.anchor = anchor
        self.selectedPly = selectedPly
    }
}

enum CoachEnhancementState: Equatable, Sendable {
    case notConfigured
    case preparing
    case ready
    case unavailable
}

struct PreparedCoaching: Equatable, Sendable {
    let anchor: PositionAnchor
    let analysis: PositionAnalysis
    let context: CoachContext
    let deterministicHint: CoachHint
    var providerHint: CoachHint?
    var enhancement: CoachEnhancementState

    var bestAvailableHint: CoachHint {
        providerHint ?? deterministicHint
    }

    /// Compatibility accessor for presentation code that only needs the best
    /// currently available explanation.
    var hint: CoachHint {
        bestAvailableHint
    }
}

enum CoachPreparationState: Equatable, Sendable {
    case idle
    case analyzing(PositionAnchor)
    case ready(PreparedCoaching)
    case failed(PositionAnchor, message: String)
}

enum TeachingMomentPhase: Equatable, Sendable {
    case preparing
    case concept(CoachHint)
    case revealed(CoachHint)
    case previewing(CoachHint, variationRank: Int, step: Int)
    case failed(message: String)
}

struct TeachingMomentState: Equatable, Sendable {
    let id: UUID
    let anchor: PositionAnchor
    let pausedClockSide: ChessSide?
    let startedAt: Date = Date()
    var phase: TeachingMomentPhase
    var isUpgradeEligible: Bool
}

enum CoachRole: String, Codable, Sendable {
    case user
    case coach
    case system
}

enum CoachMessageKind: String, Codable, Sendable {
    case lesson
    case question
    case answer
    case warningExplanation
    case legacy
}

struct CoachMessage: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    var role: CoachRole
    var text: String
    var ply: Int
    var createdAt = Date()
    var structuredReply: CoachReply? = nil
    var positionFEN: String? = nil
    var turnID: UUID? = nil
    /// Optional so messages created before the inspector re-architecture
    /// continue to decode and render through legacy inference.
    var kind: CoachMessageKind? = nil
    /// Groups a delivered lesson with its position-specific follow-up turns.
    var sessionID: UUID? = nil
}

enum AppSection: String, CaseIterable, Identifiable {
    case newGame
    case currentGame
    case games
    case progress
    case settings

    var id: String { rawValue }
    var title: String {
        switch self {
        case .newGame: "New Game"
        case .currentGame: "Current Game"
        case .games: "Games"
        case .progress: "Progress"
        case .settings: "Settings"
        }
    }
    var systemImage: String {
        switch self {
        case .newGame: "plus.square"
        case .currentGame: "checkerboard.rectangle"
        case .games: "books.vertical"
        case .progress: "chart.line.uptrend.xyaxis"
        case .settings: "gearshape"
        }
    }
}
