import Testing
@testable import ChessCoach

struct UCIParserTests {
    @Test func parsesMultiPVScoreWDLAndLine() throws {
        let line = "info depth 22 seldepth 31 multipv 2 score cp -43 wdl 121 529 350 nodes 99 pv e7e5 g1f3"
        let info = try #require(UCIParser.parseInfo(line))
        #expect(info.depth == 22)
        #expect(info.multipv == 2)
        #expect(info.score.centipawns == -43)
        #expect(info.wdl == WDL(win: 121, draw: 529, loss: 350))
        #expect(info.moves == ["e7e5", "g1f3"])
    }

    @Test func convertsBlackOutputToWhitePerspective() throws {
        let parsed = try #require(UCIParser.parseInfo(
            "info depth 10 score mate 3 wdl 900 90 10 pv e7e8q"
        ))
        let info = UCIParser.whitePerspective(parsed, sideToMove: .black)
        #expect(info.score.mate == -3)
        #expect(info.wdl == WDL(win: 10, draw: 90, loss: 900))
    }

    @Test func rejectsMalformedAndParsesBestMove() {
        #expect(UCIParser.parseInfo("info depth nope") == nil)
        #expect(UCIParser.parseInfo("info depth 12 score cp nope pv e2e4") == nil)
        #expect(UCIParser.parseInfo("info depth 12 score cp 20 pv not-a-move") == nil)
        #expect(UCIParser.parseInfo("info depth 12 multipv 0 score cp 20 pv e2e4") == nil)
        #expect(UCIParser.parseBestMove("bestmove (none)") == nil)
        #expect(UCIParser.parseBestMove("bestmove 0000") == nil)
        #expect(UCIParser.parseBestMove("bestmove not-a-move") == nil)
        let best = UCIParser.parseBestMove("bestmove e2e4 ponder e7e5")
        #expect(best?.move == "e2e4")
        #expect(best?.ponder == "e7e5")
    }

    @Test func acceptsPromotionAndIgnoresMalformedPonder() {
        let promotion = UCIParser.parseBestMove("bestmove e7e8q ponder h2h1x")
        #expect(promotion?.move == "e7e8q")
        #expect(promotion?.ponder == nil)
    }
}
