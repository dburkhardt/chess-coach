import CoreGraphics
import Foundation

struct ChessBoardGeometry: Equatable, Sendable {
    static let files = Array("abcdefgh")

    let size: CGSize
    let perspective: ChessSide
    let displayScale: CGFloat

    init(
        size: CGSize,
        perspective: ChessSide,
        displayScale: CGFloat = 1
    ) {
        self.size = size
        self.perspective = perspective
        self.displayScale = max(1, displayScale)
    }

    var boardSide: CGFloat {
        floor(min(size.width, size.height) * displayScale) / displayScale
    }

    var squareSide: CGFloat {
        boardSide / 8
    }

    var boardRect: CGRect {
        let x = pixelAligned((size.width - boardSide) / 2)
        let y = pixelAligned((size.height - boardSide) / 2)
        return CGRect(x: x, y: y, width: boardSide, height: boardSide)
    }

    func square(at point: CGPoint) -> String? {
        guard boardRect.contains(point) else { return nil }
        let column = min(7, max(0, Int((point.x - boardRect.minX) / squareSide)))
        let row = min(7, max(0, Int((point.y - boardRect.minY) / squareSide)))
        return square(atColumn: column, row: row)
    }

    func square(atColumn column: Int, row: Int) -> String? {
        guard (0..<8).contains(column), (0..<8).contains(row) else { return nil }
        let file = perspective == .white ? column : 7 - column
        let rank = perspective == .white ? 7 - row : row
        return "\(Self.files[file])\(rank + 1)"
    }

    func displayPosition(of square: String) -> (column: Int, row: Int)? {
        guard let coordinates = Self.coordinates(of: square) else { return nil }
        if perspective == .white {
            return (coordinates.file, 7 - coordinates.rank)
        }
        return (7 - coordinates.file, coordinates.rank)
    }

    func rect(for square: String) -> CGRect? {
        guard let display = displayPosition(of: square) else { return nil }
        return CGRect(
            x: boardRect.minX + CGFloat(display.column) * squareSide,
            y: boardRect.minY + CGFloat(display.row) * squareSide,
            width: squareSide,
            height: squareSide
        )
    }

    func center(of square: String) -> CGPoint? {
        guard let rect = rect(for: square) else { return nil }
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    func isLight(square: String) -> Bool {
        guard let coordinates = Self.coordinates(of: square) else { return false }
        // a1 is dark; files and ranks with matching parity are dark.
        return (coordinates.file + coordinates.rank).isMultiple(of: 2) == false
    }

    func moving(
        from square: String,
        displayColumnDelta: Int,
        displayRowDelta: Int
    ) -> String? {
        guard let position = displayPosition(of: square) else { return nil }
        return self.square(
            atColumn: position.column + displayColumnDelta,
            row: position.row + displayRowDelta
        )
    }

    static func coordinates(of square: String) -> (file: Int, rank: Int)? {
        guard square.count == 2,
              let fileCharacter = square.first,
              let file = files.firstIndex(of: fileCharacter),
              let rankCharacter = square.last,
              let rank = Int(String(rankCharacter)),
              (1...8).contains(rank)
        else {
            return nil
        }
        return (file, rank - 1)
    }

    private func pixelAligned(_ value: CGFloat) -> CGFloat {
        round(value * displayScale) / displayScale
    }
}
