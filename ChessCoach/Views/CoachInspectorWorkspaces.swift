import SwiftUI

struct CoachInspectorHeader: View {
    let presentation: CoachHeaderPresentation
    let historyCount: Int
    let onHistory: () -> Void
    let onTakeBack: () -> Void
    let onTrailingAction: (CoachHeaderAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "circle.hexagongrid.fill")
                    .foregroundStyle(Color.coachGreen)
                    .frame(width: 28, height: 28)
                    .background(
                        Color.coachGreen.opacity(0.11),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                    .accessibilityHidden(true)

                Text(presentation.title)
                    .font(.headline)
                    .lineLimit(1)
                    .layoutPriority(1)

                Spacer(minLength: 0)

                if presentation.showsHistory {
                    Button(action: onHistory) {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.plain)
                    .help("Earlier coaching (\(historyCount))")
                    .accessibilityLabel(
                        "Earlier coaching, \(historyCount) items"
                    )
                    .fixedSize()
                }

                if presentation.showsTakeBack {
                    Button(action: onTakeBack) {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.plain)
                    .help("Take Back")
                    .accessibilityLabel("Take Back")
                    .fixedSize()
                }

                if let action = presentation.trailingAction {
                    Button {
                        onTrailingAction(action.action)
                    } label: {
                        if let systemImage = action.systemImage {
                            Label(action.label, systemImage: systemImage)
                        } else {
                            Text(action.label)
                        }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(
                        action.style == .resume
                            ? Color.coachGreen
                            : Color.secondary
                    )
                    .font(.subheadline.weight(.semibold))
                    .help(
                        action.style == .resume
                            ? "Resume the game clock"
                            : "Close the teaching moment"
                    )
                    .accessibilityIdentifier("coach-lesson-dismiss")
                    .fixedSize()
                }
            }

            if let status = presentation.status {
                Label(status, systemImage: statusSymbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
                    .lineLimit(2)
                    .padding(.leading, 38)
                    .accessibilityAddTraits(.isHeader)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: 50)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Coach header")
    }

    private var statusSymbol: String {
        switch presentation.style {
        case .progress: "ellipsis.circle.fill"
        case .ready: "checkmark.circle.fill"
        case .teaching: "pause.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .unavailable: "exclamationmark.circle"
        case .completed: "checkmark.seal.fill"
        case .neutral: "circle.fill"
        }
    }

    private var statusColor: Color {
        switch presentation.style {
        case .ready, .teaching: .coachGreen
        case .warning: .orange
        case .progress: .blue
        case .unavailable: .secondary
        case .completed, .neutral: .secondary
        }
    }
}

struct CoachCommandShelf: View {
    let commands: [CoachCommandPresentation]
    let perform: (CoachCommandAction) -> Void

    var body: some View {
        VStack(spacing: 8) {
            if let primary = commands.first(where: { $0.style == .primary }) {
                commandButton(primary, fillsWidth: true)
            }

            let secondary = commands.filter { $0.style != .primary }
            if !secondary.isEmpty {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 7) {
                        ForEach(secondary) {
                            commandButton($0, fillsWidth: false)
                        }
                    }
                    .frame(maxWidth: .infinity)

                    VStack(spacing: 7) {
                        ForEach(secondary) {
                            commandButton($0, fillsWidth: true)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Coach actions")
    }

    @ViewBuilder
    private func commandButton(
        _ command: CoachCommandPresentation,
        fillsWidth: Bool
    ) -> some View {
        if command.style == .primary {
            commandButtonBody(command, fillsWidth: fillsWidth)
                .buttonStyle(.borderedProminent)
        } else {
            commandButtonBody(command, fillsWidth: fillsWidth)
                .buttonStyle(.bordered)
        }
    }

    private func commandButtonBody(
        _ command: CoachCommandPresentation,
        fillsWidth: Bool
    ) -> some View {
        Button {
            perform(command.action)
        } label: {
            if let image = command.systemImage {
                Label(command.label, systemImage: image)
                    .frame(maxWidth: fillsWidth ? .infinity : nil)
            } else {
                Text(command.label)
                    .frame(maxWidth: fillsWidth ? .infinity : nil)
            }
        }
        .tint(tint(for: command))
        .controlSize(.regular)
        .disabled(!command.isEnabled)
    }

    private func tint(
        for command: CoachCommandPresentation
    ) -> Color {
        switch command.action {
        case .takeBack, .playOn, .askCoach:
            .orange
        case .openHint, .revealMove, .exploreEngineLine,
             .previewPrevious, .previewNext, .returnToPosition:
            .blue
        case .continuePlaying:
            .coachGreen
        case .retryAnalysis:
            .accentColor
        }
    }
}

struct CoachEmptyWorkspace: View {
    let title: String
    let systemImage: String
    let detail: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(detail)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }
}

struct LiveCoachWorkspace: View {
    let currentConversationCount: Int
    let onConversation: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if currentConversationCount > 0 {
                CoachNavigationRow(
                    title: "Conversation",
                    count: currentConversationCount,
                    systemImage: "bubble.left.and.bubble.right",
                    action: onConversation
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live coaching")
    }
}

struct CoachProviderSetupFooter: View {
    let issue: InferenceConfigurationIssue
    let onConfigure: (InferenceConfigurationIssue) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalContent

            VStack(alignment: .leading, spacing: 5) {
                providerStatus
                setupButton
            }
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            CoachProviderSetupFooterContent.accessibilityLabel
        )
        .accessibilityIdentifier("coach-provider-setup")
        .releaseVisualQAProbe(
            ReleaseVisualQALayoutValidator.providerFooter
        )
    }

    private var horizontalContent: some View {
        HStack(alignment: .center, spacing: 8) {
            providerStatus
                .fixedSize(horizontal: true, vertical: true)
            setupButton
                .fixedSize(horizontal: true, vertical: true)
        }
        // Preserve the children's true intrinsic width. This lets
        // `ViewThatFits` select the vertical layout instead of accepting a
        // compressed HStack whose trailing button is clipped.
        .fixedSize(horizontal: true, vertical: true)
    }

    private var providerStatus: some View {
        Label(
            CoachProviderSetupFooterContent.status,
            systemImage: "exclamationmark.circle"
        )
        .foregroundStyle(.secondary)
    }

    private var setupButton: some View {
        Button(CoachProviderSetupFooterContent.action) {
            onConfigure(issue)
        }
        .buttonStyle(.link)
        .accessibilityIdentifier("configure-inference")
        .releaseVisualQAProbe(
            ReleaseVisualQALayoutValidator.configureInference
        )
    }
}

enum CoachProviderSetupFooterContent {
    static let status = "No inference key configured."
    static let action = "Configure here"
    static let accessibilityLabel = "\(status) \(action)"
}

struct HistoryReviewWorkspace: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                "Read-only board review",
                systemImage: "clock.arrow.circlepath"
            )
            .font(.subheadline.weight(.semibold))

            Text(
                "Return to the live position before opening a hint or asking Coach."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct TeachingWorkspace: View {
    let moment: TeachingMomentState?
    let variations: [CoachVariationPresentation]
    let playerSide: ChessSide
    let usesClock: Bool
    let questionCount: Int
    let onConversation: () -> Void
    let onReveal: () -> Void
    let onExploreVariation: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let moment {
                phaseContent(moment.phase)
            }

            if questionCount > 0 {
                CoachNavigationRow(
                    title: "Questions about this lesson",
                    count: questionCount,
                    systemImage: "bubble.left.and.bubble.right",
                    action: onConversation
                )
            }

            Label(
                "Play any legal move on the board to continue from this position.",
                systemImage: "hand.tap"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Teaching workspace")
    }

    @ViewBuilder
    private func phaseContent(_ phase: TeachingMomentPhase) -> some View {
        switch phase {
        case .preparing:
            VStack(alignment: .leading, spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Preparing your lesson")
                    .font(.title3.weight(.semibold))
                Text(
                    usesClock
                        ? "Your position and clock remain paused."
                        : "Your position stays fixed while the lesson is prepared."
                )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .concept(let hint):
            VStack(alignment: .leading, spacing: 10) {
                LessonSection(
                    eyebrow: "What to notice",
                    title: "Find the idea",
                    detail: hint.concept,
                    tint: .coachGreen
                )

                Button(action: onReveal) {
                    Label("Reveal Move", systemImage: "arrow.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.blue)
                .accessibilityIdentifier("coach-reveal-move")
            }
        case .revealed(let hint):
            revealed(hint)
        case .previewing(let hint, _, _):
            revealed(hint)
        case .failed(let message):
            LessonSection(
                eyebrow: "Lesson unavailable",
                title: "Return when you’re ready",
                detail: message,
                tint: .orange
            )
        }
    }

    private func revealed(_ hint: CoachHint) -> some View {
        let primary = variations.first(where: { $0.rank == 1 })
            ?? variations.first
        let alternatives = variations.filter { $0.rank != primary?.rank }

        return VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    recommendation(primary)
                    Spacer()
                    if let primary {
                        Text(engineEvaluationLabel(primary, playerSide))
                            .font(
                                .system(
                                    .caption,
                                    design: .monospaced,
                                    weight: .semibold
                                )
                            )
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 5) {
                    recommendation(primary)
                    if let primary {
                        Text(engineEvaluationLabel(primary, playerSide))
                            .font(
                                .system(
                                    .caption,
                                    design: .monospaced,
                                    weight: .semibold
                                )
                            )
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            explanation("Why it works", hint.why)

            if let reply = primary?.moves.dropFirst().first?.san {
                LabeledContent("Likely reply") {
                    Text(reply)
                        .font(.system(.body, design: .monospaced))
                }
                .font(.caption)
            }

            DisclosureGroup("More Coaching Detail") {
                VStack(alignment: .leading, spacing: 13) {
                    explanation("Your plan", hint.plan)
                    explanation("Watch for", hint.watchFor)
                }
                .padding(.top, 10)
            }
            .font(.subheadline.weight(.semibold))

            if let primary {
                Button {
                    onExploreVariation(primary.rank)
                } label: {
                    Label(
                        "Explore Engine Line",
                        systemImage:
                            "point.topleft.down.to.point.bottomright.curvepath"
                    )
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                .accessibilityIdentifier("coach-explore-engine-line")
            }

            if !alternatives.isEmpty {
                DisclosureGroup("Other engine ideas") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(alternatives) { variation in
                            Button {
                                onExploreVariation(variation.rank)
                            } label: {
                                HStack {
                                    Text(
                                        variation.moves.first?.san
                                            ?? "Alternative \(variation.rank)"
                                    )
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.caption.weight(.semibold))
            }
        }
    }

    private func recommendation(
        _ primary: CoachVariationPresentation?
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Stockfish recommends")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(primary?.moves.first?.san ?? "Best move")
                .font(.system(.title, design: .rounded, weight: .bold))
                .foregroundStyle(.blue)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func explanation(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Text(body)
                .font(.subheadline)
                .textSelection(.enabled)
        }
    }
}

struct EngineLineWorkspace: View {
    let variation: CoachVariationPresentation?
    let selectedStep: Int
    let playerSide: ChessSide
    let onSelectStep: (Int) -> Void
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onReturnToPosition: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label(
                    "Engine line",
                    systemImage:
                        "point.topleft.down.to.point.bottomright.curvepath"
                )
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

                Text(
                    "Explore Stockfish’s continuation on the main board. Preview moves do not change your game."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)

                if let variation {
                    HStack {
                        Text(engineEvaluationLabel(variation, playerSide))
                            .font(
                                .system(
                                    .caption,
                                    design: .monospaced,
                                    weight: .semibold
                                )
                            )
                        Spacer()
                        Text(
                            selectedStep == 0
                                ? "Starting position"
                                : "Move \(selectedStep) of \(variation.moves.count)"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 7) {
                            previewButton(
                                "Back",
                                systemImage: "chevron.left",
                                action: onPrevious,
                                isEnabled: selectedStep > 0
                            )
                            previewButton(
                                "Next",
                                systemImage: "chevron.right",
                                action: onNext,
                                isEnabled:
                                    selectedStep < variation.moves.count
                            )
                            Spacer(minLength: 0)
                            Button(
                                "Return to Position",
                                action: onReturnToPosition
                            )
                            .buttonStyle(.bordered)
                        }

                        VStack(alignment: .leading, spacing: 7) {
                            HStack(spacing: 7) {
                                previewButton(
                                    "Back",
                                    systemImage: "chevron.left",
                                    action: onPrevious,
                                    isEnabled: selectedStep > 0
                                )
                                previewButton(
                                    "Next",
                                    systemImage: "chevron.right",
                                    action: onNext,
                                    isEnabled:
                                        selectedStep < variation.moves.count
                                )
                            }
                            Button(
                                "Return to Position",
                                action: onReturnToPosition
                            )
                            .buttonStyle(.bordered)
                        }
                    }
                    .controlSize(.small)

                    ScrollView(.horizontal) {
                        HStack(spacing: 7) {
                            Button("Start") {
                                onSelectStep(0)
                            }
                            .buttonStyle(.bordered)
                            .tint(selectedStep == 0 ? .blue : .secondary)

                            ForEach(
                                Array(variation.moves.enumerated()),
                                id: \.element.id
                            ) { index, move in
                                Button(move.displayLabel) {
                                    onSelectStep(index + 1)
                                }
                                .buttonStyle(.bordered)
                                .tint(
                                    selectedStep == index + 1
                                        ? .blue
                                        : .secondary
                                )
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                } else {
                    ContentUnavailableView(
                        "Line unavailable",
                        systemImage: "exclamationmark.circle",
                        description: Text(
                            "Return to the teaching position and try again."
                        )
                    )
                }
            }
            .padding(16)
        }
        .navigationTitle("Engine Line")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Engine line preview")
    }

    private func previewButton(
        _ label: String,
        systemImage: String,
        action: @escaping () -> Void,
        isEnabled: Bool
    ) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
        }
        .buttonStyle(.bordered)
        .disabled(!isEnabled)
    }
}

struct BlunderGuardWorkspace: View {
    let warning: BlunderWarning?
    let explanation: CoachMessage?
    let isWorking: Bool
    let playerSide: ChessSide

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)

            Text("Pause before the computer replies")
                .font(.title3.weight(.semibold))

            Text(warning?.reason ?? "This move changes the position sharply.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if isWorking {
                Divider()
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Coach is explaining the danger…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else if let explanation {
                Divider()
                Text("Coach’s explanation")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
                    .textCase(.uppercase)
                CoachMessageContent(
                    message: explanation,
                    playerSide: playerSide
                )
            }
        }
        .padding(16)
        .background(
            Color.orange.opacity(0.075),
            in: RoundedRectangle(cornerRadius: 13)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Blunder Guard warning")
    }
}

struct CoachCompletedWorkspace: View {
    let itemCount: Int
    let onHistory: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 30))
                .foregroundStyle(Color.coachGreen)
                .accessibilityHidden(true)

            Text("Game complete")
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)

            if itemCount == 0 {
                Text("No coaching was used in this game.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text(
                    "\(itemCount) coaching \(itemCount == 1 ? "item is" : "items are") saved with this game."
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Button(action: onHistory) {
                    Label(
                        "View Coaching History",
                        systemImage: "clock.arrow.circlepath"
                    )
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            Color.secondary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 13)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            itemCount == 0
                ? "Game complete. No coaching was used."
                : "Game complete. \(itemCount) coaching items saved."
        )
    }
}

struct CoachConversationView: View {
    let items: [CoachThreadItem]
    let playerSide: ChessSide
    let isWorking: Bool
    let backLabel: String
    let onBack: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                CoachDestinationHeader(
                    title: "Conversation",
                    backLabel: backLabel,
                    onBack: onBack
                )

                if items.isEmpty, !isWorking {
                    ContentUnavailableView(
                        "No questions yet",
                        systemImage: "bubble.left.and.bubble.right",
                        description: Text(
                            "Ask Coach about the current position."
                        )
                    )
                    .frame(minHeight: 220)
                } else {
                    ForEach(items) { item in
                        CoachThreadItemView(
                            item: item,
                            playerSide: playerSide,
                            collapsesLessons: false
                        )
                    }
                }

                if isWorking {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Preparing a grounded answer…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .defaultScrollAnchor(.bottom)
        .navigationTitle("Conversation")
    }
}

struct CoachHistoryView: View {
    let items: [CoachThreadItem]
    let playerSide: ChessSide
    let onBack: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                CoachDestinationHeader(
                    title: "Earlier in this game",
                    onBack: onBack
                )

                if items.isEmpty {
                    ContentUnavailableView(
                        "No earlier coaching",
                        systemImage: "clock.arrow.circlepath"
                    )
                    .frame(minHeight: 220)
                } else {
                    ForEach(items) { item in
                        CoachThreadItemView(
                            item: item,
                            playerSide: playerSide,
                            collapsesLessons: true
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .navigationTitle("Coach History")
    }
}

struct CoachComposer: View {
    enum Presentation: Equatable {
        case footer
        case inline
    }

    @Environment(\.controlActiveState) private var controlActiveState

    @Binding var question: String
    let title: String
    let placeholder: String
    let isWorking: Bool
    let onSend: () -> Void
    var presentation: Presentation = .footer

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .lineLimit(1)
                .minimumScaleFactor(0.8)

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .bottom, spacing: 8) {
                    questionField
                    sendButton
                }

                VStack(alignment: .trailing, spacing: 8) {
                    questionField
                    sendButton
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(12)
        .background {
            if presentation == .inline {
                RoundedRectangle(cornerRadius: 11)
                    .fill(Color(nsColor: .controlBackgroundColor))
            }
        }
        .overlay {
            if presentation == .inline {
                RoundedRectangle(cornerRadius: 11)
                    .stroke(
                        Color.secondary.opacity(
                            controlActiveState == .inactive ? 0.42 : 0.24
                        ),
                        lineWidth: 1
                    )
            }
        }
        .padding(.horizontal, presentation == .footer ? 2 : 0)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityIdentifier("coach-composer")
    }

    private var questionField: some View {
        TextField(
            placeholder,
            text: $question,
            axis: .vertical
        )
        .textFieldStyle(.roundedBorder)
        .lineLimit(1...4)
        .frame(minWidth: 0, maxWidth: .infinity)
        .onSubmit(onSend)
        .disabled(isWorking)
    }

    private var sendButton: some View {
        Button(action: onSend) {
            Image(systemName: "arrow.up")
                .font(.headline)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.borderedProminent)
        .disabled(
            question.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty || isWorking
        )
        .accessibilityLabel("Send question")
        .accessibilityIdentifier("coach-send-question")
        .fixedSize()
    }
}

struct CoachInspectorNotice: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle")
            Text(text)
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}

private struct CoachNavigationRow: View {
    let title: String
    let count: Int
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(count.formatted())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.secondary.opacity(0.08), in: Capsule())
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) items")
    }
}

private struct LessonSection: View {
    let eyebrow: String
    let title: String
    let detail: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(eyebrow)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint)
                .textCase(.uppercase)
            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text(detail)
                .font(.subheadline)
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.075), in: RoundedRectangle(cornerRadius: 13))
    }
}

private struct CoachDestinationHeader: View {
    let title: String
    var backLabel = "Back to Now"
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: onBack) {
                Label(backLabel, systemImage: "chevron.left")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)

            Text(title)
                .font(.title3.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
        }
    }
}

private struct CoachThreadItemView: View {
    let item: CoachThreadItem
    let playerSide: ChessSide
    let collapsesLessons: Bool

    var body: some View {
        Group {
            switch item {
            case .lesson(let message):
                if collapsesLessons {
                    DisclosureGroup {
                        CoachMessageContent(
                            message: message,
                            playerSide: playerSide
                        )
                        .padding(.top, 8)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Teaching moment")
                                .font(.subheadline.weight(.semibold))
                            Text(
                                message.structuredReply?.summary ?? message.text
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        }
                    }
                    .padding(12)
                    .background(
                        .secondary.opacity(0.055),
                        in: RoundedRectangle(cornerRadius: 11)
                    )
                } else {
                    CoachMessageContent(
                        message: message,
                        playerSide: playerSide
                    )
                }
            case .turn(let turn):
                VStack(spacing: 9) {
                    CoachMessageBubble(
                        message: turn.question,
                        playerSide: playerSide
                    )
                    if let answer = turn.answer {
                        CoachMessageBubble(
                            message: answer,
                            playerSide: playerSide
                        )
                    }
                }
            case .pending(let turn):
                VStack(spacing: 9) {
                    CoachMessageBubble(
                        message: turn.question,
                        playerSide: playerSide
                    )
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Preparing a grounded answer…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(11)
                }
            case .warning(let message), .legacy(let message):
                CoachMessageBubble(
                    message: message,
                    playerSide: playerSide
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CoachMessageBubble: View {
    let message: CoachMessage
    let playerSide: ChessSide

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(roleLabel)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            CoachMessageContent(
                message: message,
                playerSide: playerSide
            )
        }
        .padding(11)
        .background(
            message.role == .user
                ? Color.accentColor.opacity(0.09)
                : Color.secondary.opacity(0.065),
            in: RoundedRectangle(cornerRadius: 11)
        )
        .padding(.leading, message.role == .user ? 28 : 0)
        .padding(.trailing, message.role == .user ? 0 : 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var roleLabel: String {
        switch message.role {
        case .user: "You"
        case .coach: "Coach"
        case .system: "Chess Coach"
        }
    }
}

private struct CoachMessageContent: View {
    let message: CoachMessage
    let playerSide: ChessSide

    var body: some View {
        if let reply = message.structuredReply {
            CoachReplyContentView(
                reply: reply,
                variations: [],
                playerSide: playerSide,
                onSelectMove: { _, _ in }
            )
        } else if let attributed = try? AttributedString(
            markdown: message.text
        ) {
            Text(attributed)
                .font(.subheadline)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(message.text.isEmpty ? "…" : message.text)
                .font(.subheadline)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private func engineEvaluationLabel(
    _ variation: CoachVariationPresentation,
    _ playerSide: ChessSide
) -> String {
    if let mate = variation.mateForPlayer {
        let leader = mate >= 0 ? playerSide : playerSide.opposite
        return "Engine · \(leader.displayName) M\(abs(mate))"
    }
    guard let centipawns = variation.centipawnsForPlayer else {
        return "Engine"
    }
    if abs(centipawns) < 5 {
        return "Engine · Even"
    }
    let leader = centipawns > 0 ? playerSide : playerSide.opposite
    let points = abs(Double(centipawns) / 100)
        .formatted(.number.precision(.fractionLength(1)))
    return "Engine · \(leader.displayName) +\(points)"
}
