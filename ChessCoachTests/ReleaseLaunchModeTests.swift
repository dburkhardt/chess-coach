import Foundation
import Testing
@testable import ChessCoach

struct ReleaseLaunchModeTests {
    @Test func releaseArchiveRequiresExplicitPreview() {
        let mode = ReleaseLaunchMode.classify(
            arguments: ["ChessCoach"],
            bundlePath:
                "/repo/dist/ChessCoach.xcarchive/Products/Applications/ChessCoach.app"
        )
        #expect(mode == .blockedCandidate)

        #expect(
            ReleaseLaunchMode.classify(
                arguments: ["ChessCoach"],
                bundlePath: "/repo/dist/dmg-root/Chess Coach.app"
            ) == .blockedCandidate
        )
    }

    @Test func explicitCandidatePreviewCarriesSourceIdentity() {
        let mode = ReleaseLaunchMode.classify(
            arguments: [
                "ChessCoach",
                "--candidate-preview",
                "--candidate-commit=1234567890abcdef",
                "--candidate-stage=capture-failed",
            ],
            bundlePath:
                "/repo/dist/.candidates/123/abc/ChessCoach.app"
        )
        #expect(
            mode == .candidatePreview(
                ReleaseCandidateIdentity(
                    arguments: [
                        "--candidate-commit=1234567890abcdef",
                        "--candidate-stage=capture-failed",
                    ]
                )
            )
        )
    }

    @Test func visualQAIsAllowedFromAnArchive() {
        let mode = ReleaseLaunchMode.classify(
            arguments: ["ChessCoach", "--visual-qa"],
            bundlePath:
                "/repo/dist/.candidates/123/abc/ChessCoach.app"
        )
        #expect(mode == .visualQA)
    }

    @Test func directDevelopmentBuildsAreBlockedButTestHostsAreAllowed() {
        #expect(
            ReleaseLaunchMode.classify(
                arguments: ["ChessCoach"],
                bundlePath: "/tmp/DerivedData/ChessCoach.app",
                isUnitTestHost: false
            ) == .blockedCandidate
        )
        #expect(
            ReleaseLaunchMode.classify(
                arguments: ["ChessCoach"],
                bundlePath: "/tmp/DerivedData/ChessCoach.app",
                isUnitTestHost: true
            ) == .testHost
        )
        #expect(
            ReleaseLaunchMode.classify(
                arguments: ["ChessCoach"],
                bundlePath: "/Applications/Chess Coach.app"
            ) == .normal
        )
    }

    @Test func artifactStagesLockNormalLaunchUntilRuntimeApproval() {
        for stage in ReleaseArtifactStage.allCases {
            #expect(
                stage.isApprovedForNormalLaunch ==
                    (stage == .runtimeApproved || stage == .published)
            )
        }
    }

    @Test func candidatePreviewCredentialsStayInMemoryForTheSession() throws {
        let store = CandidatePreviewCredentialStore()

        #expect(store.persistenceAvailability == .sessionOnly)
        #expect(try store.read(account: "provider") == nil)

        try store.save("secret", account: "provider")
        #expect(try store.read(account: "provider") == "secret")

        try store.delete(account: "provider")
        #expect(try store.read(account: "provider") == nil)
    }

    @Test func testHostNeverConstructsTheProductionWindowGroup() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: repository.appendingPathComponent(
                "ChessCoach/App/ChessCoachApp.swift"
            ),
            encoding: .utf8
        )

        #expect(source.contains("if launchMode == .testHost"))
        #expect(source.contains("Settings {"))
        #expect(
            source.contains(
                "must never\n            // construct or focus the production WindowGroup"
            )
        )
    }
}
