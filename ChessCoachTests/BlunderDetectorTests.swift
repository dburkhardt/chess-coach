import Testing
@testable import ChessCoach

struct BlunderDetectorTests {
    @Test func warnsAtTwentyPercentagePoints() {
        let detector = BlunderDetector()
        let warning = detector.warning(
            before: analysis(expected: 0.70),
            after: analysis(expected: 0.50, side: .black),
            playerSide: .white
        )
        #expect(warning != nil)
        #expect(abs((warning?.loss ?? 0) - 0.20) < 1e-9)
    }

    @Test func ignoresSmallerLoss() {
        let detector = BlunderDetector()
        #expect(detector.warning(
            before: analysis(expected: 0.69),
            after: analysis(expected: 0.50, side: .black),
            playerSide: .white
        ) == nil)
    }

    @Test func warnsWhenMoveAllowsForcedMate() {
        let detector = BlunderDetector()
        let before = analysis(expected: 0.5)
        let after = PositionAnalysis(
            fen: ChessGameState.standardInitialFEN,
            sideToMove: .black,
            bestMove: "e7e5",
            variations: [
                PrincipalVariation(
                    index: 1,
                    depth: 12,
                    score: EngineScore(mate: -3),
                    moves: ["e7e5"]
                )
            ]
        )
        #expect(detector.warning(before: before, after: after, playerSide: .white) != nil)
    }

    @Test func warnsWhenMoveThrowsAwayForcedMate() {
        let detector = BlunderDetector()
        let before = PositionAnalysis(
            fen: ChessGameState.standardInitialFEN,
            sideToMove: .white,
            bestMove: "e2e4",
            variations: [
                PrincipalVariation(
                    index: 1,
                    depth: 12,
                    score: EngineScore(mate: 3),
                    moves: ["e2e4"]
                )
            ]
        )
        let warning = detector.warning(
            before: before,
            after: analysis(expected: 0.75, side: .black),
            playerSide: .white
        )

        #expect(warning?.reason == "That move gives up a forced mate.")
    }

    private func analysis(expected: Double, side: ChessSide = .white) -> PositionAnalysis {
        let win = Int((expected * 1_000).rounded())
        return PositionAnalysis(
            fen: ChessGameState.standardInitialFEN,
            sideToMove: side,
            bestMove: "e2e4",
            variations: [
                PrincipalVariation(
                    index: 1,
                    depth: 12,
                    score: EngineScore(centipawns: 0),
                    wdl: WDL(win: win, draw: 0, loss: 1_000 - win),
                    moves: ["e2e4"]
                )
            ]
        )
    }
}
