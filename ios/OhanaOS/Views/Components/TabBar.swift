import SwiftUI

enum AppTab: String, CaseIterable, Identifiable {
    case home, calendar, chores, media, family

    var id: Self { self }
    var title: String { rawValue.capitalized }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .calendar: return "calendar"
        case .chores: return "checkmark.circle.fill"
        case .media: return "photo.on.rectangle.angled"
        case .family: return "person.2.fill"
        }
    }
}

/// Floating capsule tab bar; the selected tab is an accent pill that slides between tabs.
struct FloatingTabBar: View {
    @Binding var selection: AppTab
    @Namespace private var namespace
    @Environment(\.mood) private var mood

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AppTab.allCases) { tab in
                let selected = tab == selection
                Button {
                    withAnimation(Theme.springy) { selection = tab }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 17, weight: .semibold))
                        if selected {
                            Text(tab.title)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .fixedSize()
                                .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                        }
                    }
                    .foregroundStyle(selected ? Color.white : Theme.muted)
                    .padding(.horizontal, selected ? 16 : 0)
                    .frame(maxWidth: selected ? nil : .infinity)
                    .frame(height: 48)
                    .background {
                        if selected {
                            Capsule()
                                .fill(mood.accent)
                                .matchedGeometryEffect(id: "tab", in: namespace)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(6)
        .background(Theme.surface, in: Capsule())
        .shadow(color: .black.opacity(0.10), radius: 20, y: 8)
        // Phone width, even on the iPhone Duo's wide inner screen.
        .frame(maxWidth: 440)
        .padding(.horizontal, Theme.page)
        .sensoryFeedback(.selection, trigger: selection)
    }
}

extension View {
    /// The floating tab bar at the bottom, over a soft blur that eases the
    /// content out as it scrolls under the bar.
    func floatingTabBar(selection: Binding<AppTab>) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            FloatingTabBar(selection: selection)
                .padding(.bottom, 2)
                .background(alignment: .bottom) {
                    EdgeFade(edge: .bottom)
                        .padding(.top, -36)
                        .ignoresSafeArea(edges: .bottom)
                }
        }
    }
}

/// The tabs as a vertical rail on the right edge, for the iPhone Duo. One
/// group of icons per screen: open, the top group picks the left screen and
/// the bottom group the right one.
struct TabRail: View {
    let groups: [Binding<AppTab>]
    var labels: [String] = []

    /// A trailing safe area wider than this is the Duo's status strip.
    static let stripMinWidth: CGFloat = 40

    var body: some View {
        VStack(spacing: 8) {
            ForEach(groups.indices, id: \.self) { index in
                if index > 0 {
                    Capsule().fill(Theme.divider).frame(width: 24, height: 2)
                        .padding(.vertical, 4)
                }
                if labels.indices.contains(index) {
                    Text(labels[index])
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.muted)
                        .padding(.top, 4)
                        .accessibilityHidden(true)
                }
                TabRailGroup(selection: groups[index],
                             label: labels.indices.contains(index) ? labels[index] : nil)
            }
        }
        .padding(6)
        .background(Theme.surface, in: Capsule())
        .shadow(color: .black.opacity(0.10), radius: 20, x: -4)
    }
}

private struct TabRailGroup: View {
    @Binding var selection: AppTab
    let label: String?
    @Namespace private var namespace
    @Environment(\.mood) private var mood

    var body: some View {
        VStack(spacing: 2) {
            ForEach(AppTab.allCases) { tab in
                let selected = tab == selection
                Button {
                    withAnimation(Theme.springy) { selection = tab }
                } label: {
                    Image(systemName: tab.icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(selected ? Color.white : Theme.muted)
                        .frame(width: 48, height: 48)
                        .background {
                            if selected {
                                Circle()
                                    .fill(mood.accent)
                                    .matchedGeometryEffect(id: "rail", in: namespace)
                            }
                        }
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label.map { "\(tab.title), \($0) screen" } ?? tab.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}

extension View {
    /// Puts the tab rail on the right edge. On the Duo's outer screen it sits
    /// in the empty lower part of the status strip, so the screen keeps its
    /// width. Otherwise it takes a column of its own, centered top to bottom.
    func tabRail(_ groups: [Binding<AppTab>], labels: [String] = [], insets: EdgeInsets) -> some View {
        modifier(TabRailPlacement(groups: groups, labels: labels, insets: insets))
    }
}

private struct TabRailPlacement: ViewModifier {
    let groups: [Binding<AppTab>]
    let labels: [String]
    let insets: EdgeInsets

    func body(content: Content) -> some View {
        if insets.trailing > TabRail.stripMinWidth {
            content.overlay(alignment: .bottomTrailing) {
                TabRail(groups: groups, labels: labels)
                    .frame(width: insets.trailing)
                    .offset(x: insets.trailing)
                    .padding(.bottom, 16)
            }
        } else {
            HStack(spacing: 0) {
                content
                TabRail(groups: groups, labels: labels)
                    .padding(.trailing, 12)
            }
        }
    }
}
