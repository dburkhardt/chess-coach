import Foundation
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

    @Test func simultaneousOpponentAndAnalystDoNotBlockAsyncWorkers() async throws {
        if ProcessInfo.processInfo.environment["CHESS_COACH_REQUIRE_STRICT_EXECUTOR"] == "1" {
            #expect(ProcessInfo.processInfo.environment["SWIFT_CONCURRENCY_DEBUG_STRICT"] == "1")
        }
        let opponent = StockfishService(role: .opponent)
        let analyst = StockfishService(role: .analyst)
        let state = ChessGameState()
        _ = try state.make(uci: "e2e4")
        let fen = state.fen
        async let reply = opponent.opponentMove(
            fen: fen, difficulty: 4,
            clocks: .initial(for: .rapid10), timeControl: .rapid10
        )
        async let analysis = analyst.analyze(fen: fen, multiPV: 2, moveTimeMilliseconds: 100)
        let (move, result) = try await (reply, analysis)
        #expect(state.legalMoves.contains(move))
        #expect(state.legalMoves.contains(result.bestMove))
        await opponent.shutdown()
        await analyst.shutdown()
    }

    @Test func silentEngineTimesOutInsteadOfThinkingForever() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("silent-engine")
        try Data("#!/bin/sh\nexec /bin/sleep 30\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let service = StockfishService(
            role: .opponent, executableURL: executable, responseTimeout: .milliseconds(100)
        )
        await #expect(throws: StockfishError.responseTimedOut) {
            try await service.opponentMove(
                fen: ChessGameState.standardInitialFEN, difficulty: 4,
                clocks: .initial(for: .rapid10), timeControl: .rapid10
            )
        }
        #expect(await service.isReady == false)
        await service.shutdown()
    }

    @Test func engineThatStopsReplyingAfterHandshakeTimesOut() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("stalled-engine")
        let script = """
        #!/bin/sh
        while IFS= read -r command; do
            case "$command" in
                uci) echo uciok ;;
                isready) echo readyok ;;
                quit) exit 0 ;;
            esac
        done
        """
        try Data((script + "\n").utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let service = StockfishService(
            role: .opponent, executableURL: executable, responseTimeout: .seconds(1)
        )
        try await service.start()
        #expect(await service.isReady)
        await #expect(throws: StockfishError.responseTimedOut) {
            try await service.opponentMove(
                fen: ChessGameState.standardInitialFEN, difficulty: 4,
                clocks: .initial(for: .rapid10), timeControl: .rapid10
            )
        }
        #expect(await service.isReady == false)
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
