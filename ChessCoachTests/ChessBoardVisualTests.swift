import AppKit
import SwiftUI
import Testing
@testable import ChessCoach

@MainActor
@Suite(.serialized)
struct ChessBoardVisualTests {
    @Test func bundledVectorPieceSetsAndCurrentGameRender() async throws {
        for style in ["Chessnut", "Merida"] {
            for side in ["White", "Black"] {
                for kind in ["King", "Queen", "Rook", "Bishop", "Knight", "Pawn"] {
                    #expect(
                        NSImage(named: "\(style)\(side)\(kind)") != nil,
                        "Missing \(style)\(side)\(kind) from the asset catalog."
                    )
                }
            }
        }

        let defaultsName = "ChessBoardVisualTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        defaults.set("test-model", forKey: "ai.modelID")
        let persistence = PersistenceController(inMemory: true)
        let settings = InferenceSettings(
            defaults: defaults,
            keychain: VisualTestKeychain()
        )
        let engine = VisualTestEngine()
        let coordinator = GameCoordinator(
            persistence: persistence,
            inferenceSettings: settings,
            opponent: engine,
            analyst: engine,
            inference: VisualTestInference()
        )
        coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 4,
                timeControl: .none,
                blunderGuardEnabled: false
            )
        )
        await Task.yield()

        let defaultContent = VisualAcceptanceHost(
            coordinator: coordinator,
            inferenceSettings: settings
        )
        .frame(width: 1_420, height: 900)
        .environment(\.colorScheme, .light)

        let defaultRenderer = ImageRenderer(content: defaultContent)
        defaultRenderer.scale = 2
        let defaultImage = try #require(defaultRenderer.nsImage)
        #expect(defaultImage.size == CGSize(width: 1_420, height: 900))
        try write(defaultImage, named: "current-game-idle")

        let compactContent = VisualAcceptanceHost(
            coordinator: coordinator,
            inferenceSettings: settings
        )
        .frame(width: 1_180, height: 760)
        .environment(\.colorScheme, .light)
        let compactRenderer = ImageRenderer(content: compactContent)
        compactRenderer.scale = 2
        let compactImage = try #require(compactRenderer.nsImage)
        #expect(compactImage.size == CGSize(width: 1_180, height: 760))
        try write(compactImage, named: "current-game-compact")

        let materialContent = VisualAcceptanceHost(
            coordinator: coordinator,
            inferenceSettings: settings,
            materialBalance: MaterialBalance(
                whitePoints: 42,
                blackPoints: 39
            )
        )
        .frame(width: 1_180, height: 760)
        .environment(\.colorScheme, .light)
        let materialRenderer = ImageRenderer(content: materialContent)
        materialRenderer.scale = 2
        let materialImage = try #require(materialRenderer.nsImage)
        #expect(materialImage.size == CGSize(width: 1_180, height: 760))
        try write(materialImage, named: "current-game-material-ahead")

        let badgeContent = HStack(spacing: 12) {
            MaterialBalanceBadge(
                balance: MaterialBalance(whitePoints: 42, blackPoints: 39),
                playerSide: .white
            )
            MaterialBalanceBadge(
                balance: MaterialBalance(whitePoints: 42, blackPoints: 39),
                playerSide: .black
            )
            MaterialBalanceBadge(
                balance: MaterialBalance(whitePoints: 39, blackPoints: 39),
                playerSide: .white
            )
        }
        .padding()
        .frame(width: 340, height: 64)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .light)
        let badgeRenderer = ImageRenderer(content: badgeContent)
        badgeRenderer.scale = 2
        let badgeImage = try #require(badgeRenderer.nsImage)
        #expect(badgeImage.size == CGSize(width: 340, height: 64))
        try write(badgeImage, named: "material-badges")

        try await eventually {
            if case .ready = coordinator.coachPreparationState {
                return true
            }
            return false
        }
        try write(
            try renderAcceptance(
                coordinator: coordinator,
                settings: settings
            ),
            named: "coach-hint-ready"
        )
        coordinator.requestHint()
        try write(
            try renderAcceptance(
                coordinator: coordinator,
                settings: settings
            ),
            named: "teaching-open"
        )

        try await eventually {
            if case .concept = coordinator.teachingMoment?.phase {
                return true
            }
            return false
        }
        let anchoredSnapshot = coordinator.chessBoardSnapshot
        #expect(anchoredSnapshot.inputAvailable)
        #expect(
            anchoredSnapshot.destinations(from: "e2").contains("e4")
        )
        if case .teachingAnchor =
                coordinator.chessBoardPresentationContext {
            // Expected: exact teaching anchors remain playable.
        } else {
            Issue.record("Expected an interactive teaching-anchor board.")
        }
        try write(
            try renderAcceptance(
                coordinator: coordinator,
                settings: settings
            ),
            named: "teaching-concept"
        )

        coordinator.revealHint()
        try write(
            try renderAcceptance(
                coordinator: coordinator,
                settings: settings
            ),
            named: "teaching-reveal"
        )

        coordinator.setTeachingPreview(variationRank: 1, step: 1)
        let previewSnapshot = coordinator.chessBoardSnapshot
        #expect(!previewSnapshot.inputAvailable)
        #expect(previewSnapshot.legalDestinations.isEmpty)
        if case .lessonPreview =
                coordinator.chessBoardPresentationContext {
            // Expected: engine-line previews are disposable and read-only.
        } else {
            Issue.record("Expected a read-only lesson-preview board.")
        }
        try write(
            try renderAcceptance(
                coordinator: coordinator,
                settings: settings
            ),
            named: "teaching-preview"
        )

        coordinator.sendChat("What should I learn from this line?")
        try await eventually {
            coordinator.coachMessages.last?.structuredReply != nil
        }
        let lessonID = try #require(coordinator.teachingMoment?.id)
        try write(
            try renderAcceptance(
                coordinator: coordinator,
                settings: settings,
                initialRoutes: [
                    .variation(rank: 1),
                    .conversation(.lesson(sessionID: lessonID)),
                ]
            ),
            named: "teaching-chat"
        )
    }

    @Test func missingInferenceConfigurationNoticeRenders() throws {
        #expect(
            InferenceConfigurationIssue.missingKey.message
                == "No inference key configured."
        )

        let content = InferenceConfigurationNotice(
            issue: .missingKey,
            onConfigure: {}
        )
        .padding(16)
        .frame(width: 320, height: 70, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
        .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        #expect(image.size == CGSize(width: 320, height: 70))
        try write(image, named: "missing-inference-key")
    }

    private func renderAcceptance(
        coordinator: GameCoordinator,
        settings: InferenceSettings,
        size: CGSize = CGSize(width: 1_420, height: 900),
        initialRoutes: [CoachInspectorRoute] = []
    ) throws -> NSImage {
        let content = VisualAcceptanceHost(
            coordinator: coordinator,
            inferenceSettings: settings,
            initialCoachRoutes: initialRoutes
        )
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .light)
        let host = NSHostingController(rootView: content)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        host.view.frame = NSRect(origin: .zero, size: size)
        host.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        host.view.layoutSubtreeIfNeeded()

        let representation = try #require(
            host.view.bitmapImageRepForCachingDisplay(in: host.view.bounds)
        )
        host.view.cacheDisplay(
            in: host.view.bounds,
            to: representation
        )
        let image = NSImage(size: size)
        image.addRepresentation(representation)
        return image
    }

    private func eventually(
        _ condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<2_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        Issue.record("Visual state did not become ready.")
    }

    private func write(_ image: NSImage, named name: String) throws {
        let url = URL(
            fileURLWithPath: "/tmp/ChessCoachVisualSnapshots",
            isDirectory: true
        )
        .appendingPathComponent("\(name).png")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let tiff = try #require(image.tiffRepresentation)
        let representation = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(
            representation.representation(using: .png, properties: [:])
        )
        try png.write(to: url, options: .atomic)
    }
}

private struct VisualAcceptanceHost: View {
    @Bindable var coordinator: GameCoordinator
    @Bindable var inferenceSettings: InferenceSettings
    var materialBalance: MaterialBalance?
    var initialCoachRoutes: [CoachInspectorRoute] = []

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Chess Coach")
                    .font(.headline)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                VisualNavigationRow(title: "New Game", symbol: "plus.square")
                VisualNavigationRow(
                    title: "Current Game",
                    symbol: "checkerboard.rectangle",
                    selected: true
                )
                VisualNavigationRow(title: "Games", symbol: "books.vertical")
                VisualNavigationRow(
                    title: "Progress",
                    symbol: "chart.line.uptrend.xyaxis"
                )
                VisualNavigationRow(title: "Settings", symbol: "gearshape")
                Spacer()
            }
            .padding(.vertical, 18)
            .padding(.horizontal, 10)
            .frame(width: 190)
            .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            CurrentGameView(
                coordinator: coordinator,
                materialBalance: materialBalance
            )
                .frame(maxWidth: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))

            Divider()

            CoachSidebar(
                coordinator: coordinator,
                inferenceSettings: inferenceSettings,
                embedsScrollableTimeline: false,
                initialRoutes: initialCoachRoutes
            )
            .frame(width: 360)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct VisualNavigationRow: View {
    let title: String
    let symbol: String
    var selected = false

    var body: some View {
        Label(title, systemImage: symbol)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                selected ? Color.accentColor.opacity(0.14) : .clear,
                in: RoundedRectangle(cornerRadius: 7)
            )
    }
}

private actor VisualTestEngine: ChessEngineServing {
    func analyze(
        fen: String,
        multiPV: Int,
        moveTimeMilliseconds: Int
    ) async throws -> PositionAnalysis {
        PositionAnalysis(
            fen: fen,
            sideToMove: .white,
            bestMove: "e2e4",
            variations: [
                PrincipalVariation(
                    index: 1,
                    depth: 12,
                    score: EngineScore(centipawns: 24, mate: nil),
                    wdl: WDL(win: 228, draw: 604, loss: 168),
                    moves: ["e2e4", "e7e5"]
                )
            ]
        )
    }

    func opponentMove(
        fen: String,
        difficulty: Int,
        clocks: ClockSnapshot,
        timeControl: TimeControl
    ) async throws -> String {
        "e7e5"
    }

    func stopThinking() {}
    func shutdown() {}
}

private struct VisualTestInference: CoachInferenceServing {
    func generateHint(
        configuration: InferenceConfiguration,
        credential: String,
        context: CoachContext
    ) async throws -> CoachHint {
        CoachHint(
            concept: "Fight for the center while opening a line for a piece.",
            why: "Central space makes development easier.",
            plan: "Develop and castle.",
            likelyReply: "Black contests the center.",
            watchFor: "Pressure on the central pawn.",
            recommendedMove: context.recommendedMove,
            source: "Stockfish"
        )
    }

    func streamChat(
        configuration: InferenceConfiguration,
        credential: String,
        context: CoachContext,
        history: [CoachMessage]
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }

    func generateReply(
        configuration: InferenceConfiguration,
        credential: String,
        context: CoachContext,
        history: [CoachMessage]
    ) async throws -> CoachReply {
        CoachReply(
            summary: "Use the central space to make every developing move more useful.",
            sections: [
                CoachReplySection(
                    kind: .idea,
                    title: "What matters",
                    body: "A strong center gives your pieces better squares and limits the opponent.",
                    variationRank: nil
                ),
                CoachReplySection(
                    kind: .variation,
                    title: "See it on the board",
                    body: "Step through Stockfish’s principal continuation.",
                    variationRank: 1
                ),
            ]
        )
    }
}

private struct VisualTestKeychain: KeychainStoring {
    func read(account: String) throws -> String? { "placeholder-key" }
    func save(_ value: String, account: String) throws {}
    func delete(account: String) throws {}
}
