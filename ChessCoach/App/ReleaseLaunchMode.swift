import AppKit
import Foundation

enum ReleaseArtifactStage: String, CaseIterable, Codable, Sendable {
    case built
    case captureFailed = "capture-failed"
    case captured
    case candidateApproved = "candidate-approved"
    case installedApproved = "installed-approved"
    case runtimeApproved = "runtime-approved"
    case published

    var isApprovedForNormalLaunch: Bool {
        switch self {
        case .runtimeApproved, .published:
            true
        default:
            false
        }
    }
}

enum ReleaseLaunchMode: Equatable, Sendable {
    case normal
    case visualQA
    case testHost
    case candidatePreview(ReleaseCandidateIdentity)
    case blockedCandidate

    static var current: ReleaseLaunchMode {
        classify(
            arguments: ProcessInfo.processInfo.arguments,
            bundlePath: Bundle.main.bundleURL.path,
            isUnitTestHost: isUnitTestHost
        )
    }

    static func classify(
        arguments: [String],
        bundlePath: String,
        isUnitTestHost: Bool = false
    ) -> ReleaseLaunchMode {
        if arguments.contains("--visual-qa") ||
            arguments.contains("--installed-visual-qa") {
            return .visualQA
        }
        if arguments.contains("--candidate-preview") {
            return .candidatePreview(
                ReleaseCandidateIdentity(arguments: arguments)
            )
        }
        if isUnitTestHost {
            return .testHost
        }
        guard isDevelopmentCandidatePath(bundlePath) else {
            return .normal
        }
        return .blockedCandidate
    }

    @MainActor
    static func enforceCandidateLaunchPolicy(_ mode: ReleaseLaunchMode) {
        guard mode == .blockedCandidate else { return }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Unapproved Chess Coach candidate"
        alert.informativeText = """
        This archived build has not passed visual and runtime acceptance. \
        Use scripts/open-candidate-preview.sh for an isolated, clearly \
        labeled preview, or scripts/open-approved-app.sh to open the last \
        accepted installation.
        """
        alert.addButton(withTitle: "Quit")
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
        exit(EX_CONFIG)
    }

    @MainActor
    static func failCandidatePreviewIsolation() -> Never {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Candidate preview could not be isolated"
        alert.informativeText = """
        Chess Coach refused to open this unapproved build because isolated \
        preferences could not be created. Your installed app and its data \
        were not used.
        """
        alert.addButton(withTitle: "Quit")
        NSApplication.shared.activate(ignoringOtherApps: true)
        alert.runModal()
        exit(EX_CONFIG)
    }

    private static func isDevelopmentCandidatePath(_ path: String) -> Bool {
        let normalized = URL(fileURLWithPath: path)
            .standardizedFileURL.path
        return normalized.contains("/dist/") ||
            normalized.contains(".xcarchive/Products/Applications/") ||
            normalized.contains("/DerivedData/")
    }

    private static var isUnitTestHost: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil ||
            environment["XCTestBundlePath"] != nil ||
            ProcessInfo.processInfo.arguments.contains {
                $0.hasSuffix(".xctest")
            }
    }
}

struct ReleaseCandidateIdentity: Equatable, Sendable {
    let commit: String
    let stage: ReleaseArtifactStage

    init(arguments: [String]) {
        let commitValue = Self.value(
            for: "--candidate-commit",
            in: arguments
        ) ?? "unknown"
        commit = String(commitValue.prefix(12))
        stage = Self.value(
            for: "--candidate-stage",
            in: arguments
        ).flatMap(ReleaseArtifactStage.init(rawValue:)) ?? .built
    }

    private static func value(
        for flag: String,
        in arguments: [String]
    ) -> String? {
        let inlinePrefix = "\(flag)="
        if let inline = arguments.first(where: {
            $0.hasPrefix(inlinePrefix)
        }) {
            return String(inline.dropFirst(inlinePrefix.count))
        }
        guard let index = arguments.firstIndex(of: flag),
              arguments.indices.contains(index + 1)
        else {
            return nil
        }
        return arguments[index + 1]
    }
}

final class CandidatePreviewCredentialStore: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    let persistenceAvailability: CredentialPersistenceAvailability =
        .sessionOnly

    func read(account: String) throws -> String? {
        lock.withLock { values[account] }
    }

    func save(_ value: String, account: String) throws {
        lock.withLock {
            values[account] = value
        }
    }

    func delete(account: String) throws {
        lock.withLock {
            values[account] = nil
        }
    }
}
