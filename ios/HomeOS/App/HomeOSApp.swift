import SwiftUI

@main
struct HomeOSApp: App {
    @State private var store = FamilyStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .task { await store.start() }
        }
    }
}

/// Routes between sign-in, family setup and the main app.
struct RootView: View {
    @Environment(FamilyStore.self) private var store

    var body: some View {
        switch store.phase {
        case .loading:
            ProgressView()
        case .signedOut:
            SignInView()
        case .needsFamily:
            CreateFamilyView()
        case .ready:
            MainTabView()
        }
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            TodayView().tabItem { Label("Today", systemImage: "sun.max") }
            CalendarView().tabItem { Label("Calendar", systemImage: "calendar") }
            ChoresView().tabItem { Label("Chores", systemImage: "checklist") }
            RewardsView().tabItem { Label("Rewards", systemImage: "star") }
            PhotosView().tabItem { Label("Photos", systemImage: "photo.on.rectangle") }
            SettingsView().tabItem { Label("Family", systemImage: "person.3") }
        }
    }
}
