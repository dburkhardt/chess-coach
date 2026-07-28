import Foundation
import Testing
@testable import ChessCoach

@Suite(.serialized)
struct InstalledCredentialRuntimeProbeTests {
    @Test func parserRequiresOneValidPhaseAndIdentifier() throws {
        let identifier = try #require(
            UUID(uuidString: "6A77DD11-620F-4B9A-AEF8-31BC3858D776")
        )
        let parsed = try InstalledCredentialRuntimeProbe.parse(
            arguments: [
                "/Applications/Chess Coach.app/Contents/MacOS/ChessCoach",
                "--credential-runtime-qa=seed",
                "--credential-runtime-qa-id=\(identifier.uuidString)",
            ]
        )
        let request = try #require(parsed)

        #expect(request.phase == .seed)
        #expect(request.identifier == identifier)
        #expect(
            request.account
                == "release-runtime-qa."
                    + identifier.uuidString.lowercased()
        )
        #expect(
            request.account != InferenceProviderKind.openAI.rawValue
        )
        #expect(
            request.account
                != InferenceProviderKind.customOpenAICompatible.rawValue
        )
        #expect(
            InstalledCredentialRuntimeProbe.service
                != KeychainStore.productionService
        )
        #expect(
            !InstalledCredentialRuntimeProbe.itemLabel
                .localizedCaseInsensitiveContains("inference key")
        )
        #expect(
            InstalledCredentialRuntimeProbe.itemDescription
                .localizedCaseInsensitiveContains("disposable")
        )
        #expect(
            !InstalledCredentialRuntimeProbe.itemDescription
                .localizedCaseInsensitiveContains("inference key")
        )
        let probeStore = InstalledCredentialRuntimeProbe.makeStore()
        #expect(probeStore.service == InstalledCredentialRuntimeProbe.service)
        #expect(
            probeStore.itemLabel
                == InstalledCredentialRuntimeProbe.itemLabel
        )
        #expect(
            probeStore.itemDescription
                == InstalledCredentialRuntimeProbe.itemDescription
        )
        #expect(
            try InstalledCredentialRuntimeProbe.parse(
                arguments: ["/Applications/Chess Coach.app"]
            ) == nil
        )

        #expect(throws: InstalledCredentialRuntimeProbeError.missingIdentifier) {
            _ = try InstalledCredentialRuntimeProbe.parse(
                arguments: ["--credential-runtime-qa=seed"]
            )
        }
        #expect(throws: InstalledCredentialRuntimeProbeError.invalidPhase) {
            _ = try InstalledCredentialRuntimeProbe.parse(
                arguments: [
                    "--credential-runtime-qa=read",
                    "--credential-runtime-qa-id=\(identifier.uuidString)",
                ]
            )
        }
        #expect(throws: InstalledCredentialRuntimeProbeError.invalidIdentifier) {
            _ = try InstalledCredentialRuntimeProbe.parse(
                arguments: [
                    "--credential-runtime-qa=seed",
                    "--credential-runtime-qa-id=not-a-uuid",
                ]
            )
        }
    }

    @Test func disposableRecordSurvivesFreshStoreThenIsDeleted() throws {
        let backend = ProbeCredentialBackend()
        let identifier = UUID()
        let seedRequest = InstalledCredentialRuntimeProbeRequest(
            phase: .seed,
            identifier: identifier
        )
        let verifyRequest = InstalledCredentialRuntimeProbeRequest(
            phase: .verifyAndDelete,
            identifier: identifier
        )

        try InstalledCredentialRuntimeProbe.perform(
            seedRequest,
            store: ProbeCredentialStore(backend: backend)
        )
        #expect(backend.accounts == [seedRequest.account])

        // A new store value models the fresh installed-app process used by the
        // release script for the cross-launch read.
        try InstalledCredentialRuntimeProbe.perform(
            verifyRequest,
            store: ProbeCredentialStore(backend: backend)
        )
        #expect(backend.accounts.isEmpty)
        #expect(backend.readAccounts.allSatisfy { $0 == seedRequest.account })
        #expect(backend.savedAccounts == [seedRequest.account])
        #expect(backend.deletedAccounts == [seedRequest.account])
    }

    @Test func verificationRejectsMissingRecordAndCleanupIsIdempotent() throws {
        let backend = ProbeCredentialBackend()
        let identifier = UUID()
        let verifyRequest = InstalledCredentialRuntimeProbeRequest(
            phase: .verifyAndDelete,
            identifier: identifier
        )

        #expect(
            throws:
                InstalledCredentialRuntimeProbeError.recordMissingOrChanged
        ) {
            try InstalledCredentialRuntimeProbe.perform(
                verifyRequest,
                store: ProbeCredentialStore(backend: backend)
            )
        }

        try InstalledCredentialRuntimeProbe.perform(
            InstalledCredentialRuntimeProbeRequest(
                phase: .delete,
                identifier: identifier
            ),
            store: ProbeCredentialStore(backend: backend)
        )
        #expect(backend.accounts.isEmpty)
    }

    @Test func probeRefusesSessionOnlyCredentialStorage() {
        let request = InstalledCredentialRuntimeProbeRequest(
            phase: .seed,
            identifier: UUID()
        )
        #expect(
            throws:
                InstalledCredentialRuntimeProbeError
                    .persistentStorageUnavailable
        ) {
            try InstalledCredentialRuntimeProbe.perform(
                request,
                store: ProbeCredentialStore(
                    backend: ProbeCredentialBackend(),
                    persistenceAvailability: .sessionOnly
                )
            )
        }
    }
}

private final class ProbeCredentialBackend: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private(set) var readAccounts: [String] = []
    private(set) var savedAccounts: [String] = []
    private(set) var deletedAccounts: [String] = []

    var accounts: Set<String> {
        withLock { Set(values.keys) }
    }

    func read(account: String) -> String? {
        withLock {
            readAccounts.append(account)
            return values[account]
        }
    }

    func save(_ value: String, account: String) {
        withLock {
            savedAccounts.append(account)
            values[account] = value
        }
    }

    func delete(account: String) {
        withLock {
            deletedAccounts.append(account)
            values[account] = nil
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private struct ProbeCredentialStore: KeychainStoring {
    let backend: ProbeCredentialBackend
    let persistenceAvailability: CredentialPersistenceAvailability

    init(
        backend: ProbeCredentialBackend,
        persistenceAvailability: CredentialPersistenceAvailability = .persistent
    ) {
        self.backend = backend
        self.persistenceAvailability = persistenceAvailability
    }

    func read(account: String) throws -> String? {
        backend.read(account: account)
    }

    func save(_ value: String, account: String) throws {
        backend.save(value, account: account)
    }

    func delete(account: String) throws {
        backend.delete(account: account)
    }
}
