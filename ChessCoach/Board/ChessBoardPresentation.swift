import Foundation

struct ChessBoardPresentedPiece: Identifiable, Equatable, Sendable {
    let id: String
    var piece: BoardPiece
}

struct ChessBoardPresentationUpdate: Equatable, Sendable {
    var frame: ChessBoardPresentationFrame
    var transition: ChessBoardTransition
}

struct ChessBoardPresentationFrame: Equatable, Sendable {
    var snapshot: ChessBoardSnapshot
    var pieces: [ChessBoardPresentedPiece]

    init(snapshot: ChessBoardSnapshot) {
        self.snapshot = snapshot
        self.pieces = snapshot.pieces.map {
            ChessBoardPresentedPiece(
                id: Self.freshID(for: $0, revision: snapshot.revision),
                piece: $0
            )
        }
    }

    func updating(to next: ChessBoardSnapshot) -> ChessBoardPresentationUpdate {
        guard snapshot.gameID == next.gameID,
              next.plyCount == snapshot.plyCount + 1,
              let intent = next.lastMove,
              let moving = pieces.first(where: { $0.piece.square == intent.source }),
              let arrived = next.piece(at: intent.destination)
        else {
            let isTakeBack =
                snapshot.gameID == next.gameID &&
                snapshot.plyCount > next.plyCount
            return ChessBoardPresentationUpdate(
                frame: ChessBoardPresentationFrame(snapshot: next),
                transition: isTakeBack ? .takeBack : .immediateReplacement
            )
        }

        let castle = castleRookMove(for: moving.piece, intent: intent)
        let rook = castle.flatMap { rookMove in
            pieces.first(where: { $0.piece.square == rookMove.source })
        }
        var claimedIDs: Set<String> = [moving.id]
        if let rook {
            claimedIDs.insert(rook.id)
        }

        let presented = next.pieces.map { newPiece -> ChessBoardPresentedPiece in
            if newPiece.square == intent.destination {
                return ChessBoardPresentedPiece(id: moving.id, piece: newPiece)
            }
            if let castle,
               let rook,
               newPiece.square == castle.destination {
                return ChessBoardPresentedPiece(id: rook.id, piece: newPiece)
            }
            if let unchanged = pieces.first(where: {
                !claimedIDs.contains($0.id) &&
                    $0.piece.square == newPiece.square &&
                    $0.piece.side == newPiece.side &&
                    $0.piece.kind == newPiece.kind
            }) {
                claimedIDs.insert(unchanged.id)
                return ChessBoardPresentedPiece(id: unchanged.id, piece: newPiece)
            }
            return ChessBoardPresentedPiece(
                id: Self.freshID(for: newPiece, revision: next.revision),
                piece: newPiece
            )
        }

        let transition: ChessBoardTransition
        if let castle {
            transition = .castle(king: intent, rook: castle)
        } else if moving.piece.kind == "p", arrived.kind != "p" {
            transition = .promotion(intent)
        } else if snapshot.piece(at: intent.destination) != nil {
            transition = .capture(intent, capturedSquare: intent.destination)
        } else if moving.piece.kind == "p",
                  intent.source.first != intent.destination.first {
            let capturedSquare = String(intent.destination.prefix(1))
                + String(intent.source.suffix(1))
            transition = .enPassant(intent, capturedSquare: capturedSquare)
        } else {
            transition = .move(intent)
        }

        return ChessBoardPresentationUpdate(
            frame: ChessBoardPresentationFrame(
                snapshot: next,
                pieces: presented
            ),
            transition: transition
        )
    }

    private init(
        snapshot: ChessBoardSnapshot,
        pieces: [ChessBoardPresentedPiece]
    ) {
        self.snapshot = snapshot
        self.pieces = pieces
    }

    private func castleRookMove(
        for piece: BoardPiece,
        intent: ChessBoardMoveIntent
    ) -> ChessBoardMoveIntent? {
        guard piece.kind == "k",
              let source = ChessBoardGeometry.coordinates(of: intent.source),
              let destination = ChessBoardGeometry.coordinates(of: intent.destination),
              abs(destination.file - source.file) == 2
        else {
            return nil
        }
        let kingSide = destination.file > source.file
        let rank = source.rank + 1
        return ChessBoardMoveIntent(
            source: "\(kingSide ? "h" : "a")\(rank)",
            destination: "\(kingSide ? "f" : "d")\(rank)"
        )
    }

    private static func freshID(for piece: BoardPiece, revision: Int) -> String {
        "\(revision)-\(piece.side.rawValue)-\(piece.kind)-\(piece.square)"
    }
}
