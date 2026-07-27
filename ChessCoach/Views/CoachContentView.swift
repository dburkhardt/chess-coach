import SwiftUI

struct CoachReplyContentView: View {
    let reply: CoachReply
    let variations: [CoachVariationPresentation]
    let playerSide: ChessSide
    var selectedMoveID: String?
    var onSelectMove: (CoachVariationPresentation, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let summary = CoachReplySanitizer.plainText(reply.summary)
            if !summary.isEmpty {
                Text(summary)
                    .font(.subheadline.weight(.medium))
                    .textSelection(.enabled)
            }

            ForEach(Array(reply.sections.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 5) {
                    if !section.title.isEmpty {
                        Text(section.title)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                    }

                    let body = CoachReplySanitizer.plainText(section.body)
                    if !body.isEmpty {
                        Text(body)
                            .font(.subheadline)
                            .textSelection(.enabled)
                    }

                    if section.kind == .variation,
                       let rank = section.variationRank,
                       let variation = variations.first(where: { $0.rank == rank }) {
                        CoachVariationLineView(
                            variation: variation,
                            playerSide: playerSide,
                            selectedMoveID: selectedMoveID,
                            onSelectMove: onSelectMove
                        )
                        .padding(.top, 3)
                    }
                }
            }
        }
    }
}

struct CoachVariationLineView: View {
    let variation: CoachVariationPresentation
    let playerSide: ChessSide
    var selectedMoveID: String?
    var onSelectMove: (CoachVariationPresentation, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(variation.rank == 1 ? "Engine line" : "Alternative \(variation.rank)")
                    .font(.caption.weight(.semibold))

                Spacer(minLength: 4)

                if let evaluationLabel {
                    Text(evaluationLabel)
                        .font(.system(.caption2, design: .monospaced, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.secondary.opacity(0.08), in: Capsule())
                        .accessibilityLabel("Engine evaluation \(evaluationLabel)")
                }
            }

            ViewThatFits(in: .horizontal) {
                moveButtons

                ScrollView(.horizontal) {
                    moveButtons
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(10)
        .background(.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
        .overlay {
            RoundedRectangle(cornerRadius: 9)
                .stroke(.secondary.opacity(0.11), lineWidth: 1)
        }
    }

    private var moveButtons: some View {
        HStack(spacing: 6) {
            ForEach(
                Array(variation.moves.enumerated()),
                id: \.element.id
            ) { index, move in
                Button {
                    onSelectMove(variation, index + 1)
                } label: {
                    Text(move.displayLabel)
                        .font(
                            .system(
                                .caption,
                                design: .monospaced,
                                weight: .semibold
                            )
                        )
                        .padding(.horizontal, 3)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(
                    selectedMoveID == move.id
                        ? .accentColor
                        : .secondary
                )
                .accessibilityLabel("Preview \(move.displayLabel)")
            }
        }
    }

    private var evaluationLabel: String? {
        if let mate = variation.mateForPlayer {
            if mate == 0 {
                return "Mate"
            }
            let leader = mate > 0 ? playerSide : playerSide.opposite
            return "\(leader.displayName) mates in \(abs(mate))"
        }
        guard let centipawns = variation.centipawnsForPlayer else { return nil }
        let points = abs(Double(centipawns) / 100)
        if abs(centipawns) < 5 {
            return "Even"
        }
        let leader = centipawns > 0 ? playerSide : playerSide.opposite
        return "\(leader.displayName) +\(points.formatted(.number.precision(.fractionLength(1))))"
    }
}
