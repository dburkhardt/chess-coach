import SwiftData
import SwiftUI

@main
struct ChessCoachApp: App {
    @State private var model = AppModel()
    @AppStorage("coach.inspector.isPresented")
    private var isCoachInspectorPresented = true

    var body: some Scene {
        WindowGroup("Chess Coach") {
            RootView(model: model)
                .environment(model)
                .modelContainer(model.persistence.container)
                .frame(minWidth: 1_180, minHeight: 760)
        }
        .defaultSize(width: 1_420, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Game") {
                    model.selection = .newGame
                }
                .keyboardShortcut("n")
            }

            CommandGroup(after: .sidebar) {
                Button(
                    isCoachInspectorPresented
                        ? "Hide Coach"
                        : "Show Coach"
                ) {
                    isCoachInspectorPresented.toggle()
                }
                .keyboardShortcut("k", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 620, height: 540)
        }
    }
}
