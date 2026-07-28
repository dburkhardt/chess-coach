import SwiftUI

/// Compatibility entry point retained for visual fixtures and downstream views.
struct CoachSidebar: View {
    @Bindable var coordinator: GameCoordinator
    @Bindable var inferenceSettings: InferenceSettings
    var isGameContextVisible = true
    var embedsScrollableTimeline = true
    var initialRoutes: [CoachInspectorRoute] = []
    var onConfigureInference: () -> Void = {}

    var body: some View {
        CoachInspectorContainer(
            coordinator: coordinator,
            inferenceSettings: inferenceSettings,
            isGameContextVisible: isGameContextVisible,
            initialRoutes: initialRoutes,
            onConfigureInference: onConfigureInference
        )
    }
}

struct CoachInspectorContainer: View {
    @Bindable var coordinator: GameCoordinator
    @Bindable var inferenceSettings: InferenceSettings
    var isGameContextVisible = true
    let onConfigureInference: () -> Void

    @State private var routePath: [CoachInspectorRoute] = []
    @State private var question = ""
    @State private var showsSettings = false

    init(
        coordinator: GameCoordinator,
        inferenceSettings: InferenceSettings,
        isGameContextVisible: Bool = true,
        initialRoutes: [CoachInspectorRoute] = [],
        onConfigureInference: @escaping () -> Void = {}
    ) {
        self.coordinator = coordinator
        self.inferenceSettings = inferenceSettings
        self.isGameContextVisible = isGameContextVisible
        self.onConfigureInference = onConfigureInference
        _routePath = State(initialValue: initialRoutes)
    }

    private var projection: CoachThreadProjection {
        CoachThreadProjectionBuilder().build(
            messages: coordinator.coachMessages,
            currentPositionFEN: currentPositionFEN,
            currentPly: currentPly
        )
    }

    private var currentConversationItems: [CoachThreadItem] {
        let items = projection.currentPosition.filter { !$0.isLesson }
        guard let moment = coordinator.teachingMoment else {
            return items
        }
        return items.filter {
            $0.sessionID == moment.id ||
                ($0.sessionID == nil && $0.createdAt >= moment.startedAt)
        }
    }

    private var historyItems: [CoachThreadItem] {
        let currentIDs = Set(currentConversationItems.map(\.id))
        return projection.all.filter {
            !currentIDs.contains($0.id) && !isActiveLesson($0)
        }
    }

    private var inspectorHistoryItems: [CoachThreadItem] {
        coordinator.status.result == .inProgress
            ? historyItems
            : projection.all
    }

    private var snapshot: CoachInspectorSnapshot {
        CoachInspectorSnapshot(
            isCurrentGameVisible: isGameContextVisible,
            hasActiveGame: coordinator.activeGame != nil,
            gameResult: coordinator.status.result,
            isEngineThinking: coordinator.isEngineThinking,
            hasBlunderWarning: coordinator.blunderWarning != nil,
            isHistoryPreviewActive: coordinator.historyPreview != nil,
            preparationState: coordinator.coachPreparationState,
            teachingMoment: coordinator.teachingMoment,
            canTakeBack: coordinator.canTakeBack,
            chatState: coordinator.coachChatState,
            currentPositionTurnCount: currentConversationItems.count,
            earlierItemCount: inspectorHistoryItems.count,
            hasPrincipalVariation: !preparedVariations.isEmpty,
            principalVariationMoveCount:
                preparedVariations.first?.moves.count ?? 0
        )
    }

    private var presentation: CoachInspectorPresentation {
        CoachInspectorPresentationResolver().resolve(snapshot)
    }

    var body: some View {
        VStack(spacing: 0) {
            CoachInspectorHeader(
                presentation: presentation.header,
                historyCount: presentation.earlierItemCount,
                onHistory: showHistory,
                onTakeBack: coordinator.takeBack,
                onSettings: { showsSettings.toggle() }
            )
            .popover(isPresented: $showsSettings, arrowEdge: .top) {
                CoachSettingsPopover()
            }

            Divider()

            if !presentation.commands.isEmpty {
                CoachCommandShelf(
                    commands: presentation.commands,
                    perform: perform
                )
                Divider()
            }

            NavigationStack(path: $routePath) {
                ScrollView {
                    nowWorkspace
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(16)
                }
                .navigationDestination(for: CoachInspectorRoute.self) { route in
                    destination(for: route)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                inspectorFooter
            }
        }
        .background(.background)
        .onChange(of: visibleThreadID) {
            resetLocalState()
        }
        .onChange(of: positionKey) {
            guard coordinator.teachingMoment == nil else { return }
            routePath.removeAll()
        }
        .onChange(of: coordinator.blunderWarning != nil) {
            if coordinator.blunderWarning != nil {
                routePath.removeAll()
            }
        }
        .onChange(of: coordinator.teachingMoment?.id) {
            routePath.removeAll()
        }
        .onChange(of: coordinator.historyPreview?.id) {
            routePath.removeAll()
        }
        .onChange(of: previewVariationRank, initial: true) {
            guard let rank = previewVariationRank else {
                if let index = routePath.lastIndex(where: {
                    if case .variation = $0 { true } else { false }
                }) {
                    routePath.remove(at: index)
                }
                return
            }
            let route = CoachInspectorRoute.variation(rank: rank)
            if !routePath.contains(route) {
                routePath.append(route)
            }
        }
    }

    @ViewBuilder
    private var inspectorFooter: some View {
        let showsNotice =
            isGameContextVisible && !coordinator.errorMessage.isEmpty
        if shouldShowComposer || showsNotice {
            VStack(spacing: 0) {
                Divider()

                if shouldShowComposer {
                    CoachComposer(
                        question: $question,
                        title: composerTitle,
                        placeholder: composerPlaceholder,
                        isWorking: coordinator.isCoachWorking,
                        onSend: send
                    )
                }

                if showsNotice {
                    if shouldShowComposer {
                        Divider()
                    }
                    CoachInspectorNotice(
                        text: coordinator.errorMessage,
                        onDismiss: coordinator.clearError
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    @ViewBuilder
    private var nowWorkspace: some View {
        switch presentation.scene {
        case .neutral:
            CoachEmptyWorkspace(
                title: "No live position",
                systemImage: "rectangle.rightthird.inset.filled",
                detail: "Open Current Game to use position-aware coaching."
            )
        case .empty:
            CoachEmptyWorkspace(
                title: "Ready when you are",
                systemImage: "checkerboard.rectangle",
                detail: "Start a game to ask for grounded coaching."
            )
        case .live:
            LiveCoachWorkspace(
                chatState: coordinator.coachChatState,
                currentConversationCount: currentConversationItems.count,
                onConversation: {
                    routePath.append(.conversation(.currentPosition))
                },
                onConfigureInference: onConfigureInference
            )
        case .reviewing:
            HistoryReviewWorkspace()
        case .warning:
            BlunderGuardWorkspace(
                warning: coordinator.blunderWarning,
                explanation: latestWarningExplanation,
                isWorking: coordinator.isCoachWorking,
                playerSide: coordinator.playerSide
            )
        case .lesson:
            TeachingWorkspace(
                moment: coordinator.teachingMoment,
                variations: preparedVariations,
                playerSide: coordinator.playerSide,
                questionCount: currentConversationItems.count,
                onConversation: showLessonConversation,
                onExploreVariation: exploreVariation
            )
        case .completed:
            CoachCompletedWorkspace(
                itemCount: projection.all.count,
                onHistory: showHistory
            )
        }
    }

    @ViewBuilder
    private func destination(for route: CoachInspectorRoute) -> some View {
        switch route {
        case .conversation(let scope):
            CoachConversationView(
                items: conversationItems(for: scope),
                playerSide: coordinator.playerSide,
                isWorking: coordinator.isCoachWorking,
                backLabel: conversationBackLabel(for: scope),
                onBack: popRoute
            )
        case .history:
            CoachHistoryView(
                items: inspectorHistoryItems,
                playerSide: coordinator.playerSide,
                onBack: popRoute
            )
        case .variation(let rank):
            EngineLineWorkspace(
                variation: preparedVariations.first(where: {
                    $0.rank == rank
                }),
                selectedStep: selectedPreviewStep,
                playerSide: coordinator.playerSide,
                onSelectStep: { step in
                    coordinator.setTeachingPreview(
                        variationRank: rank,
                        step: step
                    )
                }
            )
            .onExitCommand {
                coordinator.returnFromTeachingPreview()
                popRoute()
            }
            .onKeyPress(.leftArrow) {
                coordinator.stepTeachingPreview(by: -1)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                coordinator.stepTeachingPreview(by: 1)
                return .handled
            }
        }
    }

    private func perform(_ action: CoachCommandAction) {
        switch action {
        case .openHint:
            coordinator.requestHint()
        case .retryAnalysis:
            coordinator.retryCoachPreparation()
        case .revealMove:
            coordinator.revealHint()
        case .exploreEngineLine(let rank):
            exploreVariation(rank)
        case .previewPrevious:
            coordinator.stepTeachingPreview(by: -1)
        case .previewNext:
            coordinator.stepTeachingPreview(by: 1)
        case .returnToPosition:
            coordinator.returnFromTeachingPreview()
            if case .variation = routePath.last {
                popRoute()
            }
        case .continuePlaying:
            coordinator.continueTeachingMoment()
            routePath.removeAll()
        case .takeBack:
            coordinator.takeBack()
        case .playOn:
            coordinator.playOnAfterWarning()
        case .askCoach:
            coordinator.askCoachAboutWarning()
        }
    }

    private func exploreVariation(_ rank: Int) {
        coordinator.setTeachingPreview(variationRank: rank, step: 0)
        if routePath.last != .variation(rank: rank) {
            routePath.append(.variation(rank: rank))
        }
    }

    private func send() {
        let value = question.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !value.isEmpty, !coordinator.isCoachWorking else { return }
        question = ""

        if !routePath.contains(where: {
            if case .conversation = $0 { true } else { false }
        }) {
            routePath.append(.conversation(conversationScope))
        }
        coordinator.sendChat(value)
    }

    private var shouldShowComposer: Bool {
        guard presentation.showsComposer,
              routePath.last != .history
        else {
            return false
        }
        return true
    }

    private var conversationScope: CoachConversationScope {
        if let moment = coordinator.teachingMoment {
            return .lesson(sessionID: moment.id)
        }
        return .currentPosition
    }

    private var composerTitle: String {
        if case .variation = routePath.last {
            return "Ask about this line"
        }
        if coordinator.teachingMoment != nil {
            return "Ask about this lesson"
        }
        return "Ask about this position"
    }

    private var composerPlaceholder: String {
        if case .variation = routePath.last {
            return "Why does this continuation work?"
        }
        if coordinator.teachingMoment != nil {
            return "What should I learn from this?"
        }
        return "What should I notice here?"
    }

    private func showLessonConversation() {
        guard let moment = coordinator.teachingMoment else { return }
        routePath.append(.conversation(.lesson(sessionID: moment.id)))
    }

    private func showHistory() {
        if routePath.last != .history {
            routePath.append(.history)
        }
    }

    private func conversationItems(
        for scope: CoachConversationScope
    ) -> [CoachThreadItem] {
        switch scope {
        case .currentPosition:
            return currentConversationItems
        case .lesson(let sessionID):
            return projection.currentPosition.filter {
                !$0.isLesson && $0.sessionID == sessionID
            }
        case .warning:
            guard let warningID = coordinator.blunderWarning?.id else {
                return []
            }
            return projection.currentPosition.filter {
                $0.sessionID == warningID
            }
        }
    }

    private func conversationBackLabel(
        for scope: CoachConversationScope
    ) -> String {
        switch scope {
        case .currentPosition:
            "Back to Position"
        case .lesson:
            "Back to Lesson"
        case .warning:
            "Back to Warning"
        }
    }

    private func isActiveLesson(_ item: CoachThreadItem) -> Bool {
        guard item.isLesson,
              let moment = coordinator.teachingMoment
        else {
            return false
        }
        if item.sessionID == moment.id {
            return true
        }
        return item.sessionID == nil &&
            item.createdAt >= moment.startedAt &&
            item.positionFEN == moment.anchor.fen &&
            item.ply == moment.anchor.ply
    }

    private func popRoute() {
        guard !routePath.isEmpty else { return }
        routePath.removeLast()
    }

    private func resetLocalState() {
        question = ""
        routePath.removeAll()
    }

    private var currentPositionFEN: String {
        coordinator.teachingMoment?.anchor.fen ?? coordinator.state.fen
    }

    private var currentPly: Int {
        coordinator.teachingMoment?.anchor.ply ?? coordinator.state.plyCount
    }

    private var preparedVariations: [CoachVariationPresentation] {
        guard case .ready(let prepared) = coordinator.coachPreparationState
        else {
            return []
        }
        if let moment = coordinator.teachingMoment,
           prepared.anchor != moment.anchor {
            return []
        }
        return CoachVariationPresentationBuilder().build(
            from: prepared.context
        )
    }

    private var selectedPreviewStep: Int {
        guard let moment = coordinator.teachingMoment,
              case .previewing(_, _, let step) = moment.phase
        else {
            return 0
        }
        return step
    }

    private var previewVariationRank: Int? {
        guard let moment = coordinator.teachingMoment,
              case .previewing(_, let rank, _) = moment.phase
        else {
            return nil
        }
        return rank
    }

    private var latestWarningExplanation: CoachMessage? {
        guard let warningID = coordinator.blunderWarning?.id else {
            return nil
        }
        return projection.currentPosition.reversed().compactMap {
            item -> CoachMessage? in
            guard item.sessionID == warningID else { return nil }
            switch item {
            case .warning(let message):
                return message
            case .turn(let turn):
                return turn.answer
            case .legacy(let message) where message.role == .coach:
                return message
            case .lesson, .pending, .legacy:
                return nil
            }
        }.first
    }

    private var visibleThreadID: String {
        guard isGameContextVisible else { return "inactive" }
        return coordinator.activeGame?.id.uuidString ?? "no-game"
    }

    private var positionKey: String {
        "\(visibleThreadID)|\(currentPly)|\(currentPositionFEN)"
    }
}

private extension CoachThreadItem {
    var isLesson: Bool {
        if case .lesson = self { true } else { false }
    }

    var sessionID: UUID? {
        switch self {
        case .lesson(let message),
             .warning(let message),
             .legacy(let message):
            message.sessionID
        case .turn(let turn), .pending(let turn):
            turn.sessionID
        }
    }

    var createdAt: Date {
        switch self {
        case .lesson(let message),
             .warning(let message),
             .legacy(let message):
            message.createdAt
        case .turn(let turn), .pending(let turn):
            turn.question.createdAt
        }
    }
}

struct CoachSettingsPopover: View {
    @AppStorage(ChessBoardPreferences.moveMethodKey)
    private var moveMethod =
        ChessBoardPreferences.MoveMethod.clickAndDrag.rawValue
    @AppStorage(ChessBoardPreferences.showLegalMarkersKey)
    private var showLegalMarkers = true
    @AppStorage(ChessBoardPreferences.showCoordinatesKey)
    private var showCoordinates = true
    @AppStorage(ChessBoardPreferences.animationsEnabledKey)
    private var animationsEnabled = true
    @AppStorage(ChessBoardPreferences.pieceStyleKey)
    private var pieceStyle = ChessBoardPreferences.PieceStyle.merida.rawValue
    @AppStorage("coaching.defaultBlunderGuard")
    private var defaultBlunderGuard = false

    var body: some View {
        Form {
            Section("Board") {
                Picker("Move method", selection: $moveMethod) {
                    Text("Click and drag")
                        .tag(
                            ChessBoardPreferences.MoveMethod
                                .clickAndDrag.rawValue
                        )
                    Text("Click only")
                        .tag(
                            ChessBoardPreferences.MoveMethod.clickOnly.rawValue
                        )
                    Text("Drag only")
                        .tag(
                            ChessBoardPreferences.MoveMethod.dragOnly.rawValue
                        )
                }

                Toggle("Legal move markers", isOn: $showLegalMarkers)
                Toggle("Coordinates", isOn: $showCoordinates)
                Toggle("Animations", isOn: $animationsEnabled)

                Picker("Piece style", selection: $pieceStyle) {
                    Text("Sashité Merida")
                        .tag(
                            ChessBoardPreferences.PieceStyle.merida.rawValue
                        )
                    Text("Chessnut")
                        .tag(
                            ChessBoardPreferences.PieceStyle.chessnut.rawValue
                        )
                }
            }

            Section("Coaching") {
                Toggle(
                    "Blunder Guard for new games",
                    isOn: $defaultBlunderGuard
                )
            }
        }
        .formStyle(.grouped)
        .frame(width: 350)
        .padding(.vertical, 8)
        .accessibilityLabel("Coach and board settings")
    }
}
