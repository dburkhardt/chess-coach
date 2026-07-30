import AppKit
import SwiftData
import SwiftUI

@main
struct ChessCoachApp: App {
    @State private var model: AppModel
    private let visualQAConfiguration: ReleaseVisualQAConfiguration?
    private let launchMode: ReleaseLaunchMode
    private let appDefaults: UserDefaults
    @AppStorage("coach.inspector.isPresented")
    private var isCoachInspectorPresented = true

    init() {
        InstalledCredentialRuntimeProbe.runIfRequested()

        let launchMode = ReleaseLaunchMode.current
        if launchMode == .testHost {
            // XCTest uses the app executable as a host. It may construct an
            // empty scene, but it must never activate or focus application
            // windows on the developer's desktop.
            _ = NSApplication.shared.setActivationPolicy(.prohibited)
        }
        ReleaseLaunchMode.enforceCandidateLaunchPolicy(launchMode)
        self.launchMode = launchMode

        let visualQAConfiguration = ReleaseVisualQAConfiguration.current
        self.visualQAConfiguration = visualQAConfiguration

        let candidateIdentity: ReleaseCandidateIdentity? = {
            guard case .candidatePreview(let identity) = launchMode else {
                return nil
            }
            return identity
        }()
        let appDefaults = visualQAConfiguration?.appDefaults ??
            candidateIdentity.map(Self.makeCandidatePreviewDefaults) ??
            UserDefaults.standard
        self.appDefaults = appDefaults
        ChessCoachWindowLayout.prepareForLaunch(defaults: appDefaults)
        _isCoachInspectorPresented = AppStorage(
            wrappedValue: true,
            "coach.inspector.isPresented",
            store: appDefaults
        )

        let inferenceDefaults = visualQAConfiguration?.makeInferenceDefaults() ??
            candidateIdentity.map(Self.makeCandidatePreviewInferenceDefaults) ??
            .standard
        let credentialStore: (any KeychainStoring)? =
            visualQAConfiguration?.makeCredentialStore() ??
            (candidateIdentity == nil
                ? nil
                : CandidatePreviewCredentialStore())
        let model = AppModel(
            inMemory: visualQAConfiguration != nil || candidateIdentity != nil,
            inferenceDefaults: inferenceDefaults,
            credentialStore: credentialStore
        )
        if visualQAConfiguration != nil || candidateIdentity != nil {
            model.persistence.profile.onboardingComplete = true
            model.persistence.save()
            model.selection = .currentGame
        }
        if candidateIdentity != nil {
            model.coordinator.newGame(
                NewGameConfiguration(
                    colorChoice: .white,
                    difficulty: 3,
                    timeControl: .none,
                    blunderGuardEnabled: false
                )
            )
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
        if launchMode == .testHost {
            EmptyView()
                .onAppear {
                    for window in NSApplication.shared.windows {
                        window.orderOut(nil)
                    }
                }
        } else {
            applicationRootContent
        }
    }

    @ViewBuilder
    private var applicationRootContent: some View {
        let root = Group {
            if case .candidatePreview(let identity) = launchMode {
                VStack(spacing: 0) {
                    ReleaseCandidatePreviewBanner(identity: identity)
                    RootView(model: model)
                }
            } else {
                RootView(model: model)
            }
        }
            .environment(model)
            .modelContainer(model.persistence.container)
            .defaultAppStorage(appDefaults)
            .frame(minWidth: 980, minHeight: 760)

        if let visualQAConfiguration {
            if visualQAConfiguration.scenarios.count == 1 {
                root
                    .preferredColorScheme(
                        visualQAConfiguration.scenario.colorScheme
                    )
                    .onAppear {
                        ReleaseVisualQARunner.shippingRootDidAppear()
                    }
            } else {
                // The one-process release harness changes the real AppKit
                // window appearance before each scenario. Pinning SwiftUI to
                // the first scenario here would make later light/dark
                // captures dishonest.
                root
                    .onAppear {
                        ReleaseVisualQARunner.shippingRootDidAppear()
                    }
            }
        } else {
            root
        }
    }

    @MainActor
    private static func makeCandidatePreviewDefaults(
        identity: ReleaseCandidateIdentity
    ) -> UserDefaults {
        let suiteName =
            "com.dburkhardt.chesscoach.candidate-preview.\(identity.commit)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            ReleaseLaunchMode.failCandidatePreviewIsolation()
        }
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "coach.inspector.isPresented")
        defaults.set("Merida", forKey: "chessboard.pieceStyle")
        defaults.set(true, forKey: "chessboard.showCoordinates")
        defaults.set(true, forKey: "chessboard.showLegalMoves")
        defaults.set(
            AppNavigationSidebarVisibility.expanded.rawValue,
            forKey: ChessCoachWindowLayout
                .sidebarVisibilityLaunchOverrideKey
        )
        return defaults
    }

    @MainActor
    private static func makeCandidatePreviewInferenceDefaults(
        identity: ReleaseCandidateIdentity
    ) -> UserDefaults {
        let suiteName =
            "com.dburkhardt.chesscoach.candidate-preview.inference." +
            identity.commit
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            ReleaseLaunchMode.failCandidatePreviewIsolation()
        }
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(
            InferenceProviderKind.customOpenAICompatible.rawValue,
            forKey: "ai.provider"
        )
        defaults.set("http://127.0.0.1:9", forKey: "ai.customEndpoint")
        defaults.set("candidate-preview", forKey: "ai.modelID")
        return defaults
    }
}
