import Foundation
import Darwin

enum StockfishError: LocalizedError {
    case executableMissing
    case launchFailed(String)
    case engineStopped
    case noBestMove

    var errorDescription: String? {
        switch self {
        case .executableMissing: "The bundled Stockfish engine is missing."
        case .launchFailed(let message): "Stockfish could not start: \(message)"
        case .engineStopped: "Stockfish stopped unexpectedly."
        case .noBestMove: "Stockfish did not return a legal move."
        }
    }
}

actor StockfishService {
    nonisolated static let difficultySkillLevels = [0, 2, 4, 6, 8, 10, 12, 14, 17, 20]

    enum Role {
        case opponent
        case analyst
    }

    private static let engineStoppedLine = "__ENGINE_STOPPED__"

    private let role: Role
    private let executableURL: URL?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var errorOutput: FileHandle?
    private var readerTask: Task<Void, Never>?
    private var errorReaderTask: Task<Void, Never>?
    private var lines: [String] = []
    private var waiters: [CheckedContinuation<String, Never>] = []
    private var partialLine = ""
    private var processGeneration = 0

    // Actors are reentrant at every await. This gate ensures that one logical
    // UCI request owns the command/output stream through its final readyok.
    private var searchInProgress = false
    private var searchWaiters: [CheckedContinuation<Void, Never>] = []
    private var activeSearchID: UUID?
    private var cancellationRequested = false

    private(set) var isReady = false
    private(set) var processLaunchCount = 0

    init(role: Role, executableURL: URL? = nil) {
        self.role = role
        self.executableURL = executableURL
    }

    deinit {
        readerTask?.cancel()
        errorReaderTask?.cancel()
        try? input?.close()
        try? output?.close()
        try? errorOutput?.close()
        process?.terminate()
    }

    func start() async throws {
        await acquireSearchSlot()
        defer { releaseSearchSlot() }
        try Task.checkCancellation()
        try await startProcess()
    }

    func analyze(
        fen: String,
        multiPV: Int = 3,
        moveTimeMilliseconds: Int = 700
    ) async throws -> PositionAnalysis {
        let searchID = UUID()
        return try await withTaskCancellationHandler {
            await acquireSearchSlot()
            defer { releaseSearchSlot() }

            try Task.checkCancellation()
            beginSearch(searchID)
            defer { endSearch(searchID) }
            try throwIfCancellationRequested(for: searchID)

            return try await analyzeWithRecovery(
                fen: fen,
                multiPV: multiPV,
                moveTimeMilliseconds: moveTimeMilliseconds,
                searchID: searchID
            )
        } onCancel: {
            Task { await self.cancelSearch(searchID) }
        }
    }

    func opponentMove(
        fen: String,
        difficulty: Int,
        clocks: ClockSnapshot,
        timeControl: TimeControl
    ) async throws -> String {
        let searchID = UUID()
        return try await withTaskCancellationHandler {
            await acquireSearchSlot()
            defer { releaseSearchSlot() }

            try Task.checkCancellation()
            beginSearch(searchID)
            defer { endSearch(searchID) }
            try throwIfCancellationRequested(for: searchID)

            return try await opponentMoveWithRecovery(
                fen: fen,
                difficulty: difficulty,
                clocks: clocks,
                timeControl: timeControl,
                searchID: searchID
            )
        } onCancel: {
            Task { await self.cancelSearch(searchID) }
        }
    }

    func stopThinking() {
        guard activeSearchID != nil else { return }
        cancellationRequested = true
        try? send("stop")
    }

    func shutdown() {
        cancellationRequested = true
        try? send("quit")
        discardProcess(terminate: true, failPendingReads: true)
    }

    // Intentionally internal for deterministic process-recovery coverage.
    func terminateProcessForTesting() {
        process?.terminate()
    }

    private func analyzeWithRecovery(
        fen: String,
        multiPV: Int,
        moveTimeMilliseconds: Int,
        searchID: UUID
    ) async throws -> PositionAnalysis {
        do {
            return try await analyzeOnce(
                fen: fen,
                multiPV: multiPV,
                moveTimeMilliseconds: moveTimeMilliseconds,
                searchID: searchID
            )
        } catch StockfishError.engineStopped {
            try throwIfCancellationRequested(for: searchID)
            discardProcess(terminate: true)
            return try await analyzeOnce(
                fen: fen,
                multiPV: multiPV,
                moveTimeMilliseconds: moveTimeMilliseconds,
                searchID: searchID
            )
        }
    }

    private func analyzeOnce(
        fen: String,
        multiPV: Int,
        moveTimeMilliseconds: Int,
        searchID: UUID
    ) async throws -> PositionAnalysis {
        try await startProcess()
        try throwIfCancellationRequested(for: searchID)

        let sideToMove: ChessSide = fen.split(separator: " ").dropFirst().first == "b" ? .black : .white
        try send("setoption name MultiPV value \(max(1, multiPV))")
        try send("position fen \(fen)")
        try send("go movetime \(max(50, moveTimeMilliseconds))")

        var latest: [Int: UCIParser.Info] = [:]
        while true {
            let line = await nextLine()
            if line == Self.engineStoppedLine {
                throw StockfishError.engineStopped
            }
            if let info = UCIParser.parseInfo(line) {
                latest[info.multipv] = UCIParser.whitePerspective(info, sideToMove: sideToMove)
            }
            if line.hasPrefix("bestmove ") {
                let best = UCIParser.parseBestMove(line)
                try await synchronizeAfterSearch()
                try throwIfCancellationRequested(for: searchID)
                guard let best else { throw StockfishError.noBestMove }

                let variations = latest.values.sorted(by: { $0.multipv < $1.multipv }).map {
                    PrincipalVariation(
                        index: $0.multipv,
                        depth: $0.depth,
                        score: $0.score,
                        wdl: $0.wdl,
                        moves: $0.moves
                    )
                }
                return PositionAnalysis(
                    fen: fen,
                    sideToMove: sideToMove,
                    bestMove: best.move,
                    ponderMove: best.ponder,
                    variations: variations
                )
            }
        }
    }

    private func opponentMoveWithRecovery(
        fen: String,
        difficulty: Int,
        clocks: ClockSnapshot,
        timeControl: TimeControl,
        searchID: UUID
    ) async throws -> String {
        do {
            return try await opponentMoveOnce(
                fen: fen,
                difficulty: difficulty,
                clocks: clocks,
                timeControl: timeControl,
                searchID: searchID
            )
        } catch StockfishError.engineStopped {
            try throwIfCancellationRequested(for: searchID)
            discardProcess(terminate: true)
            return try await opponentMoveOnce(
                fen: fen,
                difficulty: difficulty,
                clocks: clocks,
                timeControl: timeControl,
                searchID: searchID
            )
        }
    }

    private func opponentMoveOnce(
        fen: String,
        difficulty: Int,
        clocks: ClockSnapshot,
        timeControl: TimeControl,
        searchID: UUID
    ) async throws -> String {
        try await startProcess()
        try throwIfCancellationRequested(for: searchID)

        let level = Self.skillLevel(for: difficulty)
        try send("setoption name MultiPV value 1")
        try send("setoption name Skill Level value \(level)")
        try send("position fen \(fen)")
        try send(Self.goCommand(difficulty: difficulty, clocks: clocks, timeControl: timeControl))

        while true {
            let line = await nextLine()
            if line == Self.engineStoppedLine {
                throw StockfishError.engineStopped
            }
            if line.hasPrefix("bestmove ") {
                let best = UCIParser.parseBestMove(line)
                try await synchronizeAfterSearch()
                try throwIfCancellationRequested(for: searchID)
                guard let best else { throw StockfishError.noBestMove }
                return best.move
            }
        }
    }

    private func startProcess() async throws {
        if process?.isRunning == true, isReady { return }
        if process != nil {
            discardProcess(terminate: true)
        }

        guard let executable = executableURL ?? Self.locateExecutable() else {
            throw StockfishError.executableMissing
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw StockfishError.launchFailed(error.localizedDescription)
        }

        processGeneration += 1
        let generation = processGeneration
        self.process = process
        input = inputPipe.fileHandleForWriting
        isReady = false
        processLaunchCount += 1

        let output = outputPipe.fileHandleForReading
        self.output = output
        let outputDescriptor = output.fileDescriptor
        readerTask = Task.detached { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while !Task.isCancelled {
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(outputDescriptor, $0.baseAddress, $0.count)
                }
                guard count > 0 else { break }
                await self?.consume(
                    data: Data(buffer.prefix(count)),
                    generation: generation
                )
            }
            await self?.readerEnded(generation: generation)
        }

        let errorOutput = errorPipe.fileHandleForReading
        self.errorOutput = errorOutput
        let errorDescriptor = errorOutput.fileDescriptor
        errorReaderTask = Task.detached {
            var buffer = [UInt8](repeating: 0, count: 16_384)
            while !Task.isCancelled {
                let count = buffer.withUnsafeMutableBytes {
                    Darwin.read(errorDescriptor, $0.baseAddress, $0.count)
                }
                guard count > 0 else { break }
            }
        }

        try send("uci")
        try await wait(until: { $0 == "uciok" })
        try send("setoption name UCI_ShowWDL value true")
        if role == .analyst {
            try send("setoption name Threads value 2")
            try send("setoption name Hash value 256")
        } else {
            try send("setoption name Threads value 1")
            try send("setoption name Hash value 64")
        }
        try send("isready")
        try await wait(until: { $0 == "readyok" })
        isReady = true
    }

    private func synchronizeAfterSearch() async throws {
        try send("isready")
        try await wait(until: { $0 == "readyok" })
    }

    private func send(_ command: String) throws {
        guard process?.isRunning == true, let input else {
            throw StockfishError.engineStopped
        }
        guard let data = "\(command)\n".data(using: .utf8) else {
            throw StockfishError.engineStopped
        }
        do {
            try input.write(contentsOf: data)
        } catch {
            throw StockfishError.engineStopped
        }
    }

    private func wait(until predicate: (String) -> Bool) async throws {
        while true {
            let line = await nextLine()
            if line == Self.engineStoppedLine {
                throw StockfishError.engineStopped
            }
            if predicate(line) { return }
        }
    }

    private func nextLine() async -> String {
        if !lines.isEmpty { return lines.removeFirst() }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func consume(data: Data, generation: Int) {
        guard generation == processGeneration else { return }
        for byte in data {
            if byte == 10 {
                let line = partialLine.trimmingCharacters(in: .newlines)
                partialLine = ""
                if !line.isEmpty { receive(line: line) }
            } else {
                partialLine.unicodeScalars.append(UnicodeScalar(byte))
            }
        }
    }

    private func readerEnded(generation: Int) {
        guard generation == processGeneration else { return }
        isReady = false
        receive(line: Self.engineStoppedLine)
    }

    private func receive(line: String) {
        if !waiters.isEmpty {
            waiters.removeFirst().resume(returning: line)
        } else {
            lines.append(line)
        }
    }

    private func discardProcess(terminate: Bool, failPendingReads: Bool = false) {
        processGeneration += 1
        readerTask?.cancel()
        errorReaderTask?.cancel()
        try? input?.close()
        try? output?.close()
        try? errorOutput?.close()
        if terminate, process?.isRunning == true {
            process?.terminate()
        }
        process = nil
        input = nil
        output = nil
        errorOutput = nil
        readerTask = nil
        errorReaderTask = nil
        isReady = false
        lines.removeAll()
        partialLine = ""

        if failPendingReads {
            let pending = waiters
            waiters.removeAll()
            for waiter in pending {
                waiter.resume(returning: Self.engineStoppedLine)
            }
        }
    }

    private func acquireSearchSlot() async {
        if !searchInProgress {
            searchInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            searchWaiters.append(continuation)
        }
    }

    private func releaseSearchSlot() {
        if searchWaiters.isEmpty {
            searchInProgress = false
        } else {
            searchWaiters.removeFirst().resume()
        }
    }

    private func beginSearch(_ searchID: UUID) {
        activeSearchID = searchID
        cancellationRequested = false
    }

    private func endSearch(_ searchID: UUID) {
        guard activeSearchID == searchID else { return }
        activeSearchID = nil
        cancellationRequested = false
    }

    private func cancelSearch(_ searchID: UUID) {
        guard activeSearchID == searchID else { return }
        cancellationRequested = true
        try? send("stop")
    }

    private func throwIfCancellationRequested(for searchID: UUID) throws {
        if activeSearchID == searchID, cancellationRequested {
            throw CancellationError()
        }
        try Task.checkCancellation()
    }

    nonisolated static func locateExecutable() -> URL? {
        let fileManager = FileManager.default
        let bundled = Bundle.main.url(forResource: "stockfish", withExtension: nil, subdirectory: "Engines")
            ?? Bundle.main.url(forResource: "stockfish", withExtension: nil)
        if let bundled, fileManager.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        let developmentPaths = [
            "/opt/homebrew/bin/stockfish",
            "/usr/local/bin/stockfish",
        ]
        return developmentPaths
            .map(URL.init(fileURLWithPath:))
            .first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }

    nonisolated static func skillLevel(for difficulty: Int) -> Int {
        difficultySkillLevels[min(max(difficulty, 1), 10) - 1]
    }

    nonisolated static func goCommand(
        difficulty: Int,
        clocks: ClockSnapshot,
        timeControl: TimeControl
    ) -> String {
        guard timeControl.usesClock else {
            return "go movetime \(difficulty <= 3 ? 250 : 600)"
        }
        return "go wtime \(max(1, clocks.whiteMilliseconds)) " +
            "btime \(max(1, clocks.blackMilliseconds)) " +
            "winc \(timeControl.incrementSeconds * 1_000) " +
            "binc \(timeControl.incrementSeconds * 1_000)"
    }
}
