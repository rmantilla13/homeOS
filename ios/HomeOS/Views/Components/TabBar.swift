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
        .padding(.horizontal, 16)
        .sensoryFeedback(.selection, trigger: selection)
    }
}
