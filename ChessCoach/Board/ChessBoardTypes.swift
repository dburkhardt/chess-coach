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

struct CapturedPieceRecord: Identifiable, Equatable, Sendable {
    let ply: Int
    let side: ChessSide
    let kind: String

    var id: String {
        "\(ply)-\(side.rawValue)-\(kind)"
    }

    var pointValue: Int {
        switch kind.lowercased() {
        case "q": 9
        case "r": 5
        case "b", "n": 3
        case "p": 1
        default: 0
        }
    }

    var accessibilityName: String {
        let name = switch kind.lowercased() {
        case "q": "queen"
        case "r": "rook"
        case "b": "bishop"
        case "n": "knight"
        default: "pawn"
        }
        return "\(side.displayName) \(name)"
    }
}

struct CapturedMaterialLedger: Equatable, Sendable {
    private(set) var capturedByWhite: [CapturedPieceRecord]
    private(set) var capturedByBlack: [CapturedPieceRecord]

    static let empty = CapturedMaterialLedger(
        capturedByWhite: [],
        capturedByBlack: []
    )

    init(
        capturedByWhite: [CapturedPieceRecord],
        capturedByBlack: [CapturedPieceRecord]
    ) {
        self.capturedByWhite = Self.sorted(capturedByWhite)
        self.capturedByBlack = Self.sorted(capturedByBlack)
    }

    init(initialFEN: String, moves: [String]) {
        let state = ChessGameState(initialFEN: initialFEN)
        var white: [CapturedPieceRecord] = []
        var black: [CapturedPieceRecord] = []

        for (ply, rawMove) in moves.enumerated() {
            let move = rawMove.lowercased()
            guard move.count >= 4 else { break }
            let source = String(move.prefix(2))
            let destination = String(move.dropFirst(2).prefix(2))
            guard let movingPiece = state.piece(at: source) else { break }

            let capturedPiece = Self.capturedPiece(
                moving: movingPiece,
                from: source,
                to: destination,
                in: state
            )
            guard (try? state.make(uci: move)) != nil else { break }

            if let capturedPiece {
                let record = CapturedPieceRecord(
                    ply: ply,
                    side: capturedPiece.side,
                    kind: capturedPiece.kind
                )
                if movingPiece.side == .white {
                    white.append(record)
                } else {
                    black.append(record)
                }
            }
        }

        capturedByWhite = Self.sorted(white)
        capturedByBlack = Self.sorted(black)
    }

    func pieces(capturedBy side: ChessSide) -> [CapturedPieceRecord] {
        side == .white ? capturedByWhite : capturedByBlack
    }

    func points(capturedBy side: ChessSide) -> Int {
        pieces(capturedBy: side).reduce(0) { $0 + $1.pointValue }
    }

    private static func capturedPiece(
        moving piece: BoardPiece,
        from source: String,
        to destination: String,
        in state: ChessGameState
    ) -> BoardPiece? {
        if let target = state.piece(at: destination),
           target.side == piece.side.opposite {
            return target
        }

        // En passant lands on an empty square. The captured pawn remains on
        // the destination file and the source rank until the move is applied.
        guard piece.kind == "p",
              source.first != destination.first,
              let destinationFile = destination.first,
              let sourceRank = source.last
        else {
            return nil
        }
        let capturedSquare = "\(destinationFile)\(sourceRank)"
        guard let target = state.piece(at: capturedSquare),
              target.side == piece.side.opposite,
              target.kind == "p"
        else {
            return nil
        }
        return target
    }

    private static func sorted(
        _ pieces: [CapturedPieceRecord]
    ) -> [CapturedPieceRecord] {
        let order = ["q": 0, "r": 1, "b": 2, "n": 3, "p": 4]
        return pieces.sorted {
            let lhs = order[$0.kind.lowercased(), default: 5]
            let rhs = order[$1.kind.lowercased(), default: 5]
            return lhs == rhs ? $0.ply < $1.ply : lhs < rhs
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
