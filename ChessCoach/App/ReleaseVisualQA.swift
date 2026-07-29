import AppKit
import Darwin
import QuartzCore
import SwiftData
import SwiftUI

/// A deterministic, exact-app visual acceptance mode used by the release gate.
///
/// The release executable accepts:
///
///     ChessCoach --visual-qa \
///       --output-directory=/absolute/path \
///       --scenario=fresh-default-dark
///
/// After installation, the release gate also invokes:
///
///     ChessCoach --installed-visual-qa \
///       --output-directory=/absolute/path \
///       --scenario=installed-default-dark
///
/// Both modes present the production `WindowGroup`, `RootView`, model, and
/// inspector. Candidate scenarios use isolated preferences. The installed
/// scenario deliberately uses `UserDefaults.standard`, including AppKit's real
/// restored window/layout preferences, while keeping game data and credentials
/// isolated. Each invocation captures the complete composited window, writes a
/// PNG and JSON sidecar, then exits.
struct ReleaseVisualQAConfiguration {
    enum Mode: Equatable {
        case candidate
        case installed
    }

    enum Scenario: String, CaseIterable {
        case freshDefaultDark = "fresh-default-dark"
        case freshCompactDark = "fresh-compact-dark"
        case freshDefaultLight = "fresh-default-light"
        case sidebarCollapsedDefaultDark =
            "sidebar-collapsed-default-dark"
        case lessonDefaultDark = "lesson-default-dark"
        case lessonClockedDefaultDark = "lesson-clocked-default-dark"
        case completedDefaultDark = "completed-default-dark"
        case missingInferenceKeyDefaultLight =
            "missing-inference-key-default-light"
        case inferenceSettingsDefaultLight =
            "inference-settings-default-light"
        case installedDefaultDark = "installed-default-dark"

        var windowSize: CGSize {
            switch self {
            case .freshCompactDark:
                CGSize(width: 980, height: 760)
            default:
                CGSize(width: 1_420, height: 900)
            }
        }

        var colorScheme: ColorScheme {
            switch self {
            case .freshDefaultLight,
                 .missingInferenceKeyDefaultLight,
                 .inferenceSettingsDefaultLight:
                .light
            default:
                .dark
            }
        }
    }

    let mode: Mode
    let scenario: Scenario
    let outputDirectory: URL
    private let isolationIdentifier = UUID().uuidString

    static var isRequested: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--visual-qa") ||
            arguments.contains("--installed-visual-qa")
    }

    static let current: ReleaseVisualQAConfiguration? = {
        guard isRequested else { return nil }
        do {
            return try parse(arguments: ProcessInfo.processInfo.arguments)
        } catch {
            writeError("Chess Coach visual QA: \(error.localizedDescription)\n")
            exit(EX_USAGE)
        }
    }()

    func makeIsolatedDefaults() -> UserDefaults {
        let suiteName = "com.dburkhardt.chesscoach.visual-qa.\(isolationIdentifier)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Self.writeError(
                "Chess Coach visual QA: unable to create isolated preferences.\n"
            )
            exit(EXIT_FAILURE)
        }
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(true, forKey: "coach.inspector.isPresented")
        defaults.set("Merida", forKey: "chessboard.pieceStyle")
        defaults.set(true, forKey: "chessboard.showCoordinates")
        defaults.set(true, forKey: "chessboard.showLegalMoves")
        defaults.set(false, forKey: "coaching.defaultBlunderGuard")
        if scenario == .sidebarCollapsedDefaultDark ||
            scenario == .freshCompactDark {
            defaults.set(
                "collapsed",
                forKey: "layout.navigationSidebar.visibilityLaunchOverride"
            )
        } else {
            defaults.set(
                "expanded",
                forKey: "layout.navigationSidebar.visibilityLaunchOverride"
            )
        }
        return defaults
    }

    var appDefaults: UserDefaults {
        switch mode {
        case .candidate:
            makeIsolatedDefaults()
        case .installed:
            // This is the real preference domain that owns AppKit window
            // restoration and the user's board/inspector settings. The visual
            // runner still uses in-memory game data and credential storage.
            .standard
        }
    }

    var captureKind: String {
        switch mode {
        case .candidate:
            "whole-window"
        case .installed:
            "installed-whole-window"
        }
    }

    /// Keep visual-QA inference configuration independent from both the
    /// user's persistent settings and AppKit's launch argument domain. The
    /// latter participates in normal scene creation and must not be replaced.
    @MainActor
    func makeInferenceDefaults() -> UserDefaults {
        let suiteName =
            "com.dburkhardt.chesscoach.visual-qa.inference.\(isolationIdentifier)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Self.writeError(
                "Chess Coach visual QA: unable to isolate inference preferences.\n"
            )
            exit(EXIT_FAILURE)
        }
        defaults.removePersistentDomain(forName: suiteName)
        defaults.set(
            InferenceAPIMode.automatic.rawValue,
            forKey: "ai.apiMode"
        )
        defaults.set("visual-qa-model", forKey: "ai.modelID")
        switch scenario {
        case .missingInferenceKeyDefaultLight,
             .inferenceSettingsDefaultLight:
            // These scenarios deliberately exercise the public missing-key
            // configuration flow without touching real credential storage.
            defaults.set(
                InferenceProviderKind.openAI.rawValue,
                forKey: "ai.provider"
            )
        default:
            // Other release scenes remain keyless and fail fast on a local
            // closed port, so visual QA never reaches a real provider.
            defaults.set(
                InferenceProviderKind.customOpenAICompatible.rawValue,
                forKey: "ai.provider"
            )
            defaults.set(
                "http://127.0.0.1:9",
                forKey: "ai.customEndpoint"
            )
        }
        return defaults
    }

    func makeCredentialStore() -> any KeychainStoring {
        ReleaseVisualQACredentialStore()
    }

    private static func parse(
        arguments: [String]
    ) throws -> ReleaseVisualQAConfiguration {
        let candidateRequested = arguments.contains("--visual-qa")
        let installedRequested = arguments.contains("--installed-visual-qa")
        guard candidateRequested != installedRequested else {
            throw ReleaseVisualQAError.conflictingModes
        }
        guard let outputPath = value(
            for: "--output-directory",
            in: arguments
        ), !outputPath.isEmpty else {
            throw ReleaseVisualQAError.missingArgument("--output-directory")
        }
        guard outputPath.hasPrefix("/") else {
            throw ReleaseVisualQAError.outputDirectoryMustBeAbsolute
        }
        guard let scenarioName = value(for: "--scenario", in: arguments),
              let scenario = Scenario(rawValue: scenarioName)
        else {
            throw ReleaseVisualQAError.invalidScenario
        }
        let mode: Mode = installedRequested ? .installed : .candidate
        switch (mode, scenario) {
        case (.candidate, .installedDefaultDark),
             (.installed, .freshDefaultDark),
             (.installed, .freshCompactDark),
             (.installed, .freshDefaultLight),
             (.installed, .sidebarCollapsedDefaultDark),
             (.installed, .lessonDefaultDark),
             (.installed, .lessonClockedDefaultDark),
             (.installed, .completedDefaultDark),
             (.installed, .missingInferenceKeyDefaultLight),
             (.installed, .inferenceSettingsDefaultLight):
            throw ReleaseVisualQAError.scenarioModeMismatch
        default:
            break
        }
        return ReleaseVisualQAConfiguration(
            mode: mode,
            scenario: scenario,
            outputDirectory: URL(
                fileURLWithPath: outputPath,
                isDirectory: true
            ).standardizedFileURL
        )
    }

    private static func value(
        for flag: String,
        in arguments: [String]
    ) -> String? {
        let prefix = "\(flag)="
        guard let argument = arguments.first(where: {
            $0.hasPrefix(prefix)
        }) else { return nil }
        return String(argument.dropFirst(prefix.count))
    }

    static func writeError(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        FileHandle.standardError.write(data)
    }
}

private struct ReleaseVisualQACredentialStore: KeychainStoring, Sendable {
    let persistenceAvailability: CredentialPersistenceAvailability =
        .sessionOnly

    func read(account: String) throws -> String? {
        nil
    }

    func save(_ value: String, account: String) throws {
        throw KeychainError.installedSignedAppRequired
    }

    func delete(account: String) throws {
        throw KeychainError.installedSignedAppRequired
    }
}

private enum ReleaseVisualQAError: LocalizedError {
    case missingArgument(String)
    case outputDirectoryMustBeAbsolute
    case invalidScenario
    case conflictingModes
    case scenarioModeMismatch
    case windowUnavailable
    case positionAnalysisTimedOut
    case lessonUnavailable
    case gameCompletionUnavailable
    case inferenceSettingsUnavailable
    case foregroundCaptureRequired
    case compositedWindowUnavailable
    case pngEncodingFailed

    var errorDescription: String? {
        switch self {
        case .missingArgument(let argument):
            "missing required argument \(argument)"
        case .outputDirectoryMustBeAbsolute:
            "--output-directory=<path> must use an absolute path"
        case .invalidScenario:
            "unknown or missing --scenario=<name>; expected one of " +
                ReleaseVisualQAConfiguration.Scenario.allCases
                .map(\.rawValue)
                .joined(separator: ", ")
        case .conflictingModes:
            "specify exactly one of --visual-qa or --installed-visual-qa"
        case .scenarioModeMismatch:
            "the selected visual-QA scenario does not match the requested mode"
        case .windowUnavailable:
            "the real application window did not become available"
        case .positionAnalysisTimedOut:
            "Stockfish did not make the fresh-position hint ready"
        case .lessonUnavailable:
            "the deterministic teaching moment did not open"
        case .gameCompletionUnavailable:
            "the completed-game presentation did not become ready"
        case .inferenceSettingsUnavailable:
            "the Inference destination did not become visible"
        case .foregroundCaptureRequired:
            "exact visual QA requires an unlocked foreground GUI session; " +
                "run release preparation interactively and keep Chess Coach " +
                "frontmost while each scenario is captured"
        case .compositedWindowUnavailable:
            "the WindowServer could not capture the composited native window"
        case .pngEncodingFailed:
            "AppKit could not encode the full-window PNG"
        }
    }
}

@MainActor
enum ReleaseVisualQARunner {
    private struct PendingSession {
        let configuration: ReleaseVisualQAConfiguration
        let model: AppModel
        let defaults: UserDefaults
    }

    private static var pendingSession: PendingSession?
    private static var task: Task<Void, Never>?
    private static var didLogSceneConstruction = false

    static func configure(
        configuration: ReleaseVisualQAConfiguration,
        model: AppModel,
        defaults: UserDefaults
    ) {
        pendingSession = PendingSession(
            configuration: configuration,
            model: model,
            defaults: defaults
        )
        ReleaseVisualQAConfiguration.writeError(
            "Chess Coach visual QA: application model configured.\n"
        )
    }

    static func noteSceneConstruction() {
        guard !didLogSceneConstruction else { return }
        didLogSceneConstruction = true
        ReleaseVisualQAConfiguration.writeError(
            "Chess Coach visual QA: WindowGroup scene constructed.\n"
        )
    }

    static func shippingRootDidAppear() {
        guard task == nil, let session = pendingSession else { return }
        task = Task {
            do {
                NSApplication.shared.activate()
                try await Task.sleep(for: .milliseconds(250))
                try await run(session: session)
                exit(EXIT_SUCCESS)
            } catch {
                ReleaseVisualQAConfiguration.writeError(
                    "Chess Coach visual QA: \(error.localizedDescription)\n"
                )
                exit(EXIT_FAILURE)
            }
        }
    }

    @MainActor
    private static func run(session: PendingSession) async throws {
        let configuration = session.configuration
        let model = session.model
        let window = try await applicationWindow()
        model.persistence.profile.onboardingComplete = true
        model.persistence.save()
        model.selection = .currentGame
        let timeControl: TimeControl =
            configuration.scenario == .lessonClockedDefaultDark
                ? .rapid10
                : .none
        model.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 3,
                timeControl: timeControl,
                blunderGuardEnabled: false
            )
        )

        switch configuration.scenario {
        case .freshDefaultDark,
             .freshCompactDark,
             .freshDefaultLight,
             .sidebarCollapsedDefaultDark,
             .missingInferenceKeyDefaultLight,
             .installedDefaultDark:
            guard await waitForPreparedPosition(model: model) else {
                throw ReleaseVisualQAError.positionAnalysisTimedOut
            }
        case .inferenceSettingsDefaultLight:
            guard await waitForPreparedPosition(model: model) else {
                throw ReleaseVisualQAError.positionAnalysisTimedOut
            }
            model.openInferenceSettings(focusTarget: .inferenceKey)
            guard await wait(
                timeout: .seconds(5),
                until: { model.selection == .settings }
            ) else {
                throw ReleaseVisualQAError.inferenceSettingsUnavailable
            }
        case .lessonDefaultDark, .lessonClockedDefaultDark:
            guard await waitForPreparedPosition(model: model) else {
                throw ReleaseVisualQAError.positionAnalysisTimedOut
            }
            model.coordinator.requestHint()
            guard await wait(
                timeout: .seconds(5),
                until: { model.coordinator.teachingMoment != nil }
            ) else {
                throw ReleaseVisualQAError.lessonUnavailable
            }
        case .completedDefaultDark:
            guard await waitForPreparedPosition(model: model) else {
                throw ReleaseVisualQAError.positionAnalysisTimedOut
            }
            model.coordinator.requestHint()
            guard await wait(
                timeout: .seconds(5),
                until: { model.coordinator.teachingMoment != nil }
            ) else {
                throw ReleaseVisualQAError.lessonUnavailable
            }
            model.coordinator.continueTeachingMoment()
            guard await wait(
                timeout: .seconds(5),
                until: {
                    model.coordinator.teachingMoment == nil &&
                        !model.coordinator.coachMessages.isEmpty
                }
            ) else {
                throw ReleaseVisualQAError.lessonUnavailable
            }
            model.coordinator.resign()
            guard await wait(
                timeout: .seconds(5),
                until: { model.coordinator.status.isFinished }
            ) else {
                throw ReleaseVisualQAError.gameCompletionUnavailable
            }
        }

        for otherWindow in NSApplication.shared.windows where
            otherWindow !== window &&
                !otherWindow.isSheet &&
                !(otherWindow is NSPanel) {
            otherWindow.orderOut(nil)
        }
        if configuration.mode == .candidate {
            let targetSize = configuration.scenario.windowSize
            let visibleFrame = NSScreen.main?.visibleFrame ?? window.frame
            let targetFrame = NSRect(
                x: visibleFrame.midX - targetSize.width / 2,
                y: visibleFrame.midY - targetSize.height / 2,
                width: targetSize.width,
                height: targetSize.height
            )
            window.setFrame(targetFrame, display: true)
        }
        window.appearance = NSAppearance(
            named: configuration.scenario.colorScheme == .dark
                ? .darkAqua
                : .aqua
        )
        // LaunchServices may start an automated candidate on the Space that
        // last contained this bundle identifier while leaving another app
        // frontmost. Put the exact shipping window on the user's active Space
        // before asking AppKit to activate it. The capture still refuses to
        // proceed until this real window is both active and key.
        var collectionBehavior = window.collectionBehavior
        collectionBehavior.remove(.canJoinAllSpaces)
        collectionBehavior.insert(.moveToActiveSpace)
        window.collectionBehavior = collectionBehavior
        window.orderFrontRegardless()
        _ = NSRunningApplication.current.activate(
            options: [.activateAllWindows]
        )
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)

        // Allow inspector sizing, vector assets, and the titlebar to finish
        // their real-window layout before freezing the release artifact.
        try await Task.sleep(for: .milliseconds(700))
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        if configuration.scenario == .inferenceSettingsDefaultLight {
            try exerciseInferenceKeyField(in: window)
            // A render invalidation spin blocks this main-actor suspension from
            // resuming. The external scenario timeout then fails the release.
            try await Task.sleep(for: .seconds(5))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        if !NSApplication.shared.isActive || !window.isKeyWindow {
            ReleaseVisualQAConfiguration.writeError(
                "Chess Coach visual QA: waiting for the real app window to " +
                    "become foreground and key; click Chess Coach now.\n"
            )
        }
        let becameForeground = await wait(timeout: .seconds(20)) {
            NSApplication.shared.isActive && window.isKeyWindow
        }
        guard becameForeground else {
            throw ReleaseVisualQAError.foregroundCaptureRequired
        }
        try capture(window: window, configuration: configuration)
    }

    @MainActor
    private static func waitForPreparedPosition(
        model: AppModel
    ) async -> Bool {
        await wait(timeout: .seconds(20)) {
            if case .ready = model.coordinator.coachPreparationState {
                return true
            }
            return false
        }
    }

    @MainActor
    private static func applicationWindow() async throws -> NSWindow {
        // Capture the window installed by the shipping SwiftUI `WindowGroup`.
        // Creating another NSWindow here would bypass the exact AppKit scene,
        // toolbar, inspector, and restored-geometry lifecycle this release
        // gate exists to validate.
        let becameAvailable = await wait(timeout: .seconds(5)) {
            shippingApplicationWindow() != nil
        }
        guard becameAvailable,
              let window = shippingApplicationWindow()
        else {
            logApplicationWindows()
            throw ReleaseVisualQAError.windowUnavailable
        }
        return window
    }

    @MainActor
    private static func shippingApplicationWindow() -> NSWindow? {
        NSApplication.shared.windows
            .filter { window in
                window.isVisible &&
                    !window.isSheet &&
                    !(window is NSPanel) &&
                    window.styleMask.contains(.titled) &&
                    window.contentViewController != nil &&
                    window.frame.width >= 960 &&
                    window.frame.height >= 650
            }
            .sorted { lhs, rhs in
                let lhsTitleMatch = lhs.title == "Chess Coach"
                let rhsTitleMatch = rhs.title == "Chess Coach"
                if lhsTitleMatch != rhsTitleMatch {
                    return lhsTitleMatch
                }
                return lhs.frame.width * lhs.frame.height >
                    rhs.frame.width * rhs.frame.height
            }
            .first
    }

    @MainActor
    private static func logApplicationWindows() {
        let descriptions = NSApplication.shared.windows.map { window in
            "#\(window.windowNumber) " +
                "title=\(String(reflecting: window.title)) " +
                "frame=\(NSStringFromRect(window.frame)) " +
                "visible=\(window.isVisible) " +
                "sheet=\(window.isSheet) " +
                "panel=\(window is NSPanel) " +
                "titled=\(window.styleMask.contains(.titled))"
        }
        ReleaseVisualQAConfiguration.writeError(
            "Chess Coach visual QA: available application windows:\n" +
                (descriptions.isEmpty
                    ? "  (none)\n"
                    : descriptions.map { "  \($0)\n" }.joined())
        )
    }

    @MainActor
    private static func wait(
        timeout: Duration,
        until condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    @MainActor
    private static func exerciseInferenceKeyField(
        in window: NSWindow
    ) throws {
        guard let contentView = window.contentView,
              let field = firstSecureTextField(in: contentView)
        else {
            throw ReleaseVisualQAError.inferenceSettingsUnavailable
        }

        let location = field.convert(
            NSPoint(x: field.bounds.midX, y: field.bounds.midY),
            to: nil
        )
        guard let mouseDown = NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ), let mouseUp = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime + 0.01,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 2,
            clickCount: 1,
            pressure: 0
        ) else {
            throw ReleaseVisualQAError.inferenceSettingsUnavailable
        }

        // NSTextField tracks the mouse in a nested AppKit run loop. Queue the
        // matching mouse-up first, then deliver the down event synchronously,
        // reproducing the real pointer/focus path without UI-test privileges.
        NSApplication.shared.postEvent(mouseUp, atStart: false)
        window.sendEvent(mouseDown)
    }

    private static func firstSecureTextField(
        in view: NSView
    ) -> NSSecureTextField? {
        if let field = view as? NSSecureTextField, !field.isHidden {
            return field
        }
        for subview in view.subviews {
            if let match = firstSecureTextField(in: subview) {
                return match
            }
        }
        return nil
    }

    @MainActor
    private static func capture(
        window: NSWindow,
        configuration: ReleaseVisualQAConfiguration
    ) throws {
        window.displayIfNeeded()
        window.contentView?.displayIfNeeded()
        CATransaction.flush()
        ReleaseVisualQAConfiguration.writeError(
            "Chess Coach visual QA: capturing window " +
                "\(window.windowNumber), frame \(NSStringFromRect(window.frame)), " +
                "visible \(window.isVisible), key \(window.isKeyWindow).\n"
        )
        // Capturing an NSHostingView through cacheDisplay omits SwiftUI's
        // separately composited inspector and material layers. Capture this
        // app's own WindowServer surface instead so the release artifact is
        // the same whole window a person sees. Dynamic lookup keeps this
        // self-window capture available on current macOS without linking the
        // screen-capture-obsoleted API into ordinary app execution.
        typealias CreateWindowImage = @convention(c) (
            CGRect,
            CGWindowListOption,
            CGWindowID,
            CGWindowImageOption
        ) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(
            UnsafeMutableRawPointer(bitPattern: -2),
            "CGWindowListCreateImage"
        ) else {
            throw ReleaseVisualQAError.compositedWindowUnavailable
        }
        let createWindowImage = unsafeBitCast(
            symbol,
            to: CreateWindowImage.self
        )
        guard let unmanagedImage = createWindowImage(
            .null,
            [.optionIncludingWindow],
            CGWindowID(window.windowNumber),
            [.bestResolution, .boundsIgnoreFraming]
        ) else {
            throw ReleaseVisualQAError.compositedWindowUnavailable
        }
        let bitmap = NSBitmapImageRep(
            cgImage: unmanagedImage.takeRetainedValue()
        )
        guard let png = bitmap.representation(
            using: .png,
            properties: [:]
        ) else {
            throw ReleaseVisualQAError.pngEncodingFailed
        }

        try FileManager.default.createDirectory(
            at: configuration.outputDirectory,
            withIntermediateDirectories: true
        )
        let imageName = "\(configuration.scenario.rawValue).png"
        let imageURL = configuration.outputDirectory
            .appendingPathComponent(imageName)
        try png.write(to: imageURL, options: .atomic)

        let bundle = Bundle.main
        let metadata = ReleaseVisualQAMetadata(
            scenario: configuration.scenario.rawValue,
            // Candidate and installed proof are deliberately distinct release
            // artifacts even though both capture the shipping WindowGroup.
            captureKind: configuration.captureKind,
            image: imageName,
            bundleID: bundle.bundleIdentifier ?? "",
            appVersion: bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "",
            appBuild: bundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "",
            pixelWidth: bitmap.pixelsWide,
            pixelHeight: bitmap.pixelsHigh
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        let metadataURL = configuration.outputDirectory
            .appendingPathComponent(
                "\(configuration.scenario.rawValue).json"
            )
        try data.write(to: metadataURL, options: .atomic)
    }
}

private struct ReleaseVisualQAMetadata: Encodable {
    let scenario: String
    let captureKind: String
    let image: String
    let bundleID: String
    let appVersion: String
    let appBuild: String
    let pixelWidth: Int
    let pixelHeight: Int
}
