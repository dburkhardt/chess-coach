import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.controlActiveState)
    private var inheritedControlActiveState
    @Environment(\.dynamicTypeSize)
    private var inheritedDynamicTypeSize
    @State private var showingThirdPartyNotices = false
    @SceneStorage(ChessCoachWindowLayout.sidebarVisibilitySceneKey)
    private var navigationSidebarVisibilityRaw =
        AppNavigationSidebarVisibility.expanded.rawValue
    @AppStorage(ChessCoachWindowLayout.sidebarVisibilityLaunchOverrideKey)
    private var navigationSidebarVisibilityLaunchOverride = ""
    @AppStorage("coach.inspector.isPresented")
    private var isCoachInspectorPresented = true
    @AppStorage(
        ReleaseVisualQAViewOverrides.inactiveNavigationSelectionKey
    )
    private var visualQAUsesInactiveNavigationSelection = false
    @AppStorage(ReleaseVisualQAViewOverrides.largeTextKey)
    private var visualQAUsesLargeText = false
    @AppStorage(ReleaseVisualQAViewOverrides.navigationWidthKey)
    private var visualQANavigationWidth = 0.0
    @AppStorage(ReleaseVisualQAViewOverrides.inspectorWidthKey)
    private var visualQAInspectorWidth = 0.0

    var body: some View {
        NavigationSplitView(
            columnVisibility: navigationColumnVisibility
        ) {
            AppNavigationSidebar(selection: $model.selection)
                .environment(
                    \.controlActiveState,
                    visualQAUsesInactiveNavigationSelection
                        ? .inactive
                        : inheritedControlActiveState
                )
                .navigationSplitViewColumnWidth(
                    min: navigationWidths.minimum,
                    ideal: navigationWidths.ideal,
                    max: navigationWidths.maximum
                )
                .accessibilityIdentifier("app-navigation-column")
                .releaseVisualQAProbe(
                    ReleaseVisualQALayoutValidator.navigation
                )
        } detail: {
            NavigationStack {
                content
                    .frame(minWidth: 620)
            }
            .accessibilityIdentifier("app-game-detail-column")
            .releaseVisualQAProbe(
                ReleaseVisualQALayoutValidator.gameDetail
            )
            .background {
                Color(nsColor: .windowBackgroundColor)
                    .backgroundExtensionEffect()
            }
        }
        .navigationSplitViewStyle(.balanced)
        .onAppear {
            applyNavigationSidebarLaunchOverride()
        }
        .inspector(isPresented: $isCoachInspectorPresented) {
            CoachInspectorContainer(
                coordinator: model.coordinator,
                inferenceSettings: model.inferenceSettings,
                isGameContextVisible: model.selection == .currentGame,
                onConfigureInference: { issue in
                    model.openInferenceSettings(
                        focusTarget: issue.settingsFocusTarget
                    )
                }
            )
            .inspectorColumnWidth(
                min: inspectorWidths.minimum,
                ideal: inspectorWidths.ideal,
                max: inspectorWidths.maximum
            )
            .accessibilityIdentifier(
                CoachInspectorMetrics.accessibilityIdentifier
            )
            .releaseVisualQAProbe(
                ReleaseVisualQALayoutValidator.coachInspector
            )
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
        .environment(
            \.dynamicTypeSize,
            visualQAUsesLargeText
                ? .accessibility1
                : inheritedDynamicTypeSize
        )
    }

    private var navigationWidths: AppColumnWidthRange {
        AppNavigationSidebarMetrics.widths(
            visualQAOverride: ReleaseVisualQAConfiguration.isRequested
                ? visualQANavigationWidth
                : 0
        )
    }

    private var inspectorWidths: AppColumnWidthRange {
        CoachInspectorMetrics.widths(
            visualQAOverride: ReleaseVisualQAConfiguration.isRequested
                ? visualQAInspectorWidth
                : 0
        )
    }

    private var navigationColumnVisibility:
        Binding<NavigationSplitViewVisibility> {
        Binding(
            get: {
                AppNavigationSidebarVisibility(
                    rawValue: navigationSidebarVisibilityRaw
                )?.splitViewVisibility ?? .all
            },
            set: { visibility in
                navigationSidebarVisibilityRaw =
                    AppNavigationSidebarVisibility(visibility).rawValue
            }
        )
    }

    private func applyNavigationSidebarLaunchOverride() {
        guard let visibility = AppNavigationSidebarVisibility(
            rawValue: navigationSidebarVisibilityLaunchOverride
        ) else {
            return
        }
        navigationSidebarVisibilityRaw = visibility.rawValue
        navigationSidebarVisibilityLaunchOverride = ""
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
