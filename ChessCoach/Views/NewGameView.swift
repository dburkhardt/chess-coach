import SwiftUI

struct NewGameView: View {
    @State private var configuration = NewGameConfiguration()
    @AppStorage("coaching.defaultBlunderGuard")
    private var defaultBlunderGuard = false
    var start: (NewGameConfiguration) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("New Training Game")
                        .font(.largeTitle.bold())
                    Text("Choose a comfortable challenge. Difficulty levels change Stockfish play, not the quality of your coach.")
                        .foregroundStyle(.secondary)
                }

                GroupBox("Your side") {
                    Picker("Your side", selection: $configuration.colorChoice) {
                        ForEach(PlayerColorChoice.allCases) { choice in
                            Text(choice.displayName).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.vertical, 6)
                }

                GroupBox("Stockfish difficulty") {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Level \(configuration.difficulty)")
                                .font(.title2.bold())
                            Spacer()
                            Text(difficultyDescription)
                                .foregroundStyle(.secondary)
                        }
                        Slider(
                            value: Binding(
                                get: { Double(configuration.difficulty) },
                                set: { configuration.difficulty = Int($0.rounded()) }
                            ),
                            in: 1...10,
                            step: 1
                        )
                        HStack {
                            Text("Gentle")
                            Spacer()
                            Text("Maximum")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }

                GroupBox("Clock") {
                    Picker("Time control", selection: $configuration.timeControl) {
                        ForEach(TimeControl.allCases) { control in
                            Text(control.title).tag(control)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.vertical, 6)
                }

                GroupBox {
                    Toggle(isOn: $configuration.blunderGuardEnabled) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Blunder Guard")
                                .font(.headline)
                            Text("Pause before Stockfish replies when a move severely changes the game. Change the default from Coach settings.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                    .padding(.vertical, 6)
                }

                Button {
                    start(configuration)
                } label: {
                    Label("Start Game", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(36)
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            configuration.blunderGuardEnabled = defaultBlunderGuard
        }
        .onChange(of: defaultBlunderGuard) { _, value in
            configuration.blunderGuardEnabled = value
        }
    }

    private var difficultyDescription: String {
        switch configuration.difficulty {
        case 1...2: "Learning pace"
        case 3...4: "Casual"
        case 5...6: "Challenging"
        case 7...8: "Strong"
        default: "Engine strength"
        }
    }
}
