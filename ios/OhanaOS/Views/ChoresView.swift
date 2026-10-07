import SwiftUI

enum ChoresMode: String, CaseIterable {
    case chores = "Chores", rewards = "Rewards"
}

/// Chores for today per member, parent approvals, and the rewards shop.
struct ChoresView: View {
    @Environment(FamilyStore.self) private var store
    #if DEBUG
    @State private var mode: ChoresMode = DemoMode.choresMode
    #else
    @State private var mode: ChoresMode = .chores
    #endif
    @State private var showingAddTask = false
    @State private var showingAddReward = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ScreenHeader(title: mode.rawValue,
                                 subtitle: Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day())) {
                        if store.isParent {
                            CircleIconButton(systemName: "plus") {
                                if mode == .chores { showingAddTask = true } else { showingAddReward = true }
                            }
                            .accessibilityLabel(mode == .chores ? "Add chore" : "Add reward")
                        }
                    }
                    SegmentedPill(ChoresMode.allCases, selection: $mode) { $0.rawValue }
                    switch mode {
                    case .chores:
                        ChoreBoard().transition(.move(edge: .leading).combined(with: .opacity))
                    case .rewards:
                        RewardsBoard().transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, Theme.page)
                .padding(.bottom, 24)
            }
            .screenBackground()
            .refreshable { await store.refresh() }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingAddTask) { AddTaskView() }
            .sheet(isPresented: $showingAddReward) { AddRewardView() }
            .showsStoreErrors()
        }
    }
}

struct ChoreBoard: View {
    @Environment(FamilyStore.self) private var store

    var body: some View {
        let people = store.members.filter { !store.dueTasks(for: $0).isEmpty }
        let anyone = store.dueTasks(for: nil)
        VStack(alignment: .leading, spacing: 18) {
            if store.isParent && !store.pendingCompletions.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader("Waiting for your OK")
                    ForEach(store.pendingCompletions) { completion in
                        ApprovalCard(completion: completion)
                            .transition(.scale(scale: 0.9).combined(with: .opacity))
                    }
                }
            }
            ForEach(people) { member in
                MemberChoreCard(member: member)
            }
            if !anyone.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Image(systemName: "person.3.fill")
                            .foregroundStyle(Theme.muted)
                            .frame(width: 44, height: 44)
                            .background(Theme.sunken, in: Circle())
                        Text("Anyone").font(.headline).foregroundStyle(Theme.text)
                    }
                    ForEach(anyone) { task in ChoreRow(task: task, member: nil) }
                }
                .card()
            }
            if people.isEmpty && anyone.isEmpty && !store.choresLoadedToday {
                EmptyCard(text: "Today's chores haven't loaded yet. Pull to refresh.", systemImage: "arrow.clockwise")
            } else if people.isEmpty && anyone.isEmpty {
                EmptyCard(text: store.isParent ? "No chores today. Add one with +." : "No chores today.",
                          systemImage: "checkmark.circle")
            }
            if store.isParent {
                OtherChores()
            }
        }
        .animation(Theme.springy, value: store.completions)
    }
}

/// Parents only: chores that aren't up today (another day's repeat, or a
/// rule that has run out), folded away at the bottom so they can still be
/// found and removed.
struct OtherChores: View {
    @Environment(FamilyStore.self) private var store
    @State private var expanded = false

    var body: some View {
        let others = store.choresNotDueToday
        if !others.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button { withAnimation(Theme.springy) { expanded.toggle() } } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "calendar.badge.clock")
                            .foregroundStyle(Theme.muted)
                            .frame(width: 44, height: 44)
                            .background(Theme.sunken, in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Other chores").font(.headline).foregroundStyle(Theme.text)
                            Text("\(others.count) not due today").font(.caption).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Theme.muted)
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(expanded ? "Shown" : "Hidden")
                if expanded {
                    ForEach(others) { task in OtherChoreRow(task: task) }
                }
            }
            .card()
        }
    }
}

/// A chore that isn't up today: when it repeats and who it's for. Long-press
/// to remove it, as on today's list.
struct OtherChoreRow: View {
    @Environment(FamilyStore.self) private var store
    let task: FamilyTask

    var body: some View {
        HStack(spacing: 12) {
            Text(task.icon ?? "✔️")
                .font(.title3)
                .frame(width: 40, height: 40)
                .background(Theme.sunken, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.text)
                Text("\(ChoreRow.repeatLabel(task.rrule)) · \(store.member(task.assigneeId)?.displayName ?? "Anyone")")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Remove chore", systemImage: "trash", role: .destructive) { Task { await store.archiveTask(task) } }
        }
    }
}

struct MemberChoreCard: View {
    @Environment(FamilyStore.self) private var store
    let member: Member

    var body: some View {
        let tasks = store.dueTasks(for: member)
        let progress = store.choreProgress(for: member)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                MemberAvatar(member: member, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(member.displayName).font(.headline).foregroundStyle(Theme.text)
                    Text("\(progress.done) of \(progress.total) done")
                        .font(.caption)
                        .foregroundStyle(progress.done == progress.total ? Theme.success : Theme.muted)
                        .contentTransition(.numericText(value: Double(progress.done)))
                }
                Spacer()
                PointsText(value: store.points[member.id] ?? 0)
            }
            ProgressBar(value: progress.total == 0 ? 0 : Double(progress.done) / Double(progress.total),
                        color: Color(hex: member.color))
            VStack(spacing: 2) {
                ForEach(tasks) { task in ChoreRow(task: task, member: member) }
            }
        }
        .card()
    }
}

struct ChoreRow: View {
    @Environment(FamilyStore.self) private var store
    let task: FamilyTask
    /// nil for unassigned chores: anyone can do them.
    let member: Member?

    var body: some View {
        let completion = store.completion(of: task, by: member?.id)
        let status = completion?.status
        HStack(spacing: 12) {
            Text(task.icon ?? "✔️")
                .font(.title3)
                .frame(width: 40, height: 40)
                .background(Theme.sunken, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.subheadline.weight(.semibold))
                    .strikethrough(status == "approved", color: Theme.muted)
                    .foregroundStyle(status == "approved" ? Theme.muted : Theme.text)
                HStack(spacing: 6) {
                    Text(Self.repeatLabel(task.rrule))
                    if task.points > 0 {
                        Text("+\(task.points) ★").foregroundStyle(Theme.warning)
                    }
                    if status == "pending" {
                        Text("Waiting for OK").foregroundStyle(Theme.warning)
                    } else if status == "rejected" {
                        Text("Try again").foregroundStyle(Theme.danger)
                    }
                    if member == nil, let completion, let who = store.member(completion.memberId) {
                        Text("· \(who.displayName)")
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            statusControl(status)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .contextMenu {
            if store.isParent {
                if let completion {
                    Button("Undo", systemImage: "arrow.uturn.backward") { Task { await store.undo(completion) } }
                }
                Button("Remove chore", systemImage: "trash", role: .destructive) { Task { await store.archiveTask(task) } }
            }
        }
        .sensoryFeedback(.success, trigger: status == "approved")
    }

    @ViewBuilder
    private func statusControl(_ status: String?) -> some View {
        switch status ?? "" {
        case "approved":
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(Theme.success)
                .symbolEffect(.bounce, value: status)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
                .accessibilityLabel("Done")
        case "pending":
            Image(systemName: "clock.fill")
                .font(.system(size: 26))
                .foregroundStyle(Theme.warning)
                .transition(.scale(scale: 0.4).combined(with: .opacity))
                .accessibilityLabel("Waiting for approval")
        default:
            if let member {
                Button { Task { await store.markDone(task, by: member) } } label: { emptyCircle }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Mark \(task.title) done for \(member.displayName)")
            } else {
                Menu {
                    ForEach(store.members) { person in
                        Button(person.displayName) { Task { await store.markDone(task, by: person) } }
                    }
                } label: { emptyCircle }
                .accessibilityLabel("Mark \(task.title) done")
            }
        }
    }

    private var emptyCircle: some View {
        Circle()
            .stroke(Theme.divider, lineWidth: 2.5)
            .frame(width: 30, height: 30)
            .contentShape(Circle())
    }

    /// "Every day", "Weekdays", "Every 2 weeks: Mon, Thu", "Monthly"… from the
    /// chore's RRULE. The server decides when it's due; this only names it.
    static func repeatLabel(_ rrule: String?) -> String {
        guard let rrule, !rrule.trimmingCharacters(in: .whitespaces).isEmpty else { return "One time" }
        var parts: [String: String] = [:]
        for part in rrule.uppercased().replacingOccurrences(of: "RRULE:", with: "").split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { parts[pair[0]] = pair[1] }
        }
        let interval = max(Int(parts["INTERVAL"] ?? "") ?? 1, 1)
        let every: (String) -> String = { unit in interval > 1 ? "Every \(interval) \(unit)s" : "Every \(unit)" }
        switch parts["FREQ"] ?? "" {
        case "DAILY":
            return every("day")
        case "WEEKLY":
            let days = weekdayNames(parts["BYDAY"])
            if interval == 1 && parts["BYDAY"] == "MO,TU,WE,TH,FR" { return "Weekdays" }
            if interval == 1 && parts["BYDAY"] == "SA,SU" { return "Weekends" }
            if interval == 1 { return days.isEmpty ? "Weekly" : "Weekly: \(days)" }
            return days.isEmpty ? every("week") : "\(every("week")): \(days)"
        case "MONTHLY":
            return interval > 1 ? every("month") : "Monthly"
        case "YEARLY":
            return interval > 1 ? every("year") : "Yearly"
        default:
            return "Repeats"
        }
    }

    /// "MO,TH" → "Mon, Thu" in the phone's language. Ordinals ("2TU") keep their weekday.
    private static func weekdayNames(_ byDay: String?) -> String {
        let codes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
        let symbols = Calendar.current.shortWeekdaySymbols
        return (byDay ?? "").split(separator: ",")
            .compactMap { codes.firstIndex(of: String($0.suffix(2))) }
            .map { symbols[$0] }
            .joined(separator: ", ")
    }
}

struct AddTaskView: View {
    enum Repeat: String, CaseIterable {
        case once = "One time", daily = "Every day", weekdays = "Weekdays", weekends = "Weekends"

        var rrule: String? {
            switch self {
            case .once: return nil
            case .daily: return "FREQ=DAILY"
            case .weekdays: return "FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR"
            case .weekends: return "FREQ=WEEKLY;BYDAY=SA,SU"
            }
        }
    }

    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var icon = "🧹"
    @State private var assignee: UUID?
    @State private var points = 10
    @State private var repeats: Repeat = .daily
    @State private var requiresApproval = true

    private let icons = ["🧹", "🛏️", "🍽️", "🐶", "🧺", "🪴", "📚", "🦷", "🗑️", "🧸"]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Chore", text: $title)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(icons, id: \.self) { emoji in
                                Text(emoji)
                                    .font(.title2)
                                    .frame(width: 44, height: 44)
                                    .background(emoji == icon ? Theme.accentSoft : Theme.sunken, in: Circle())
                                    .onTapGesture { withAnimation(Theme.springy) { icon = emoji } }
                            }
                        }
                    }
                }
                Section {
                    Picker("For", selection: $assignee) {
                        Text("Anyone").tag(UUID?.none)
                        ForEach(store.members) { Text($0.displayName).tag(Optional($0.id)) }
                    }
                    Picker("Repeats", selection: $repeats) {
                        ForEach(Repeat.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    Stepper("Points: \(points)", value: $points, in: 0...200, step: 5)
                    Toggle("Needs a parent's OK", isOn: $requiresApproval)
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .navigationTitle("New chore")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let family = store.family else { return }
                        let task = NewTask(familyId: family.id, title: title, icon: icon, assigneeId: assignee,
                                           points: points, rrule: repeats.rrule, requiresApproval: requiresApproval)
                        Task { await store.addTask(task); dismiss() }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
