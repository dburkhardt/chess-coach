import ChessKit
import Foundation

extension ChessSide {
    var pieceColor: PieceColor { self == .white ? .white : .black }
}

extension PieceColor {
    var chessSide: ChessSide { self == .white ? .white : .black }
}

struct BoardPiece: Identifiable, Equatable {
    var square: String
    var side: ChessSide
    var kind: String

    var id: String { square }

    var glyph: String {
        switch (side, kind) {
        case (.white, "k"): "♔"
        case (.white, "q"): "♕"
        case (.white, "r"): "♖"
        case (.white, "b"): "♗"
        case (.white, "n"): "♘"
        case (.white, "p"): "♙"
        case (.black, "k"): "♚"
        case (.black, "q"): "♛"
        case (.black, "r"): "♜"
        case (.black, "b"): "♝"
        case (.black, "n"): "♞"
        default: "♟"
        }
    }

    var accessibilityName: String {
        let pieceName: String = switch kind {
        case "k": "king"
        case "q": "queen"
        case "r": "rook"
        case "b": "bishop"
        case "n": "knight"
        default: "pawn"
        }
        return "\(side.displayName) \(pieceName) on \(square)"
    }
}

struct ChessGameStatus: Equatable {
    var result: GameResult = .inProgress
    var reason: GameEndReason = .none
    var message = ""

    var isFinished: Bool { result != .inProgress }
}

struct MadeMove {
    var uci: String
    var san: String
    var side: ChessSide
    var fenBefore: String
    var fenAfter: String
}

final class ChessGameState {
    static let standardInitialFEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1"

    private let fenSerialization = FenSerialization()
    private let sanSerialization = SanSerialization()
    private(set) var game: Game
    private(set) var uciMoves: [String] = []
    private(set) var sanMoves: [String] = []
    private(set) var positionKeys: [String: Int] = [:]
    let initialFEN: String

    init(initialFEN: String = ChessGameState.standardInitialFEN, moves: [String] = []) {
        self.initialFEN = initialFEN
        self.game = Game(position: fenSerialization.deserialize(fen: initialFEN))
        registerCurrentPosition()
        for move in moves {
            _ = try? make(uci: move)
        }
    }

    var fen: String { fenSerialization.serialize(position: game.position) }
    var sideToMove: ChessSide { game.position.state.turn.chessSide }
    var legalMoves: [String] { game.legalMoves.map(\.description) }
    var isCheck: Bool { game.isCheck }
    var plyCount: Int { uciMoves.count }

    var pieces: [BoardPiece] {
        game.position.board.enumeratedPieces().map { square, piece in
            BoardPiece(
                square: square.coordinate,
                side: piece.color.chessSide,
                kind: piece.kind.rawValue
            )
        }
    }

    func piece(at square: String) -> BoardPiece? {
        pieces.first(where: { $0.square == square })
    }

    func legalMoves(from square: String) -> [String] {
        game.legalMoves
            .filter { $0.from.coordinate == square }
            .map(\.description)
    }

    func make(uci: String) throws -> MadeMove {
        guard let move = game.legalMoves.first(where: {
            $0.description.lowercased() == uci.lowercased()
        }) else {
            throw ChessStateError.illegalMove(uci)
        }

        let before = fen
        let side = sideToMove
        let san = sanSerialization.san(for: move, in: game)
        game.make(move: move)
        uciMoves.append(move.description.lowercased())
        sanMoves.append(san)
        registerCurrentPosition()
        return MadeMove(
            uci: move.description.lowercased(),
            san: san,
            side: side,
            fenBefore: before,
            fenAfter: fen
        )
    }

    func rebuilt(keeping count: Int) -> ChessGameState {
        ChessGameState(initialFEN: initialFEN, moves: Array(uciMoves.prefix(count)))
    }

    func status() -> ChessGameStatus {
        if game.legalMoves.isEmpty {
            if game.isCheck {
                let winner = sideToMove.opposite
                return ChessGameStatus(
                    result: winner == .white ? .whiteWon : .blackWon,
                    reason: .checkmate,
                    message: "Checkmate — \(winner.displayName) wins."
                )
            }
            return ChessGameStatus(result: .draw, reason: .stalemate, message: "Draw by stalemate.")
        }

        if game.position.counter.halfMoves >= 100 {
            return ChessGameStatus(result: .draw, reason: .fiftyMoveRule, message: "Draw by the fifty-move rule.")
        }

        if positionKeys[positionKey(for: fen), default: 0] >= 3 {
            return ChessGameStatus(result: .draw, reason: .repetition, message: "Draw by threefold repetition.")
        }

        if hasInsufficientMaterial {
            return ChessGameStatus(result: .draw, reason: .insufficientMaterial, message: "Draw by insufficient material.")
        }

        return ChessGameStatus()
    }

    func pgn(playerSide: ChessSide, result: GameResult, date: Date = .now) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy.MM.dd"
        let white = playerSide == .white ? "You" : "Stockfish"
        let black = playerSide == .black ? "You" : "Stockfish"
        var lines = [
            "[Event \"Chess Coach Training Game\"]",
            "[Site \"Chess Coach\"]",
            "[Date \"\(formatter.string(from: date))\"]",
            "[Round \"-\"]",
            "[White \"\(white)\"]",
            "[Black \"\(black)\"]",
            "[Result \"\(result.pgnValue)\"]",
            "",
        ]

        var movetext: [String] = []
        for index in stride(from: 0, to: sanMoves.count, by: 2) {
            var entry = "\(index / 2 + 1). \(sanMoves[index])"
            if index + 1 < sanMoves.count {
                entry += " \(sanMoves[index + 1])"
            }
            movetext.append(entry)
        }
        lines.append(movetext.joined(separator: " ") + " " + result.pgnValue)
        return lines.joined(separator: "\n")
    }

    private func registerCurrentPosition() {
        let key = positionKey(for: fen)
        positionKeys[key, default: 0] += 1
    }

    private func positionKey(for fen: String) -> String {
        fen.split(separator: " ").prefix(4).joined(separator: " ")
    }

    private var hasInsufficientMaterial: Bool {
        let pieces = game.position.board.enumeratedPieces().filter { $0.1.kind != .king }
        if pieces.isEmpty { return true }
        if pieces.count == 1 {
            return pieces[0].1.kind == .bishop || pieces[0].1.kind == .knight
        }
        if pieces.allSatisfy({ $0.1.kind == .bishop }) {
            let squareColors = pieces.map { ($0.0.file + $0.0.rank) % 2 }
            return Set(squareColors).count == 1
        }
        return false
    }
}

enum ChessStateError: LocalizedError {
    case illegalMove(String)

    var errorDescription: String? {
        switch self {
        case .illegalMove(let move): "Illegal move: \(move)"
        }
    }
}

struct PositionFeatures: Codable, Equatable, Sendable {
    var sideToMove: String
    var inCheck: Bool
    var material: String
    var legalCaptures: [String]
    var loosePieces: [String]
    var checkingMoves: [String]
    var immediateThreats: [String]
    var castlingRights: String

    static func extract(from state: ChessGameState) -> PositionFeatures {
        let board = state.game.position.board
        let counts = Dictionary(grouping: board.enumeratedPieces(), by: {
            "\($0.1.color.chessSide.rawValue)-\($0.1.kind.rawValue)"
        }).mapValues(\.count)

        let material = [
            "White: Q\(counts["white-q", default: 0]) R\(counts["white-r", default: 0]) B\(counts["white-b", default: 0]) N\(counts["white-n", default: 0]) P\(counts["white-p", default: 0])",
            "Black: Q\(counts["black-q", default: 0]) R\(counts["black-r", default: 0]) B\(counts["black-b", default: 0]) N\(counts["black-n", default: 0]) P\(counts["black-p", default: 0])",
        ].joined(separator: "; ")

        let serializer = SanSerialization()
        var captures: [String] = []
        var loosePieces: [String] = []
        var checks: [String] = []
        for move in state.game.legalMoves {
            let san = serializer.san(for: move, in: state.game)
            if san.contains("x") {
                captures.append(san)
                if let target = state.piece(at: move.to.coordinate) {
                    loosePieces.append(target.accessibilityName)
                }
            }
            if san.hasSuffix("+") || san.hasSuffix("#") { checks.append(san) }
        }

        let rights = state.game.position.state.castlings.map(\.description).joined()
        return PositionFeatures(
            sideToMove: state.sideToMove.rawValue,
            inCheck: state.isCheck,
            material: material,
            legalCaptures: Array(captures.prefix(12)),
            loosePieces: Array(Set(loosePieces)).sorted().prefix(12).map(\.self),
            checkingMoves: Array(checks.prefix(12)),
            immediateThreats: Array((checks + captures).prefix(12)),
            castlingRights: rights.isEmpty ? "-" : rights
        )
    }
}
