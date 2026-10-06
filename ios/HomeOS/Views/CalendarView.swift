import SwiftUI

struct CalendarView: View {
    @Environment(FamilyStore.self) private var store
    @State private var showingAdd = false

    private struct Day: Identifiable {
        let id: Date
        let events: [FamilyEvent]
    }

    private var days: [Day] {
        let grouped = Dictionary(grouping: store.events) { Calendar.current.startOfDay(for: $0.startsAt) }
        return grouped.keys.sorted()
            .filter { $0 >= Calendar.current.startOfDay(for: .now) }
            .map { Day(id: $0, events: grouped[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(days) { day in
                    Section(day.id.formatted(.dateTime.weekday(.wide).month().day())) {
                        ForEach(day.events) { event in
                            EventRow(event: event)
                                .swipeActions { Button("Delete", role: .destructive) { Task { await store.deleteEvent(event) } } }
                        }
                    }
                }
            }
            .overlay { if days.isEmpty { ContentUnavailableView("No upcoming events", systemImage: "calendar") } }
            .navigationTitle("Calendar")
            .toolbar { Button { showingAdd = true } label: { Image(systemName: "plus") } }
            .sheet(isPresented: $showingAdd) { AddEventView() }
            .refreshable { await store.refresh() }
            .showsStoreErrors()
        }
    }
}

struct AddEventView: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var location = ""
    @State private var allDay = false
    @State private var start = Date.now.addingTimeInterval(3600)
    @State private var end = Date.now.addingTimeInterval(7200)
    @State private var who: Set<UUID> = []

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                TextField("Location", text: $location)
                Toggle("All day", isOn: $allDay)
                DatePicker("Starts", selection: $start, displayedComponents: allDay ? .date : [.date, .hourAndMinute])
                if !allDay {
                    DatePicker("Ends", selection: $end, in: start..., displayedComponents: [.date, .hourAndMinute])
                }
                Section("Who") {
                    ForEach(store.members) { member in
                        Button {
                            if who.contains(member.id) { who.remove(member.id) } else { who.insert(member.id) }
                        } label: {
                            HStack {
                                MemberAvatar(member: member, size: 28)
                                Text(member.displayName).foregroundStyle(.primary)
                                Spacer()
                                if who.contains(member.id) { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            }
            .navigationTitle("New event")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let dayStart = Calendar.current.startOfDay(for: start)
                        let s = allDay ? dayStart : start
                        let e = allDay ? dayStart.addingTimeInterval(86_399) : end
                        Task {
                            await store.addEvent(title: title, location: location.isEmpty ? nil : location,
                                                 start: s, end: e, allDay: allDay, memberIds: who)
                            dismiss()
                        }
                    }
                    .disabled(title.isEmpty)
                }
            }
        }
    }
}
