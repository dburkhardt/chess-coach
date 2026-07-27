import Foundation

protocol ChessEngineServing: Sendable {
    func analyze(
        fen: String,
        multiPV: Int,
        moveTimeMilliseconds: Int
    ) async throws -> PositionAnalysis

    func opponentMove(
        fen: String,
        difficulty: Int,
        clocks: ClockSnapshot,
        timeControl: TimeControl
    ) async throws -> String

    func stopThinking() async
    func shutdown() async
}

extension StockfishService: ChessEngineServing {}

protocol CoachInferenceServing: Sendable {
    func generateHint(
        configuration: InferenceConfiguration,
        credential: String,
        context: CoachContext
    ) async throws -> CoachHint

    func streamChat(
        configuration: InferenceConfiguration,
        credential: String,
        context: CoachContext,
        history: [CoachMessage]
    ) -> AsyncThrowingStream<String, Error>

    func generateReply(
        configuration: InferenceConfiguration,
        credential: String,
        context: CoachContext,
        history: [CoachMessage]
    ) async throws -> CoachReply
}

extension CoachInferenceServing {
    /// Compatibility path for injected/test inference services that implement
    /// only the text stream. The production client provides a typed structured
    /// implementation.
    func generateReply(
        configuration: InferenceConfiguration,
        credential: String,
        context: CoachContext,
        history: [CoachMessage]
    ) async throws -> CoachReply {
        var text = ""
        for try await chunk in streamChat(
            configuration: configuration,
            credential: credential,
            context: context,
            history: history
        ) {
            try Task.checkCancellation()
            text += chunk
        }
        let reply = CoachReply.legacy(text: text)
        guard !reply.plainText.isEmpty else {
            throw InferenceError.invalidResponse
        }
        return reply
    }
}

extension ModelInferenceClient: CoachInferenceServing {}

protocol GameClockServing: Sendable {
    func now() -> Date
    func sleepForTick() async
}

struct SystemGameClock: GameClockServing {
    func now() -> Date {
        .now
    }

    func sleepForTick() async {
        try? await Task.sleep(for: .milliseconds(100))
    }
}
