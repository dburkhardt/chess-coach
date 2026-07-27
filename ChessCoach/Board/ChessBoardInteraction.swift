import CoreGraphics
import Foundation

struct ChessBoardInteraction: Equatable, Sendable {
    struct Drag: Equatable, Sendable {
        let source: String
        let start: CGPoint
        var location: CGPoint
    }

    enum Result: Equatable, Sendable {
        case none
        case selectionChanged
        case move(ChessBoardMoveIntent)
        case invalidDrop(source: String)
    }

    var selectedSquare: String?
    var focusedSquare: String?
    var drag: Drag?

    mutating func tap(
        square: String,
        snapshot: ChessBoardSnapshot,
        method: ChessBoardPreferences.MoveMethod
    ) -> Result {
        guard method.allowsClick, snapshot.inputAvailable else { return .none }
        focusedSquare = square

        if let selectedSquare {
            if selectedSquare == square {
                self.selectedSquare = nil
                return .selectionChanged
            }
            if let destination = normalizedDestination(
                from: selectedSquare,
                requestedDestination: square,
                snapshot: snapshot
            ) {
                self.selectedSquare = nil
                focusedSquare = destination
                return .move(ChessBoardMoveIntent(
                    source: selectedSquare,
                    destination: destination
                ))
            }
        }

        if isMovablePiece(on: square, snapshot: snapshot) {
            selectedSquare = square
        } else {
            selectedSquare = nil
        }
        return .selectionChanged
    }

    mutating func beginDrag(
        square: String?,
        at point: CGPoint,
        snapshot: ChessBoardSnapshot,
        method: ChessBoardPreferences.MoveMethod
    ) -> Bool {
        guard method.allowsDrag,
              snapshot.inputAvailable,
              let square,
              isMovablePiece(on: square, snapshot: snapshot)
        else {
            return false
        }
        selectedSquare = square
        focusedSquare = square
        drag = Drag(source: square, start: point, location: point)
        return true
    }

    mutating func updateDrag(to point: CGPoint) {
        drag?.location = point
    }

    mutating func endDrag(
        on destination: String?,
        snapshot: ChessBoardSnapshot
    ) -> Result {
        guard let drag else { return .none }
        self.drag = nil
        guard let destination,
              let normalizedDestination = normalizedDestination(
                from: drag.source,
                requestedDestination: destination,
                snapshot: snapshot
              )
        else {
            return .invalidDrop(source: drag.source)
        }
        selectedSquare = nil
        focusedSquare = normalizedDestination
        return .move(ChessBoardMoveIntent(
            source: drag.source,
            destination: normalizedDestination
        ))
    }

    mutating func cancel() {
        selectedSquare = nil
        drag = nil
    }

    mutating func resetForRevision() {
        selectedSquare = nil
        drag = nil
    }

    private func isMovablePiece(
        on square: String,
        snapshot: ChessBoardSnapshot
    ) -> Bool {
        snapshot.piece(at: square)?.side == snapshot.turn &&
        !snapshot.destinations(from: square).isEmpty
    }

    private func normalizedDestination(
        from source: String,
        requestedDestination: String,
        snapshot: ChessBoardSnapshot
    ) -> String? {
        let canonicalDestinations = snapshot.destinations(from: source)
        if canonicalDestinations.contains(requestedDestination) {
            return requestedDestination
        }

        guard let king = snapshot.piece(at: source),
              king.kind.lowercased() == "k",
              king.side == snapshot.turn,
              let alias = Self.castlingAlias(
                source: source,
                rookSquare: requestedDestination,
                side: king.side
              ),
              let rook = snapshot.piece(at: requestedDestination),
              rook.kind.lowercased() == "r",
              rook.side == king.side,
              canonicalDestinations.contains(alias)
        else {
            return nil
        }
        return alias
    }

    private static func castlingAlias(
        source: String,
        rookSquare: String,
        side: ChessSide
    ) -> String? {
        switch (side, source, rookSquare) {
        case (.white, "e1", "h1"): "g1"
        case (.white, "e1", "a1"): "c1"
        case (.black, "e8", "h8"): "g8"
        case (.black, "e8", "a8"): "c8"
        default: nil
        }
    }
}
