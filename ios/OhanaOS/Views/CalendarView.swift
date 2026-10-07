import SwiftUI

enum CalendarMode: String, CaseIterable {
    case day = "Day", week = "Week", month = "Month"
}

struct CalendarView: View {
    @Environment(FamilyStore.self) private var store
    #if DEBUG
    @State private var mode: CalendarMode = DemoMode.calendarMode
    #else
    @State private var mode: CalendarMode = .month
    #endif
    @State private var focusDate = Date.now
    @State private var showingAdd = false
    @State private var selectedEvent: FamilyEvent?

    private let calendar = Calendar.current

    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                VStack(spacing: 14) {
                    ScreenHeader(title: "Calendar", subtitle: store.family?.name) {
                        CircleIconButton(systemName: "plus") { showingAdd = true }
                            .accessibilityLabel("Add event")
                    }
                    SegmentedPill(CalendarMode.allCases, selection: $mode) { $0.rawValue }
                    navigator
                }
                .padding(.horizontal, Theme.page)

                Group {
                    switch mode {
                    case .month:
                        monthPage
                    case .week:
                        TimeGrid(days: weekDays, onSelectEvent: { selectedEvent = $0 },
                                 onSelectDay: { day in withAnimation(Theme.springy) { focusDate = day; mode = .day } })
                    case .day:
                        TimeGrid(days: [focusDate], onSelectEvent: { selectedEvent = $0 })
                    }
                }
                .id(mode)
                .transition(.opacity)
                .frame(maxHeight: .infinity, alignment: .top)
            }
            .screenBackground()
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showingAdd) { AddEventView(day: mode == .month ? nil : focusDate) }
            .sheet(item: $selectedEvent) { EventDetailView(event: $0) }
            .showsStoreErrors()
        }
    }

    // MARK: Period navigation

    private var navigator: some View {
        HStack(spacing: 6) {
            Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 34, height: 34) }
                .accessibilityLabel("Previous")
            Text(periodTitle)
                .font(.headline)
                .foregroundStyle(Theme.text)
                .contentTransition(.numericText())
                .lineLimit(1)
            Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 34, height: 34) }
                .accessibilityLabel("Next")
            Spacer()
            Button("Today") { withAnimation(Theme.springy) { focusDate = .now } }
                .buttonStyle(.pill(.soft))
        }
        .font(.body.weight(.semibold))
        .foregroundStyle(Theme.text)
    }

    private var periodTitle: String {
        switch mode {
        case .month:
            return focusDate.formatted(.dateTime.month(.wide).year())
        case .week:
            guard let first = weekDays.first, let last = weekDays.last else { return "" }
            return "\(first.formatted(.dateTime.month(.abbreviated).day())) – \(last.formatted(.dateTime.month(.abbreviated).day()))"
        case .day:
            return focusDate.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
    }

    private func shift(_ direction: Int) {
        let component: Calendar.Component = mode == .month ? .month : .day
        let amount = mode == .week ? 7 * direction : direction
        if let next = calendar.date(byAdding: component, value: amount, to: focusDate) {
            withAnimation(Theme.springy) { focusDate = next }
        }
    }

    private var weekDays: [Date] {
        let start = calendar.dateInterval(of: .weekOfYear, for: focusDate)?.start ?? calendar.startOfDay(for: focusDate)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    // MARK: Month

    private var monthPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                MonthGrid(month: focusDate) { day in
                    withAnimation(Theme.springy) {
                        focusDate = day
                        mode = .day
                    }
                }
                SectionHeader("Your upcoming activities")
                let upcoming = monthUpcoming
                if upcoming.isEmpty {
                    EmptyCard(text: "Nothing planned this month", systemImage: "calendar")
                }
                ForEach(upcoming) { event in
                    Button { selectedEvent = event } label: { ActivityCard(event: event) }
                        .buttonStyle(PressableStyle())
                }
            }
            .padding(.horizontal, Theme.page)
            .padding(.bottom, 24)
        }
        .refreshable { await store.refresh() }
    }

    /// Events in the shown month that haven't ended yet.
    private var monthUpcoming: [FamilyEvent] {
        guard let interval = calendar.dateInterval(of: .month, for: focusDate) else { return [] }
        let now = Date.now
        return Array(store.events
            .filter { $0.startsAt < interval.end && $0.endsAt >= max(interval.start, now) }
            .prefix(12))
    }
}

// MARK: - Month grid

struct MonthGrid: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.mood) private var mood
    let month: Date
    let onSelect: (Date) -> Void

    private let calendar = Calendar.current
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 0) {
                ForEach(Array(weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day {
                        Button { onSelect(day) } label: { dayCell(day) }
                            .buttonStyle(.plain)
                    } else {
                        Color.clear.frame(height: 56)
                    }
                }
            }
        }
        .card(padding: 12)
    }

    private func dayCell(_ day: Date) -> some View {
        let isToday = calendar.isDateInToday(day)
        let events = store.eventsOn(day)
        return VStack(spacing: 4) {
            Text("\(calendar.component(.day, from: day))")
                .font(.subheadline.weight(isToday ? .bold : .medium))
                .foregroundStyle(isToday ? Theme.background : Theme.text)
                .frame(width: 30, height: 30)
                .background {
                    if isToday { Circle().fill(Theme.text) }
                }
            VStack(spacing: 2) {
                ForEach(events.prefix(3)) { event in
                    Capsule()
                        .fill(store.color(for: event))
                        .frame(height: 4)
                }
            }
            .frame(width: 24, height: 16, alignment: .top)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 56)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(day.formatted(date: .complete, time: .omitted)), \(events.count) events")
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortWeekdaySymbols
        let first = calendar.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }

    /// Leading blanks for the first week, then each day of the month.
    private var days: [Date?] {
        guard let start = calendar.dateInterval(of: .month, for: month)?.start,
              let count = calendar.range(of: .day, in: .month, for: month)?.count else { return [] }
        let leading = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let blanks: [Date?] = Array(repeating: nil, count: leading)
        return blanks + (0..<count).map { calendar.date(byAdding: .day, value: $0, to: start) }
    }
}

// MARK: - Time grid (week and day)

struct TimeGrid: View {
    @Environment(FamilyStore.self) private var store
    let days: [Date]
    let onSelectEvent: (FamilyEvent) -> Void
    var onSelectDay: ((Date) -> Void)?

    private let hourHeight: CGFloat = 56
    private let gutter: CGFloat = 46
    private let calendar = Calendar.current

    private var compact: Bool { days.count > 1 }

    var body: some View {
        VStack(spacing: 0) {
            if compact { dayHeader }
            allDayStrip
            ScrollViewReader { proxy in
                ScrollView {
                    ZStack(alignment: .topLeading) {
                        hourLines
                        HStack(spacing: 0) {
                            Color.clear.frame(width: gutter)
                            ForEach(days, id: \.self) { day in
                                DayColumn(day: day,
                                          events: store.eventsOn(day).filter { !$0.allDay },
                                          hourHeight: hourHeight,
                                          compact: compact,
                                          onSelect: onSelectEvent)
                            }
                        }
                    }
                    .frame(height: hourHeight * 24)
                    .padding(.trailing, 8)
                    .padding(.top, 10)
                    .padding(.bottom, 24)
                }
                .onAppear { proxy.scrollTo(scrollHour, anchor: .top) }
            }
        }
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .padding(.horizontal, 12)
    }

    private var scrollHour: Int {
        #if DEBUG
        // Screenshots show the same hours whatever the runner's clock says.
        if DemoMode.isOn { return DemoMode.firstGridHour }
        #endif
        return days.contains(where: calendar.isDateInToday)
            ? max(0, calendar.component(.hour, from: .now) - 1)
            : 7
    }

    private var dayHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter)
            ForEach(days, id: \.self) { day in
                let isToday = calendar.isDateInToday(day)
                Button { onSelectDay?(day) } label: {
                    VStack(spacing: 3) {
                        Text(day.formatted(.dateTime.weekday(.narrow)))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Theme.muted)
                        Text("\(calendar.component(.day, from: day))")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(isToday ? Theme.background : Theme.text)
                            .frame(width: 28, height: 28)
                            .background { if isToday { Circle().fill(Theme.text) } }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.trailing, 8)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var allDayStrip: some View {
        let allDay = days.map { day in store.eventsOn(day).filter(\.allDay) }
        if allDay.contains(where: { !$0.isEmpty }) {
            HStack(alignment: .top, spacing: 0) {
                Text("all-day")
                    .font(.caption2)
                    .foregroundStyle(Theme.muted)
                    .frame(width: gutter - 6, alignment: .trailing)
                    .padding(.trailing, 6)
                ForEach(Array(days.enumerated()), id: \.offset) { index, _ in
                    VStack(spacing: 2) {
                        ForEach(allDay[index].prefix(compact ? 2 : 4)) { event in
                            let color = store.color(for: event)
                            Button { onSelectEvent(event) } label: {
                                Text(event.title)
                                    .font(.caption2.weight(.semibold))
                                    .lineLimit(1)
                                    .foregroundStyle(Theme.text)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(color.opacity(0.3), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 1)
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .padding(.trailing, 8)
            .padding(.vertical, 6)
        }
    }

    private var hourLines: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(alignment: .top, spacing: 6) {
                    Text(hourLabel(hour))
                        .font(.caption2)
                        .foregroundStyle(Theme.muted)
                        .frame(width: gutter - 6, alignment: .trailing)
                        .offset(y: -7)
                    Rectangle().fill(Theme.divider).frame(height: 1)
                }
                .frame(height: hourHeight, alignment: .top)
                .id(hour)
            }
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        guard hour > 0, let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: .now) else { return "" }
        return date.formatted(.dateTime.hour())
    }
}

/// One day's column of timed events, laid out side by side when they overlap.
struct DayColumn: View {
    let day: Date
    let events: [FamilyEvent]
    let hourHeight: CGFloat
    let compact: Bool
    let onSelect: (FamilyEvent) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let placed = EventLayout.place(events, on: day, hourHeight: hourHeight)
            ZStack(alignment: .topLeading) {
                ForEach(placed) { item in
                    let laneWidth = width / CGFloat(item.lanes)
                    Button { onSelect(item.event) } label: {
                        EventBlock(event: item.event, compact: compact)
                    }
                    .buttonStyle(PressableStyle())
                    .frame(width: max(0, laneWidth - 3), height: item.height)
                    .offset(x: laneWidth * CGFloat(item.lane) + 1.5, y: item.top)
                }
                if Calendar.current.isDateInToday(day), showsNowLine {
                    NowLine(hourHeight: hourHeight)
                }
            }
            .frame(width: width, height: geo.size.height, alignment: .topLeading)
        }
        .overlay(alignment: .leading) {
            if compact { Rectangle().fill(Theme.divider.opacity(0.6)).frame(width: 1) }
        }
    }

    /// Demo screenshots show 9:41 in the status bar; the real time would not match it.
    private var showsNowLine: Bool {
        #if DEBUG
        return !DemoMode.isOn
        #else
        return true
        #endif
    }
}

struct NowLine: View {
    let hourHeight: CGFloat

    var body: some View {
        TimelineView(.everyMinute) { context in
            let start = Calendar.current.startOfDay(for: context.date)
            let y = CGFloat(context.date.timeIntervalSince(start) / 3600) * hourHeight
            HStack(spacing: 0) {
                Circle().fill(Theme.danger).frame(width: 8, height: 8)
                Rectangle().fill(Theme.danger).frame(height: 2)
            }
            .offset(x: -4, y: y - 4)
        }
        .allowsHitTesting(false)
    }
}

struct EventBlock: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    let event: FamilyEvent
    let compact: Bool

    var body: some View {
        let color = store.color(for: event)
        let ink = scheme == .dark ? color.adjusted(brightness: 1.35, saturation: 0.6) : color.adjusted(brightness: 0.5, saturation: 1.2)
        let members = event.memberIds.compactMap { store.member($0) }
        VStack(alignment: .leading, spacing: 2) {
            Text(event.title)
                .font(compact ? Font.caption2.weight(.semibold) : Font.subheadline.weight(.semibold))
                .lineLimit(compact ? 3 : 2)
            if !compact {
                Text(timeLabel(for: event)).font(.caption)
                if let location = event.location, !location.isEmpty {
                    Text(location).font(.caption).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: -4) {
                ForEach(members.prefix(compact ? 2 : 4)) { member in
                    MemberAvatar(member: member, size: compact ? 14 : 20, ring: true)
                }
            }
        }
        .foregroundStyle(ink)
        .multilineTextAlignment(.leading)
        .padding(compact ? 4 : 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(color.opacity(scheme == .dark ? 0.35 : 0.28),
                    in: RoundedRectangle(cornerRadius: compact ? 8 : 12, style: .continuous))
        .clipped()
    }
}

/// Places timed events in lanes so overlapping ones sit side by side.
enum EventLayout {
    struct Placed: Identifiable {
        let event: FamilyEvent
        let lane: Int
        var lanes: Int
        let top: CGFloat
        let height: CGFloat
        var id: UUID { event.id }
    }

    static func place(_ events: [FamilyEvent], on day: Date, hourHeight: CGFloat) -> [Placed] {
        let dayStart = Calendar.current.startOfDay(for: day)
        let dayEnd = dayStart.addingTimeInterval(86_400)
        var result: [Placed] = []
        var cluster: [Int] = []
        var laneEnds: [Date] = []
        var clusterEnd = Date.distantPast

        func closeCluster() {
            for index in cluster { result[index].lanes = laneEnds.count }
            cluster = []
            laneEnds = []
        }

        for event in events.sorted(by: { $0.startsAt < $1.startsAt }) {
            let start = max(event.startsAt, dayStart)
            let end = min(max(event.endsAt, start.addingTimeInterval(15 * 60)), dayEnd)
            if start >= clusterEnd { closeCluster() }
            let lane = laneEnds.firstIndex { $0 <= start } ?? laneEnds.count
            if lane == laneEnds.count { laneEnds.append(end) } else { laneEnds[lane] = end }
            clusterEnd = max(clusterEnd, end)
            let top = CGFloat(start.timeIntervalSince(dayStart) / 3600) * hourHeight
            let height = max(CGFloat(end.timeIntervalSince(start) / 3600) * hourHeight, 22)
            result.append(Placed(event: event, lane: lane, lanes: 1, top: top, height: height))
            cluster.append(result.count - 1)
        }
        closeCluster()
        return result
    }
}

// MARK: - Event detail

struct EventDetailView: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let event: FamilyEvent
    @State private var confirmingDelete = false
    @State private var showingEdit = false

    /// The row after a save, so the sheet shows the new time and people.
    private var live: FamilyEvent {
        store.events.first { $0.id == event.id } ?? event
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    MemberTags(memberIds: live.memberIds)
                    Text(live.title)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.text)
                    VStack(alignment: .leading, spacing: 10) {
                        Label("\(dayLabel(for: live.startsAt)) · \(timeLabel(for: live))", systemImage: "clock")
                        if let location = live.location, !location.isEmpty {
                            Label(location, systemImage: "mappin.and.ellipse")
                        }
                        if live.rrule != nil {
                            Label("Repeats", systemImage: "repeat")
                        }
                    }
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)

                    let members = live.memberIds.compactMap { store.member($0) }
                    if !members.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(members) { member in
                                HStack(spacing: 10) {
                                    MemberAvatar(member: member, size: 30)
                                    Text(member.displayName).foregroundStyle(Theme.text)
                                }
                            }
                        }
                        .card(padding: 14, radius: Theme.radiusSm)
                    }
                }
                .padding(Theme.page)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .screenBackground()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Edit") { showingEdit = true } }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                Button("Delete event", role: .destructive) { confirmingDelete = true }
                    .buttonStyle(.pill(.destructive))
                    .padding(.bottom, 8)
            }
            .sheet(isPresented: $showingEdit) { AddEventView(event: live) }
            .confirmationDialog("Delete “\(live.title)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    Task {
                        await store.deleteEvent(live)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Add event

struct AddEventView: View {
    @Environment(FamilyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    private let existing: FamilyEvent?
    @State private var title: String
    @State private var location: String
    @State private var allDay: Bool
    @State private var start: Date
    @State private var end: Date
    @State private var who: Set<UUID>

    /// A new event starts on `day` at 9:00, or at the next full hour today.
    /// Pass `event` to edit one that already exists.
    init(day: Date? = nil, event: FamilyEvent? = nil) {
        existing = event
        if let event {
            _title = State(initialValue: event.title)
            _location = State(initialValue: event.location ?? "")
            _allDay = State(initialValue: event.allDay)
            _start = State(initialValue: event.startsAt)
            _end = State(initialValue: max(event.endsAt, event.startsAt))
            _who = State(initialValue: Set(event.memberIds))
            return
        }
        let calendar = Calendar.current
        let base: Date
        if let day, !calendar.isDateInToday(day) {
            base = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
        } else {
            base = calendar.nextDate(after: .now, matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? .now
        }
        _title = State(initialValue: "")
        _location = State(initialValue: "")
        _allDay = State(initialValue: false)
        _start = State(initialValue: base)
        _end = State(initialValue: base.addingTimeInterval(3600))
        _who = State(initialValue: [])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                    TextField("Location", text: $location)
                }
                Section {
                    Toggle("All day", isOn: $allDay)
                    DatePicker("Starts", selection: $start, displayedComponents: allDay ? .date : [.date, .hourAndMinute])
                    if !allDay {
                        DatePicker("Ends", selection: $end, in: start..., displayedComponents: [.date, .hourAndMinute])
                    }
                }
                Section("Who") {
                    ForEach(store.members) { member in
                        Button {
                            withAnimation(Theme.springy) {
                                if who.contains(member.id) { who.remove(member.id) } else { who.insert(member.id) }
                            }
                        } label: {
                            HStack {
                                MemberAvatar(member: member, size: 28)
                                Text(member.displayName).foregroundStyle(Theme.text)
                                Spacer()
                                if who.contains(member.id) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color(hex: member.color))
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .screenBackground()
            .onChange(of: start) { old, new in
                // Keep the event's length when the start moves.
                end = new.addingTimeInterval(max(end.timeIntervalSince(old), 15 * 60))
            }
            .navigationTitle(existing == nil ? "New event" : "Edit event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "Add" : "Save") {
                        let dayStart = Calendar.current.startOfDay(for: start)
                        let s = allDay ? dayStart : start
                        // All-day stays one day, unless this event already covered more than that.
                        let e: Date = {
                            guard allDay else { return end }
                            guard let existing, existing.allDay else { return dayStart.addingTimeInterval(86_399) }
                            let originalStart = Calendar.current.startOfDay(for: existing.startsAt)
                            let span = max(existing.endsAt.timeIntervalSince(originalStart), 86_399)
                            return dayStart.addingTimeInterval(span)
                        }()
                        let place = location.trimmingCharacters(in: .whitespacesAndNewlines)
                        Task {
                            if let existing {
                                await store.updateEvent(existing, title: title, location: place.isEmpty ? nil : place,
                                                        start: s, end: e, allDay: allDay, memberIds: who)
                            } else {
                                await store.addEvent(title: title, location: place.isEmpty ? nil : place,
                                                     start: s, end: e, allDay: allDay, memberIds: who)
                            }
                            dismiss()
                        }
                    }
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
