import Charts
import SwiftData
import SwiftUI

struct LearnerProgressView: View {
    @Environment(AppModel.self) private var appModel
    @Query private var profiles: [LearnerProfile]

    @State private var confirmingReset = false

    private var profile: LearnerProfile? { profiles.first }

    var body: some View {
        ScrollView {
            if let profile {
                @Bindable var profile = profile
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Progress")
                                .font(.largeTitle.bold())
                            Text(profile.estimateLabel)
                                .font(.title2)
                            Text("A coaching estimate—not a FIDE, Chess.com, or Lichess rating.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Reset Profile", role: .destructive) {
                            confirmingReset = true
                        }
                    }

                    HStack(spacing: 14) {
                        metric("Eligible games", "\(profile.eligibleGames)")
                        metric("Games reviewed", "\(profile.reviewedGames)")
                        metric("Mistake rate", profile.mistakeRate.formatted(.percent.precision(.fractionLength(0))))
                        metric("Blunder rate", profile.blunderRate.formatted(.percent.precision(.fractionLength(0))))
                    }

                    if profile.eligibleGames < 5 {
                        GroupBox("Calibration") {
                            VStack(alignment: .leading, spacing: 8) {
                                ProgressView(
                                    value: Double(profile.eligibleGames),
                                    total: 5
                                )
                                Text("\(5 - profile.eligibleGames) more completed, clocked, unassisted \(profile.eligibleGames == 4 ? "game" : "games") before the estimate is shown.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.top, 4)
                        }
                    } else if ratingPoints(for: profile).count >= 2 {
                        GroupBox("Recent estimate trend") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(profile.recentTrendLabel)
                                    .font(.headline)
                                Chart(ratingPoints(for: profile)) { point in
                                    LineMark(
                                        x: .value("Eligible game", point.game),
                                        y: .value("Estimate center", point.estimate)
                                    )
                                    PointMark(
                                        x: .value("Eligible game", point.game),
                                        y: .value("Estimate center", point.estimate)
                                    )
                                }
                                .frame(height: 150)
                            }
                            .padding(.top, 4)
                        }
                    }

                    GroupBox("Learner profile") {
                        Form {
                            Picker("Experience", selection: $profile.experience) {
                                ForEach(ExperienceLevel.allCases) { level in
                                    Text(level.title).tag(level)
                                }
                            }

                            LabeledContent("Confidence", value: profile.confidence.formatted(.percent.precision(.fractionLength(0))))
                            LabeledContent("Opening", value: profile.openingScore.formatted(.percent.precision(.fractionLength(0))))
                            LabeledContent("Middlegame", value: profile.middlegameScore.formatted(.percent.precision(.fractionLength(0))))
                            LabeledContent("Endgame", value: profile.endgameScore.formatted(.percent.precision(.fractionLength(0))))
                            LabeledContent("Time-pressure errors", value: profile.timePressureRate.formatted(.percent.precision(.fractionLength(0))))
                            LabeledContent("Recurring themes", value: profile.weaknessSummary)
                            LabeledContent("Current strength", value: profile.strengthsSummary)
                        }
                        .formStyle(.grouped)
                        .padding(.top, 4)
                    }

                    GroupBox("Your coaching notes") {
                        TextEditor(text: $profile.userNotes)
                            .font(.body)
                            .frame(minHeight: 130)
                            .scrollContentBackground(.hidden)
                        Text("Correct the coach, record goals, or add context you want included in future explanations.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(24)
                .onChange(of: profile.experience) { _, _ in appModel.persistence.save() }
                .onChange(of: profile.userNotes) { _, _ in appModel.persistence.save() }
                .confirmationDialog(
                    "Reset learned coaching data?",
                    isPresented: $confirmingReset
                ) {
                    Button("Reset Learned Data", role: .destructive) {
                        appModel.persistence.resetProfile()
                    }
                } message: {
                    Text("Your experience selection and completed onboarding will be kept.")
                }
            } else {
                ProgressView()
            }
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(value)
                .font(.title2.bold().monospacedDigit())
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private func ratingPoints(for profile: LearnerProfile) -> [RatingPoint] {
        profile.ratingHistory.enumerated().map {
            RatingPoint(game: $0.offset + 1, estimate: $0.element)
        }
    }
}

private struct RatingPoint: Identifiable {
    let game: Int
    let estimate: Int
    var id: Int { game }
}
