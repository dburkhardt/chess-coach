import SwiftData
import SwiftUI

@main
struct ChessCoachApp: App {
    @State private var model: AppModel
    private let visualQAConfiguration: ReleaseVisualQAConfiguration?
    private let appDefaults: UserDefaults
    @AppStorage("coach.inspector.isPresented")
    private var isCoachInspectorPresented = true

    init() {
        InstalledCredentialRuntimeProbe.runIfRequested()

        let visualQAConfiguration = ReleaseVisualQAConfiguration.current
        self.visualQAConfiguration = visualQAConfiguration

        let appDefaults =
            visualQAConfiguration?.appDefaults ?? UserDefaults.standard
        self.appDefaults = appDefaults
        ChessCoachWindowLayout.prepareForLaunch(defaults: appDefaults)
        _isCoachInspectorPresented = AppStorage(
            wrappedValue: true,
            "coach.inspector.isPresented",
            store: appDefaults
        )

        let model = AppModel(
            inMemory: visualQAConfiguration != nil,
            inferenceDefaults:
                visualQAConfiguration?.makeInferenceDefaults() ?? .standard,
            credentialStore: visualQAConfiguration?.makeCredentialStore()
        )
        if visualQAConfiguration != nil {
            model.persistence.profile.onboardingComplete = true
            model.persistence.save()
            model.selection = .currentGame
        }
        _model = State(initialValue: model)

        if let visualQAConfiguration {
            ReleaseVisualQARunner.configure(
                configuration: visualQAConfiguration,
                model: model,
                defaults: appDefaults
            )
        }
    }

    var body: some Scene {
        let _ = visualQAConfiguration.map { _ in
            ReleaseVisualQARunner.noteSceneConstruction()
        }

        WindowGroup("Chess Coach") {
            rootContent
        }
        .defaultSize(
            width: visualQAConfiguration?.scenario.windowSize.width ?? 1_420,
            height: visualQAConfiguration?.scenario.windowSize.height ?? 900
        )
        .commands {
            SidebarCommands()

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

            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    model.selection = .settings
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }

    @ViewBuilder
    private var rootContent: some View {
        let root = RootView(model: model)
            .environment(model)
            .modelContainer(model.persistence.container)
            .defaultAppStorage(appDefaults)
            .frame(minWidth: 980, minHeight: 760)

        if let visualQAConfiguration {
            root
                .preferredColorScheme(
                    visualQAConfiguration.scenario.colorScheme
                )
                .onAppear {
                    ReleaseVisualQARunner.shippingRootDidAppear()
                }
        } else {
            root
        }
    }
}
