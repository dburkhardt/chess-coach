import Foundation

struct ChessBoardMoveIntent: Equatable, Sendable {
    let source: String
    let destination: String
    let promotion: String?

    init(source: String, destination: String, promotion: String? = nil) {
        self.source = source
        self.destination = destination
        self.promotion = promotion
    }

    var uci: String {
        source + destination + (promotion ?? "")
    }
}

struct ChessBoardArrow: Equatable, Sendable {
    let source: String
    let destination: String
}

struct ChessBoardPromotionState: Equatable, Sendable {
    let source: String
    let destination: String
    let choices: [String]
}

struct MaterialBalance: Equatable, Sendable {
    enum Advantage: Equatable, Sendable {
        case ahead(points: Int)
        case even
        case behind(points: Int)
    }

    let whitePoints: Int
    let blackPoints: Int

    init(pieces: [BoardPiece]) {
        self.init(
            whitePoints: Self.points(for: .white, in: pieces),
            blackPoints: Self.points(for: .black, in: pieces)
        )
    }

    init(whitePoints: Int, blackPoints: Int) {
        self.whitePoints = max(0, whitePoints)
        self.blackPoints = max(0, blackPoints)
    }

    var isEven: Bool {
        whitePoints == blackPoints
    }

    func points(for side: ChessSide) -> Int {
        side == .white ? whitePoints : blackPoints
    }

    func advantage(for side: ChessSide) -> Advantage {
        let difference = points(for: side) - points(for: side.opposite)
        if difference > 0 {
            return .ahead(points: difference)
        }
        if difference < 0 {
            return .behind(points: -difference)
        }
        return .even
    }

    private static func points(
        for side: ChessSide,
        in pieces: [BoardPiece]
    ) -> Int {
        pieces.lazy
            .filter { $0.side == side }
            .reduce(into: 0) { total, piece in
                let value = switch piece.kind.lowercased() {
                case "q": 9
                case "r": 5
                case "b", "n": 3
                case "p": 1
                default: 0
                }
                total += value
            }
    }
}

struct ChessBoardSnapshot: Equatable, Sendable {
    let gameID: UUID?
    let revision: Int
    let plyCount: Int
    let pieces: [BoardPiece]
    let perspective: ChessSide
    let turn: ChessSide
    let legalDestinations: [String: Set<String>]
    let lastMove: ChessBoardMoveIntent?
    let checkSquare: String?
    let arrows: [ChessBoardArrow]
    let promotionState: ChessBoardPromotionState?
    let inputAvailable: Bool

    func piece(at square: String) -> BoardPiece? {
        pieces.first { $0.square == square }
    }

    func destinations(from square: String) -> Set<String> {
        legalDestinations[square] ?? []
    }
}

enum ChessBoardTransition: Equatable, Sendable {
    case move(ChessBoardMoveIntent)
    case capture(ChessBoardMoveIntent, capturedSquare: String)
    case castle(king: ChessBoardMoveIntent, rook: ChessBoardMoveIntent)
    case enPassant(ChessBoardMoveIntent, capturedSquare: String)
    case promotion(ChessBoardMoveIntent)
    case takeBack
    case immediateReplacement
}

extension BoardPiece: @unchecked Sendable {}
