import SwiftUI

struct HomeView: View {
    @Environment(FamilyStore.self) private var store
    @Binding var selectedTab: AppTab
    @State private var launch: AssistantLaunch?
    /// A suggestion waiting for the person to allow the AI assistant.
    @State private var consentLaunch: AssistantLaunch?
    /// Allowed: the chat opens once the consent sheet has closed.
    @State private var allowedLaunch: AssistantLaunch?
    @State private var planningDinner = false
    @State private var showingProfile = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    AssistantHeroCard(name: store.me?.displayName) { openAssistant($0) }
                    approvals
                    choreProgress
                    upcoming
                    dinner
                }
                .padding(.horizontal, Theme.page)
                .padding(.bottom, 24)
                .animation(Theme.springy, value: store.pendingCompletions)
            }
            .screenBackground()
            .refreshable { await store.refresh() }
            .toolbar(.hidden, for: .navigationBar)
            .fullScreenCover(item: $launch) { AssistantView(launch: $0) }
            .sheet(item: $consentLaunch, onDismiss: { openAllowedLaunch() }) { pending in
                AIConsentSheet(
                    onAllow: {
                        store.allowAI()
                        allowedLaunch = pending
                        consentLaunch = nil
                    },
                    onNotNow: { consentLaunch = nil })
            }
            .sheet(isPresented: $planningDinner) { MealEditor(day: DayKey.today) }
            .sheet(isPresented: $showingProfile) { ProfileView() }
            .showsStoreErrors()
            #if DEBUG
            .task {
                // -OhanaScreen assistant: open the chat once Home is on screen.
                guard DemoMode.opensAssistant else { return }
                DemoMode.assistantShown = true
                try? await Task.sleep(for: .milliseconds(400))
                launch = AssistantLaunch()
            }
            #endif
        }
    }

    /// A suggestion sends its question as the chat opens, so it waits for
    /// consent here. The ask pill and the mic only open the chat, which asks
    /// before it sends anything.
    private func openAssistant(_ next: AssistantLaunch) {
        if next.prompt != nil, !store.hasAIConsent {
            consentLaunch = next
        } else {
            launch = next
        }
    }

    /// After Allow, opens the chat once the consent sheet is gone. A new
    /// presentation can't start while another one is closing.
    private func openAllowedLaunch() {
        guard let next = allowedLaunch else { return }
        allowedLaunch = nil
        launch = next
    }

    private var header: some View {
        ScreenHeader(title: store.family?.name ?? "Ohana Display",
                     subtitle: Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day())) {
            Button { showingProfile = true } label: {
                MemberAvatar(member: store.me, size: 44)
            }
            .buttonStyle(PressableStyle())
            .accessibilityLabel("Your profile")
        }
    }

    @ViewBuilder
    private var approvals: some View {
        let pending = store.pendingCompletions
        if store.isParent && !pending.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                SectionHeader("Waiting for your OK")
                ForEach(pending) { completion in
                    ApprovalCard(completion: completion)
                        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                                removal: .scale(scale: 0.9).combined(with: .opacity)))
                }
            }
        }
    }

    private var choreProgress: some View {
        let people = store.members.filter { !store.dueTasks(for: $0).isEmpty }
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Today's chores") {
                Button("See all") { withAnimation(Theme.springy) { selectedTab = .chores } }
                    .font(.subheadline.weight(.semibold))
            }
            if people.isEmpty && !store.choresLoadedToday {
                EmptyCard(text: "Today's chores haven't loaded yet. Pull to refresh.", systemImage: "arrow.clockwise")
            } else if people.isEmpty {
                EmptyCard(text: "No chores today", systemImage: "checkmark.circle")
            } else {
                VStack(spacing: 16) {
                    ForEach(people) { member in
                        let progress = store.choreProgress(for: member)
                        HStack(spacing: 12) {
                            MemberAvatar(member: member, size: 36)
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(member.displayName).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                                    Spacer()
                                    Text("\(progress.done)/\(progress.total)")
                                        .font(.subheadline.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(progress.done == progress.total ? Theme.success : Theme.muted)
                                        .contentTransition(.numericText(value: Double(progress.done)))
                                }
                                ProgressBar(value: progress.total == 0 ? 0 : Double(progress.done) / Double(progress.total),
                                            color: Color(hex: member.color))
                            }
                        }
                    }
                }
                .card()
            }
        }
    }

    private var upcoming: some View {
        let events = store.upcomingEvents(limit: 4)
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Your upcoming activities") {
                Button("See all") { withAnimation(Theme.springy) { selectedTab = .calendar } }
                    .font(.subheadline.weight(.semibold))
            }
            if events.isEmpty {
                EmptyCard(text: "Nothing on the calendar yet", systemImage: "calendar")
            }
            ForEach(events) { ActivityCard(event: $0) }
        }
    }

    private var dinner: some View {
        let meal = store.meal(.dinner, on: DayKey.today)
        return VStack(alignment: .leading, spacing: 12) {
            SectionHeader("Dinner tonight")
            HStack(spacing: 14) {
                Image(systemName: "fork.knife")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.warning)
                    .frame(width: 48, height: 48)
                    .background(Theme.warning.opacity(0.16), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(meal?.title ?? "Not planned yet")
                        .font(.headline)
                        .foregroundStyle(meal == nil ? Theme.muted : Theme.text)
                    if let notes = meal?.notes, !notes.isEmpty {
                        Text(notes).font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                Spacer()
                Button(meal == nil ? "Plan" : "Edit") { planningDinner = true }
                    .buttonStyle(.pill(.soft))
            }
            .card()
        }
    }
}

/// "How can I help you today?" card with the glow arch, suggestion chips and the ask pill.
struct AssistantHeroCard: View {
    let name: String?
    let open: (AssistantLaunch) -> Void

    private var greetingName: String {
        let first = name?.split(separator: " ").first.map(String.init) ?? "there"
        return first.uppercased()
    }

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 6) {
                Text("HELLO \(greetingName)!")
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.text.opacity(0.7))
                Text("How can I help you today?")
                    .font(.system(size: 26, weight: .bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.text)
            }
            .padding(.top, 40)
            .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(AssistantSuggestion.hero) { suggestion in
                        Button { open(AssistantLaunch(prompt: suggestion.prompt)) } label: {
                            Chip(title: suggestion.title, icon: suggestion.icon)
                        }
                        .buttonStyle(PressableStyle())
                    }
                }
                .padding(.horizontal, 16)
            }

            HStack(spacing: 8) {
                Button { open(AssistantLaunch()) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                        Text("Ask Ohana anything")
                        Spacer()
                    }
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                    .padding(.leading, 16)
                    .frame(height: 48)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                CircleIconButton(systemName: "mic.fill", size: 44) { open(AssistantLaunch(listen: true)) }
                    .accessibilityLabel("Ask by voice")
            }
            .padding(4)
            .background(Theme.background, in: Capsule())
            .padding(.horizontal, 14)
            .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity)
        .background {
            ZStack(alignment: .top) {
                Theme.surface
                GlowView()
                    .frame(height: 230)
                    .offset(y: -80)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 16, y: 6)
    }
}
