import SwiftUI

struct CurrentGameView: View {
    @Bindable var coordinator: GameCoordinator
    @State private var showsRewindConfirmation = false

    private let materialBalanceOverride: MaterialBalance?
    private let capturedMaterialOverride: CapturedMaterialLedger?
    private let isCoachPresented: Bool
    private let onShowCoach: () -> Void

    init(
        coordinator: GameCoordinator,
        materialBalance: MaterialBalance? = nil,
        capturedMaterial: CapturedMaterialLedger? = nil,
        isCoachPresented: Bool = true,
        onShowCoach: @escaping () -> Void = {}
    ) {
        self.coordinator = coordinator
        self.materialBalanceOverride = materialBalance
        self.capturedMaterialOverride = capturedMaterial
        self.isCoachPresented = isCoachPresented
        self.onShowCoach = onShowCoach
    }

    var body: some View {
        if coordinator.activeGame == nil {
            ContentUnavailableView(
                "No current game",
                systemImage: "checkerboard.rectangle",
                description: Text("Choose New Game to begin a training game.")
            )
        } else {
            GeometryReader { geometry in
                let layout = CurrentGameLayout(
                    availableSize: geometry.size,
                    showsGameOverPanel:
                        coordinator.status.isFinished &&
                        coordinator.historyPreview == nil
                )

                VStack(spacing: 0) {
                    PlayerStrip(
                        coordinator: coordinator,
                        materialBalance: materialBalanceOverride
                            ?? coordinator.displayedMaterialBalance,
                        capturedMaterial: capturedMaterialOverride
                            ?? coordinator.displayedCapturedMaterial,
                        isPreviewMaterial: coordinator.isTeachingPreviewActive
                    )
                        .frame(width: layout.stageWidth)

                    HStack(alignment: .top, spacing: layout.showsHistory ? 16 : 0) {
                        ChessBoardView(coordinator: coordinator)
                            .frame(width: layout.boardSide, height: layout.boardSide)

                        if layout.showsHistory {
                            MoveHistoryView(coordinator: coordinator)
                                .frame(
                                    width: CurrentGameLayout.historyWidth,
                                    height: layout.boardSide
                                )
                        }
                    }
                    .frame(width: layout.stageWidth)
                    .padding(.top, 11)

                    if coordinator.historyPreview != nil {
                        HistoryPreviewFooter(
                            coordinator: coordinator,
                            onConfirmRewind: {
                                showsRewindConfirmation = true
                            }
                        )
                        .frame(width: layout.stageWidth)
                        .padding(.top, 8)
                    } else if coordinator.status.isFinished {
                        GameOverPanel(
                            status: coordinator.status,
                            playerSide: coordinator.playerSide,
                            canReview:
                                !(coordinator.activeGame?.sortedPlies.isEmpty
                                    ?? true),
                            onReview: {
                                _ = coordinator.selectHistoryPreview(ply: 0)
                            },
                            onPlayAgain: coordinator.restart
                        )
                        .frame(width: layout.stageWidth)
                        .padding(.top, 12)
                    } else {
                        BoardFooter(
                            coordinator: coordinator,
                            presentsCompactHistory: !layout.showsHistory
                        )
                        .frame(width: layout.stageWidth)
                        .padding(.top, 8)
                    }
                }
                .padding(CurrentGameLayout.contentPadding)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .center
                )
            }
            .navigationTitle("Current Game")
            .alert(
                rewindConfirmationTitle,
                isPresented: $showsRewindConfirmation
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Go Back", role: .destructive) {
                    _ = coordinator.rewindToHistoryPreview()
                }
            } message: {
                Text(rewindConfirmationMessage)
            }
            .overlay(alignment: .topTrailing) {
                if coordinator.teachingMoment != nil, !isCoachPresented {
                    Button(action: onShowCoach) {
                        Label(
                            "Teaching moment paused · Show Coach",
                            systemImage: "pause.circle.fill"
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(Color.coachGreen)
                    .padding(14)
                    .help("Show the paused teaching moment")
                    .accessibilityHint(
                        "Opens Coach without resuming the game clock"
                    )
                }
            }
        }
    }

    private var rewindConfirmationTitle: String {
        coordinator.historyPreview?.selectedPly == 0
            ? "Go back to the start?"
            : "Go back to this move?"
    }

    private var rewindConfirmationMessage: String {
        guard let preview = coordinator.historyPreview else {
            return "The current game will remain unchanged."
        }
        let removed = max(0, preview.anchor.ply - preview.selectedPly)
        let continuation = removed == 1
            ? "1 later move"
            : "\(removed) later moves"
        return "This permanently discards \(continuation), reopens the game, and cannot be undone."
    }
}

private struct CurrentGameLayout {
    static let contentPadding: CGFloat = 18
    static let historyWidth: CGFloat = 174
    static let maximumBoardSide: CGFloat = 680
    static let historyBreakpoint: CGFloat = 760
    static let verticalChrome: CGFloat = 118
    static let gameOverChrome: CGFloat = 166

    var boardSide: CGFloat
    var showsHistory: Bool

    var stageWidth: CGFloat {
        boardSide + (showsHistory ? Self.historyWidth + 16 : 0)
    }

    init(availableSize: CGSize, showsGameOverPanel: Bool = false) {
        showsHistory = availableSize.width >= Self.historyBreakpoint

        let widthAllowance = availableSize.width
            - (Self.contentPadding * 2)
            - (showsHistory ? Self.historyWidth + 16 : 0)
        let heightAllowance = availableSize.height
            - (Self.contentPadding * 2)
            - Self.verticalChrome
            - (showsGameOverPanel ? Self.gameOverChrome : 0)
        boardSide = floor(
            max(280, min(widthAllowance, heightAllowance, Self.maximumBoardSide))
        )
    }
}

private struct PlayerStrip: View {
    @Bindable var coordinator: GameCoordinator
    let materialBalance: MaterialBalance
    let capturedMaterial: CapturedMaterialLedger
    let isPreviewMaterial: Bool

    @AppStorage(ChessBoardPreferences.pieceStyleKey)
    private var pieceStyleRaw =
        ChessBoardPreferences.PieceStyle.merida.rawValue

    var body: some View {
        HStack(spacing: 10) {
            PlayerSummary(
                side: coordinator.playerSide.opposite,
                name: "Computer",
                detail: "Stockfish · Level \(coordinator.configuration.difficulty)",
                milliseconds: coordinator.displayedClocks.value(
                    for: coordinator.playerSide.opposite
                ),
                showsClock: coordinator.configuration.timeControl.usesClock,
                active: coordinator.isEngineThinking,
                capturedPieces: capturedMaterial.pieces(
                    capturedBy: coordinator.playerSide.opposite
                ),
                advantagePoints: advantagePoints(
                    for: coordinator.playerSide.opposite
                ),
                pieceStyle: pieceStyle
            )

            Text("vs")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .accessibilityHidden(true)

            PlayerSummary(
                side: coordinator.playerSide,
                name: "You",
                detail: coordinator.playerSide.displayName,
                milliseconds: coordinator.displayedClocks.value(
                    for: coordinator.playerSide
                ),
                showsClock: coordinator.configuration.timeControl.usesClock,
                active: coordinator.canPlayerMove,
                capturedPieces: capturedMaterial.pieces(
                    capturedBy: coordinator.playerSide
                ),
                advantagePoints: advantagePoints(
                    for: coordinator.playerSide
                ),
                pieceStyle: pieceStyle,
                alignment: .trailing
            )
        }
        .padding(7)
        .background(.background, in: RoundedRectangle(cornerRadius: 13))
        .overlay {
            RoundedRectangle(cornerRadius: 13)
                .stroke(.secondary.opacity(0.18), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.035), radius: 2, y: 1)
        .accessibilityElement(children: .contain)
    }

    private var pieceStyle: ChessBoardPreferences.PieceStyle {
        ChessBoardPreferences.PieceStyle(rawValue: pieceStyleRaw) ?? .merida
    }

    private func advantagePoints(for side: ChessSide) -> Int? {
        guard case .ahead(let points) = materialBalance.advantage(for: side)
        else {
            return nil
        }
        return points
    }
}

private struct PlayerSummary: View {
    var side: ChessSide
    var name: String
    var detail: String
    var milliseconds: Int
    var showsClock: Bool
    var active: Bool
    var capturedPieces: [CapturedPieceRecord]
    var advantagePoints: Int?
    var pieceStyle: ChessBoardPreferences.PieceStyle
    var alignment: HorizontalAlignment = .leading

    init(
        side: ChessSide,
        name: String,
        detail: String,
        milliseconds: Int,
        showsClock: Bool,
        active: Bool,
        capturedPieces: [CapturedPieceRecord] = [],
        advantagePoints: Int? = nil,
        pieceStyle: ChessBoardPreferences.PieceStyle = .merida,
        alignment: HorizontalAlignment = .leading
    ) {
        self.side = side
        self.name = name
        self.detail = detail
        self.milliseconds = milliseconds
        self.showsClock = showsClock
        self.active = active
        self.capturedPieces = capturedPieces
        self.advantagePoints = advantagePoints
        self.pieceStyle = pieceStyle
        self.alignment = alignment
    }

    var body: some View {
        VStack(alignment: alignment, spacing: 3) {
            HStack(spacing: 9) {
                if alignment == .trailing {
                    clock
                }

                pieceBadge

                VStack(alignment: alignment, spacing: 1) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if alignment == .leading {
                    Spacer(minLength: 4)
                    clock
                }
            }

            if !capturedPieces.isEmpty || advantagePoints != nil {
                HStack(spacing: 5) {
                    if alignment == .trailing {
                        Spacer(minLength: 0)
                    }
                    CapturedPieceStrip(
                        pieces: capturedPieces,
                        style: pieceStyle
                    )
                    if let advantagePoints {
                        Text("+\(advantagePoints)")
                            .font(
                                .system(
                                    .caption2,
                                    design: .monospaced,
                                    weight: .bold
                                )
                            )
                            .foregroundStyle(.secondary)
                            .help(
                                "\(side.displayName) leads by \(advantagePoints) material \(advantagePoints == 1 ? "point" : "points")"
                            )
                    }
                    if alignment == .leading {
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(active ? Color.coachGreen.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }

    private var pieceBadge: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(.secondary.opacity(0.07))
            .frame(width: 31, height: 31)
            .overlay {
                Circle()
                    .fill(side == .white ? .white : Color(red: 0.16, green: 0.18, blue: 0.15))
                    .stroke(.secondary.opacity(0.45), lineWidth: 1)
                    .frame(width: 18, height: 18)
            }
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var clock: some View {
        if showsClock {
            Text(Self.format(milliseconds: milliseconds))
                .font(.system(.title3, design: .monospaced, weight: .semibold))
                .monospacedDigit()
        }
    }

    private static func format(milliseconds: Int) -> String {
        let clamped = max(0, milliseconds)
        let seconds = clamped / 1_000
        if clamped < 10_000 {
            return String(format: "0:%04.1f", Double(clamped) / 1_000)
        }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

private struct CapturedPieceStrip: View {
    let pieces: [CapturedPieceRecord]
    let style: ChessBoardPreferences.PieceStyle

    var body: some View {
        HStack(spacing: -5) {
            ForEach(pieces) { captured in
                ChessPieceArtwork(
                    piece: BoardPiece(
                        square: "a1",
                        side: captured.side,
                        kind: captured.kind
                    ),
                    style: style
                )
                .frame(width: 16, height: 16)
                .saturation(0.2)
                .opacity(0.52)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        guard !pieces.isEmpty else { return "No captured pieces" }
        let names = pieces.map(\.accessibilityName)
        return "Captured \(names.joined(separator: ", "))"
    }
}

struct MaterialBalanceBadge: View {
    let balance: MaterialBalance
    let playerSide: ChessSide
    var isPreview = false

    var body: some View {
        VStack(spacing: 1) {
            Text(displayText)
                .font(.system(.caption2, design: .monospaced, weight: .bold))
            if isPreview {
                Text("Preview")
                    .font(.system(size: 8, weight: .bold))
                    .textCase(.uppercase)
            }
        }
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(backgroundColor, in: Capsule())
        .accessibilityLabel(accessibilityText)
        .help(accessibilityText)
    }

    var displayText: String {
        switch balance.advantage(for: playerSide) {
        case .ahead(let points): "You +\(points)"
        case .even: "Material · Even"
        case .behind(let points): "Computer +\(points)"
        }
    }

    var accessibilityText: String {
        let prefix = isPreview ? "Preview material" : "Material"
        let totals = "\(prefix): White \(balance.whitePoints) points, Black \(balance.blackPoints) points."
        switch balance.advantage(for: playerSide) {
        case .ahead(let points):
            return "\(totals) You lead by \(points) \(points == 1 ? "point" : "points")."
        case .even:
            return "\(totals) Material is even."
        case .behind(let points):
            return "\(totals) Computer leads by \(points) \(points == 1 ? "point" : "points")."
        }
    }

    private var foregroundColor: Color {
        switch balance.advantage(for: playerSide) {
        case .ahead: Color.coachGreen
        case .even: .secondary
        case .behind: .orange
        }
    }

    private var backgroundColor: Color {
        foregroundColor.opacity(0.12)
    }
}

private struct HistoryPreviewFooter: View {
    @Bindable var coordinator: GameCoordinator
    let onConfirmRewind: () -> Void

    var body: some View {
        VStack(spacing: 9) {
            HStack(spacing: 8) {
                Label(selectedPositionLabel, systemImage: "clock.arrow.circlepath")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text("\(selectedPly) of \(totalPlies)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) {
                    previousButton
                    nextButton
                    returnToLiveButton

                    Spacer(minLength: 8)

                    rewindButton
                }

                VStack(spacing: 7) {
                    HStack(spacing: 7) {
                        previousButton
                            .labelStyle(.iconOnly)
                        nextButton
                            .labelStyle(.iconOnly)
                        returnToLiveButton
                        Spacer(minLength: 4)
                    }
                    rewindButton
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(11)
        .background(
            Color.accentColor.opacity(0.07),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.accentColor.opacity(0.22), lineWidth: 1)
        }
        .onExitCommand {
            coordinator.returnToLivePosition()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(
            "Reviewing \(selectedPositionLabel), move \(selectedPly) of \(totalPlies)"
        )
    }

    private var selectedPly: Int {
        coordinator.historyPreview?.selectedPly ?? totalPlies
    }

    private var totalPlies: Int {
        coordinator.activeGame?.sortedPlies.count ?? 0
    }

    private var previousButton: some View {
        Button {
            _ = coordinator.stepHistoryPreview(by: -1)
        } label: {
            Label("Previous", systemImage: "chevron.left")
        }
        .disabled(selectedPly == 0)
        .help("Show the previous position")
    }

    private var nextButton: some View {
        Button {
            _ = coordinator.stepHistoryPreview(by: 1)
        } label: {
            Label("Next", systemImage: "chevron.right")
        }
        .disabled(selectedPly >= totalPlies)
        .help("Show the next position")
    }

    private var returnToLiveButton: some View {
        Button {
            coordinator.returnToLivePosition()
        } label: {
            Label("Return to Live", systemImage: "forward.end")
        }
        .help("Return to the current position without changing the game")
    }

    private var rewindButton: some View {
        Button(
            selectedPly == 0
                ? "Go Back to Start…"
                : "Go Back to This Move…",
            role: .destructive,
            action: onConfirmRewind
        )
        .help("Discard the later continuation after confirmation")
    }

    private var selectedPositionLabel: String {
        guard selectedPly > 0,
              let plies = coordinator.activeGame?.sortedPlies,
              plies.indices.contains(selectedPly - 1)
        else {
            return "Start position"
        }
        let ply = plies[selectedPly - 1]
        let number = (selectedPly + 1) / 2
        return ply.side == .white
            ? "After \(number). \(ply.san)"
            : "After \(number)… \(ply.san)"
    }
}

private struct BoardFooter: View {
    @Bindable var coordinator: GameCoordinator
    var presentsCompactHistory: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if coordinator.status.isFinished {
                    Label(coordinator.status.message, systemImage: "flag.checkered")
                } else if coordinator.teachingMoment != nil {
                    Label(
                        "Teaching moment · game paused",
                        systemImage: "pause.fill"
                    )
                } else if coordinator.isEngineThinking {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Computer is thinking…")
                    }
                } else {
                    Text(coordinator.canPlayerMove ? "Your move" : "Game in progress")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)

            Spacer(minLength: 8)

            if presentsCompactHistory {
                CompactMoveHistoryMenu(coordinator: coordinator)
            }

            Button("Restart") {
                coordinator.restart()
            }
            .help("Restart with the current game settings")

            Button("Resign", role: .destructive) {
                coordinator.resign()
            }
            .disabled(coordinator.status.isFinished)
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(minHeight: 30)
    }
}

private struct MoveHistoryView: View {
    @Bindable var coordinator: GameCoordinator

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Moves")
                    .font(.caption.weight(.semibold))
                Spacer()
                Text("\(coordinator.activeGame?.plies.count ?? 0) plies")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .frame(height: 42)

            Divider()

            if coordinator.moveRows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "list.number")
                        .font(.title3)
                    Text("Your moves will appear here")
                        .multilineTextAlignment(.center)
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    let plies = coordinator.activeGame?.sortedPlies ?? []
                    LazyVGrid(
                        columns: [
                            GridItem(.fixed(25), alignment: .trailing),
                            GridItem(.flexible(), alignment: .leading),
                            GridItem(.flexible(), alignment: .leading)
                        ],
                        alignment: .leading,
                        spacing: 7
                    ) {
                        ForEach(
                            Array(stride(from: 0, to: plies.count, by: 2)),
                            id: \.self
                        ) { index in
                            Text("\(index / 2 + 1).")
                                .foregroundStyle(.tertiary)

                            historyButton(for: plies[index])

                            if plies.indices.contains(index + 1) {
                                historyButton(for: plies[index + 1])
                            } else {
                                Color.clear
                                    .frame(height: 20)
                            }
                        }
                    }
                    .font(.system(.caption, design: .monospaced))
                    .padding(12)
                }
            }

            Divider()

            HStack(spacing: 5) {
                Button {
                    showPreviousPosition()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled((coordinator.activeGame?.sortedPlies.isEmpty) != false)
                .help("Previous position")

                Button {
                    _ = coordinator.stepHistoryPreview(by: 1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(coordinator.historyPreview == nil)
                .help("Next position")

                Spacer(minLength: 2)

                Button {
                    coordinator.returnToLivePosition()
                } label: {
                    Image(systemName: "forward.end")
                }
                .disabled(coordinator.historyPreview == nil)
                .help("Return to live position")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .padding(.horizontal, 10)
            .frame(height: 34)
        }
        .background(.background, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(.secondary.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Move history")
    }

    private func showPreviousPosition() {
        if coordinator.historyPreview != nil {
            _ = coordinator.stepHistoryPreview(by: -1)
            return
        }
        let count = coordinator.activeGame?.sortedPlies.count ?? 0
        guard count > 0 else { return }
        _ = coordinator.selectHistoryPreview(ply: max(0, count - 1))
    }

    private func historyButton(for ply: SavedPly) -> some View {
        let selected = coordinator.historyPreview?.selectedPly == ply.index + 1
        return Button {
            _ = coordinator.selectHistoryPreview(ply: ply.index + 1)
        } label: {
            Text(ply.san)
                .fontWeight(.semibold)
                .lineLimit(1)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    selected
                        ? Color.accentColor.opacity(0.15)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            "Move \(ply.index + 1), \(ply.san)"
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct CompactMoveHistoryMenu: View {
    @Bindable var coordinator: GameCoordinator

    var body: some View {
        Menu {
            let plies = coordinator.activeGame?.sortedPlies ?? []
            if plies.isEmpty {
                Text("No moves yet")
            } else {
                Button("Start position") {
                    _ = coordinator.selectHistoryPreview(ply: 0)
                }
                Divider()
                ForEach(plies) { ply in
                    Button(moveLabel(for: ply)) {
                        _ = coordinator.selectHistoryPreview(
                            ply: ply.index + 1
                        )
                    }
                }
            }
        } label: {
            Label(
                "\(coordinator.activeGame?.plies.count ?? 0) moves",
                systemImage: "list.number"
            )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Show move history")
    }

    private func moveLabel(for ply: SavedPly) -> String {
        let number = ply.index / 2 + 1
        return ply.side == .white
            ? "\(number). \(ply.san)"
            : "\(number)… \(ply.san)"
    }
}

extension Color {
    static let coachGreen = Color(red: 0.28, green: 0.46, blue: 0.31)
}
