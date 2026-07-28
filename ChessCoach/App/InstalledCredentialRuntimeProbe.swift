import Darwin
import Foundation

enum InstalledCredentialRuntimeProbePhase: String, Equatable, Sendable {
    case seed
    case verifyAndDelete = "verify-and-delete"
    case delete
}

struct InstalledCredentialRuntimeProbeRequest: Equatable, Sendable {
    let phase: InstalledCredentialRuntimeProbePhase
    let identifier: UUID

    var account: String {
        "release-runtime-qa.\(identifier.uuidString.lowercased())"
    }

    fileprivate var expectedValue: String {
        "ChessCoachReleaseRuntimeQA/v1/\(identifier.uuidString.lowercased())"
    }
}

enum InstalledCredentialRuntimeProbeError: LocalizedError, Equatable {
    case duplicateOption(String)
    case invalidPhase
    case invalidIdentifier
    case missingPhase
    case missingIdentifier
    case persistentStorageUnavailable
    case recordAlreadyExists
    case recordMissingOrChanged
    case recordWasNotDeleted

    var errorDescription: String? {
        switch self {
        case .duplicateOption(let option):
            "Duplicate runtime credential QA option: \(option)."
        case .invalidPhase:
            "Invalid runtime credential QA phase."
        case .invalidIdentifier:
            "Invalid runtime credential QA identifier."
        case .missingPhase:
            "Runtime credential QA phase is missing."
        case .missingIdentifier:
            "Runtime credential QA identifier is missing."
        case .persistentStorageUnavailable:
            "Persistent Keychain access is unavailable to this process."
        case .recordAlreadyExists:
            "The disposable runtime credential record already exists."
        case .recordMissingOrChanged:
            "The disposable runtime credential record is missing or changed."
        case .recordWasNotDeleted:
            "The disposable runtime credential record was not deleted."
        }
    }
}

/// An installed-artifact-only release probe for persistent Keychain behavior.
///
/// The probe deliberately uses a service and UUID-derived account that can
/// never overlap with an inference provider credential. Release QA invokes the
/// exact installed executable once to seed the record and again to read and
/// delete it, proving access across fresh processes without exposing or
/// modifying a user's inference key.
enum InstalledCredentialRuntimeProbe {
    static let service =
        "com.dburkhardt.chesscoach.release-runtime-qa.v1"
    static let itemLabel = "Chess Coach release credential QA"
    static let itemDescription =
        "Disposable release verification record; contains no user credential"

    private static let phasePrefix = "--credential-runtime-qa="
    private static let identifierPrefix = "--credential-runtime-qa-id="

    static func makeStore() -> KeychainStore {
        KeychainStore(
            service: service,
            itemLabel: itemLabel,
            itemDescription: itemDescription
        )
    }

    static func parse(
        arguments: [String]
    ) throws -> InstalledCredentialRuntimeProbeRequest? {
        let phaseValues = arguments.compactMap {
            $0.hasPrefix(phasePrefix)
                ? String($0.dropFirst(phasePrefix.count))
                : nil
        }
        let identifierValues = arguments.compactMap {
            $0.hasPrefix(identifierPrefix)
                ? String($0.dropFirst(identifierPrefix.count))
                : nil
        }

        guard !phaseValues.isEmpty || !identifierValues.isEmpty else {
            return nil
        }
        guard phaseValues.count <= 1 else {
            throw InstalledCredentialRuntimeProbeError.duplicateOption(
                "--credential-runtime-qa"
            )
        }
        guard identifierValues.count <= 1 else {
            throw InstalledCredentialRuntimeProbeError.duplicateOption(
                "--credential-runtime-qa-id"
            )
        }
        guard let phaseValue = phaseValues.first else {
            throw InstalledCredentialRuntimeProbeError.missingPhase
        }
        guard let phase = InstalledCredentialRuntimeProbePhase(
            rawValue: phaseValue
        ) else {
            throw InstalledCredentialRuntimeProbeError.invalidPhase
        }
        guard let identifierValue = identifierValues.first else {
            throw InstalledCredentialRuntimeProbeError.missingIdentifier
        }
        guard let identifier = UUID(uuidString: identifierValue) else {
            throw InstalledCredentialRuntimeProbeError.invalidIdentifier
        }

        return InstalledCredentialRuntimeProbeRequest(
            phase: phase,
            identifier: identifier
        )
    }

    static func perform(
        _ request: InstalledCredentialRuntimeProbeRequest,
        store: any KeychainStoring
    ) throws {
        guard store.persistenceAvailability == .persistent else {
            throw InstalledCredentialRuntimeProbeError
                .persistentStorageUnavailable
        }

        switch request.phase {
        case .seed:
            guard try store.read(account: request.account) == nil else {
                throw InstalledCredentialRuntimeProbeError.recordAlreadyExists
            }
            do {
                try store.save(
                    request.expectedValue,
                    account: request.account
                )
                guard try store.read(account: request.account)
                    == request.expectedValue
                else {
                    throw InstalledCredentialRuntimeProbeError
                        .recordMissingOrChanged
                }
            } catch {
                try? store.delete(account: request.account)
                throw error
            }

        case .verifyAndDelete:
            guard try store.read(account: request.account)
                == request.expectedValue
            else {
                try? store.delete(account: request.account)
                throw InstalledCredentialRuntimeProbeError
                    .recordMissingOrChanged
            }
            try store.delete(account: request.account)
            guard try store.read(account: request.account) == nil else {
                throw InstalledCredentialRuntimeProbeError.recordWasNotDeleted
            }

        case .delete:
            try store.delete(account: request.account)
            guard try store.read(account: request.account) == nil else {
                throw InstalledCredentialRuntimeProbeError.recordWasNotDeleted
            }
        }
    }

    static func runIfRequested(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        let request: InstalledCredentialRuntimeProbeRequest
        do {
            guard let parsed = try parse(arguments: arguments) else {
                return
            }
            request = parsed
        } catch {
            writeError(
                "Chess Coach credential runtime QA: "
                    + "\(error.localizedDescription)\n"
            )
            exit(EX_USAGE)
        }

        do {
            let store = makeStore()
            try perform(request, store: store)
            writeOutput(
                "credential-runtime-qa \(request.phase.rawValue)-ok\n"
            )
            exit(EXIT_SUCCESS)
        } catch {
            writeError(
                "Chess Coach credential runtime QA failed: "
                    + "\(error.localizedDescription)\n"
            )
            exit(EXIT_FAILURE)
        }
    }

    private static func writeOutput(_ message: String) {
        FileHandle.standardOutput.write(Data(message.utf8))
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}
