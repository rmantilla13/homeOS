import SwiftUI

struct TodayView: View {
    @Environment(FamilyStore.self) private var store

    private var todaysEvents: [FamilyEvent] {
        store.events.filter { Calendar.current.isDateInToday($0.startsAt) }
    }

    var body: some View {
        NavigationStack {
            List {
                if store.isParent && !store.pendingCompletions.isEmpty {
                    Section("Waiting for your OK") {
                        ForEach(store.pendingCompletions) { completion in
                            ApprovalRow(completion: completion)
                        }
                    }
                }
                Section("Today") {
                    if todaysEvents.isEmpty {
                        Text("Nothing scheduled").foregroundStyle(.secondary)
                    }
                    ForEach(todaysEvents) { EventRow(event: $0) }
                }
                Section("Points") {
                    ForEach(store.kids) { kid in
                        HStack {
                            MemberAvatar(member: kid)
                            Text(kid.displayName)
                            Spacer()
                            Label("\(store.points[kid.id] ?? 0)", systemImage: "star.fill")
                                .foregroundStyle(.orange)
                        }
                    }
                }
            }
            .navigationTitle(store.family?.name ?? "Today")
            .refreshable { await store.refresh() }
            .showsStoreErrors()
        }
    }
}

struct ApprovalRow: View {
    @Environment(FamilyStore.self) private var store
    let completion: TaskCompletion

    var body: some View {
        let task = store.tasks.first { $0.id == completion.taskId }
        HStack {
            MemberAvatar(member: store.member(completion.memberId))
            VStack(alignment: .leading) {
                Text(task?.title ?? "Chore")
                Text("+\(task?.points ?? 0) points").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await store.review(completion, approve: false) } } label: {
                Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            Button { Task { await store.review(completion, approve: true) } } label: {
                Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
            }
            .buttonStyle(.plain)
        }
    }
}

struct EventRow: View {
    @Environment(FamilyStore.self) private var store
    let event: FamilyEvent

    var body: some View {
        let first = store.member(event.members?.first?.memberId)
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(hex: first?.color ?? "#7C6CF2"))
                .frame(width: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.headline)
                if event.allDay {
                    Text("All day").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("\(event.startsAt.formatted(date: .omitted, time: .shortened)) – \(event.endsAt.formatted(date: .omitted, time: .shortened))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
        }
    }
}
