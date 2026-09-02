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
/// Release preparation normally captures every candidate scenario in one
/// foreground session:
///
///     ChessCoach --visual-qa \
///       --output-directory=/absolute/path \
///       --scenario-sequence=fresh-default-dark,fresh-compact-dark,...
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
/// PNG and JSON sidecar for every requested scenario, then exits.
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
        case sidebarRestoredExpandedDefaultLight =
            "sidebar-restored-expanded-default-light"
        case sidebarMinimumWidthDefaultLight =
            "sidebar-minimum-width-default-light"
        case sidebarMaximumWidthDefaultLight =
            "sidebar-maximum-width-default-light"
        case sidebarInactiveSelectionDefaultLight =
            "sidebar-inactive-selection-default-light"
        case sidebarInactiveSelectionDefaultDark =
            "sidebar-inactive-selection-default-dark"
        case lessonDefaultDark = "lesson-default-dark"
        case lessonClockedDefaultDark = "lesson-clocked-default-dark"
        case completedDefaultDark = "completed-default-dark"
        case missingInferenceKeyDefaultLight =
            "missing-inference-key-default-light"
        case missingInferenceKeyMinimumInspectorLight =
            "missing-inference-key-minimum-inspector-light"
        case missingInferenceKeyMinimumInspectorLargeTextLight =
            "missing-inference-key-minimum-inspector-large-text-light"
        case missingInferenceKeyMaximumInspectorLight =
            "missing-inference-key-maximum-inspector-light"
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
                 .sidebarRestoredExpandedDefaultLight,
                 .sidebarMinimumWidthDefaultLight,
                 .sidebarMaximumWidthDefaultLight,
                 .sidebarInactiveSelectionDefaultLight,
                 .missingInferenceKeyDefaultLight,
                 .missingInferenceKeyMinimumInspectorLight,
                 .missingInferenceKeyMinimumInspectorLargeTextLight,
                 .missingInferenceKeyMaximumInspectorLight,
                 .inferenceSettingsDefaultLight:
                .light
            default:
                .dark
            }
        }

        var expectsExpandedNavigation: Bool {
            switch self {
            case .freshCompactDark, .sidebarCollapsedDefaultDark:
                false
            default:
                true
            }
        }

        var requestedNavigationWidth: CGFloat? {
            switch self {
            case .sidebarMinimumWidthDefaultLight:
                AppNavigationSidebarMetrics.minimumWidth
            case .sidebarMaximumWidthDefaultLight:
                AppNavigationSidebarMetrics.maximumWidth
            default:
                nil
            }
        }

        var requestedInspectorWidth: CGFloat? {
            switch self {
            case .missingInferenceKeyMinimumInspectorLight:
                300
            case .missingInferenceKeyMinimumInspectorLargeTextLight:
                300
            case .missingInferenceKeyMaximumInspectorLight:
                460
            default:
                nil
            }
        }

        var exercisesMissingInferenceConfiguration: Bool {
            switch self {
            case .missingInferenceKeyDefaultLight,
                 .missingInferenceKeyMinimumInspectorLight,
                 .missingInferenceKeyMinimumInspectorLargeTextLight,
                 .missingInferenceKeyMaximumInspectorLight,
                 .inferenceSettingsDefaultLight:
                true
            default:
                false
            }
        }

        var usesInactiveNavigationSelection: Bool {
            switch self {
            case .sidebarInactiveSelectionDefaultLight,
                 .sidebarInactiveSelectionDefaultDark:
                true
            default:
                false
            }
        }

        var usesLargeText: Bool {
            self == .missingInferenceKeyMinimumInspectorLargeTextLight
        }

        func applyCandidateViewOverrides(to defaults: UserDefaults) {
            defaults.set(
                Double(
                    requestedNavigationWidth ??
                        AppNavigationSidebarMetrics.idealWidth
                ),
                forKey: ReleaseVisualQAViewOverrides.navigationWidthKey
            )
            defaults.set(
                Double(
                    requestedInspectorWidth ??
                        CoachInspectorMetrics.idealWidth
                ),
                forKey: ReleaseVisualQAViewOverrides.inspectorWidthKey
            )
        }
    }

    let mode: Mode
    let scenarios: [Scenario]
    let outputDirectory: URL
    private let isolationIdentifier = UUID().uuidString

    /// Scene construction needs one deterministic initial size and appearance.
    /// The runner mutates the real shipping window for subsequent scenarios.
    var scenario: Scenario {
        guard let scenario = scenarios.first else {
            preconditionFailure("Visual QA requires at least one scenario.")
        }
        return scenario
    }

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
        // Seed the first scenario before SwiftUI constructs the shipping
        // WindowGroup. On current macOS, changing exact NavigationSplitView
        // and inspector constraints only after their native split views exist
        // does not reliably resize the first rendered layout.
        scenario.applyCandidateViewOverrides(to: defaults)
        defaults.set(
            scenario.expectsExpandedNavigation,
            forKey: ReleaseVisualQAViewOverrides.navigationExpandedKey
        )
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
             .missingInferenceKeyMinimumInspectorLight,
             .missingInferenceKeyMinimumInspectorLargeTextLight,
             .missingInferenceKeyMaximumInspectorLight,
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
        let scenarioNames: [String]
        if let sequence = value(for: "--scenario-sequence", in: arguments) {
            guard value(for: "--scenario", in: arguments) == nil else {
                throw ReleaseVisualQAError.conflictingScenarioArguments
            }
            scenarioNames = sequence
                .split(separator: ",")
                .map(String.init)
        } else if let scenarioName = value(
            for: "--scenario",
            in: arguments
        ) {
            scenarioNames = [scenarioName]
        } else {
            throw ReleaseVisualQAError.invalidScenario
        }
        let scenarios = scenarioNames.compactMap(Scenario.init(rawValue:))
        guard !scenarios.isEmpty,
              scenarios.count == scenarioNames.count,
              Set(scenarios.map(\.rawValue)).count == scenarios.count
        else {
            throw ReleaseVisualQAError.invalidScenario
        }
        let mode: Mode = installedRequested ? .installed : .candidate
        for scenario in scenarios {
            switch (mode, scenario) {
            case (.candidate, .installedDefaultDark),
                 (.installed, .freshDefaultDark),
                 (.installed, .freshCompactDark),
                 (.installed, .freshDefaultLight),
                 (.installed, .sidebarCollapsedDefaultDark),
                 (.installed, .sidebarRestoredExpandedDefaultLight),
                 (.installed, .sidebarMinimumWidthDefaultLight),
                 (.installed, .sidebarMaximumWidthDefaultLight),
                 (.installed, .sidebarInactiveSelectionDefaultLight),
                 (.installed, .sidebarInactiveSelectionDefaultDark),
                 (.installed, .lessonDefaultDark),
                 (.installed, .lessonClockedDefaultDark),
                 (.installed, .completedDefaultDark),
                 (.installed, .missingInferenceKeyDefaultLight),
                 (.installed, .missingInferenceKeyMinimumInspectorLight),
                 (.installed,
                    .missingInferenceKeyMinimumInspectorLargeTextLight),
                 (.installed, .missingInferenceKeyMaximumInspectorLight),
                 (.installed, .inferenceSettingsDefaultLight):
                throw ReleaseVisualQAError.scenarioModeMismatch
            default:
                break
            }
        }
        return ReleaseVisualQAConfiguration(
            mode: mode,
            scenarios: scenarios,
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

enum ReleaseVisualQAViewOverrides {
    static let inactiveNavigationSelectionKey =
        "release.visualQA.inactiveNavigationSelection"
    static let largeTextKey = "release.visualQA.largeText"
    static let navigationWidthKey = "release.visualQA.navigationWidth"
    static let inspectorWidthKey = "release.visualQA.inspectorWidth"
    static let navigationExpandedKey =
        "release.visualQA.navigationExpanded"
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
    case conflictingScenarioArguments
    case scenarioModeMismatch
    case windowUnavailable
    case positionAnalysisTimedOut
    case lessonUnavailable
    case gameCompletionUnavailable
    case inferenceSettingsUnavailable
    case foregroundCaptureRequired
    case compositedWindowUnavailable
    case pngEncodingFailed
    case splitViewUnavailable(String)
    case layoutProbeUnavailable(String)
    case invalidLayout([String])

    var errorDescription: String? {
        switch self {
        case .missingArgument(let argument):
            "missing required argument \(argument)"
        case .outputDirectoryMustBeAbsolute:
            "--output-directory=<path> must use an absolute path"
        case .invalidScenario:
            "unknown, duplicate, or missing visual-QA scenario; expected one of " +
                ReleaseVisualQAConfiguration.Scenario.allCases
                .map(\.rawValue)
                .joined(separator: ", ")
        case .conflictingModes:
            "specify exactly one of --visual-qa or --installed-visual-qa"
        case .conflictingScenarioArguments:
            "specify --scenario or --scenario-sequence, not both"
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
        case .splitViewUnavailable(let pane):
            "the shipping \(pane) split-view pane could not be resized"
        case .layoutProbeUnavailable(let name):
            "the required \(name) layout probe was unavailable"
        case .invalidLayout(let failures):
            "release layout validation failed: " +
                failures.joined(separator: "; ")
        }
    }
}

struct ReleaseVisualQARect: Codable, Equatable, Sendable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.width
        height = rect.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

struct ReleaseVisualQALayoutProbe: Codable, Equatable, Sendable {
    let name: String
    let owner: String
    let frame: ReleaseVisualQARect
}

struct ReleaseVisualQALayoutEvidence: Codable, Equatable, Sendable {
    let coordinateSpace: String
    let requestedNavigationWidth: Double?
    let requestedInspectorWidth: Double?
    let probes: [ReleaseVisualQALayoutProbe]
    let validation: String
}

enum ReleaseVisualQALayoutValidator {
    static let window = "window"
    static let navigation = "navigation"
    static let gameDetail = "game-detail"
    static let coachInspector = "coach-inspector"
    static let board = "board"
    static let moveHistory = "move-history"
    static let providerFooter = "provider-footer"
    static let configureInference = "configure-inference"

    static let navigationRows = [
        "navigation-newGame",
        "navigation-currentGame",
        "navigation-games",
        "navigation-progress",
        "navigation-settings",
    ]

    static func failures(
        probes: [ReleaseVisualQALayoutProbe],
        scenario: ReleaseVisualQAConfiguration.Scenario
    ) -> [String] {
        var failures: [String] = []
        var frames: [String: CGRect] = [:]

        for probe in probes {
            if frames[probe.name] != nil {
                failures.append("\(probe.name) probe is duplicated")
                continue
            }
            frames[probe.name] = probe.frame.cgRect
            let frame = probe.frame.cgRect
            if !frame.origin.x.isFinite ||
                !frame.origin.y.isFinite ||
                !frame.width.isFinite ||
                !frame.height.isFinite ||
                frame.width <= 0 ||
                frame.height <= 0 {
                failures.append("\(probe.name) has an invalid frame")
            }
        }

        let expectedOwners = [
            navigation: window,
            gameDetail: window,
            coachInspector: window,
            board: gameDetail,
            moveHistory: gameDetail,
            providerFooter: coachInspector,
            configureInference: providerFooter,
        ].merging(
            Dictionary(
                uniqueKeysWithValues: navigationRows.map {
                    ($0, navigation)
                }
            )
        ) { current, _ in current }
        for probe in probes {
            if let expectedOwner = expectedOwners[probe.name],
               probe.owner != expectedOwner {
                failures.append(
                    "\(probe.name) must be owned by " +
                        displayName(expectedOwner)
                )
            }
        }

        guard frames[window] != nil else {
            return failures + ["window probe is missing"]
        }

        for probe in probes where probe.name != window {
            guard !probe.owner.isEmpty else {
                failures.append("\(probe.name) has no layout owner")
                continue
            }
            guard let ownerFrame = frames[probe.owner] else {
                failures.append(
                    "\(probe.name) owner \(displayName(probe.owner)) " +
                        "probe is missing"
                )
                continue
            }
            if !contains(ownerFrame, probe.frame.cgRect, tolerance: 2) {
                failures.append(
                    "\(probe.name) extends outside " +
                        displayName(probe.owner)
                )
            }
        }

        if scenario.expectsExpandedNavigation {
            if let navigationFrame = frames[navigation] {
                for row in navigationRows {
                    guard frames[row] != nil else {
                        failures.append("\(row) probe is missing")
                        continue
                    }
                }
                if let requested = scenario.requestedNavigationWidth,
                   abs(navigationFrame.width - requested) > 8 {
                    failures.append(
                        "navigation width \(rounded(navigationFrame.width)) " +
                            "does not match requested \(rounded(requested))"
                    )
                }
            } else {
                failures.append("expanded navigation probe is missing")
            }
        }

        if scenario.exercisesMissingInferenceConfiguration {
            if scenario != .inferenceSettingsDefaultLight,
               (frames[providerFooter] == nil ||
                frames[configureInference] == nil) {
                failures.append("provider footer or action probe is missing")
            }
        }

        if scenario != .inferenceSettingsDefaultLight {
            if frames[gameDetail] == nil {
                failures.append("game-detail probe is missing")
            }
            if frames[board] == nil {
                failures.append("chess board probe is missing")
            }
            if frames[moveHistory] == nil {
                failures.append("move-history probe is missing")
            }
            if frames[coachInspector] == nil {
                failures.append("Coach inspector probe is missing")
            }
            if let navigationFrame = frames[navigation],
               let gameDetailFrame = frames[gameDetail],
               overlapsHorizontally(navigationFrame, gameDetailFrame) {
                failures.append("navigation overlaps game detail")
            }
            if let gameDetailFrame = frames[gameDetail],
               let inspectorFrame = frames[coachInspector],
               overlapsHorizontally(gameDetailFrame, inspectorFrame) {
                failures.append("game detail overlaps Coach inspector")
            }
            if let boardFrame = frames[board],
               let moveFrame = frames[moveHistory],
               boardFrame.intersects(moveFrame) {
                failures.append("chess board overlaps move history")
            }
        }

        if let requested = scenario.requestedInspectorWidth {
            if let inspectorFrame = frames[coachInspector] {
                if abs(inspectorFrame.width - requested) > 8 {
                    failures.append(
                        "Coach width \(rounded(inspectorFrame.width)) " +
                            "does not match requested \(rounded(requested))"
                    )
                }
            } else {
                failures.append("Coach inspector probe is missing")
            }
        }

        return failures
    }

    private static func displayName(_ name: String) -> String {
        switch name {
        case gameDetail:
            "game detail"
        case coachInspector:
            "Coach inspector"
        case providerFooter:
            "provider footer"
        default:
            name
        }
    }

    private static func contains(
        _ owner: CGRect,
        _ child: CGRect,
        tolerance: CGFloat
    ) -> Bool {
        owner.insetBy(dx: -tolerance, dy: -tolerance).contains(child)
    }

    private static func overlapsHorizontally(
        _ lhs: CGRect,
        _ rhs: CGRect
    ) -> Bool {
        lhs.maxX > rhs.minX + 2 && rhs.maxX > lhs.minX + 2
    }

    private static func rounded(_ value: CGFloat) -> String {
        String(format: "%.1f", value)
    }
}

@MainActor
private final class ReleaseVisualQAWeakProbe {
    weak var view: ReleaseVisualQAProbeView?

    init(_ view: ReleaseVisualQAProbeView) {
        self.view = view
    }
}

@MainActor
enum ReleaseVisualQAProbeRegistry {
    private static var probes: [String: [ReleaseVisualQAWeakProbe]] = [:]

    static func register(
        _ view: ReleaseVisualQAProbeView,
        name: String
    ) {
        var entries = probes[name, default: []]
        entries.removeAll {
            $0.view == nil || $0.view === view
        }
        entries.append(ReleaseVisualQAWeakProbe(view))
        probes[name] = entries
    }

    static func unregister(
        _ view: ReleaseVisualQAProbeView,
        name: String
    ) {
        guard var entries = probes[name] else { return }
        entries.removeAll {
            $0.view == nil || $0.view === view
        }
        if entries.isEmpty {
            probes.removeValue(forKey: name)
        } else {
            probes[name] = entries
        }
    }

    static func frame(
        named name: String,
        in window: NSWindow
    ) -> CGRect? {
        guard let view = probes[name]?
            .compactMap(\.view)
            .first(where: {
                $0.window === window &&
                    !$0.isHiddenOrHasHiddenAncestor &&
                    $0.bounds.width > 0 &&
                    $0.bounds.height > 0
            })
        else {
            return nil
        }
        let windowFrame = view.convert(view.bounds, to: nil)
        return window.convertToScreen(windowFrame)
    }
}

@MainActor
final class ReleaseVisualQAProbeView: NSView {
    var probeName: String

    init(probeName: String) {
        self.probeName = probeName
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            ReleaseVisualQAProbeRegistry.unregister(
                self,
                name: probeName
            )
        } else {
            ReleaseVisualQAProbeRegistry.register(
                self,
                name: probeName
            )
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

private struct ReleaseVisualQAProbeRepresentable: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> ReleaseVisualQAProbeView {
        ReleaseVisualQAProbeView(probeName: name)
    }

    func updateNSView(
        _ nsView: ReleaseVisualQAProbeView,
        context: Context
    ) {
        guard nsView.probeName != name else { return }
        ReleaseVisualQAProbeRegistry.unregister(
            nsView,
            name: nsView.probeName
        )
        nsView.probeName = name
        if nsView.window != nil {
            ReleaseVisualQAProbeRegistry.register(nsView, name: name)
        }
    }

    static func dismantleNSView(
        _ nsView: ReleaseVisualQAProbeView,
        coordinator: Void
    ) {
        ReleaseVisualQAProbeRegistry.unregister(
            nsView,
            name: nsView.probeName
        )
    }
}

extension View {
    @ViewBuilder
    func releaseVisualQAProbe(_ name: String) -> some View {
        if ReleaseVisualQAConfiguration.isRequested {
            background {
                ReleaseVisualQAProbeRepresentable(name: name)
                    .allowsHitTesting(false)
            }
        } else {
            self
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

    private struct InstalledPreferenceSnapshot {
        let navigationWasExpanded: Bool
        let inspectorPresented: Any?
        let inactiveNavigationSelection: Any?
        let largeText: Any?

        init(
            defaults: UserDefaults,
            navigationWasExpanded: Bool
        ) {
            self.navigationWasExpanded = navigationWasExpanded
            inspectorPresented = defaults.object(
                forKey: "coach.inspector.isPresented"
            )
            inactiveNavigationSelection = defaults.object(
                forKey:
                    ReleaseVisualQAViewOverrides
                    .inactiveNavigationSelectionKey
            )
            largeText = defaults.object(
                forKey: ReleaseVisualQAViewOverrides.largeTextKey
            )
        }
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

        for otherWindow in NSApplication.shared.windows where
            otherWindow !== window &&
                !otherWindow.isSheet &&
                !(otherWindow is NSPanel) {
            otherWindow.orderOut(nil)
        }

        setWindowPresentation(
            window,
            scenario: configuration.scenario,
            mode: configuration.mode
        )
        // LaunchServices may start an automated candidate on the Space that
        // last contained this bundle identifier while leaving another app
        // frontmost. Put the exact shipping window on the active Space, but
        // never force activation or steal focus. The capture waits passively
        // for one user click if LaunchServices did not foreground it.
        var collectionBehavior = window.collectionBehavior
        collectionBehavior.remove(.canJoinAllSpaces)
        collectionBehavior.insert(.moveToActiveSpace)
        window.collectionBehavior = collectionBehavior
        window.orderFront(nil)

        // Allow inspector sizing, vector assets, and the titlebar to finish
        // their real-window layout before asking for the single foreground
        // acquisition used by the complete candidate capture session.
        try await Task.sleep(for: .milliseconds(700))
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        if !NSApplication.shared.isActive || !window.isKeyWindow {
            ReleaseVisualQAConfiguration.writeError(
                "Chess Coach visual QA: waiting for the real app window to " +
                    "become foreground and key; click Chess Coach once to " +
                    "capture the complete scenario sequence.\n"
            )
        }
        let becameForeground = await wait(timeout: .seconds(60)) {
            NSApplication.shared.isActive && window.isKeyWindow
        }
        guard becameForeground else {
            throw ReleaseVisualQAError.foregroundCaptureRequired
        }

        let installedPreferences: InstalledPreferenceSnapshot? = {
            guard configuration.mode == .installed else { return nil }
            return InstalledPreferenceSnapshot(
                defaults: session.defaults,
                navigationWasExpanded: isNavigationExpanded(in: window)
            )
        }()
        if installedPreferences != nil {
            // Installed proof must include Coach, but the release gate must not
            // permanently change whether the user normally keeps it open.
            session.defaults.set(
                true,
                forKey: "coach.inspector.isPresented"
            )
        }

        do {
            for scenario in configuration.scenarios {
                ReleaseVisualQAConfiguration.writeError(
                    "Chess Coach visual QA: preparing \(scenario.rawValue).\n"
                )
                try await prepare(
                    scenario: scenario,
                    model: model,
                    window: window,
                    mode: configuration.mode,
                    defaults: session.defaults
                )
                guard NSApplication.shared.isActive, window.isKeyWindow else {
                    throw ReleaseVisualQAError.foregroundCaptureRequired
                }
                try capture(
                    window: window,
                    configuration: configuration,
                    scenario: scenario
                )
            }
        } catch {
            if let installedPreferences {
                try? await restoreInstalledPreferences(
                    installedPreferences,
                    defaults: session.defaults,
                    window: window
                )
            }
            throw error
        }

        if let installedPreferences {
            try await restoreInstalledPreferences(
                installedPreferences,
                defaults: session.defaults,
                window: window
            )
        }
    }

    @MainActor
    private static func restoreInstalledPreferences(
        _ snapshot: InstalledPreferenceSnapshot,
        defaults: UserDefaults,
        window: NSWindow
    ) async throws {
        restoreDefault(
            snapshot.inspectorPresented,
            key: "coach.inspector.isPresented",
            defaults: defaults
        )
        restoreDefault(
            snapshot.inactiveNavigationSelection,
            key:
                ReleaseVisualQAViewOverrides
                .inactiveNavigationSelectionKey,
            defaults: defaults
        )
        restoreDefault(
            snapshot.largeText,
            key: ReleaseVisualQAViewOverrides.largeTextKey,
            defaults: defaults
        )
        try await setNavigationVisibility(
            expanded: snapshot.navigationWasExpanded,
            window: window,
            cycleBeforeExpanding: false
        )
    }

    private static func restoreDefault(
        _ value: Any?,
        key: String,
        defaults: UserDefaults
    ) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    @MainActor
    private static func prepare(
        scenario: ReleaseVisualQAConfiguration.Scenario,
        model: AppModel,
        window: NSWindow,
        mode: ReleaseVisualQAConfiguration.Mode,
        defaults: UserDefaults
    ) async throws {
        defaults.set(
            scenario.usesInactiveNavigationSelection,
            forKey:
                ReleaseVisualQAViewOverrides
                .inactiveNavigationSelectionKey
        )
        defaults.set(
            scenario.usesLargeText,
            forKey: ReleaseVisualQAViewOverrides.largeTextKey
        )
        if mode == .candidate {
            scenario.applyCandidateViewOverrides(to: defaults)
        }
        setWindowPresentation(window, scenario: scenario, mode: mode)
        configureInference(for: scenario, model: model)
        model.selection = .currentGame
        model.coordinator.newGame(
            NewGameConfiguration(
                colorChoice: .white,
                difficulty: 3,
                timeControl: scenario == .lessonClockedDefaultDark
                    ? .rapid10
                    : .none,
                blunderGuardEnabled: false
            )
        )

        switch scenario {
        case .freshDefaultDark,
             .freshCompactDark,
             .freshDefaultLight,
             .sidebarCollapsedDefaultDark,
             .sidebarRestoredExpandedDefaultLight,
             .sidebarMinimumWidthDefaultLight,
             .sidebarMaximumWidthDefaultLight,
             .sidebarInactiveSelectionDefaultLight,
             .sidebarInactiveSelectionDefaultDark,
             .missingInferenceKeyDefaultLight,
             .missingInferenceKeyMinimumInspectorLight,
             .missingInferenceKeyMinimumInspectorLargeTextLight,
             .missingInferenceKeyMaximumInspectorLight,
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

        if mode == .candidate {
            try await setCandidateNavigationVisibility(
                expanded: scenario.expectsExpandedNavigation,
                window: window,
                defaults: defaults,
                cycleBeforeExpanding:
                    scenario == .sidebarRestoredExpandedDefaultLight
            )
        } else {
            try await setNavigationVisibility(
                expanded: scenario.expectsExpandedNavigation,
                window: window,
                cycleBeforeExpanding:
                    scenario == .sidebarRestoredExpandedDefaultLight
            )
        }

        // Candidate-only AppStorage overrides constrain the shipping
        // NavigationSplitView and inspector to exact widths without depending
        // on private AppKit backing-view classes. The accessibility frames
        // below prove that the real WindowGroup adopted those constraints.
        window.contentView?.layoutSubtreeIfNeeded()
        if mode == .candidate {
            try await waitForCandidateColumnWidths(
                scenario: scenario,
                in: window
            )
        }

        try await Task.sleep(for: .milliseconds(700))
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        if scenario == .inferenceSettingsDefaultLight {
            try exerciseInferenceKeyField(in: window)
            // A render invalidation spin blocks this main-actor suspension from
            // resuming. The external session timeout then fails the release.
            try await Task.sleep(for: .seconds(5))
            window.contentView?.layoutSubtreeIfNeeded()
        }
    }

    @MainActor
    private static func configureInference(
        for scenario: ReleaseVisualQAConfiguration.Scenario,
        model: AppModel
    ) {
        model.inferenceSettings.modelID = "visual-qa-model"
        if scenario.exercisesMissingInferenceConfiguration {
            model.inferenceSettings.provider = .openAI
        } else {
            model.inferenceSettings.customEndpoint = "http://127.0.0.1:9"
            model.inferenceSettings.provider = .customOpenAICompatible
        }
    }

    @MainActor
    private static func setWindowPresentation(
        _ window: NSWindow,
        scenario: ReleaseVisualQAConfiguration.Scenario,
        mode: ReleaseVisualQAConfiguration.Mode
    ) {
        if mode == .candidate {
            let targetSize = scenario.windowSize
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
            named: scenario.colorScheme == .dark ? .darkAqua : .aqua
        )
    }

    @MainActor
    private static func setNavigationVisibility(
        expanded: Bool,
        window: NSWindow,
        cycleBeforeExpanding: Bool
    ) async throws {
        window.contentView?.layoutSubtreeIfNeeded()
        if cycleBeforeExpanding, isNavigationExpanded(in: window) {
            try await toggleNavigationSidebar(in: window)
        }
        if isNavigationExpanded(in: window) != expanded {
            try await toggleNavigationSidebar(in: window)
        }
        guard isNavigationExpanded(in: window) == expanded else {
            throw ReleaseVisualQAError.layoutProbeUnavailable(
                expanded ? "expanded navigation" : "collapsed navigation"
            )
        }
    }

    @MainActor
    private static func setCandidateNavigationVisibility(
        expanded: Bool,
        window: NSWindow,
        defaults: UserDefaults,
        cycleBeforeExpanding: Bool
    ) async throws {
        if cycleBeforeExpanding {
            defaults.set(
                false,
                forKey: ReleaseVisualQAViewOverrides.navigationExpandedKey
            )
            guard await waitForNavigationVisibility(
                expanded: false,
                in: window
            ) else {
                throw ReleaseVisualQAError.splitViewUnavailable("navigation")
            }
        }

        defaults.set(
            expanded,
            forKey: ReleaseVisualQAViewOverrides.navigationExpandedKey
        )
        guard await waitForNavigationVisibility(
            expanded: expanded,
            in: window
        ) else {
            throw ReleaseVisualQAError.splitViewUnavailable("navigation")
        }
    }

    @MainActor
    private static func waitForNavigationVisibility(
        expanded: Bool,
        in window: NSWindow
    ) async -> Bool {
        await wait(timeout: .seconds(3)) {
            window.contentView?.layoutSubtreeIfNeeded()
            return isNavigationExpanded(in: window) == expanded
        }
    }

    @MainActor
    private static func toggleNavigationSidebar(
        in window: NSWindow
    ) async throws {
        window.makeFirstResponder(window.contentView)
        let priorState = isNavigationExpanded(in: window)
        let sent = NSApplication.shared.sendAction(
            #selector(NSSplitViewController.toggleSidebar(_:)),
            to: nil,
            from: nil
        )
        guard sent else {
            throw ReleaseVisualQAError.splitViewUnavailable(
                "navigation"
            )
        }
        let changed = await wait(timeout: .seconds(3)) {
            window.contentView?.layoutSubtreeIfNeeded()
            return isNavigationExpanded(in: window) != priorState
        }
        guard changed else {
            throw ReleaseVisualQAError.splitViewUnavailable(
                "navigation"
            )
        }
    }

    @MainActor
    private static func isNavigationExpanded(in window: NSWindow) -> Bool {
        let frame = navigationFrame(in: window)
        guard let frame,
              frame.width > 20,
              frame.height > 100
        else {
            return false
        }
        return window.frame.intersection(frame).width >= frame.width - 4
    }

    @MainActor
    private static func waitForCandidateColumnWidths(
        scenario: ReleaseVisualQAConfiguration.Scenario,
        in window: NSWindow
    ) async throws {
        let requestedNavigationWidth =
            scenario.requestedNavigationWidth ??
            AppNavigationSidebarMetrics.idealWidth
        let requestedInspectorWidth =
            scenario.requestedInspectorWidth ??
            CoachInspectorMetrics.idealWidth
        let adoptedWidths = await wait(timeout: .seconds(3)) {
            window.contentView?.layoutSubtreeIfNeeded()
            let inspectorWidth = inspectorFrame(in: window)?.width
            let inspectorMatches = inspectorWidth.map {
                abs($0 - requestedInspectorWidth) <= 8
            } ?? false
            guard inspectorMatches else { return false }
            guard scenario.expectsExpandedNavigation else { return true }
            let navigationWidth = navigationFrame(in: window)?.width
            return navigationWidth.map {
                abs($0 - requestedNavigationWidth) <= 8
            } ?? false
        }
        guard adoptedWidths else {
            throw ReleaseVisualQAError.layoutProbeUnavailable(
                "requested native column widths"
            )
        }
    }

    @MainActor
    private static func splitViewCandidates(
        in window: NSWindow
    ) -> [NSSplitView] {
        guard let contentView = window.contentView else { return [] }
        return allSubviews(in: contentView).compactMap { $0 as? NSSplitView }
    }

    private static func allSubviews(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { allSubviews(in: $0) }
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

    private struct AccessibilitySnapshot {
        let identifier: String?
        let label: String?
        let frame: CGRect
    }

    @MainActor
    private static func accessibilityFrame(
        identifier: String,
        in window: NSWindow
    ) -> CGRect? {
        accessibilitySnapshots(in: window)
            .filter { $0.identifier == identifier && isUsable($0.frame) }
            .max { lhs, rhs in
                lhs.frame.width * lhs.frame.height <
                    rhs.frame.width * rhs.frame.height
            }?
            .frame
    }

    @MainActor
    private static func accessibilityFrame(
        labelPrefix: String,
        in window: NSWindow
    ) -> CGRect? {
        accessibilitySnapshots(in: window)
            .filter {
                $0.label?.lowercased().hasPrefix(labelPrefix.lowercased()) ==
                    true && isUsable($0.frame)
            }
            .max { lhs, rhs in
                lhs.frame.width * lhs.frame.height <
                    rhs.frame.width * rhs.frame.height
            }?
            .frame
    }

    @MainActor
    private static func accessibilitySnapshots(
        in window: NSWindow
    ) -> [AccessibilitySnapshot] {
        guard let contentView = window.contentView else { return [] }
        var snapshots: [AccessibilitySnapshot] = []
        var visited: Set<ObjectIdentifier> = []

        func visit(_ value: Any) {
            guard let object = value as AnyObject? else { return }
            let identity = ObjectIdentifier(object)
            guard visited.insert(identity).inserted else { return }

            if let view = value as? NSView {
                snapshots.append(
                    AccessibilitySnapshot(
                        identifier: view.accessibilityIdentifier(),
                        label: view.accessibilityLabel(),
                        frame: view.accessibilityFrame()
                    )
                )
                for child in view.accessibilityChildren() ?? [] {
                    visit(child)
                }
                for subview in view.subviews {
                    visit(subview)
                }
                return
            }

            if let element = value as? NSAccessibilityElement {
                snapshots.append(
                    AccessibilitySnapshot(
                        identifier: element.accessibilityIdentifier(),
                        label: element.accessibilityLabel(),
                        frame: element.accessibilityFrame()
                    )
                )
                for child in element.accessibilityChildren() ?? [] {
                    visit(child)
                }
            }
        }

        visit(contentView)
        return snapshots
    }

    private static func isUsable(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite &&
            frame.origin.y.isFinite &&
            frame.width.isFinite &&
            frame.height.isFinite &&
            frame.width > 0 &&
            frame.height > 0
    }

    @MainActor
    private static func splitPaneFrame(
        edge: NSRectEdge,
        expectedWidth: ClosedRange<CGFloat>,
        in window: NSWindow
    ) -> CGRect? {
        let panes = splitViewCandidates(in: window)
            .filter { $0.isVertical && $0.subviews.count >= 2 }
            .flatMap { splitView -> [(CGRect, CGFloat, CGFloat)] in
                splitView.subviews.compactMap { pane in
                    guard expectedWidth.contains(pane.frame.width),
                          pane.frame.height > 500
                    else {
                        return nil
                    }
                    let touchesRequestedEdge: Bool
                    switch edge {
                    case .minX:
                        touchesRequestedEdge =
                            abs(pane.frame.minX - splitView.bounds.minX) <= 4
                    case .maxX:
                        touchesRequestedEdge =
                            abs(pane.frame.maxX - splitView.bounds.maxX) <= 4
                    default:
                        return nil
                    }
                    guard touchesRequestedEdge else { return nil }
                    let ideal: CGFloat = edge == .minX ? 220 : 360
                    let frameInWindow = pane.convert(pane.bounds, to: nil)
                    let frameOnScreen = window.convertToScreen(frameInWindow)
                    let windowEdgeDistance: CGFloat
                    switch edge {
                    case .minX:
                        windowEdgeDistance = abs(
                            frameOnScreen.minX - window.frame.minX
                        )
                    case .maxX:
                        windowEdgeDistance = abs(
                            frameOnScreen.maxX - window.frame.maxX
                        )
                    default:
                        return nil
                    }
                    // A shipping navigation or inspector pane reaches the
                    // corresponding outer edge of the real window. Nested
                    // vertical split views can contain similarly sized panes;
                    // rejecting those prevents a false "collapsed" reading.
                    guard windowEdgeDistance <= 12 else { return nil }
                    return (
                        frameOnScreen,
                        abs(pane.frame.width - ideal),
                        windowEdgeDistance
                    )
                }
            }
            .sorted {
                if $0.2 != $1.2 { return $0.2 < $1.2 }
                return $0.1 < $1.1
            }

        return panes.first?.0
    }

    @MainActor
    private static func navigationFrame(in window: NSWindow) -> CGRect? {
        firstPlausibleColumnFrame(
            [
                ReleaseVisualQAProbeRegistry.frame(
                    named: ReleaseVisualQALayoutValidator.navigation,
                    in: window
                ),
                accessibilityFrame(
                    identifier: "app-navigation-column",
                    in: window
                ),
                splitPaneFrame(
                    edge: .minX,
                    expectedWidth: 150...300,
                    in: window
                ),
            ],
            expectedWidth: 150...300
        )
    }

    @MainActor
    private static func inspectorFrame(in window: NSWindow) -> CGRect? {
        firstPlausibleColumnFrame(
            [
                ReleaseVisualQAProbeRegistry.frame(
                    named: ReleaseVisualQALayoutValidator.coachInspector,
                    in: window
                ),
                accessibilityFrame(
                    identifier: CoachInspectorMetrics.accessibilityIdentifier,
                    in: window
                ),
                splitPaneFrame(
                    edge: .maxX,
                    expectedWidth: 250...520,
                    in: window
                ),
            ],
            expectedWidth: 250...520
        )
    }

    private static func firstPlausibleColumnFrame(
        _ frames: [CGRect?],
        expectedWidth: ClosedRange<CGFloat>
    ) -> CGRect? {
        frames.compactMap { $0 }.first {
            expectedWidth.contains($0.width) && $0.height > 100
        }
    }

    @MainActor
    private static func gameDetailFrame(in window: NSWindow) -> CGRect? {
        if let accessibilityFrame = accessibilityFrame(
            identifier: "app-game-detail-column",
            in: window
        ) {
            return accessibilityFrame
        }

        // `NavigationSplitView` is nested inside the inspector split. The
        // detail pane is the smallest full-height wide pane; the larger
        // candidate is the outer main-content pane that still includes the
        // navigation column.
        let panes = splitViewCandidates(in: window)
            .filter { $0.isVertical && $0.subviews.count >= 2 }
            .flatMap(\.subviews)
            .filter {
                $0.frame.width >= 600 &&
                    $0.frame.width <= 1_200 &&
                    $0.frame.height > 500
            }
            .sorted { $0.frame.width < $1.frame.width }
        guard let pane = panes.first else { return nil }
        return window.convertToScreen(pane.convert(pane.bounds, to: nil))
    }

    @MainActor
    private static func layoutEvidence(
        window: NSWindow,
        scenario: ReleaseVisualQAConfiguration.Scenario
    ) throws -> ReleaseVisualQALayoutEvidence {
        var probes: [ReleaseVisualQALayoutProbe] = [
            ReleaseVisualQALayoutProbe(
                name: ReleaseVisualQALayoutValidator.window,
                owner: "",
                frame: ReleaseVisualQARect(window.frame)
            )
        ]

        func append(
            _ name: String,
            owner: String,
            frame: CGRect?
        ) {
            guard let frame, isUsable(frame) else { return }
            probes.append(
                ReleaseVisualQALayoutProbe(
                    name: name,
                    owner: owner,
                    frame: ReleaseVisualQARect(frame)
                )
            )
        }

        if scenario.expectsExpandedNavigation {
            append(
                ReleaseVisualQALayoutValidator.navigation,
                owner: ReleaseVisualQALayoutValidator.window,
                frame: navigationFrame(in: window)
            )
            for section in AppSection.allCases {
                let name = "navigation-\(section.rawValue)"
                append(
                    name,
                    owner: ReleaseVisualQALayoutValidator.navigation,
                    frame: ReleaseVisualQAProbeRegistry.frame(
                        named: name,
                        in: window
                    ) ?? accessibilityFrame(
                            identifier:
                                "app-navigation-\(section.rawValue)",
                            in: window
                        )
                )
            }
        }
        append(
            ReleaseVisualQALayoutValidator.gameDetail,
            owner: ReleaseVisualQALayoutValidator.window,
            frame: ReleaseVisualQAProbeRegistry.frame(
                named: ReleaseVisualQALayoutValidator.gameDetail,
                in: window
            ) ?? gameDetailFrame(in: window)
        )
        append(
            ReleaseVisualQALayoutValidator.coachInspector,
            owner: ReleaseVisualQALayoutValidator.window,
            frame: inspectorFrame(in: window)
        )
        append(
            ReleaseVisualQALayoutValidator.board,
            owner: ReleaseVisualQALayoutValidator.gameDetail,
            frame: ReleaseVisualQAProbeRegistry.frame(
                named: ReleaseVisualQALayoutValidator.board,
                in: window
            ) ?? accessibilityFrame(
                    labelPrefix: "Chess board",
                    in: window
                )
        )
        append(
            ReleaseVisualQALayoutValidator.moveHistory,
            owner: ReleaseVisualQALayoutValidator.gameDetail,
            frame: ReleaseVisualQAProbeRegistry.frame(
                named: ReleaseVisualQALayoutValidator.moveHistory,
                in: window
            ) ?? accessibilityFrame(
                    labelPrefix: "Move history",
                    in: window
                )
        )
        append(
            ReleaseVisualQALayoutValidator.providerFooter,
            owner: ReleaseVisualQALayoutValidator.coachInspector,
            frame: ReleaseVisualQAProbeRegistry.frame(
                named: ReleaseVisualQALayoutValidator.providerFooter,
                in: window
            ) ?? accessibilityFrame(
                    identifier: "coach-provider-setup",
                    in: window
                )
        )
        append(
            ReleaseVisualQALayoutValidator.configureInference,
            owner: ReleaseVisualQALayoutValidator.providerFooter,
            frame: ReleaseVisualQAProbeRegistry.frame(
                named: ReleaseVisualQALayoutValidator.configureInference,
                in: window
            ) ?? accessibilityFrame(
                    identifier: "configure-inference",
                    in: window
                )
        )

        let failures = ReleaseVisualQALayoutValidator.failures(
            probes: probes,
            scenario: scenario
        )
        guard failures.isEmpty else {
            throw ReleaseVisualQAError.invalidLayout(failures)
        }
        return ReleaseVisualQALayoutEvidence(
            coordinateSpace: "screen-points",
            requestedNavigationWidth:
                scenario.requestedNavigationWidth.map(Double.init),
            requestedInspectorWidth:
                scenario.requestedInspectorWidth.map(Double.init),
            probes: probes.sorted { $0.name < $1.name },
            validation: "passed"
        )
    }

    @MainActor
    private static func capture(
        window: NSWindow,
        configuration: ReleaseVisualQAConfiguration,
        scenario: ReleaseVisualQAConfiguration.Scenario
    ) throws {
        window.displayIfNeeded()
        window.contentView?.displayIfNeeded()
        CATransaction.flush()
        let layout = try layoutEvidence(window: window, scenario: scenario)
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
        let imageName = "\(scenario.rawValue).png"
        let imageURL = configuration.outputDirectory
            .appendingPathComponent(imageName)
        try png.write(to: imageURL, options: .atomic)

        let bundle = Bundle.main
        let metadata = ReleaseVisualQAMetadata(
            scenario: scenario.rawValue,
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
            pixelHeight: bitmap.pixelsHigh,
            layout: layout
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        let metadataURL = configuration.outputDirectory
            .appendingPathComponent(
                "\(scenario.rawValue).json"
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
    let layout: ReleaseVisualQALayoutEvidence
}
