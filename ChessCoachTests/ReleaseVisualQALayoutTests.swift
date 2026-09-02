import CoreGraphics
import Foundation
import Testing
@testable import ChessCoach

@Suite
struct ReleaseVisualQALayoutTests {
    @Test func expandedGameplayLayoutRequiresContainedNavigationRows() {
        var probes = validGameplayProbes(
            navigationWidth: 220,
            inspectorWidth: 360
        )
        probes.removeAll { $0.name == "navigation-currentGame" }
        probes.append(
            probe(
                "navigation-currentGame",
                owner: "navigation",
                frame: CGRect(x: -24, y: 700, width: 210, height: 34)
            )
        )

        let failures = ReleaseVisualQALayoutValidator.failures(
            probes: probes,
            scenario: .freshDefaultLight
        )

        #expect(
            failures.contains {
                $0.contains("navigation-currentGame extends outside navigation")
            },
            "The release gate must reject the beta.9-style leading cutoff."
        )
    }

    @Test func gameplayLayoutRequiresBoardMoveListAndCoach() {
        let incomplete = validGameplayProbes(
            navigationWidth: 220,
            inspectorWidth: 360
        ).filter {
            ![
                "game-detail",
                "board",
                "move-history",
                "coach-inspector",
            ].contains($0.name)
        }

        let failures = ReleaseVisualQALayoutValidator.failures(
            probes: incomplete,
            scenario: .freshDefaultDark
        )

        #expect(failures.contains("game-detail probe is missing"))
        #expect(failures.contains("chess board probe is missing"))
        #expect(failures.contains("move-history probe is missing"))
        #expect(failures.contains("Coach inspector probe is missing"))
    }

    @Test func gameContentCannotEscapeItsDetailColumn() {
        var probes = validGameplayProbes(
            navigationWidth: 220,
            inspectorWidth: 360
        )

        probes.replace(
            name: "board",
            with: probe(
                "board",
                owner: "game-detail",
                frame: CGRect(
                    x: 210,
                    y: 100,
                    width: 1_000,
                    height: 650
                )
            )
        )
        var failures = ReleaseVisualQALayoutValidator.failures(
            probes: probes,
            scenario: .freshDefaultDark
        )
        #expect(failures.contains("board extends outside game detail"))

        probes = validGameplayProbes(
            navigationWidth: 220,
            inspectorWidth: 360
        )
        probes.replace(
            name: "move-history",
            with: probe(
                "move-history",
                owner: "game-detail",
                frame: CGRect(x: 80, y: 100, width: 140, height: 650)
            )
        )
        failures = ReleaseVisualQALayoutValidator.failures(
            probes: probes,
            scenario: .freshDefaultDark
        )
        #expect(
            failures.contains("move-history extends outside game detail")
        )

        probes = validGameplayProbes(
            navigationWidth: 220,
            inspectorWidth: 360
        )
        probes.replace(
            name: "board",
            with: probe(
                "board",
                owner: "window",
                frame: CGRect(
                    x: 220,
                    y: 100,
                    width: 1_150,
                    height: 650
                )
            )
        )
        failures = ReleaseVisualQALayoutValidator.failures(
            probes: probes,
            scenario: .freshDefaultDark
        )
        #expect(failures.contains("board must be owned by game detail"))
    }

    @Test func detailColumnCannotOverlapNavigationOrCoach() {
        var probes = validGameplayProbes(
            navigationWidth: 220,
            inspectorWidth: 360
        )
        probes.replace(
            name: "game-detail",
            with: probe(
                "game-detail",
                owner: "window",
                frame: CGRect(x: 180, y: 0, width: 900, height: 900)
            )
        )

        var failures = ReleaseVisualQALayoutValidator.failures(
            probes: probes,
            scenario: .freshDefaultDark
        )
        #expect(failures.contains("navigation overlaps game detail"))

        probes = validGameplayProbes(
            navigationWidth: 220,
            inspectorWidth: 360
        )
        probes.replace(
            name: "game-detail",
            with: probe(
                "game-detail",
                owner: "window",
                frame: CGRect(x: 220, y: 0, width: 900, height: 900)
            )
        )
        failures = ReleaseVisualQALayoutValidator.failures(
            probes: probes,
            scenario: .freshDefaultDark
        )
        #expect(failures.contains("game detail overlaps Coach inspector"))
    }

    @Test func requestedSidebarWidthsAreEnforced() {
        let valid = ReleaseVisualQALayoutValidator.failures(
            probes: validGameplayProbes(
                navigationWidth: 190,
                inspectorWidth: 360
            ),
            scenario: .sidebarMinimumWidthDefaultLight
        )
        #expect(valid.isEmpty)

        let wrong = ReleaseVisualQALayoutValidator.failures(
            probes: validGameplayProbes(
                navigationWidth: 220,
                inspectorWidth: 360
            ),
            scenario: .sidebarMinimumWidthDefaultLight
        )
        #expect(wrong.contains { $0.contains("does not match requested 190") })
    }

    @Test func missingKeyFooterAndMinimumInspectorMustBeContained() {
        var probes = validGameplayProbes(
            navigationWidth: 220,
            inspectorWidth: 300
        )
        probes.append(
            probe(
                "provider-footer",
                owner: "coach-inspector",
                frame: CGRect(x: 1_120, y: 0, width: 300, height: 60)
            )
        )
        probes.append(
            probe(
                "configure-inference",
                owner: "provider-footer",
                frame: CGRect(x: 1_330, y: 12, width: 80, height: 30)
            )
        )

        let valid = ReleaseVisualQALayoutValidator.failures(
            probes: probes,
            scenario: .missingInferenceKeyMinimumInspectorLight
        )
        #expect(valid.isEmpty)

        probes.removeAll { $0.name == "configure-inference" }
        probes.append(
            probe(
                "configure-inference",
                owner: "provider-footer",
                frame: CGRect(x: 1_390, y: 12, width: 80, height: 30)
            )
        )
        let clipped = ReleaseVisualQALayoutValidator.failures(
            probes: probes,
            scenario: .missingInferenceKeyMinimumInspectorLight
        )
        #expect(
            clipped.contains {
                $0.contains("configure-inference extends outside provider footer")
            }
        )
    }

    @Test func candidateCaptureUsesOneScenarioSequence() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = try String(
            contentsOf: repository.appendingPathComponent(
                "scripts/capture-release-visual-qa.sh"
            ),
            encoding: .utf8
        )
        let installedScript = try String(
            contentsOf: repository.appendingPathComponent(
                "scripts/approve-installed-release-visual-qa.sh"
            ),
            encoding: .utf8
        )
        func openCommands(in source: String) -> [String] {
            source
                .split(whereSeparator: \.isNewline)
                .map {
                    String($0).trimmingCharacters(in: .whitespaces)
                }
                .filter {
                    $0.hasPrefix("open ") ||
                        $0.hasPrefix("/usr/bin/open ") ||
                        $0.hasPrefix("command open ")
                }
        }
        let candidateOpenCommands = openCommands(in: script)
        let installedOpenCommands = openCommands(in: installedScript)

        #expect(script.contains("--scenario-sequence=${scenario_sequence}"))
        #expect(script.contains("--visual-qa-session-id=${CAPTURE_SESSION_ID}"))
        #expect(script.contains("candidate_session_pids()"))
        #expect(script.contains("stop_candidate_session"))
        #expect(!script.contains("run_scenario()"))
        #expect(
            candidateOpenCommands == ["open -F -n -W \\"],
            "Candidate QA must contain exactly one app launch command."
        )
        #expect(
            !script.contains(
                "open \"${APP_PATH}\""
            ),
            "Candidate QA must launch once and never reopen the app."
        )
        #expect(
            script.contains(
                "Never call `open` again while this session is alive."
            )
        )
        #expect(
            installedOpenCommands == [
                "open -n -W \\",
            ],
            "Installed QA must launch the app exactly once."
        )
        #expect(
            !installedScript.contains(
                "open \"${APP_PATH}\""
            ),
            "Installed QA must launch once and never reopen the app."
        )
        #expect(
            installedScript.contains(
                "Never call `open` again while the installed QA session is alive."
            )
        )
        for source in [script, installedScript] {
            #expect(!source.contains("to activate"))
            #expect(!source.contains("activate application"))
        }
        #expect(
            script.contains(
                "run_capture_session \"${SCENARIO_SEQUENCE}\""
            )
        )
    }

    @Test func documentedCandidateScenariosMatchApplicationHarness() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let scenarioText = try String(
            contentsOf: repository.appendingPathComponent(
                "docs/visual-qa-scenarios.txt"
            ),
            encoding: .utf8
        )
        let documented = scenarioText
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        let expected = ReleaseVisualQAConfiguration.Scenario.allCases
            .filter { $0 != .installedDefaultDark }
            .map(\.rawValue)

        #expect(documented == expected)
    }

    @Test func visualScenariosExerciseInactiveAndLargeTextStates() {
        #expect(
            ReleaseVisualQAConfiguration.Scenario
                .sidebarInactiveSelectionDefaultLight
                .usesInactiveNavigationSelection
        )
        #expect(
            ReleaseVisualQAConfiguration.Scenario
                .sidebarInactiveSelectionDefaultDark
                .usesInactiveNavigationSelection
        )
        #expect(
            ReleaseVisualQAConfiguration.Scenario
                .sidebarInactiveSelectionDefaultLight.colorScheme == .light
        )
        #expect(
            ReleaseVisualQAConfiguration.Scenario
                .sidebarInactiveSelectionDefaultDark.colorScheme == .dark
        )
        #expect(
            ReleaseVisualQAConfiguration.Scenario
                .missingInferenceKeyMinimumInspectorLargeTextLight
                .usesLargeText
        )
        #expect(
            ReleaseVisualQAConfiguration.Scenario
                .missingInferenceKeyMinimumInspectorLargeTextLight
                .requestedInspectorWidth == 300
        )
    }

    @Test func visualHarnessWiresNewScenariosThroughUIAndOCR() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let validator = try String(
            contentsOf: repository.appendingPathComponent(
                "scripts/validate-release-visual-text.swift"
            ),
            encoding: .utf8
        )
        let rootView = try String(
            contentsOf: repository.appendingPathComponent(
                "ChessCoach/Views/RootView.swift"
            ),
            encoding: .utf8
        )
        let app = try String(
            contentsOf: repository.appendingPathComponent(
                "ChessCoach/App/ChessCoachApp.swift"
            ),
            encoding: .utf8
        )
        let visualRunner = try String(
            contentsOf: repository.appendingPathComponent(
                "ChessCoach/App/ReleaseVisualQA.swift"
            ),
            encoding: .utf8
        )

        #expect(
            validator.contains(
                "\"sidebar-inactive-selection-default-light\""
            )
        )
        #expect(
            validator.contains(
                "\"sidebar-inactive-selection-default-dark\""
            )
        )
        #expect(
            validator.contains(
                "\"missing-inference-key-minimum-inspector-large-text-light\""
            )
        )
        #expect(
            rootView.contains(
                "ReleaseVisualQAViewOverrides" +
                    ".inactiveNavigationSelectionKey"
            )
        )
        #expect(
            rootView.contains(
                "ReleaseVisualQAViewOverrides.largeTextKey"
            )
        )
        #expect(
            rootView.contains(
                "ReleaseVisualQAViewOverrides.navigationWidthKey"
            )
        )
        #expect(
            rootView.contains(
                "ReleaseVisualQAViewOverrides.inspectorWidthKey"
            )
        )
        #expect(
            rootView.contains(
                "ReleaseVisualQAViewOverrides.navigationExpandedKey"
            )
        )
        #expect(visualRunner.contains("ReleaseVisualQAProbeRegistry.frame"))
        #expect(
            visualRunner.contains(
                ".frame(maxWidth: .infinity, maxHeight: .infinity)"
            )
        )
        #expect(visualRunner.contains("waitForCandidateColumnWidths"))
        #expect(visualRunner.contains("setCandidateNavigationVisibility"))
        #expect(visualRunner.contains("firstPlausibleColumnFrame"))
        #expect(visualRunner.contains("renderedWindowFrame(in: window)"))
        #expect(!visualRunner.contains("window.convertToScreen"))
        #expect(visualRunner.contains("window.convertFromScreen"))
        #expect(visualRunner.contains("navigationFrameFromRows"))
        #expect(visualRunner.contains("frames.count == AppSection.allCases.count"))
        #expect(
            visualRunner.contains(
                "splitPaneFrame(\n                    edge: .minX"
            )
        )
        #expect(
            visualRunner.contains(
                "splitPaneFrame(\n                    edge: .maxX"
            )
        )
        #expect(visualRunner.contains("windowEdgeDistance <= 12"))
        #expect(!visualRunner.contains(".setPosition("))
        #expect(!visualRunner.contains("NSApplication.shared.activate"))
        #expect(!visualRunner.contains(".activateAllWindows"))
        #expect(
            rootView.contains(
                "visualQAOverride: ReleaseVisualQAConfiguration.isRequested"
            )
        )
        #expect(!rootView.contains(".backgroundExtensionEffect()"))
        #expect(app.contains(".frame(minWidth: 620, minHeight: 760)"))
        #expect(!app.contains(".frame(minWidth: 980, minHeight: 760)"))
        #expect(
            visualRunner.contains(
                "[String: [ReleaseVisualQAWeakProbe]]"
            )
        )
        #expect(rootView.contains(".accessibility1"))
    }

    @Test func candidateWidthsAreSeededBeforeSceneConstruction() throws {
        let suiteName = "release-visual-qa-widths-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        ReleaseVisualQAConfiguration.Scenario.freshDefaultDark
            .applyCandidateViewOverrides(to: defaults)
        #expect(
            defaults.double(
                forKey: ReleaseVisualQAViewOverrides.navigationWidthKey
            ) == 220
        )
        #expect(
            defaults.double(
                forKey: ReleaseVisualQAViewOverrides.inspectorWidthKey
            ) == 360
        )

        ReleaseVisualQAConfiguration.Scenario.sidebarMinimumWidthDefaultLight
            .applyCandidateViewOverrides(to: defaults)
        #expect(
            defaults.double(
                forKey: ReleaseVisualQAViewOverrides.navigationWidthKey
            ) == 190
        )

        ReleaseVisualQAConfiguration.Scenario
            .missingInferenceKeyMaximumInspectorLight
            .applyCandidateViewOverrides(to: defaults)
        #expect(
            defaults.double(
                forKey: ReleaseVisualQAViewOverrides.inspectorWidthKey
            ) == 460
        )
    }

    @Test func beta9TruncatedPixelFixtureFailsSpatialOCR() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let fixture = repository.appendingPathComponent(
            "ChessCoachTests/Fixtures/beta9-truncated-navigation.png"
        )
        let validator = repository.appendingPathComponent(
            "scripts/validate-release-visual-text.swift"
        )
        #expect(
            try fixture.resourceValues(
                forKeys: [.fileSizeKey]
            ).fileSize.map { $0 > 500_000 } == true,
            "The regression must use the real beta.9 pixel capture."
        )

        let process = Process()
        let standardError = Pipe()
        process.executableURL = validator
        process.arguments = [
            "--scenario",
            "fresh-default-light",
            "--image",
            fixture.path,
        ]
        process.standardOutput = Pipe()
        process.standardError = standardError
        try process.run()
        process.waitUntilExit()

        let errorText = String(
            decoding:
                standardError.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        #expect(process.terminationStatus != 0)
        #expect(
            errorText.contains(
                "required release text was not visible"
            )
        )
        #expect(errorText.contains("navigation OCR:"))
        #expect(errorText.contains("New Game"))
    }

    private func validGameplayProbes(
        navigationWidth: CGFloat,
        inspectorWidth: CGFloat
    ) -> [ReleaseVisualQALayoutProbe] {
        let windowWidth: CGFloat = 1_420
        let inspectorX = windowWidth - inspectorWidth
        let moveX = inspectorX - 160
        let detailFrame = CGRect(
            x: navigationWidth,
            y: 0,
            width: inspectorX - navigationWidth,
            height: 900
        )
        var probes = [
            probe(
                "window",
                owner: "",
                frame: CGRect(x: 0, y: 0, width: windowWidth, height: 900)
            ),
            probe(
                "navigation",
                owner: "window",
                frame: CGRect(
                    x: 0,
                    y: 0,
                    width: navigationWidth,
                    height: 900
                )
            ),
            probe(
                "game-detail",
                owner: "window",
                frame: detailFrame
            ),
            probe(
                "coach-inspector",
                owner: "window",
                frame: CGRect(
                    x: inspectorX,
                    y: 0,
                    width: inspectorWidth,
                    height: 900
                )
            ),
            probe(
                "board",
                owner: "game-detail",
                frame: CGRect(
                    x: navigationWidth + 20,
                    y: 100,
                    width: moveX - navigationWidth - 40,
                    height: 650
                )
            ),
            probe(
                "move-history",
                owner: "game-detail",
                frame: CGRect(x: moveX, y: 100, width: 140, height: 650)
            ),
        ]
        for (index, name) in
            ReleaseVisualQALayoutValidator.navigationRows.enumerated() {
            probes.append(
                probe(
                    name,
                    owner: "navigation",
                    frame: CGRect(
                        x: 10,
                        y: 700 - CGFloat(index * 44),
                        width: navigationWidth - 20,
                        height: 34
                    )
                )
            )
        }
        return probes
    }

    private func probe(
        _ name: String,
        owner: String,
        frame: CGRect
    ) -> ReleaseVisualQALayoutProbe {
        ReleaseVisualQALayoutProbe(
            name: name,
            owner: owner,
            frame: ReleaseVisualQARect(frame)
        )
    }
}

private extension Array where Element == ReleaseVisualQALayoutProbe {
    mutating func replace(
        name: String,
        with replacement: ReleaseVisualQALayoutProbe
    ) {
        removeAll { $0.name == name }
        append(replacement)
    }
}
