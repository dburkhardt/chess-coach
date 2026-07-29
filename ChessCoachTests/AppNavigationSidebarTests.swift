import AppKit
import Foundation
import SwiftUI
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
        defaults.set(
            true,
            forKey: "layout.sidebarNavigationSplitViewRepair.v2"
        )

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

    @Test func sidebarUsesNativeWidthRangeAndPinsSettingsSeparately() {
        #expect(AppNavigationSidebarMetrics.minimumWidth == 190)
        #expect(AppNavigationSidebarMetrics.idealWidth == 220)
        #expect(AppNavigationSidebarMetrics.maximumWidth == 260)
        #expect(
            AppNavigationSidebarSections.primary == [
                .newGame,
                .currentGame,
                .games,
                .progress,
            ]
        )
        #expect(!AppNavigationSidebarSections.primary.contains(.settings))
    }

    @MainActor
    @Test func sidebarDoesNotCreateScrollBackedNavigation() {
        let selection = SelectionBox(.currentGame)
        let content = AppNavigationSidebar(
            selection: Binding(
                get: { selection.value },
                set: { selection.value = $0 }
            )
        )
        .frame(
            width: AppNavigationSidebarMetrics.idealWidth,
            height: 700
        )
        let host = NSHostingController(rootView: content)

        _ = host.view
        host.view.frame = NSRect(
            x: 0,
            y: 0,
            width: AppNavigationSidebarMetrics.idealWidth,
            height: 700
        )
        host.view.layoutSubtreeIfNeeded()

        #expect(
            descendants(of: NSScrollView.self, in: host.view).isEmpty,
            "Fixed app navigation must never be backed by NSScrollView."
        )
        #expect(
            descendants(of: NSClipView.self, in: host.view).isEmpty,
            "Fixed app navigation must never retain an NSClipView offset."
        )
    }

    @MainActor
    @Test func providerFooterFitsHorizontallyThenFallsBackVertically() {
        let wideSize = providerFooterSize(width: 300)
        let narrowSize = providerFooterSize(width: 190)

        #expect(wideSize.width <= 300)
        #expect(narrowSize.width <= 190)
        #expect(wideSize.height > 0)
        #expect(
            narrowSize.height > wideSize.height,
            "The narrow footer must stack instead of clipping its action."
        )
        #expect(
            CoachProviderSetupFooterContent.accessibilityLabel
                == "No inference key configured. Configure here"
        )
    }

    @Test func sidebarVisibilityUsesStableRestorableValues() {
        #expect(
            AppNavigationSidebarVisibility.expanded.splitViewVisibility
                == .all
        )
        #expect(
            AppNavigationSidebarVisibility.collapsed.splitViewVisibility
                == .detailOnly
        )
        #expect(
            AppNavigationSidebarVisibility(.all) == .expanded
        )
        #expect(
            AppNavigationSidebarVisibility(.detailOnly) == .collapsed
        )
        #expect(
            ChessCoachWindowLayout.sidebarVisibilitySceneKey
                == "layout.navigationSidebar.visibility.v1"
        )
        #expect(
            ChessCoachWindowLayout.sidebarVisibilityLaunchOverrideKey
                == "layout.navigationSidebar.visibilityLaunchOverride"
        )
    }
}

private final class SelectionBox {
    var value: AppSection

    init(_ value: AppSection) {
        self.value = value
    }
}

@MainActor
private func descendants<ViewType: NSView>(
    of type: ViewType.Type,
    in root: NSView
) -> [ViewType] {
    root.subviews.flatMap { child -> [ViewType] in
        var matches = descendants(of: type, in: child)
        if let matchingChild = child as? ViewType {
            matches.insert(matchingChild, at: 0)
        }
        return matches
    }
}

@MainActor
private func providerFooterSize(width: CGFloat) -> CGSize {
    let content = CoachProviderSetupFooter(
        issue: .missingKey,
        onConfigure: { _ in }
    )
    let host = NSHostingController(rootView: content)
    return host.sizeThatFits(
        in: CGSize(width: width, height: .greatestFiniteMagnitude)
    )
}
