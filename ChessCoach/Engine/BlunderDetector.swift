import Foundation

struct BlunderDetector {
    static let severeThreshold = 0.20

    func warning(
        before: PositionAnalysis,
        after: PositionAnalysis,
        playerSide: ChessSide
    ) -> BlunderWarning? {
        let beforeMate = before.primary?.score.mate
        let afterMate = after.primary?.score.mate

        if isPlayerForcedMate(mate: beforeMate, playerSide: playerSide),
           !isPlayerForcedMate(mate: afterMate, playerSide: playerSide) {
            return BlunderWarning(
                loss: 1,
                previousAnalysis: before,
                currentAnalysis: after,
                reason: "That move gives up a forced mate."
            )
        }

        if isOpponentForcedMate(mate: afterMate, playerSide: playerSide) {
            return BlunderWarning(
                loss: 1,
                previousAnalysis: before,
                currentAnalysis: after,
                reason: "That move allows a forced mate."
            )
        }

        guard
            let oldScore = before.expectedScore(for: playerSide),
            let newScore = after.expectedScore(for: playerSide)
        else { return nil }

        let loss = oldScore - newScore
        guard loss + 1e-9 >= Self.severeThreshold else { return nil }
        return BlunderWarning(
            loss: loss,
            previousAnalysis: before,
            currentAnalysis: after,
            reason: "That move drops your expected score by \(Int((loss * 100).rounded())) percentage points."
        )
    }

    private func isPlayerForcedMate(mate: Int?, playerSide: ChessSide) -> Bool {
        guard let mate else { return false }
        return (mate > 0 && playerSide == .white) || (mate < 0 && playerSide == .black)
    }

    private func isOpponentForcedMate(mate: Int?, playerSide: ChessSide) -> Bool {
        guard let mate else { return false }
        return (mate > 0 && playerSide == .black) || (mate < 0 && playerSide == .white)
    }
}
