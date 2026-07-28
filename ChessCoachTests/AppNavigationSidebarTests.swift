import Foundation
import Testing
@testable import ChessCoach

@Suite(.serialized)
struct AppNavigationSidebarTests {
    @Test func splitViewRepairClearsLegacyGeometryExactlyOnce() throws {
        let suiteName = "AppNavigationSidebarTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let splitFrameKey =
            "NSSplitView Subview Frames LegacyRoot-1-AppWindow-1, " +
            "SidebarNavigationSplitView"
        let incompatibleFrames = [
            "0.000000, 0.000000, 218.000000, 900.000000, NO, NO",
            "0.000000, 0.000000, 1558.000000, 900.000000, NO, NO",
        ]
        defaults.set(incompatibleFrames, forKey: splitFrameKey)

        ChessCoachWindowLayout.prepareForLaunch(defaults: defaults)
        #expect(defaults.object(forKey: splitFrameKey) == nil)

        let currentFrames = [
            "0.000000, 0.000000, 210.000000, 900.000000, NO, NO",
            "0.000000, 0.000000, 1210.000000, 900.000000, NO, NO",
        ]
        defaults.set(currentFrames, forKey: splitFrameKey)

        ChessCoachWindowLayout.prepareForLaunch(defaults: defaults)
        #expect(
            defaults.stringArray(forKey: splitFrameKey) == currentFrames,
            "Normal launches must preserve the repaired divider width."
        )

        ChessCoachWindowLayout.prepareForLaunch(
            defaults: defaults,
            force: true
        )
        #expect(defaults.object(forKey: splitFrameKey) == nil)
    }
}
