import SwiftUI

struct AppNavigationSidebar: View {
    @Binding var selection: AppSection

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                ForEach(AppNavigationSidebarSections.primary) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .lineLimit(1)
                        .tag(section)
                        .accessibilityIdentifier(
                            "app-navigation-\(section.rawValue)"
                        )
                }
            }
            .listStyle(.sidebar)

            List(selection: $selection) {
                Label(
                    AppSection.settings.title,
                    systemImage: AppSection.settings.systemImage
                )
                .lineLimit(1)
                .tag(AppSection.settings)
                .accessibilityIdentifier("app-navigation-settings")
            }
            .listStyle(.sidebar)
            .scrollDisabled(true)
            .frame(height: 46)
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }
}

enum AppNavigationSidebarMetrics {
    static let minimumWidth: CGFloat = 190
    static let idealWidth: CGFloat = 220
    static let maximumWidth: CGFloat = 260
}

enum AppNavigationSidebarSections {
    static let primary: [AppSection] = [
        .newGame,
        .currentGame,
        .games,
        .progress,
    ]
}

enum AppNavigationSidebarVisibility: String {
    case expanded
    case collapsed

    init(_ visibility: NavigationSplitViewVisibility) {
        self = visibility == .detailOnly ? .collapsed : .expanded
    }

    var splitViewVisibility: NavigationSplitViewVisibility {
        switch self {
        case .expanded:
            .all
        case .collapsed:
            .detailOnly
        }
    }
}

enum ChessCoachWindowLayout {
    /// Per-window state restoration. Values are `expanded` or `collapsed`.
    static let sidebarVisibilitySceneKey =
        "layout.navigationSidebar.visibility.v1"
    /// Optional one-launch override used by deterministic release visual QA.
    /// Values are `expanded` or `collapsed`; the app consumes and clears it.
    static let sidebarVisibilityLaunchOverrideKey =
        "layout.navigationSidebar.visibilityLaunchOverride"

    private static let splitViewRepairKey =
        "layout.sidebarNavigationSplitViewRepair.v2"

    static func prepareForLaunch(
        defaults: UserDefaults = .standard,
        force: Bool = false
    ) {
        guard force || !defaults.bool(forKey: splitViewRepairKey) else {
            return
        }

        let incompatibleKeys = defaults.dictionaryRepresentation().keys
            .filter {
                $0.hasPrefix("NSSplitView Subview Frames ") &&
                    $0.contains("SidebarNavigationSplitView")
            }
        for key in incompatibleKeys {
            defaults.removeObject(forKey: key)
        }
        defaults.set(true, forKey: splitViewRepairKey)
    }
}
