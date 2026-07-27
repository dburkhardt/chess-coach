import Foundation

/// Identifies whether the large board is presenting the authoritative live
/// position or a disposable teaching-line clone. Lesson previews deliberately
/// receive a distinct game identity so presentation animations can never be
/// reconciled into the live game's move stream.
enum ChessBoardPresentationContext: Equatable, Sendable {
    case live(gameID: UUID?, revision: Int)
    case teachingAnchor(
        lessonID: UUID,
        anchor: PositionAnchor
    )
    case lessonPreview(
        lessonID: UUID,
        anchor: PositionAnchor,
        variationRank: Int,
        step: Int
    )
}
