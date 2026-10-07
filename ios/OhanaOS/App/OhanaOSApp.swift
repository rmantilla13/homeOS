import Network
import SwiftUI
import UIKit

@main
struct OhanaOSApp: App {
    @State private var store = FamilyStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .providesMood()
                .task { await store.start() }
                // ohanaos://invite/<CODE> and ohanaos://auth-callback (URL scheme in project.yml).
                .onOpenURL { store.handleOpenURL($0) }
                // Chores due are worked out per day. Back in the foreground on a
                // new day, at midnight with the app open, or back online after
                // that load failed, load the new day's.
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await store.refreshIfNewDay() } }
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                    Task { await store.refreshIfNewDay() }
                }
                .task {
                    for await _ in networkUp() { await store.refreshIfNewDay() }
                }
        }
    }
}

/// Ticks whenever the network is usable: at the start if it already is, and
/// each time it comes back or changes route. NWPathMonitor calls back on its
/// own queue; the stream carries just the tick, and keeps only the latest
/// while the last one is still being handled.
private func networkUp() -> AsyncStream<Void> {
    AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            if path.status == .satisfied { continuation.yield() }
        }
        continuation.onTermination = { _ in monitor.cancel() }
        monitor.start(queue: DispatchQueue(label: "com.ohanaos.network"))
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
        .sheet(item: Binding<InviteLink?>(
            get: {
                #if DEBUG
                if DemoMode.isOn { return nil }
                #endif
                return store.phase == .ready ? store.pendingInviteCode.map(InviteLink.init) : nil
            },
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

/// Five screens behind a floating tab bar. On a regular-width, regular-height
/// screen (the iPhone Duo open) the calendar gets its own pane on the leading
/// side, and the other four tabs share the trailing one.
struct MainTabView: View {
    #if DEBUG
    @State private var tab: AppTab = DemoMode.initialTab
    #else
    @State private var tab: AppTab = .home
    #endif
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private var splitsCalendar: Bool {
        horizontalSizeClass == .regular && verticalSizeClass == .regular
    }

    var body: some View {
        Group {
            if splitsCalendar {
                HStack(spacing: 0) {
                    CalendarView()
                        .frame(maxWidth: .infinity)
                    Rectangle()
                        .fill(Theme.sunken)
                        .frame(width: 1)
                        .ignoresSafeArea()
                    tabs(AppTab.besideCalendar)
                        .frame(maxWidth: .infinity)
                }
                .environment(\.calendarIsBeside, true)
            } else {
                tabs(AppTab.allCases)
            }
        }
        .screenBackground()
        // Opening the phone on the Calendar tab: the calendar moves to its
        // pane and Home takes the other.
        .onChange(of: splitsCalendar, initial: true) { _, splits in
            if splits && tab == .calendar { tab = .home }
        }
    }

    private func tabs(_ shown: [AppTab]) -> some View {
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
        .safeAreaInset(edge: .bottom, spacing: 0) {
            FloatingTabBar(selection: $tab, tabs: shown)
                .padding(.bottom, 2)
        }
    }
}
