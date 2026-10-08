import SwiftUI

/// The open iPhone Duo (or any regular-width window): two screens side by
/// side, one each side of the fold. The rail on the right edge has a group of
/// tabs for each: the top group picks the left screen, the bottom group the
/// right one. Picking what the other side already shows swaps the two. The
/// choice is kept on this phone.
struct DualPaneView: View {
    let insets: EdgeInsets
    @AppStorage("duo.leftPane") private var left: AppTab = .calendar
    @AppStorage("duo.rightPane") private var right: AppTab = .home

    var body: some View {
        HStack(spacing: 0) {
            pane(selection: leftBinding, other: rightBinding)
            // Down the middle, where the fold is. When the rail takes a column
            // of its own, the two halves split what's left, a little left of
            // the fold, so neither gets too narrow to read.
            Rectangle()
                .fill(Theme.divider.opacity(0.6))
                .frame(width: 1)
                .ignoresSafeArea()
            pane(selection: rightBinding, other: leftBinding)
        }
        .tabRail([leftBinding, rightBinding], labels: ["Left", "Right"], insets: insets)
        .screenBackground()
    }

    private func pane(selection: Binding<AppTab>, other: Binding<AppTab>) -> some View {
        PaneContent(tab: selection.wrappedValue, other: other)
            .id(selection.wrappedValue)
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .softEdges(top: 10, bottom: 28)
            // Home leaves out upcoming activities when the calendar is beside it.
            .environment(\.calendarBeside, other.wrappedValue == .calendar)
    }

    private var leftBinding: Binding<AppTab> {
        Binding(get: { left }, set: { tab in
            withAnimation(Theme.springy) {
                if tab == right { right = left }
                left = tab
            }
        })
    }

    private var rightBinding: Binding<AppTab> {
        Binding(get: { right }, set: { tab in
            withAnimation(Theme.springy) {
                if tab == left { left = right }
                right = tab
            }
        })
    }
}

/// One side's screen. "See all" on Home opens that screen on the other side.
private struct PaneContent: View {
    let tab: AppTab
    @Binding var other: AppTab

    var body: some View {
        switch tab {
        case .home: HomeView(selectedTab: openBeside)
        case .calendar: CalendarView()
        case .chores: ChoresView()
        case .media: MediaView()
        case .family: FamilyView()
        }
    }

    private var openBeside: Binding<AppTab> {
        Binding(get: { tab }, set: { next in
            guard next != tab else { return }
            other = next
        })
    }
}

private struct CalendarBesideKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True when the calendar is on the other side of the open iPhone Duo.
    var calendarBeside: Bool {
        get { self[CalendarBesideKey.self] }
        set { self[CalendarBesideKey.self] = newValue }
    }
}
