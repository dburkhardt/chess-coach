import SwiftUI

struct GameOverPresentation: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        case playerWin
        case computerWin
        case draw
    }

    let outcome: Outcome
    let title: String
    let reason: String
    let resultNotation: String

    var accessibilitySummary: String {
        "\(title). \(reason). Result \(spokenResultNotation)."
    }

    var systemImage: String {
        switch outcome {
        case .playerWin:
            "trophy.fill"
        case .computerWin:
            "flag.checkered"
        case .draw:
            "equal.circle.fill"
        }
    }

    private var spokenResultNotation: String {
        switch resultNotation {
        case "1-0":
            "one to zero"
        case "0-1":
            "zero to one"
        case "1/2-1/2":
            "one half to one half"
        default:
            resultNotation
        }
    }
}

enum GameOverPresentationMapper {
    static func resolve(
        status: ChessGameStatus,
        playerSide: ChessSide
    ) -> GameOverPresentation? {
        let outcome: GameOverPresentation.Outcome
        let resultNotation: String

        switch status.result {
        case .whiteWon:
            outcome = playerSide == .white ? .playerWin : .computerWin
            resultNotation = "1-0"
        case .blackWon:
            outcome = playerSide == .black ? .playerWin : .computerWin
            resultNotation = "0-1"
        case .draw:
            outcome = .draw
            resultNotation = "1/2-1/2"
        case .resigned, .timeout:
            // Legacy saved games did not retain the winner's color. Only the
            // learner can resign or run out of time in those records.
            outcome = .computerWin
            resultNotation = playerSide == .white ? "0-1" : "1-0"
        case .inProgress, .abandoned:
            return nil
        }

        return GameOverPresentation(
            outcome: outcome,
            title: title(for: outcome),
            reason: reason(
                for: status.reason,
                outcome: outcome,
                fallback: status.message
            ),
            resultNotation: resultNotation
        )
    }

    private static func title(
        for outcome: GameOverPresentation.Outcome
    ) -> String {
        switch outcome {
        case .playerWin:
            "You won"
        case .computerWin:
            "Computer won"
        case .draw:
            "Draw"
        }
    }

    private static func reason(
        for reason: GameEndReason,
        outcome: GameOverPresentation.Outcome,
        fallback: String
    ) -> String {
        switch reason {
        case .checkmate:
            "Checkmate"
        case .stalemate:
            "Stalemate"
        case .repetition:
            "Threefold repetition"
        case .fiftyMoveRule:
            "Fifty-move rule"
        case .insufficientMaterial:
            "Insufficient material"
        case .resignation:
            outcome == .playerWin ? "Computer resigned" : "You resigned"
        case .timeout:
            outcome == .playerWin
                ? "Computer ran out of time"
                : "You ran out of time"
        case .restarted:
            "Game restarted"
        case .none:
            fallback.isEmpty ? "Game complete" : fallback
        }
    }
}

struct GameOverPanel: View {
    let status: ChessGameStatus
    let playerSide: ChessSide
    let canReview: Bool
    let onReview: () -> Void
    let onPlayAgain: () -> Void

    init(
        status: ChessGameStatus,
        playerSide: ChessSide,
        canReview: Bool = true,
        onReview: @escaping () -> Void,
        onPlayAgain: @escaping () -> Void
    ) {
        self.status = status
        self.playerSide = playerSide
        self.canReview = canReview
        self.onReview = onReview
        self.onPlayAgain = onPlayAgain
    }

    var body: some View {
        if let presentation = GameOverPresentationMapper.resolve(
            status: status,
            playerSide: playerSide
        ) {
            panel(for: presentation)
        }
    }

    private func panel(
        for presentation: GameOverPresentation
    ) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: presentation.systemImage)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(accentColor(for: presentation.outcome))
                    .frame(width: 38, height: 38)
                    .background(
                        accentColor(for: presentation.outcome).opacity(0.12),
                        in: Circle()
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(presentation.title)
                        .font(.title2.weight(.bold))
                        .accessibilityAddTraits(.isHeader)

                    Text(presentation.reason)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(presentation.resultNotation)
                    .font(.system(.subheadline, design: .monospaced).weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(.quaternary, in: Capsule())
                    .accessibilityLabel(
                        "Result \(presentation.resultNotation)"
                    )
            }

            if canReview {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        reviewButton
                        playAgainButton
                    }

                    VStack(spacing: 8) {
                        playAgainButton
                        reviewButton
                    }
                }
            } else {
                playAgainButton
            }
        }
        .padding(18)
        .frame(maxWidth: 520, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay {
            RoundedRectangle(cornerRadius: 16)
                .stroke(.separator.opacity(0.7), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(presentation.accessibilitySummary)
    }

    private var reviewButton: some View {
        Button(action: onReview) {
            Label("Review Game", systemImage: "chart.xyaxis.line")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityHint("Opens the completed game review")
    }

    private var playAgainButton: some View {
        Button(action: onPlayAgain) {
            Label("Play Again", systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(Color.coachGreen)
        .accessibilityHint("Starts a new game with the current settings")
    }

    private func accentColor(
        for outcome: GameOverPresentation.Outcome
    ) -> Color {
        switch outcome {
        case .playerWin:
            .coachGreen
        case .computerWin:
            .orange
        case .draw:
            .blue
        }
    }
}
