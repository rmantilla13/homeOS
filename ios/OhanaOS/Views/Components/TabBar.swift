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

    /// The tabs beside the calendar when it has its own pane.
    static let besideCalendar: [AppTab] = allCases.filter { $0 != .calendar }
}

private struct CalendarIsBesideKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when the calendar is on screen in its own pane (the iPhone Duo open),
    /// so links that would open the Calendar tab aren't needed.
    var calendarIsBeside: Bool {
        get { self[CalendarIsBesideKey.self] }
        set { self[CalendarIsBesideKey.self] = newValue }
    }
}

/// Floating capsule tab bar; the selected tab is an accent pill that slides between tabs.
struct FloatingTabBar: View {
    @Binding var selection: AppTab
    var tabs: [AppTab] = AppTab.allCases
    @Namespace private var namespace
    @Environment(\.mood) private var mood
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        HStack(spacing: 2) {
            ForEach(tabs) { tab in
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
        // Phone-sized on the iPhone Duo's inner display, not stretched across it.
        .frame(maxWidth: sizeClass == .regular ? 520 : nil)
        .padding(.horizontal, 16)
        .sensoryFeedback(.selection, trigger: selection)
    }
}
