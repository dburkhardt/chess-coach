import Testing
@testable import ChessCoach

@Suite(.serialized)
struct StockfishServiceTests {
    @Test func allTenDifficultyLevelsMapToPinnedSkillValues() {
        let actual = (1...10).map(StockfishService.skillLevel(for:))
        #expect(actual == [0, 2, 4, 6, 8, 10, 12, 14, 17, 20])
        #expect(StockfishService.skillLevel(for: -2) == 0)
        #expect(StockfishService.skillLevel(for: 99) == 20)
    }

    @Test func clockAwareGoCommandsIncludeBothClocksAndIncrements() {
        let command = StockfishService.goCommand(
            difficulty: 7,
            clocks: ClockSnapshot(whiteMilliseconds: 12_345, blackMilliseconds: 67_890),
            timeControl: .rapid15Increment10
        )
        #expect(command == "go wtime 12345 btime 67890 winc 10000 binc 10000")
        #expect(
            StockfishService.goCommand(
                difficulty: 2,
                clocks: .initial(for: .none),
                timeControl: .none
            ) == "go movetime 250"
        )
    }

    @Test func bundledStockfishReturnsLegalMultiPVAnalysis() async throws {
        let service = StockfishService(role: .analyst)
        let analysis = try await service.analyze(
            fen: ChessGameState.standardInitialFEN,
            multiPV: 2,
            moveTimeMilliseconds: 100
        )
        #expect(ChessGameState().legalMoves.contains(analysis.bestMove))
        #expect(!analysis.variations.isEmpty)
        #expect(analysis.variations.count <= 2)
        await service.shutdown()
    }

    @Test func concurrentSearchesOnOneProcessAreSerialized() async throws {
        let service = StockfishService(role: .analyst)
        let afterE4 = ChessGameState()
        _ = try afterE4.make(uci: "e2e4")
        let afterE4FEN = afterE4.fen
        let afterE4LegalMoves = afterE4.legalMoves

        async let initial = service.analyze(
            fen: ChessGameState.standardInitialFEN,
            multiPV: 2,
            moveTimeMilliseconds: 100
        )
        async let reply = service.analyze(
            fen: afterE4FEN,
            multiPV: 2,
            moveTimeMilliseconds: 100
        )

        let (initialAnalysis, replyAnalysis) = try await (initial, reply)
        #expect(initialAnalysis.fen == ChessGameState.standardInitialFEN)
        #expect(replyAnalysis.fen == afterE4FEN)
        #expect(ChessGameState().legalMoves.contains(initialAnalysis.bestMove))
        #expect(afterE4LegalMoves.contains(replyAnalysis.bestMove))
        #expect(await service.processLaunchCount == 1)
        await service.shutdown()
    }

    @Test func taskCancellationDrainsSearchAndLeavesProcessReady() async throws {
        let service = StockfishService(role: .analyst)
        let search = Task {
            try await service.analyze(
                fen: ChessGameState.standardInitialFEN,
                multiPV: 3,
                moveTimeMilliseconds: 5_000
            )
        }

        try await Task.sleep(for: .milliseconds(75))
        search.cancel()
        await expectCancellation(from: search)

        let followUp = try await service.analyze(
            fen: ChessGameState.standardInitialFEN,
            multiPV: 1,
            moveTimeMilliseconds: 100
        )
        #expect(ChessGameState().legalMoves.contains(followUp.bestMove))
        #expect(await service.processLaunchCount == 1)
        await service.shutdown()
    }

    @Test func explicitStopDrainsSearchAndLeavesProcessReady() async throws {
        let service = StockfishService(role: .analyst)
        let search = Task {
            try await service.analyze(
                fen: ChessGameState.standardInitialFEN,
                multiPV: 1,
                moveTimeMilliseconds: 5_000
            )
        }

        try await Task.sleep(for: .milliseconds(75))
        await service.stopThinking()
        await expectCancellation(from: search)

        let followUp = try await service.analyze(
            fen: ChessGameState.standardInitialFEN,
            multiPV: 1,
            moveTimeMilliseconds: 100
        )
        #expect(ChessGameState().legalMoves.contains(followUp.bestMove))
        #expect(await service.processLaunchCount == 1)
        await service.shutdown()
    }

    @Test func unexpectedProcessExitRestartsAndRetriesOnce() async throws {
        let service = StockfishService(role: .analyst)
        try await service.start()
        let launchCount = await service.processLaunchCount
        let search = Task {
            try await service.analyze(
                fen: ChessGameState.standardInitialFEN,
                multiPV: 1,
                moveTimeMilliseconds: 500
            )
        }

        try await Task.sleep(for: .milliseconds(75))
        await service.terminateProcessForTesting()
        let recovered = try await search.value

        #expect(ChessGameState().legalMoves.contains(recovered.bestMove))
        #expect(await service.processLaunchCount == launchCount + 1)
        await service.shutdown()
    }

    private func expectCancellation(from task: Task<PositionAnalysis, Error>) async {
        do {
            _ = try await task.value
            Issue.record("Expected the Stockfish search to be cancelled.")
        } catch is CancellationError {
            // Expected.
        } catch {
            Issue.record("Expected CancellationError, received \(error).")
        }
    }
}
