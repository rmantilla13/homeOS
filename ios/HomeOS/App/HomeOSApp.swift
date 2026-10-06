import SwiftUI

@main
struct HomeOSApp: App {
    @State private var store = FamilyStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .providesMood()
                .task { await store.start() }
        }
    }
}

/// Routes between sign-in, family setup and the main app.
struct RootView: View {
    @Environment(FamilyStore.self) private var store

    var body: some View {
        Group {
            switch store.phase {
            case .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .screenBackground()
            case .signedOut:
                SignInView()
            case .needsFamily:
                CreateFamilyView()
            case .ready:
                MainTabView()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: store.phase)
    }
}

/// Five screens behind a floating tab bar.
struct MainTabView: View {
    @State private var tab: AppTab = .home

    var body: some View {
        ZStack {
            switch tab {
            case .home: HomeView(selectedTab: $tab).transition(.opacity)
            case .calendar: CalendarView().transition(.opacity)
            case .chores: ChoresView().transition(.opacity)
            case .media: MediaView().transition(.opacity)
            case .family: FamilyView().transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenBackground()
        .safeAreaInset(edge: .bottom, spacing: 0) {
            FloatingTabBar(selection: $tab)
                .padding(.bottom, 2)
        }
    }
}
