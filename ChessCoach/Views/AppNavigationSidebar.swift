import SwiftUI

/// The app has five fixed destinations, so its primary navigation must not
/// live in a scroll-backed `List`. A sidebar list can retain a horizontal
/// clip-view offset after window restoration, hiding its leading content.
///
/// `NavigationSplitView` still owns the native sidebar column, its material,
/// and collapse behavior. Only the fixed navigation contents avoid scrolling.
struct AppNavigationSidebar: View {
    @Binding var selection: AppSection

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                ForEach(AppNavigationSidebarSections.primary) { section in
                    navigationButton(for: section)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)

            Spacer(minLength: 8)

            navigationButton(for: .settings)
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }

    private func navigationButton(for section: AppSection) -> some View {
        Button {
            selection = section
        } label: {
            Label(section.title, systemImage: section.systemImage)
                .lineLimit(1)
                .frame(
                    maxWidth: .infinity,
                    minHeight: 30,
                    alignment: .leading
                )
                .contentShape(.rect)
        }
        .buttonStyle(
            AppNavigationRowButtonStyle(
                isSelected: selection == section
            )
        )
        .accessibilityAddTraits(
            selection == section ? .isSelected : []
        )
        .accessibilityIdentifier(
            "app-navigation-\(section.rawValue)"
        )
        .releaseVisualQAProbe("navigation-\(section.rawValue)")
    }
}

enum AppNavigationSidebarMetrics {
    static let minimumWidth: CGFloat = 190
    static let idealWidth: CGFloat = 220
    static let maximumWidth: CGFloat = 260

    static func widths(
        visualQAOverride: Double
    ) -> AppColumnWidthRange {
        AppColumnWidthRange.resolving(
            visualQAOverride: visualQAOverride,
            minimum: minimumWidth,
            ideal: idealWidth,
            maximum: maximumWidth
        )
    }
}

enum CoachInspectorMetrics {
    static let minimumWidth: CGFloat = 300
    static let idealWidth: CGFloat = 360
    static let maximumWidth: CGFloat = 460
    static let accessibilityIdentifier = "coach-inspector-column"

    static func widths(
        visualQAOverride: Double
    ) -> AppColumnWidthRange {
        AppColumnWidthRange.resolving(
            visualQAOverride: visualQAOverride,
            minimum: minimumWidth,
            ideal: idealWidth,
            maximum: maximumWidth
        )
    }
}

struct AppColumnWidthRange: Equatable {
    let minimum: CGFloat
    let ideal: CGFloat
    let maximum: CGFloat

    static func resolving(
        visualQAOverride: Double,
        minimum: CGFloat,
        ideal: CGFloat,
        maximum: CGFloat
    ) -> Self {
        let requested = CGFloat(visualQAOverride)
        guard requested.isFinite,
              requested >= minimum,
              requested <= maximum
        else {
            return Self(
                minimum: minimum,
                ideal: ideal,
                maximum: maximum
            )
        }
        return Self(
            minimum: requested,
            ideal: requested,
            maximum: requested
        )
    }
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
        "layout.sidebarNavigationSplitViewRepair.v3"

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

private struct AppNavigationRowButtonStyle: ButtonStyle {
    @Environment(\.controlActiveState) private var controlActiveState

    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .foregroundStyle(foregroundStyle)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(selectionBackground)
                } else if configuration.isPressed {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(.primary.opacity(0.08))
                }
            }
    }

    private var foregroundStyle: Color {
        guard isSelected else { return .primary }
        return controlActiveState == .inactive ? .primary : .white
    }

    private var selectionBackground: Color {
        if controlActiveState == .inactive {
            return Color(
                nsColor: .unemphasizedSelectedContentBackgroundColor
            )
        }
        return .accentColor
    }
}
