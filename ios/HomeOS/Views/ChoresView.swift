import SwiftUI

struct ChoresView: View {
    @Environment(FamilyStore.self) private var store
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.members) { member in
                    let tasks = store.tasks.filter { $0.assigneeId == member.id }
                    if !tasks.isEmpty {
                        Section {
                            ForEach(tasks) { task in
                                HStack {
                                    Text(task.icon ?? "✔️")
                                    VStack(alignment: .leading) {
                                        Text(task.title)
                                        Text(repeatLabel(task.rrule)).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    if task.points > 0 { Text("+\(task.points) ★").foregroundStyle(.orange) }
                                }
                            }
                        } header: {
                            HStack { MemberAvatar(member: member, size: 22); Text(member.displayName) }
                        }
                    }
                }
            }
            .navigationTitle("Chores")
            .toolbar {
                if store.isParent { Button { showingAdd = true } label: { Image(systemName: "plus") } }
            }
            .sheet(isPresented: $showingAdd) { AddTaskView() }
            .refreshable { await store.refresh() }
            .showsStoreErrors()
        }
    }

    private func repeatLabel(_ rrule: String?) -> String {
        guard let rrule else { return "One time" }
        if rrule.contains("DAILY") { return "Every day" }
        if let days = rrule.components(separatedBy: "BYDAY=").last, rrule.contains("WEEKLY") { return "Weekly: \(days)" }
        return rrule
    }
}

struct AddTaskView: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var icon = "🧹"
    @State private var assignee: UUID?
    @State private var points = 10
    @State private var daily = true
    @State private var requiresApproval = true

    var body: some View {
        NavigationStack {
            Form {
                HStack {
                    TextField("Icon", text: $icon).frame(width: 44)
                    TextField("Chore", text: $title)
                }
                Picker("For", selection: $assignee) {
                    Text("Anyone").tag(UUID?.none)
                    ForEach(store.members) { Text($0.displayName).tag(Optional($0.id)) }
                }
                Stepper("Points: \(points)", value: $points, in: 0...200, step: 5)
                Toggle("Repeats every day", isOn: $daily)
                Toggle("Needs a parent's OK", isOn: $requiresApproval)
            }
            .navigationTitle("New chore")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let family = store.family else { return }
                        let task = NewTask(familyId: family.id, title: title, icon: icon, assigneeId: assignee,
                                           points: points, rrule: daily ? "FREQ=DAILY" : nil, requiresApproval: requiresApproval)
                        Task { await store.addTask(task); dismiss() }
                    }
                    .disabled(title.isEmpty)
                }
            }
        }
    }
}
