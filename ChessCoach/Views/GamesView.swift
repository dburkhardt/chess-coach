import Charts
import SwiftData
import SwiftUI

struct GamesView: View {
    @Environment(AppModel.self) private var appModel
    @Query(sort: \SavedGame.startedAt, order: .reverse) private var games: [SavedGame]

    @State private var selectedGame: SavedGame?

    var body: some View {
        NavigationSplitView {
            List(games, selection: $selectedGame) { game in
                VStack(alignment: .leading, spacing: 4) {
                    Text(game.title)
                        .font(.headline)
                    Text(game.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(game.resultLabel)
                        .font(.caption)
                }
                .tag(game)
            }
            .navigationTitle("Games")
            .overlay {
                if games.isEmpty {
                    ContentUnavailableView(
                        "No saved games",
                        systemImage: "books.vertical",
                        description: Text("Games are saved automatically as you play.")
                    )
                }
            }
        } detail: {
            if let selectedGame {
                GameReviewView(game: selectedGame)
            } else {
                ContentUnavailableView("Select a game", systemImage: "checkerboard.rectangle")
            }
        }
        .onAppear {
            if selectedGame == nil {
                selectedGame = games.first
            }
        }
    }
}

private struct GameReviewView: View {
    @Environment(AppModel.self) private var appModel
    let game: SavedGame

    @State private var exportError: String?
    @State private var confirmingDelete = false

    private var chartPoints: [ReviewPoint] {
        game.sortedPlies.compactMap { ply in
            guard let score = ply.expectedScoreAfter else { return nil }
            return ReviewPoint(ply: ply.index + 1, expected: score)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading) {
                        Text(game.title)
                            .font(.largeTitle.bold())
                        Text(game.startedAt.formatted(date: .long, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(game.resultLabel)
                        .font(.title2.monospacedDigit())
                }

                if chartPoints.isEmpty {
                    ContentUnavailableView(
                        game.reviewCompleted ? "No evaluation data" : "Review pending",
                        systemImage: "chart.xyaxis.line",
                        description: Text("Full-strength analysis runs after the game ends.")
                    )
                    .frame(height: 220)
                } else {
                    GroupBox("Your expected score") {
                        Chart(chartPoints) { point in
                            LineMark(
                                x: .value("Ply", point.ply),
                                y: .value("Expected score", point.expected)
                            )
                            .interpolationMethod(.catmullRom)
                            RuleMark(y: .value("Equal", 0.5))
                                .foregroundStyle(.secondary.opacity(0.5))
                        }
                        .chartYScale(domain: 0...1)
                        .frame(height: 220)
                        .padding(.top, 8)
                    }
                }

                if !game.reviewSummary.isEmpty {
                    GroupBox("Review") {
                        Text(game.reviewSummary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                GroupBox("Moves") {
                    LazyVGrid(columns: [
                        GridItem(.fixed(42), alignment: .trailing),
                        GridItem(.flexible(), alignment: .leading),
                        GridItem(.flexible(), alignment: .leading)
                    ], alignment: .leading, spacing: 8) {
                        ForEach(fullMoves, id: \.number) { row in
                            Text("\(row.number).")
                                .foregroundStyle(.secondary)
                            moveCell(row.white)
                            moveCell(row.black)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 6)
                }

                HStack {
                    Button("Export PGN", systemImage: "square.and.arrow.up") {
                        exportPGN()
                    }
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        confirmingDelete = true
                    }
                    Spacer()
                    if game.result == .inProgress {
                        Button("Resume") {
                            appModel.resume(game: game)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }

                if let exportError {
                    Text(exportError)
                        .foregroundStyle(.red)
                }
            }
            .padding(24)
        }
        .confirmationDialog(
            "Delete this game?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Game", role: .destructive) {
                appModel.persistence.delete(game)
            }
        }
    }

    @ViewBuilder
    private func moveCell(_ ply: SavedPly?) -> some View {
        if let ply {
            VStack(alignment: .leading, spacing: 2) {
                Text(ply.san)
                if let classification = ply.classification {
                    Text(classification.rawValue.capitalized)
                        .font(.caption2)
                        .foregroundStyle(classificationColor(classification.rawValue))
                }
            }
        } else {
            Text("")
        }
    }

    private var fullMoves: [MoveRow] {
        let plies = game.sortedPlies
        return stride(from: 0, to: plies.count, by: 2).map { index in
            return MoveRow(
                number: index / 2 + 1,
                white: plies[safe: index],
                black: plies[safe: index + 1]
            )
        }
    }

    private func classificationColor(_ classification: String) -> Color {
        switch classification {
        case MoveClassification.blunder.rawValue: return .red
        case MoveClassification.mistake.rawValue: return .orange
        case MoveClassification.inaccuracy.rawValue: return .yellow
        default: return .secondary
        }
    }

    private func exportPGN() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.text]
        panel.nameFieldStringValue = "Chess-Coach-\(game.startedAt.formatted(.iso8601.year().month().day())).pgn"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try game.pgn.write(to: url, atomically: true, encoding: .utf8)
            exportError = nil
        } catch {
            exportError = "Could not export PGN: \(error.localizedDescription)"
        }
    }
}

private struct ReviewPoint: Identifiable {
    let ply: Int
    let expected: Double
    var id: Int { ply }
}

private struct MoveRow {
    let number: Int
    let white: SavedPly?
    let black: SavedPly?
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
