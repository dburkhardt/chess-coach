import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @State private var showingThirdPartyNotices = false
    @AppStorage("coach.inspector.isPresented")
    private var isCoachInspectorPresented = true

    var body: some View {
        HStack(spacing: 0) {
            AppNavigationSidebar(selection: $model.selection)
                .frame(width: AppNavigationSidebarMetrics.idealWidth)
                .background(.bar)
                .accessibilityIdentifier("app-navigation-column")

            Divider()

            NavigationStack {
                content
                    .frame(minWidth: 620)
            }
        }
        .inspector(isPresented: $isCoachInspectorPresented) {
            CoachInspectorContainer(
                coordinator: model.coordinator,
                inferenceSettings: model.inferenceSettings,
                isGameContextVisible: model.selection == .currentGame,
                onConfigureInference: model.openInferenceSettings
            )
            .inspectorColumnWidth(min: 300, ideal: 360, max: 460)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isCoachInspectorPresented.toggle()
                } label: {
                    Label(
                        isCoachInspectorPresented ? "Hide Coach" : "Show Coach",
                        systemImage: "sidebar.right"
                    )
                }
                .help(
                    isCoachInspectorPresented
                        ? "Hide the Coach inspector"
                        : "Show the Coach inspector"
                )
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingThirdPartyNotices = true
                } label: {
                    Label("Third-Party Notices", systemImage: "doc.text")
                }
                .help("View open-source licenses and engine provenance")
            }
        }
        .onChange(of: model.coordinator.teachingMoment != nil) {
            if model.coordinator.teachingMoment != nil {
                isCoachInspectorPresented = true
            }
        }
        .onChange(of: model.coordinator.blunderWarning != nil) {
            if model.coordinator.blunderWarning != nil {
                isCoachInspectorPresented = true
            }
        }
        .sheet(isPresented: Binding(
            get: { !model.persistence.profile.onboardingComplete },
            set: { _ in }
        )) {
            OnboardingView(profile: model.persistence.profile) {
                model.persistence.profile.onboardingComplete = true
                model.persistence.save()
            }
            .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showingThirdPartyNotices) {
            ThirdPartyNoticesView()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.selection {
        case .newGame:
            NewGameView { configuration in
                model.coordinator.newGame(configuration)
                model.selection = .currentGame
            }
        case .currentGame:
            CurrentGameView(
                coordinator: model.coordinator,
                isCoachPresented: isCoachInspectorPresented
            ) {
                isCoachInspectorPresented = true
            }
        case .games:
            GamesView()
        case .progress:
            LearnerProgressView()
        case .settings:
            SettingsView()
        }
    }
}
