import Foundation

@MainActor
final class ReviewAnalyzer {
    private let analyst: any ChessEngineServing
    private let profileService = LearnerProfileService()

    init(analyst: any ChessEngineServing) {
        self.analyst = analyst
    }

    func reviewPendingGames(persistence: PersistenceController) async {
        for game in persistence.pendingReviewGames {
            guard !Task.isCancelled else { return }
            await review(game: game, persistence: persistence)
        }
    }

    func review(game: SavedGame, persistence: PersistenceController) async {
        guard shouldContinueReview(game) else { return }
        if game.reviewCompleted {
            incorporateProfileIfNeeded(game: game, persistence: persistence)
            return
        }

        game.reviewAttemptedAt = .now
        game.reviewLastError = ""
        persistence.save()

        var losses: [Double] = []
        var keyMoments: [(SavedPly, Double)] = []
        var failures: [String] = []
        var cache: [String: PositionAnalysis] = [:]
        let plies = game.sortedPlies

        for ply in plies {
            guard !Task.isCancelled else { return }
            do {
                let before = try await analysis(
                    for: ply.fenBefore,
                    multiPV: ply.side == game.playerSide ? 3 : 1,
                    cache: &cache
                )
                guard shouldContinueReview(game) else { return }
                let after = try await analysis(
                    for: ply.fenAfter,
                    multiPV: 1,
                    cache: &cache
                )
                guard shouldContinueReview(game) else { return }
                persistence.recordAnalysis(
                    before,
                    purpose: "review-before",
                    atPly: ply.index,
                    in: game
                )
                persistence.recordAnalysis(
                    after,
                    purpose: "review-after",
                    atPly: ply.index + 1,
                    in: game
                )

                let oldScore = expectedScore(before, for: game.playerSide)
                let newScore = expectedScore(after, for: game.playerSide)
                ply.expectedScoreBefore = oldScore
                ply.expectedScoreAfter = newScore

                if ply.side == game.playerSide {
                    let loss = max(0, oldScore - newScore)
                    ply.expectedScoreLoss = loss
                    ply.classification = MoveClassification.from(expectedScoreLoss: loss)
                    ply.bestMoveUCI = before.bestMove
                    ply.bestMoveSAN = san(for: before.bestMove, in: ply.fenBefore)
                    ply.principalVariationSAN = sanLine(
                        for: before.primary?.moves ?? [],
                        in: ply.fenBefore
                    ).joined(separator: " ")
                    losses.append(loss)
                    keyMoments.append((ply, loss))
                }
            } catch is CancellationError {
                return
            } catch {
                guard shouldContinueReview(game) else { return }
                failures.append("Move \(ply.index / 2 + 1): \(error.localizedDescription)")
            }
        }

        guard shouldContinueReview(game) else { return }
        game.averageExpectedScoreLoss = losses.isEmpty ? 0 : losses.reduce(0, +) / Double(losses.count)
        game.blunderCount = plies.filter { $0.side == game.playerSide && $0.classification == .blunder }.count
        game.mistakeCount = plies.filter { $0.side == game.playerSide && $0.classification == .mistake }.count
        let top = keyMoments.sorted(by: { $0.1 > $1.1 }).prefix(3)
        if top.isEmpty {
            game.reviewSummary = "No critical moments were available for analysis."
        } else {
            game.reviewSummary = top.map {
                let alternative = $0.0.bestMoveSAN.isEmpty
                    ? ""
                    : "; Stockfish preferred \($0.0.bestMoveSAN)"
                return "• \($0.0.san) on move \($0.0.index / 2 + 1): " +
                    "\(Int(($0.1 * 100).rounded()))-point expected-score loss\(alternative)"
            }.joined(separator: "\n")
        }

        if failures.isEmpty {
            game.reviewCompleted = true
            game.reviewLastError = ""
            incorporateProfileIfNeeded(game: game, persistence: persistence)
        } else {
            game.reviewCompleted = false
            game.reviewLastError = failures.prefix(3).joined(separator: "\n")
        }
        persistence.save()
        persistence.refreshGames()
    }

    private func incorporateProfileIfNeeded(
        game: SavedGame,
        persistence: PersistenceController
    ) {
        guard shouldContinueReview(game), !game.profileIncorporated else {
            return
        }
        profileService.incorporate(game: game, into: persistence.profile)
        game.profileIncorporated = true
        persistence.save()
    }

    private func shouldContinueReview(_ game: SavedGame) -> Bool {
        !Task.isCancelled &&
            game.result != .inProgress &&
            game.result != .abandoned
    }

    private func analysis(
        for fen: String,
        multiPV: Int,
        cache: inout [String: PositionAnalysis]
    ) async throws -> PositionAnalysis {
        if let cached = cache[fen],
           cached.variations.count >= multiPV || multiPV == 1 {
            return cached
        }
        let result = try await analyst.analyze(
            fen: fen,
            multiPV: multiPV,
            moveTimeMilliseconds: 300
        )
        cache[fen] = result
        return result
    }

    private func expectedScore(
        _ analysis: PositionAnalysis,
        for side: ChessSide
    ) -> Double {
        if let score = analysis.expectedScore(for: side) {
            return score
        }

        if let mate = analysis.primary?.score.mate {
            let whiteScore = mate > 0 ? 1.0 : 0.0
            return side == .white ? whiteScore : 1 - whiteScore
        }

        let centipawns = Double(analysis.primary?.score.centipawns ?? 0)
        let whiteScore = 1 / (1 + pow(10, -centipawns / 400))
        return side == .white ? whiteScore : 1 - whiteScore
    }

    private func san(for move: String, in fen: String) -> String {
        guard !move.isEmpty else { return "" }
        let state = ChessGameState(initialFEN: fen)
        return (try? state.make(uci: move).san) ?? move
    }

    private func sanLine(for moves: [String], in fen: String) -> [String] {
        let state = ChessGameState(initialFEN: fen)
        var result: [String] = []
        for move in moves.prefix(10) {
            guard let made = try? state.make(uci: move) else { break }
            result.append(made.san)
        }
        return result
    }
}
