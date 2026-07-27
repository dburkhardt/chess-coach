import SwiftUI

struct CoachInspectorHeader: View {
    let presentation: CoachHeaderPresentation
    let historyCount: Int
    let onHistory: () -> Void
    let onTakeBack: () -> Void
    let onSettings: () -> Void

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

                Spacer(minLength: 8)

                if presentation.showsHistory {
                    Button(action: onHistory) {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                    .buttonStyle(.plain)
                    .help("Earlier coaching (\(historyCount))")
                    .accessibilityLabel(
                        "Earlier coaching, \(historyCount) items"
                    )
                }

                if presentation.showsTakeBack {
                    Button(action: onTakeBack) {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.plain)
                    .help("Take Back")
                    .accessibilityLabel("Take Back")
                }

                if presentation.showsSettings {
                    Button(action: onSettings) {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.plain)
                    .help("Coach and board settings")
                    .accessibilityLabel("Coach and board settings")
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
        .frame(minHeight: 62)
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
        case .revealMove, .exploreEngineLine,
             .previewPrevious, .previewNext, .returnToPosition:
            .blue
        case .continuePlaying, .openHint:
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
    let preparationState: CoachPreparationState
    let isEngineThinking: Bool
    let chatState: CoachChatState
    let currentConversationCount: Int
    let historyCount: Int
    let onConversation: () -> Void
    let onHistory: () -> Void
    let onSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 7) {
                Label("Need a nudge?", systemImage: "lightbulb")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.coachGreen)
                    .textCase(.uppercase)

                Text(title)
                    .font(.title3.weight(.semibold))

                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.coachGreen.opacity(0.075),
                in: RoundedRectangle(cornerRadius: 13)
            )

            if currentConversationCount > 0 {
                CoachNavigationRow(
                    title: "Conversation",
                    count: currentConversationCount,
                    systemImage: "bubble.left.and.bubble.right",
                    action: onConversation
                )
            }

            if historyCount > 0 {
                CoachNavigationRow(
                    title: "Earlier in this game",
                    count: historyCount,
                    systemImage: "clock.arrow.circlepath",
                    action: onHistory
                )
            }

            if case .unavailable(let message) = chatState {
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Configure AI Provider in Settings", action: onSettings)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Live coaching")
    }

    private var title: String {
        "Build the habit, not just the move."
    }

    private var detail: String {
        switch preparationState {
        case .failed:
            return "Retry when you want Coach to study this exact position."
        case .idle, .analyzing, .ready:
            return "Open Hint for one concept. The game pauses while you explore it."
        }
    }
}

struct TeachingWorkspace: View {
    let moment: TeachingMomentState?
    let variations: [CoachVariationPresentation]
    let playerSide: ChessSide
    let questionCount: Int
    let onConversation: () -> Void
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
                Text("Your position and clock remain paused.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .concept(let hint):
            LessonSection(
                eyebrow: "What to notice",
                title: "Find the idea",
                detail: hint.concept,
                tint: .coachGreen
            )
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
    let items: [CoachThreadItem]
    let playerSide: ChessSide

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Game transcript")
                .font(.title3.weight(.semibold))

            Text("This completed game is read-only.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if items.isEmpty {
                ContentUnavailableView(
                    "No coaching in this game",
                    systemImage: "bubble.left",
                    description: Text(
                        "Hints and conversations will appear here."
                    )
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
            .padding(16)
        }
        .navigationTitle("Coach History")
    }
}

struct CoachComposer: View {
    @Binding var question: String
    let title: String
    let placeholder: String
    let isWorking: Bool
    let onSend: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            HStack(alignment: .bottom, spacing: 8) {
                TextField(
                    placeholder,
                    text: $question,
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
                .onSubmit(onSend)
                .disabled(isWorking)

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
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
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
                        Text(message.structuredReply?.summary ?? message.text)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(
            message.role == .user
                ? Color.accentColor.opacity(0.09)
                : Color.secondary.opacity(0.065),
            in: RoundedRectangle(cornerRadius: 11)
        )
        .padding(.leading, message.role == .user ? 28 : 0)
        .padding(.trailing, message.role == .user ? 0 : 14)
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
        } else {
            Text(message.text.isEmpty ? "…" : message.text)
                .font(.subheadline)
                .textSelection(.enabled)
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
