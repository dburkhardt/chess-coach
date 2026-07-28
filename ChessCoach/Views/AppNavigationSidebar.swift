import SwiftUI

/// The app has five fixed destinations, so its primary navigation should not
/// live in a scroll-backed `List`. A sidebar list can retain a horizontal
/// clip-view offset after window restoration, hiding its leading content.
struct AppNavigationSidebar: View {
    @Binding var selection: AppSection

    var body: some View {
        VStack(spacing: 2) {
            ForEach(AppSection.allCases) { section in
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
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .frame(
            maxWidth: .infinity,
            maxHeight: .infinity,
            alignment: .topLeading
        )
    }
}

enum AppNavigationSidebarMetrics {
    static let minimumWidth: CGFloat = 190
    static let idealWidth: CGFloat = 210
    static let maximumWidth: CGFloat = 250
}

enum ChessCoachWindowLayout {
    private static let splitViewRepairKey =
        "layout.sidebarNavigationSplitViewRepair.v1"

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
