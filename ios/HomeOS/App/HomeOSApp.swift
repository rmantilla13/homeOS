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
                // homeos://invite/<CODE> and homeos://auth-callback (URL scheme in project.yml).
                .onOpenURL { store.handleOpenURL($0) }
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
                LoadingView()
            case .signedOut:
                WelcomeView()
            case .needsFamily:
                FamilySetupView()
            case .ready:
                MainTabView()
            }
        }
        .animation(.easeInOut(duration: 0.3), value: store.phase)
        // An invite link opened while you're already in a family.
        .sheet(item: Binding(
            get: { store.phase == .ready ? store.pendingInviteCode.map(InviteLink.init) : nil },
            set: { if $0 == nil { store.setPendingInvite(nil) } }
        )) { link in
            InviteLinkSheet(code: link.code)
        }
    }
}

/// Spinner while the session and family load, with a retry if that fails.
private struct LoadingView: View {
    @Environment(FamilyStore.self) private var store

    var body: some View {
        VStack(spacing: 16) {
            if let message = store.errorMessage {
                Image(systemName: "wifi.exclamationmark")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.muted)
                Text(message)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.muted)
                Button("Try again") {
                    store.errorMessage = nil
                    Task { await store.loadFamily() }
                }
                .buttonStyle(.pill())
            } else {
                ProgressView()
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .screenBackground()
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
