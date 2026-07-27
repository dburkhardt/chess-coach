import Foundation

@MainActor
struct LearnerProfileService {
    /// Informal internal anchors for Stockfish levels 1–10. These are coaching
    /// calibration inputs, not claims about FIDE, Chess.com, or Lichess ratings.
    static let levelAnchors = [700, 850, 1_000, 1_150, 1_300, 1_500, 1_700, 1_900, 2_150, 2_400]

    func incorporate(game: SavedGame, into profile: LearnerProfile) {
        profile.reviewedGames += 1

        let playerPlies = game.plies.filter { $0.side == game.playerSide }
        let classified = playerPlies.compactMap(\.classification)
        let count = max(1, classified.count)
        let blunders = classified.filter { $0 == .blunder }.count
        let mistakes = classified.filter { $0 == .mistake }.count
        profile.blunderRate = rolling(previous: profile.blunderRate, new: Double(blunders) / Double(count), samples: profile.reviewedGames)
        profile.mistakeRate = rolling(previous: profile.mistakeRate, new: Double(mistakes) / Double(count), samples: profile.reviewedGames)

        let timePressureMoves = playerPlies.filter {
            let before = $0.clockBefore.value(for: game.playerSide)
            return game.timeControl.usesClock && before < 60_000
        }
        let timePressureErrors = timePressureMoves.filter {
            $0.classification == .mistake || $0.classification == .blunder
        }
        if !timePressureMoves.isEmpty {
            let rate = Double(timePressureErrors.count) / Double(timePressureMoves.count)
            profile.timePressureRate = rolling(previous: profile.timePressureRate, new: rate, samples: profile.reviewedGames)
        }

        let phases = phaseScores(for: playerPlies)
        profile.openingScore = rolling(previous: profile.openingScore, new: phases.opening, samples: profile.reviewedGames)
        profile.middlegameScore = rolling(previous: profile.middlegameScore, new: phases.middle, samples: profile.reviewedGames)
        profile.endgameScore = rolling(previous: profile.endgameScore, new: phases.end, samples: profile.reviewedGames)

        var weaknesses: [String] = []
        if profile.blunderRate >= 0.12 { weaknesses.append("severe tactical oversights") }
        if profile.mistakeRate >= 0.20 { weaknesses.append("candidate-move comparison") }
        if profile.timePressureRate >= 0.25 { weaknesses.append("decision quality under one minute") }
        let weakestPhase = [
            ("opening", profile.openingScore),
            ("middlegame", profile.middlegameScore),
            ("endgame", profile.endgameScore),
        ].min(by: { $0.1 < $1.1 })?.0
        if let weakestPhase, !classified.isEmpty {
            weaknesses.append("\(weakestPhase) decision-making")
        }
        profile.weaknessSummary = weaknesses.isEmpty
            ? "No repeated weakness has enough evidence yet."
            : "Focus areas: " + weaknesses.joined(separator: ", ") + "."

        let strongestPhase = [
            ("opening", profile.openingScore),
            ("middlegame", profile.middlegameScore),
            ("endgame", profile.endgameScore),
        ].max(by: { $0.1 < $1.1 })?.0 ?? "opening"
        profile.strengthsSummary = "Current relative strength: \(strongestPhase) play."

        if game.timeControl.usesClock,
           !game.assistanceUsed,
           let score = ratingScore(for: game) {
            updateRating(score: score, difficulty: game.difficulty, profile: profile)
        }
        profile.updatedAt = .now
    }

    private func ratingScore(for game: SavedGame) -> Double? {
        switch game.result {
        case .draw:
            return 0.5
        case .whiteWon:
            return game.playerSide == .white ? 1 : 0
        case .blackWon:
            return game.playerSide == .black ? 1 : 0
        default:
            return nil
        }
    }

    private func updateRating(
        score: Double,
        difficulty: Int,
        profile: LearnerProfile
    ) {
        profile.eligibleGames += 1
        let center = Double(profile.estimateLow + profile.estimateHigh) / 2
        let opponent = Double(Self.levelAnchors[min(max(difficulty, 1), 10) - 1])
        let expected = 1 / (1 + pow(10, (opponent - center) / 400))
        let k = profile.eligibleGames <= 10 ? 40.0 : 24.0
        let updated = center + k * (score - expected)
        let halfWidth = profile.eligibleGames < 5
            ? 250
            : max(100, Int(300 / sqrt(Double(profile.eligibleGames) / 5)))
        profile.estimateLow = max(100, Int(updated.rounded()) - halfWidth)
        profile.estimateHigh = min(3_000, Int(updated.rounded()) + halfWidth)
        profile.confidence = min(1, Double(profile.eligibleGames) / 20)
        profile.ratingHistory.append(Int(updated.rounded()))
    }

    private func phaseScores(for plies: [SavedPly]) -> (opening: Double, middle: Double, end: Double) {
        func quality(_ slice: [SavedPly]) -> Double {
            guard !slice.isEmpty else { return 0.5 }
            let total = slice.reduce(0.0) { partial, ply in
                let value: Double
                switch ply.classification {
                case .best: value = 1
                case .good: value = 0.85
                case .inaccuracy: value = 0.6
                case .mistake: value = 0.3
                case .blunder: value = 0
                case nil: value = 0.5
                }
                return partial + value
            }
            return total / Double(slice.count)
        }
        let opening = plies.filter { $0.index < 20 }
        let middle = plies.filter { $0.index >= 20 && $0.index < 60 }
        let end = plies.filter { $0.index >= 60 }
        return (quality(opening), quality(middle), quality(end))
    }

    private func rolling(previous: Double, new: Double, samples: Int) -> Double {
        let weight = min(max(samples, 1), 20)
        return previous + (new - previous) / Double(weight)
    }
}
