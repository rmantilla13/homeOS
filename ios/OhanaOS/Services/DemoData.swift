#if DEBUG
import UIKit

// Demo mode for App Store screenshots. Debug builds only: Release and
// TestFlight builds compile none of this file. Launch arguments land in
// UserDefaults' argument domain:
//
//   -OhanaDemo YES                       a sample family; Supabase and the network are never called
//   -OhanaScreen <name>                  what is on screen at launch (DemoScreen), default home
//   -OhanaMood <morning|day|evening|night>  pins the palette, default day
//
// .github/workflows/screenshots.yml launches the simulator build this way.
// See docs/IOS.md → Demo mode (screenshots).

/// The screens `-OhanaScreen` can open.
enum DemoScreen: String {
    case home
    case assistant
    case calendarWeek = "calendar-week"
    case calendarMonth = "calendar-month"
    case chores
    case rewards
    case media
    case family
}

enum DemoMode {
    static let isOn = UserDefaults.standard.bool(forKey: "OhanaDemo")

    static let screen: DemoScreen = UserDefaults.standard.string(forKey: "OhanaScreen")
        .flatMap { DemoScreen(rawValue: $0.lowercased()) } ?? .home

    /// The pinned palette: `-OhanaMood`, else day in demo mode. Nil lets the clock decide.
    static let mood: Mood? = {
        if let name = UserDefaults.standard.string(forKey: "OhanaMood"),
           let pinned = Mood(rawValue: name.lowercased()) {
            return pinned
        }
        return DemoMode.isOn ? .day : nil
    }()

    /// The account signed in on the demo phone: Sofia, a parent.
    static let userId = UUID(uuidString: "D3E0A0A0-0000-4000-8000-000000000001")!
    static let email = "sofia.rivera@example.com"

    /// The first hour the week and day grids show, whatever the time.
    static let firstGridHour = 8

    /// The answer to anything asked in demo mode, which sends nothing.
    static let offlineReply = "This is a demo, so nothing was sent. In the app, Ohana answers here."

    static var initialTab: AppTab {
        guard isOn else { return .home }
        switch screen {
        case .home, .assistant: return .home
        case .calendarWeek, .calendarMonth: return .calendar
        case .chores, .rewards: return .chores
        case .media: return .media
        case .family: return .family
        }
    }

    static var calendarMode: CalendarMode {
        isOn && screen == .calendarWeek ? .week : .month
    }

    static var choresMode: ChoresMode {
        isOn && screen == .rewards ? .rewards : .chores
    }

    /// Set once the assistant has opened over Home, so it opens only at launch.
    @MainActor static var assistantShown = false

    /// -OhanaScreen assistant, and not opened yet.
    @MainActor static var opensAssistant: Bool {
        isOn && screen == .assistant && !assistantShown
    }
}

// MARK: - Loading the sample family

extension FamilyStore {
    /// Fills the store with the Rivera family and opens it. Nothing here
    /// touches Supabase or the network.
    func loadDemo() {
        let sample = DemoFamily(now: .now)
        errorMessage = nil
        families = [sample.family]
        family = sample.family
        members = sample.members
        profiles = sample.profiles
        devices = sample.devices
        invites = sample.invites
        events = sample.events
        tasks = sample.tasks
        completions = sample.completions
        markDemoChoresDue()
        rewards = sample.rewards
        redemptions = sample.redemptions
        points = sample.points
        lists = sample.lists
        listItems = sample.listItems
        meals = sample.meals
        memories = sample.memories
        media = sample.media
        DemoMedia.seed(sample.media)
        threads = sample.threads
        currentThreadId = DemoFamily.weekThreadId
        chat = demoTranscript(for: DemoFamily.weekThreadId)
        phase = .ready
    }

    /// The sample chores up on `day`. On the server `chores_due` decides; the
    /// sample chores only repeat daily or weekly on named days, so that is
    /// all this reads. A chore with no rule is up until someone finishes it.
    func demoDueTaskIds(on day: Date) -> Set<UUID> {
        let codes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
        let code = codes[Calendar.current.component(.weekday, from: day) - 1]
        let key = DayKey.string(day)
        let due = tasks.filter { task in
            guard let rule = task.rrule?.uppercased(), !rule.isEmpty else {
                return !completions.contains { $0.taskId == task.id && $0.forDate < key && $0.status != "rejected" }
            }
            guard rule.contains("FREQ=WEEKLY"),
                  let byDay = rule.components(separatedBy: "BYDAY=").dropFirst().first else { return true }
            return byDay.split(separator: ";").first?.split(separator: ",").contains { $0 == code } ?? true
        }
        return Set(due.map(\.id))
    }

    /// A demo thread's conversation, written from the sample data on screen.
    func demoTranscript(for threadId: UUID) -> [ChatMessage] {
        let calendar = Calendar.current
        let now = Date.now
        let dinner = meal(.dinner, on: DayKey.today)?.title ?? "Chicken tacos"

        if threadId == DemoFamily.dinnerThreadId {
            let salmonDay = calendar.date(byAdding: .day, value: 2, to: calendar.startOfDay(for: now)) ?? now
            let dayName = salmonDay.formatted(.dateTime.weekday(.wide))
            let reply = """
            Three that take under 30 minutes:
            • **Sheet-pan salmon and veggies**, one pan and 25 minutes
            • **Teriyaki chicken bowls**, with rice from the rice cooker
            • **Quesadillas**, Leo's favorite

            I put the salmon on \(dayName). Want me to add lemons to the grocery list?
            """
            return [
                ChatMessage(role: .user, text: "Ideas for quick dinners on soccer nights?"),
                ChatMessage(role: .assistant, text: reply, actions: [
                    AssistantAction(type: "set_meal", summary: "Set dinner on \(dayName): Sheet-pan salmon and veggies"),
                ]),
            ]
        }

        guard threadId == DemoFamily.weekThreadId else { return [] }

        let soccer = events.first { $0.title == "Soccer practice" && $0.startsAt > now }
        let soccerDay = soccer?.startsAt.formatted(.dateTime.weekday(.wide)) ?? "Thursday"
        let soccerShortDay = soccer?.startsAt.formatted(.dateTime.weekday(.abbreviated)) ?? "Thu"
        let soccerTime = soccer?.startsAt.formatted(date: .omitted, time: .shortened) ?? "4:30 PM"
        let place = soccer?.location ?? "Riverside Park"

        let weekAhead = now.addingTimeInterval(7 * 86_400)
        let coming = events
            .filter { $0.startsAt > now && $0.startsAt < weekAhead }
            .filter { $0.title != "School pickup" && $0.title != "Soccer practice" }
            .prefix(4)
        let lines = coming.map { event -> String in
            let day: String
            if calendar.isDateInToday(event.startsAt) {
                day = "Today"
            } else if calendar.isDateInTomorrow(event.startsAt) {
                day = "Tomorrow"
            } else {
                day = event.startsAt.formatted(.dateTime.weekday(.wide))
            }
            let names = event.memberIds.compactMap { member($0)?.displayName }
            let who = names.isEmpty || names.count == members.count ? "" : " (\(names.joined(separator: ", ")))"
            let time = event.allDay ? "all day" : event.startsAt.formatted(date: .omitted, time: .shortened)
            return "• **\(day)** \(event.title)\(who), \(time)"
        }

        var reply = "Done. Soccer practice is on the calendar for \(soccerDay) at \(soccerTime), \(place)."
        if !lines.isEmpty {
            reply += "\n\nAlso coming up:\n" + lines.joined(separator: "\n")
        }
        reply += "\n\nDinner tonight is **\(dinner)**."

        return [
            ChatMessage(role: .user, text: "What's for dinner tonight?"),
            ChatMessage(role: .assistant,
                        text: "**\(dinner)**. Leo's go without cilantro, and tortillas are already on the grocery list."),
            ChatMessage(role: .user,
                        text: "Add Maya's soccer practice on \(soccerDay) at \(soccerTime). What else is on this week?"),
            ChatMessage(role: .assistant, text: reply, actions: [
                AssistantAction(type: "create_event",
                                summary: "Added “Soccer practice” for Maya on \(soccerShortDay) \(soccerTime)"),
            ]),
        ]
    }
}

// MARK: - The Rivera family

/// One believable family: Sofia and Marco (parents, both with logins), Maya
/// (9, with a login) and Leo (6, without). Every date is relative to today,
/// so the calendar is never stale.
private struct DemoFamily {
    static let familyId = UUID(uuidString: "D3E0A0A0-0000-4000-8000-0000000000F1")!
    static let marcoUserId = UUID(uuidString: "D3E0A0A0-0000-4000-8000-000000000002")!
    static let mayaUserId = UUID(uuidString: "D3E0A0A0-0000-4000-8000-000000000003")!
    static let weekThreadId = UUID(uuidString: "D3E0A0A0-0000-4000-8000-0000000000A1")!
    static let dinnerThreadId = UUID(uuidString: "D3E0A0A0-0000-4000-8000-0000000000A2")!

    let family: Family
    let members: [Member]
    let profiles: [Profile]
    let devices: [Device]
    let invites: [FamilyInvite]
    let events: [FamilyEvent]
    let tasks: [FamilyTask]
    let completions: [TaskCompletion]
    let rewards: [Reward]
    let redemptions: [RewardRedemption]
    let points: [UUID: Int]
    let lists: [FamilyList]
    let listItems: [ListItem]
    let meals: [MealPlan]
    let memories: [FamilyMemory]
    let media: [MediaItem]
    let threads: [AssistantThread]

    init(now: Date) {
        let calendar = Calendar.current
        let fid = Self.familyId
        let today = calendar.startOfDay(for: now)
        let dayLength: TimeInterval = 86_400

        family = Family(id: fid, name: "The Rivera Family", timezone: "America/New_York")

        // Members and accounts.
        let sofia = Member(id: UUID(), familyId: fid, userId: DemoMode.userId, displayName: "Sofia",
                           role: .parent, color: "#8E9CE6", sortOrder: 0)
        let marco = Member(id: UUID(), familyId: fid, userId: Self.marcoUserId, displayName: "Marco",
                           role: .parent, color: "#5FB3B3", sortOrder: 1)
        let maya = Member(id: UUID(), familyId: fid, userId: Self.mayaUserId, displayName: "Maya",
                          role: .child, color: "#EF8A6F", sortOrder: 2)
        let leo = Member(id: UUID(), familyId: fid, userId: nil, displayName: "Leo",
                         role: .child, color: "#7CC08B", sortOrder: 3)
        let everyone = [sofia, marco, maya, leo]
        members = everyone
        profiles = [
            Profile(id: DemoMode.userId, displayName: "Sofia Rivera", avatarPath: nil, updatedAt: nil),
            Profile(id: Self.marcoUserId, displayName: "Marco Rivera", avatarPath: nil, updatedAt: nil),
            Profile(id: Self.mayaUserId, displayName: "Maya Rivera", avatarPath: nil, updatedAt: nil),
        ]
        devices = [Device(id: UUID(), name: "Kitchen display", lastSeenAt: now.addingTimeInterval(-90))]
        invites = [
            FamilyInvite(id: UUID(), code: "RVRA7K2M", role: .other, memberId: nil, email: "abuela@example.com",
                         createdAt: now.addingTimeInterval(-dayLength), expiresAt: now.addingTimeInterval(13 * dayLength),
                         acceptedBy: nil, acceptedAt: nil, revokedAt: nil),
            FamilyInvite(id: UUID(), code: "MAYA9R2T", role: .child, memberId: maya.id, email: nil,
                         createdAt: now.addingTimeInterval(-32 * dayLength), expiresAt: now.addingTimeInterval(-25 * dayLength),
                         acceptedBy: Self.mayaUserId, acceptedAt: now.addingTimeInterval(-31 * dayLength), revokedAt: nil),
            FamilyInvite(id: UUID(), code: "MRCO4H8P", role: .parent, memberId: nil, email: nil,
                         createdAt: now.addingTimeInterval(-60 * dayLength), expiresAt: now.addingTimeInterval(-53 * dayLength),
                         acceptedBy: Self.marcoUserId, acceptedAt: now.addingTimeInterval(-59 * dayLength), revokedAt: nil),
        ]

        // Calendar: this week, the weeks around it, and the rest of the month.
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
        /// The day with this weekday (1 is Sunday) in this week, or `week` weeks away.
        func weekday(_ weekday: Int, week: Int = 0) -> Date {
            let offset = (weekday - calendar.firstWeekday + 7) % 7 + 7 * week
            return calendar.date(byAdding: .day, value: offset, to: weekStart) ?? weekStart
        }
        func startTime(_ day: Date, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        /// A repeating event: one stored row, so each of its repeats has the
        /// same `eventId` and series start, as `event_occurrences` returns them.
        struct Series {
            let id = UUID()
            let rrule: String
            let firstStart: Date
        }
        var calendarEvents: [FamilyEvent] = []
        func event(_ title: String, _ start: Date, minutes: Int, at location: String?,
                   for people: [Member], color: String? = nil, repeating series: Series? = nil) {
            let length = TimeInterval(minutes * 60)
            calendarEvents.append(FamilyEvent(
                eventId: series?.id ?? UUID(), familyId: fid, title: title, location: location,
                startsAt: start, endsAt: start.addingTimeInterval(length),
                allDay: false, color: color, rrule: series?.rrule,
                seriesStartsAt: series?.firstStart, seriesEndsAt: series.map { $0.firstStart.addingTimeInterval(length) },
                memberIds: people.map(\.id)))
        }
        func allDay(_ title: String, _ first: Date, days: Int = 1, at location: String?,
                    for people: [Member], color: String? = nil) {
            let start = calendar.startOfDay(for: first)
            let lastDay = calendar.date(byAdding: .day, value: days - 1, to: start) ?? start
            calendarEvents.append(FamilyEvent(
                eventId: UUID(), familyId: fid, title: title, location: location,
                startsAt: start, endsAt: lastDay.addingTimeInterval(dayLength - 1),
                allDay: true, color: color, rrule: nil,
                memberIds: people.map(\.id)))
        }

        // The weekly routine, five weeks either side, so any month view is full.
        // Each is a repeating event that started five weeks ago.
        let pickupMonFri = Series(rrule: "FREQ=WEEKLY;BYDAY=MO,FR", firstStart: startTime(weekday(2, week: -5), 15))
        let pickupWed = Series(rrule: "FREQ=WEEKLY;BYDAY=WE", firstStart: startTime(weekday(4, week: -5), 15))
        let piano = Series(rrule: "FREQ=WEEKLY;BYDAY=MO", firstStart: startTime(weekday(2, week: -5), 16))
        let soccer = Series(rrule: "FREQ=WEEKLY;BYDAY=TU,TH", firstStart: startTime(weekday(3, week: -5), 16, 30))
        for week in -5...5 {
            event("School pickup", startTime(weekday(2, week: week), 15), minutes: 30, at: "Lincoln Elementary",
                  for: [marco, maya, leo], repeating: pickupMonFri)
            event("Piano lesson", startTime(weekday(2, week: week), 16), minutes: 45, at: "Harmony Music School",
                  for: [leo], repeating: piano)
            event("Soccer practice", startTime(weekday(3, week: week), 16, 30), minutes: 75, at: "Riverside Park, field 3",
                  for: [maya], repeating: soccer)
            event("School pickup", startTime(weekday(4, week: week), 15), minutes: 30, at: "Lincoln Elementary",
                  for: [sofia, maya, leo], repeating: pickupWed)
            event("Soccer practice", startTime(weekday(5, week: week), 16, 30), minutes: 75, at: "Riverside Park, field 3",
                  for: [maya], repeating: soccer)
            event("School pickup", startTime(weekday(6, week: week), 15), minutes: 30, at: "Lincoln Elementary",
                  for: [marco, maya, leo], repeating: pickupMonFri)
        }

        // Last week.
        event("Swim lesson", startTime(weekday(7, week: -1), 11), minutes: 45, at: "Community pool", for: [leo])
        event("Grandpa's birthday dinner", startTime(weekday(1, week: -1), 17), minutes: 120, at: "Abuela's house",
              for: everyone, color: "#E58FB5")

        // This week.
        allDay("Apple picking", weekday(1), at: "Hillside Orchard", for: everyone, color: "#F2B84B")
        event("Family dinner at Abuela's", startTime(weekday(1), 18), minutes: 90, at: "Abuela's house",
              for: everyone, color: "#B48EE0")
        event("PTA meeting", startTime(weekday(4), 19), minutes: 60, at: "Lincoln Elementary", for: [sofia])
        event("Dentist", startTime(weekday(5), 9, 30), minutes: 60, at: "Bright Smiles Dental", for: [leo, sofia])
        event("Pizza and movie night", startTime(weekday(6), 18, 30), minutes: 120, at: nil,
              for: everyone, color: "#E58FB5")
        event("Soccer game", startTime(weekday(7), 9), minutes: 60, at: "Riverside Park", for: [maya, marco])
        event("Sophie's birthday party", startTime(weekday(7), 13), minutes: 120, at: "Jump Park", for: [maya, sofia])

        // Next week and after.
        event("Parent-teacher conference", startTime(weekday(3, week: 1), 17, 45), minutes: 30, at: "Lincoln Elementary",
              for: [sofia, marco])
        allDay("Science museum field trip", weekday(4, week: 1), at: "City Science Center", for: [maya])
        event("Flu shots", startTime(weekday(7, week: 1), 10), minutes: 45, at: "Riverside Pediatrics", for: everyone)
        event("Haircuts", startTime(weekday(5, week: 2), 17), minutes: 45, at: "Main Street salon", for: [maya, leo])
        allDay("Weekend at Lake George", weekday(6, week: 2), days: 3, at: "Lake George", for: everyone,
               color: "#5FB3B3")

        events = calendarEvents.sorted { $0.startsAt < $1.startsAt }

        // Chores, for the kids and anyone. Daily ones show every day; the weekly one falls on today.
        let codes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
        let todayCode = codes[calendar.component(.weekday, from: now) - 1]
        let daily = "FREQ=DAILY"
        let weeklyToday = "FREQ=WEEKLY;BYDAY=\(todayCode)"
        func chore(_ title: String, _ icon: String, for member: Member?, points: Int, rrule: String,
                   approval: Bool) -> FamilyTask {
            FamilyTask(id: UUID(), familyId: fid, title: title, icon: icon, assigneeId: member?.id, points: points,
                       dueDate: nil, rrule: rrule, requiresApproval: approval)
        }
        let makeBed = chore("Make bed", "🛏️", for: maya, points: 5, rrule: daily, approval: false)
        let feedDog = chore("Feed Biscuit", "🐶", for: maya, points: 10, rrule: daily, approval: true)
        let reading = chore("Read for 20 minutes", "📚", for: maya, points: 15, rrule: daily, approval: true)
        let setTable = chore("Set the table", "🍽️", for: maya, points: 10, rrule: daily, approval: true)
        let tidyToys = chore("Tidy up toys", "🧸", for: leo, points: 5, rrule: daily, approval: true)
        let brushTeeth = chore("Brush teeth", "🦷", for: leo, points: 5, rrule: daily, approval: false)
        let plants = chore("Water the plants", "🪴", for: leo, points: 10, rrule: weeklyToday, approval: true)
        let sweep = chore("Sweep the kitchen", "🧹", for: nil, points: 10, rrule: daily, approval: true)
        tasks = [makeBed, feedDog, reading, setTable, tidyToys, brushTeeth, plants, sweep]

        let todayKey = DayKey.string(now)
        let yesterdayKey = DayKey.string(now.addingTimeInterval(-dayLength))
        func done(_ task: FamilyTask, by member: Member, on key: String, _ status: String = "approved") -> TaskCompletion {
            TaskCompletion(id: UUID(), taskId: task.id, memberId: member.id, forDate: key, status: status)
        }
        completions = [
            done(makeBed, by: maya, on: yesterdayKey),
            done(feedDog, by: maya, on: yesterdayKey),
            done(reading, by: maya, on: yesterdayKey),
            done(brushTeeth, by: leo, on: yesterdayKey),
            done(makeBed, by: maya, on: todayKey),
            done(feedDog, by: maya, on: todayKey),
            done(reading, by: maya, on: todayKey, "pending"),
            done(tidyToys, by: leo, on: todayKey),
            done(brushTeeth, by: leo, on: todayKey),
        ]

        // Rewards and points.
        func reward(_ title: String, _ icon: String, cost: Int) -> Reward {
            Reward(id: UUID(), familyId: fid, title: title, icon: icon, cost: cost, active: true)
        }
        let iceCream = reward("Ice cream trip", "🍦", cost: 50)
        rewards = [
            reward("Extra screen time", "📱", cost: 30),
            reward("Pick the movie", "🎬", cost: 40),
            iceCream,
            reward("Stay up 30 minutes late", "🌙", cost: 60),
            reward("New book", "📖", cost: 100),
            reward("Trampoline park", "🤸", cost: 200),
        ]
        redemptions = [
            RewardRedemption(id: UUID(), rewardId: iceCream.id, memberId: leo.id, cost: 50, status: "requested",
                             createdAt: now.addingTimeInterval(-2 * 3_600)),
        ]
        points = [maya.id: 145, leo.id: 85]

        // Lists.
        let groceries = FamilyList(id: UUID(), familyId: fid, name: "Groceries", kind: "shopping", sortOrder: 0)
        let packing = FamilyList(id: UUID(), familyId: fid, name: "Lake George packing", kind: "todo", sortOrder: 1)
        lists = [groceries, packing]
        func item(_ text: String, _ quantity: String? = nil, on list: FamilyList, done: Bool = false) -> ListItem {
            ListItem(id: UUID(), listId: list.id, text: text, quantity: quantity, done: done)
        }
        listItems = [
            item("Tortillas", on: groceries),
            item("Avocados", "3", on: groceries),
            item("Milk", "1 gallon", on: groceries),
            item("Bananas", on: groceries),
            item("Apples for lunches", on: groceries),
            item("Chicken thighs", "2 lb", on: groceries),
            item("Spinach", on: groceries),
            item("Cheddar", on: groceries, done: true),
            item("Coffee beans", on: groceries, done: true),
            item("Cereal", on: groceries, done: true),
            item("Sleeping bags", on: packing),
            item("Flashlights", on: packing, done: true),
            item("Sunscreen", on: packing),
            item("Board games", on: packing),
            item("Rain jackets", on: packing),
        ]

        // Meals for the next seven days.
        func mealKey(_ offset: Int) -> String {
            DayKey.string(calendar.date(byAdding: .day, value: offset, to: today) ?? today)
        }
        func plan(_ offset: Int, _ slot: MealSlot, _ title: String, notes: String? = nil) -> MealPlan {
            MealPlan(id: UUID(), familyId: fid, date: mealKey(offset), meal: slot, title: title, notes: notes)
        }
        meals = [
            plan(0, .breakfast, "Banana pancakes"),
            plan(0, .lunch, "Turkey sandwiches"),
            plan(0, .dinner, "Chicken tacos", notes: "No cilantro on Leo's"),
            plan(1, .lunch, "Leftover tacos"),
            plan(1, .dinner, "Spaghetti and meatballs"),
            plan(2, .breakfast, "Yogurt and granola"),
            plan(2, .dinner, "Sheet-pan salmon and veggies"),
            plan(3, .lunch, "Quesadillas"),
            plan(3, .dinner, "Homemade pizza night"),
            plan(4, .dinner, "Teriyaki chicken bowls"),
            plan(5, .breakfast, "Waffles"),
            plan(5, .dinner, "Burgers on the grill"),
            plan(6, .dinner, "Abuela's arroz con pollo"),
        ]

        // Family memory, newest first.
        memories = [
            FamilyMemory(id: UUID(), content: "Leo doesn't like cilantro.", source: "assistant",
                         createdAt: now.addingTimeInterval(-3 * dayLength)),
            FamilyMemory(id: UUID(), content: "Biscuit eats at 7 AM and 6 PM.", source: "manual",
                         createdAt: now.addingTimeInterval(-9 * dayLength)),
            FamilyMemory(id: UUID(), content: "Marco does school pickup on Mondays and Fridays.", source: "assistant",
                         createdAt: now.addingTimeInterval(-14 * dayLength)),
            FamilyMemory(id: UUID(), content: "Maya has soccer practice Tuesdays and Thursdays at Riverside Park.",
                         source: "assistant", createdAt: now.addingTimeInterval(-20 * dayLength)),
            FamilyMemory(id: UUID(), content: "Leo's favorite snack is apple slices.", source: "manual",
                         createdAt: now.addingTimeInterval(-40 * dayLength)),
        ]

        // Assistant history.
        threads = [
            AssistantThread(id: Self.weekThreadId, title: "Soccer practice and our week",
                            updatedAt: now.addingTimeInterval(-4 * 60)),
            AssistantThread(id: Self.dinnerThreadId, title: "Quick dinners for soccer nights",
                            updatedAt: now.addingTimeInterval(-2 * dayLength)),
        ]

        media = Self.mediaItems(familyId: fid, now: now)
    }

    /// Rows as the server sends them. MediaItem has a custom decoder and no
    /// memberwise init, so these go through JSON like real rows.
    private static func mediaItems(familyId: UUID, now: Date) -> [MediaItem] {
        let iso = ISO8601DateFormatter()
        var rows: [[String: Any]] = []
        for (index, scene) in DemoScene.allCases.enumerated() {
            let taken = now.addingTimeInterval(-TimeInterval(scene.daysAgo) * 86_400 - TimeInterval(index % 5) * 3_600)
            let width: Int = scene.isVideo ? 1920 : (scene.isPortrait ? 3024 : 4032)
            let height: Int = scene.isVideo ? 1080 : (scene.isPortrait ? 4032 : 3024)
            let fileExtension = scene.isVideo ? "mov" : "jpg"
            let kind = scene.isVideo ? "video" : "photo"
            let contentType = scene.isVideo ? "video/quicktime" : "image/jpeg"
            // One hidden from the wall frame, to show its badge.
            let onFrame: Bool = scene != .cityDusk
            var row: [String: Any] = [:]
            row["id"] = UUID().uuidString
            row["family_id"] = familyId.uuidString
            row["storage_path"] = "demo/\(scene.rawValue).\(fileExtension)"
            row["kind"] = kind
            row["file_store"] = "blob"
            row["width"] = width
            row["height"] = height
            row["caption"] = scene.caption
            row["taken_at"] = iso.string(from: taken)
            row["created_at"] = iso.string(from: taken.addingTimeInterval(3_600))
            row["show_on_frame"] = onFrame
            row["content_type"] = contentType
            if let seconds = scene.durationSeconds { row["duration_seconds"] = seconds }
            rows.append(row)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard JSONSerialization.isValidJSONObject(rows),
              let data = try? JSONSerialization.data(withJSONObject: rows),
              let items = try? decoder.decode([MediaItem].self, from: data) else { return [] }
        return items
    }
}

// MARK: - Demo photos and videos

/// Pictures drawn in code stand in for the family's photos. There are no
/// photo assets in the bundle and demo mode never downloads anything.
@MainActor
enum DemoMedia {
    /// Puts each item's thumbnail and average color in the cache the grid
    /// and the viewer read.
    static func seed(_ items: [MediaItem]) {
        for item in items {
            guard let scene = DemoScene(path: item.storagePath) else { continue }
            MediaCache.shared.seedThumbnail(render(scene, longSide: 480), for: item)
        }
    }

    /// A screen-sized version for the viewer, drawn when it opens.
    static func fullImage(for item: MediaItem) -> UIImage? {
        guard let scene = DemoScene(path: item.storagePath), !scene.isVideo else { return nil }
        return render(scene, longSide: 1600)
    }

    private static func render(_ scene: DemoScene, longSide: CGFloat) -> UIImage {
        let shortSide = (longSide * 0.75).rounded()
        let size = scene.isPortrait
            ? CGSize(width: shortSide, height: longSide)
            : CGSize(width: longSide, height: shortSide)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            scene.draw(on: DemoCanvas(ctx: context.cgContext, size: size))
        }
    }
}

/// One picture per case, newest first. The raw value is the file name in
/// `storage_path`, which is how a cached item finds its picture again.
private enum DemoScene: String, CaseIterable {
    case pumpkinPatch = "pumpkin-patch"
    case soccerGame = "soccer-game"
    case appleOrchard = "apple-orchard"
    case autumnPark = "autumn-park"
    case balloons
    case sunsetHills = "sunset-hills"
    case sailboat
    case cityDusk = "city-dusk"
    case rainbow
    case fireworks
    case meadow
    case picnic
    case mountainLake = "mountain-lake"
    case nightSky = "night-sky"
    case beach
    case waves

    init?(path: String) {
        let file = path.split(separator: "/").last.map(String.init) ?? path
        let name = file.split(separator: ".").first.map(String.init) ?? file
        self.init(rawValue: name)
    }

    var isVideo: Bool { self == .soccerGame || self == .fireworks }

    var isPortrait: Bool { self == .balloons || self == .autumnPark }

    var durationSeconds: Double? {
        switch self {
        case .soccerGame: return 42
        case .fireworks: return 18.5
        default: return nil
        }
    }

    var daysAgo: Int {
        switch self {
        case .pumpkinPatch: return 1
        case .soccerGame: return 3
        case .appleOrchard: return 5
        case .autumnPark: return 8
        case .balloons: return 11
        case .sunsetHills: return 14
        case .sailboat: return 18
        case .cityDusk: return 22
        case .rainbow: return 26
        case .fireworks: return 31
        case .meadow: return 36
        case .picnic: return 40
        case .mountainLake: return 44
        case .nightSky: return 45
        case .beach: return 52
        case .waves: return 53
        }
    }

    var caption: String {
        switch self {
        case .pumpkinPatch: return "Pumpkin patch"
        case .soccerGame: return "Maya's soccer game"
        case .appleOrchard: return "Apple picking"
        case .autumnPark: return "Leaves in the park"
        case .balloons: return "Birthday balloons"
        case .sunsetHills: return "Sunset from the porch"
        case .sailboat: return "Sailing on the lake"
        case .cityDusk: return "City lights"
        case .rainbow: return "After the storm"
        case .fireworks: return "Fireworks"
        case .meadow: return "Wildflowers"
        case .picnic: return "Picnic in the park"
        case .mountainLake: return "Lake George"
        case .nightSky: return "Camping under the stars"
        case .beach: return "Beach day"
        case .waves: return "Waves"
        }
    }

    func draw(on c: DemoCanvas) {
        switch self {
        case .pumpkinPatch: drawPumpkinPatch(c)
        case .soccerGame: drawSoccerGame(c)
        case .appleOrchard: drawOrchard(c, fruit: 0xD94141, seed: 23)
        case .autumnPark: drawAutumnPark(c)
        case .balloons: drawBalloons(c)
        case .sunsetHills: drawSunsetHills(c)
        case .sailboat: drawSailboat(c)
        case .cityDusk: drawCityDusk(c)
        case .rainbow: drawRainbow(c)
        case .fireworks: drawFireworks(c)
        case .meadow: drawMeadow(c)
        case .picnic: drawPicnic(c)
        case .mountainLake: drawMountainLake(c)
        case .nightSky: drawNightSky(c)
        case .beach: drawBeach(c)
        case .waves: drawWaves(c)
        }
    }

    // MARK: Scenes

    private func drawPumpkinPatch(_ c: DemoCanvas) {
        c.sky([0x8EC5FC, 0xFFD3A5, 0xFFB677], bottom: 0.62)
        c.glow(0.8, 0.42, radius: 0.35, 0xFFE8B0, 0.7)
        c.disc(0.8, 0.42, radius: 0.07, 0xFFF1C9)
        c.cloud(0.22, 0.18, size: 1)
        c.ridge([(0, 0.56), (0.3, 0.5), (0.6, 0.57), (1, 0.51)], 0x9BB168)
        c.ridge([(0, 0.62), (0.5, 0.58), (1, 0.63)], gradient: [0x7A9A4A, 0x4F6E2E])
        var rng = SeededRandom(11)
        for row in 0..<4 {
            let y = 0.67 + CGFloat(row) * 0.09
            let size = 0.03 + CGFloat(row) * 0.016
            let count = 7 - row
            for i in 0..<count {
                let x = (CGFloat(i) + 0.5 + rng.next(-0.25, 0.25)) / CGFloat(count)
                c.pumpkin(x, y, size: size)
            }
        }
    }

    private func drawSoccerGame(_ c: DemoCanvas) {
        c.sky([0x7FB8F0, 0xCFE7FB], bottom: 0.36)
        c.cloud(0.7, 0.14, size: 0.8)
        c.ridge([(0, 0.33), (0.25, 0.28), (0.5, 0.33), (0.75, 0.27), (1, 0.32)], 0x4F8A5B)
        for i in 0..<8 {
            c.rect(CGFloat(i) / 8, 0.35, 0.125, 0.65, i % 2 == 0 ? 0x5DB35F : 0x52A454)
        }
        c.line((0.5, 0.35), (0.5, 1), width: 0.006, 0xFFFFFF, 0.85)
        c.ring(0.5, 0.68, width: 0.34, height: 0.16, lineWidth: 0.006, 0xFFFFFF, 0.85)
        c.line((0.02, 0.45), (0.12, 0.45), width: 0.006, 0xFFFFFF, 0.85)
        c.line((0.12, 0.45), (0.12, 0.9), width: 0.006, 0xFFFFFF, 0.85)
        c.line((0.12, 0.9), (0.02, 0.9), width: 0.006, 0xFFFFFF, 0.85)
        c.player(0.32, 0.6, shirt: 0xEF8A6F, scale: 1.1)
        c.player(0.68, 0.55, shirt: 0x4F7CF7, scale: 1)
        c.player(0.82, 0.7, shirt: 0xEF8A6F, scale: 1.25)
        c.player(0.45, 0.78, shirt: 0x4F7CF7, scale: 1.35)
        c.oval(0.58, 0.88, width: 0.07, height: 0.018, 0x2E6B30, 0.4)
        c.disc(0.58, 0.85, radius: 0.03, 0xFFFFFF)
        c.disc(0.58, 0.85, radius: 0.01, 0x2B2B2B)
    }

    private func drawOrchard(_ c: DemoCanvas, fruit: Int, seed: UInt64) {
        c.sky([0x9FD3F7, 0xE3F3FC], bottom: 0.6)
        c.glow(0.15, 0.15, radius: 0.3, 0xFFF4C2, 0.7)
        c.cloud(0.6, 0.16, size: 1.1)
        c.ridge([(0, 0.55), (0.35, 0.49), (0.7, 0.56), (1, 0.51)], 0x9CC57A)
        c.ridge([(0, 0.64), (0.5, 0.6), (1, 0.66)], gradient: [0x7DB35E, 0x5E9445])
        var rng = SeededRandom(seed)
        let back: [CGFloat] = [0.08, 0.3, 0.52, 0.74, 0.96]
        for x in back {
            c.tree(x, 0.62, size: 0.7, leaves: 0x5E9C4E, fruit: fruit, rng: &rng)
        }
        let front: [CGFloat] = [0.18, 0.5, 0.84]
        for x in front {
            c.tree(x, 0.9, size: 1.25, leaves: 0x4E8C43, fruit: fruit, rng: &rng)
        }
        c.rect(0.6, 0.86, 0.07, 0.06, 0x9C6B3F)
        for _ in 0..<6 {
            c.disc(0.6 + rng.next(0.012, 0.058), 0.86 + rng.next(-0.004, 0.01), radius: 0.011, fruit)
        }
    }

    private func drawAutumnPark(_ c: DemoCanvas) {
        c.sky([0xFCE7C8, 0xF6C99A], bottom: 0.66)
        c.ridge([(0, 0.62), (0.5, 0.58), (1, 0.63)], gradient: [0xD69A5A, 0xB97A3E])
        c.polygon([(0.4, 1), (0.6, 1), (0.53, 0.62), (0.47, 0.62)], 0xEAD7B7, 0.85)
        var rng = SeededRandom(5)
        c.tree(0.12, 0.62, size: 1.2, leaves: 0xF4A261, fruit: nil, rng: &rng)
        c.tree(0.86, 0.6, size: 1.3, leaves: 0xE76F51, fruit: nil, rng: &rng)
        c.tree(0.25, 0.8, size: 1.9, leaves: 0xD1495B, fruit: nil, rng: &rng)
        c.tree(0.78, 0.86, size: 2.1, leaves: 0xE9C46A, fruit: nil, rng: &rng)
        let leaves = [0xE76F51, 0xF4A261, 0xE9C46A, 0xD1495B, 0xC8553D]
        for _ in 0..<70 {
            let color = leaves[Int(rng.next() * CGFloat(leaves.count)) % leaves.count]
            c.oval(rng.next(0, 1), rng.next(0.66, 1), width: 0.022, height: 0.012, color, 0.9)
        }
    }

    private func drawBalloons(_ c: DemoCanvas) {
        c.sky([0xFDE2E4, 0xFFF1E6, 0xE2ECE9])
        var rng = SeededRandom(17)
        let confetti = [0xEF8A6F, 0x8E9CE6, 0xF2B84B, 0x7CC08B, 0xE58FB5, 0xB48EE0]
        for _ in 0..<60 {
            let color = confetti[Int(rng.next() * CGFloat(confetti.count)) % confetti.count]
            c.disc(rng.next(0, 1), rng.next(0, 1), radius: rng.next(0.004, 0.009), color, 0.7)
        }
        let balloons: [(CGFloat, CGFloat, Int)] = [
            (0.28, 0.3, 0xEF8A6F), (0.52, 0.22, 0x8E9CE6), (0.74, 0.32, 0xF2B84B),
            (0.38, 0.47, 0x7CC08B), (0.64, 0.46, 0xE58FB5), (0.5, 0.36, 0xB48EE0),
        ]
        for (x, y, _) in balloons {
            c.line((x, y + 0.08), (0.5, 0.9), width: 0.003, 0x7A7A7A, 0.6)
        }
        for (x, y, color) in balloons {
            c.oval(x, y, width: 0.2, height: 0.25, color)
            c.oval(x - 0.04, y - 0.04, width: 0.04, height: 0.07, 0xFFFFFF, 0.45)
            c.polygon([(x, y + 0.085), (x - 0.012, y + 0.1), (x + 0.012, y + 0.1)], color)
        }
        c.rect(0.44, 0.9, 0.12, 0.1, 0xF7F2EA)
        c.rect(0.44, 0.9, 0.12, 0.012, 0xE58FB5)
    }

    private func drawSunsetHills(_ c: DemoCanvas) {
        c.sky([0x3B4A8F, 0x9B5FA6, 0xF07F5A, 0xF7C873], bottom: 0.72)
        c.glow(0.62, 0.6, radius: 0.45, 0xFFC27A, 0.75)
        c.disc(0.62, 0.6, radius: 0.085, 0xFFE6A8)
        c.ridge([(0, 0.6), (0.2, 0.55), (0.45, 0.62), (0.7, 0.54), (1, 0.6)], 0xB0657E, 0.9)
        c.ridge([(0, 0.7), (0.3, 0.64), (0.6, 0.72), (1, 0.66)], 0x7A4C7C)
        c.ridge([(0, 0.84), (0.4, 0.77), (0.75, 0.85), (1, 0.8)], 0x3E3157)
        c.line((0.24, 0.3), (0.26, 0.32), width: 0.004, 0x3B2E4A)
        c.line((0.26, 0.32), (0.28, 0.3), width: 0.004, 0x3B2E4A)
        c.line((0.31, 0.25), (0.325, 0.265), width: 0.003, 0x3B2E4A)
        c.line((0.325, 0.265), (0.34, 0.25), width: 0.003, 0x3B2E4A)
    }

    private func drawSailboat(_ c: DemoCanvas) {
        c.sky([0xFFC9A3, 0xFFE3C4, 0xFFD1B0], bottom: 0.62)
        c.glow(0.3, 0.56, radius: 0.35, 0xFFD27F, 0.8)
        c.disc(0.3, 0.56, radius: 0.06, 0xFFE9B8)
        c.ridge([(0, 0.6), (0.3, 0.56), (0.55, 0.6), (0.8, 0.55), (1, 0.59)], 0xC79A9A, 0.7)
        c.sky([0x6FB1CF, 0x2F7FA6], top: 0.62, bottom: 1)
        for i in 0..<6 {
            let y = 0.64 + CGFloat(i) * 0.05
            let half = 0.03 + CGFloat(i) * 0.012
            c.line((0.3 - half, y), (0.3 + half, y), width: 0.005, 0xFFE9B8, 0.5)
        }
        c.polygon([(0.52, 0.72), (0.74, 0.72), (0.7, 0.77), (0.56, 0.77)], 0x3E3157)
        c.line((0.63, 0.72), (0.63, 0.44), width: 0.005, 0x3E3157)
        c.polygon([(0.636, 0.45), (0.636, 0.71), (0.73, 0.71)], 0xFFFFFF)
        c.polygon([(0.624, 0.5), (0.624, 0.71), (0.55, 0.71)], 0xF7F2EA)
        c.line((0.5, 0.8), (0.58, 0.8), width: 0.004, 0xFFFFFF, 0.4)
        c.line((0.68, 0.82), (0.78, 0.82), width: 0.004, 0xFFFFFF, 0.4)
    }

    private func drawCityDusk(_ c: DemoCanvas) {
        c.sky([0x26306E, 0x6D4E9E, 0xE88C7D, 0xF7C59F], bottom: 0.85)
        var rng = SeededRandom(29)
        for _ in 0..<25 {
            c.disc(rng.next(0, 1), rng.next(0, 0.3), radius: rng.next(0.0015, 0.003), 0xFFFFFF, 0.8)
        }
        var x: CGFloat = -0.02
        var index = 0
        while x < 1 {
            let width = rng.next(0.06, 0.11)
            let height = rng.next(0.22, 0.52)
            let top = 0.86 - height
            c.rect(x, top, width, height, index % 2 == 0 ? 0x232643 : 0x2C2F52)
            var wy = top + 0.03
            while wy < 0.84 {
                var wx = x + 0.012
                while wx < x + width - 0.02 {
                    if rng.next() < 0.38 {
                        c.rect(wx, wy, 0.012, 0.016, 0xFFD98A, 0.9)
                    }
                    wx += 0.022
                }
                wy += 0.035
            }
            x += width + 0.004
            index += 1
        }
        c.sky([0x1A1C33, 0x2B2550], top: 0.86, bottom: 1)
        for _ in 0..<14 {
            let lx = rng.next(0, 1)
            let ly = rng.next(0.88, 0.98)
            c.line((lx, ly), (lx + 0.03, ly), width: 0.003, 0xFFD98A, 0.5)
        }
    }

    private func drawRainbow(_ c: DemoCanvas) {
        c.sky([0x7FB9DE, 0xCBE8F7], bottom: 0.66)
        let bands = [0xE5604D, 0xF2A93B, 0xF7D046, 0x7CC08B, 0x4F7CF7, 0x8E6CD9]
        for (i, color) in bands.enumerated() {
            c.arc(0.5, 0.78, radius: 0.42 - CGFloat(i) * 0.024, width: 0.025, color, 0.6)
        }
        c.cloud(0.18, 0.3, size: 1.2)
        c.cloud(0.84, 0.22, size: 0.9)
        c.ridge([(0, 0.66), (0.35, 0.62), (0.7, 0.67), (1, 0.63)], 0x8CC977)
        c.ridge([(0, 0.76), (0.5, 0.72), (1, 0.78)], gradient: [0x6DB35F, 0x4C9450])
        var rng = SeededRandom(41)
        for _ in 0..<40 {
            c.disc(rng.next(0, 1), rng.next(0.78, 1), radius: rng.next(0.003, 0.006), 0xFFFFFF, 0.8)
        }
    }

    private func drawFireworks(_ c: DemoCanvas) {
        c.sky([0x080B24, 0x1B1F4D, 0x2E2A5C])
        let bursts: [(CGFloat, CGFloat, CGFloat, Int)] = [
            (0.3, 0.3, 0.16, 0xF2B84B), (0.68, 0.22, 0.13, 0xE58FB5),
            (0.55, 0.48, 0.1, 0x7CC0F0), (0.18, 0.55, 0.08, 0x7CC08B), (0.84, 0.5, 0.09, 0xEF8A6F),
        ]
        let a = c.aspect
        for (x, y, radius, color) in bursts {
            c.glow(x, y, radius: radius * 1.2, color, 0.35)
            for k in 0..<24 {
                let angle = CGFloat(k) * 2 * CGFloat.pi / 24
                let dx = cos(angle)
                let dy = sin(angle) * a
                c.line((x + dx * radius * 0.25, y + dy * radius * 0.25), (x + dx * radius, y + dy * radius),
                       width: 0.004, color, 0.9)
                c.disc(x + dx * radius * 1.08, y + dy * radius * 1.08, radius: 0.004, 0xFFFFFF, 0.9)
            }
        }
        var rng = SeededRandom(3)
        var x: CGFloat = 0
        while x < 1 {
            let width = rng.next(0.05, 0.1)
            let height = rng.next(0.08, 0.2)
            c.rect(x, 1 - height, width, height, 0x0E1030)
            x += width
        }
    }

    private func drawMeadow(_ c: DemoCanvas) {
        c.sky([0xA9DDFB, 0xE9F7FF], bottom: 0.6)
        c.glow(0.18, 0.16, radius: 0.3, 0xFFF4C2, 0.8)
        c.disc(0.18, 0.16, radius: 0.055, 0xFFF8DC)
        c.cloud(0.62, 0.2, size: 1.2)
        c.ridge([(0, 0.55), (0.3, 0.5), (0.65, 0.56), (1, 0.5)], 0xA7D58E)
        c.ridge([(0, 0.63), (0.4, 0.6), (0.8, 0.65), (1, 0.62)], 0x7FC06F)
        c.ridge([(0, 0.72), (0.5, 0.68), (1, 0.73)], gradient: [0x6DB35F, 0x4C9450])
        var rng = SeededRandom(7)
        let flowers = [0xFFFFFF, 0xF7D046, 0xE58FB5, 0xB48EE0, 0xEF8A6F]
        for _ in 0..<150 {
            let y = rng.next(0.72, 1)
            let color = flowers[Int(rng.next() * CGFloat(flowers.count)) % flowers.count]
            let radius = 0.003 + (y - 0.72) * 0.03
            c.disc(rng.next(0, 1), y, radius: radius, color)
        }
    }

    private func drawPicnic(_ c: DemoCanvas) {
        c.sky([0xBFE6FF, 0xEAF7FF], bottom: 0.42)
        c.cloud(0.3, 0.16, size: 1)
        c.ridge([(0, 0.4), (0.15, 0.33), (0.3, 0.39), (0.5, 0.31), (0.7, 0.38), (0.85, 0.32), (1, 0.38)], 0x5E9C4E)
        c.sky([0x8CCB6E, 0x5FA34E], top: 0.42, bottom: 1)
        // A checked blanket, turned a little and seen at an angle.
        let ctx = c.ctx
        ctx.saveGState()
        ctx.translateBy(x: c.w * 0.5, y: c.h * 0.7)
        ctx.scaleBy(x: 1, y: 0.55)
        ctx.rotate(by: -0.2)
        let square = c.w * 0.06
        for row in -3..<3 {
            for col in -3..<3 {
                let red = (row + col) % 2 == 0
                ctx.setFillColor(UIColor(rgb: red ? 0xE5604D : 0xFFF3EC).cgColor)
                ctx.fill(CGRect(x: CGFloat(col) * square, y: CGFloat(row) * square, width: square, height: square))
            }
        }
        ctx.restoreGState()
        c.oval(0.42, 0.68, width: 0.08, height: 0.035, 0xFFFFFF)
        c.oval(0.56, 0.74, width: 0.08, height: 0.035, 0xFFFFFF)
        c.oval(0.42, 0.675, width: 0.04, height: 0.015, 0xEF8A6F)
        c.rect(0.62, 0.56, 0.12, 0.09, 0xB07A45)
        c.arc(0.68, 0.565, radius: 0.045, width: 0.008, 0x8A5A30)
    }

    private func drawMountainLake(_ c: DemoCanvas) {
        c.sky([0x8CC8F2, 0xE4F3FD], bottom: 0.6)
        c.polygon([(-0.05, 0.6), (0.2, 0.3), (0.42, 0.6)], 0x8494BA)
        c.polygon([(0.62, 0.6), (0.84, 0.34), (1.08, 0.6)], 0x8494BA)
        c.polygon([(0.28, 0.6), (0.56, 0.2), (0.86, 0.6)], 0x5E6F99)
        c.polygon([(0.56, 0.2), (0.515, 0.265), (0.545, 0.255), (0.56, 0.28), (0.58, 0.255), (0.607, 0.265)], 0xFFFFFF)
        c.polygon([(0.2, 0.3), (0.165, 0.345), (0.19, 0.34), (0.2, 0.355), (0.215, 0.34), (0.235, 0.345)], 0xFFFFFF)
        c.sky([0x4E8CC2, 0x2B5C8A], top: 0.6, bottom: 1)
        c.polygon([(0.28, 0.6), (0.56, 1), (0.86, 0.6)], 0x1F3F66, 0.25)
        c.polygon([(-0.05, 0.6), (0.2, 0.9), (0.42, 0.6)], 0x1F3F66, 0.18)
        var rng = SeededRandom(13)
        var x: CGFloat = 0
        while x < 1.02 {
            let height = rng.next(0.05, 0.1)
            c.polygon([(x - 0.018, 0.61), (x, 0.61 - height), (x + 0.018, 0.61)], 0x2F5D50)
            x += rng.next(0.025, 0.05)
        }
        for _ in 0..<10 {
            let lx = rng.next(0, 0.95)
            let ly = rng.next(0.66, 0.97)
            c.line((lx, ly), (lx + 0.05, ly), width: 0.003, 0xFFFFFF, 0.3)
        }
    }

    private func drawNightSky(_ c: DemoCanvas) {
        c.sky([0x0B1033, 0x232A6B, 0x4B3F86])
        var rng = SeededRandom(31)
        for _ in 0..<110 {
            c.disc(rng.next(0, 1), rng.next(0, 0.7), radius: rng.next(0.0012, 0.0035), 0xFFFFFF, rng.next(0.5, 1))
        }
        c.glow(0.78, 0.2, radius: 0.18, 0xFFF4D6, 0.35)
        c.disc(0.78, 0.2, radius: 0.045, 0xFFF4D6)
        c.ridge([(0, 0.68), (0.3, 0.6), (0.55, 0.7), (0.8, 0.62), (1, 0.67)], 0x22285A)
        c.ridge([(0, 0.82), (0.5, 0.78), (1, 0.83)], 0x141833)
        c.glow(0.48, 0.8, radius: 0.22, 0xFFC86B, 0.4)
        c.polygon([(0.36, 0.84), (0.48, 0.64), (0.6, 0.84)], 0xF2A93B)
        c.polygon([(0.45, 0.84), (0.48, 0.72), (0.51, 0.84)], 0xFFE0A0)
        c.glow(0.72, 0.85, radius: 0.08, 0xFF9A3C, 0.7)
        c.polygon([(0.7, 0.87), (0.72, 0.81), (0.74, 0.87)], 0xFFB347)
    }

    private func drawBeach(_ c: DemoCanvas) {
        c.sky([0x6EC1F0, 0xBFE6FA], bottom: 0.52)
        c.glow(0.82, 0.18, radius: 0.25, 0xFFF4C2, 0.8)
        c.disc(0.82, 0.18, radius: 0.06, 0xFFF8DC)
        c.cloud(0.25, 0.2, size: 1)
        c.sky([0x2E9CCA, 0x5CC6DE], top: 0.5, bottom: 0.74)
        c.ridge([(0, 0.705), (0.4, 0.675), (0.75, 0.725), (1, 0.685)], 0xFFFFFF, 0.7)
        c.ridge([(0, 0.72), (0.4, 0.69), (0.75, 0.74), (1, 0.7)], gradient: [0xF5DEAD, 0xE8C07E])
        c.line((0.3, 0.6), (0.3, 0.88), width: 0.006, 0x6B4F3A)
        c.dome(0.3, 0.62, radius: 0.12, 0xF07F5A)
        c.dome(0.3, 0.62, radius: 0.04, 0xFFF3EC)
        c.rect(0.44, 0.83, 0.18, 0.05, 0x8E9CE6)
        c.rect(0.44, 0.845, 0.18, 0.012, 0xFFFFFF)
        c.disc(0.72, 0.84, radius: 0.025, 0xFFFFFF)
        c.dome(0.72, 0.84, radius: 0.025, 0xE5604D)
    }

    private func drawWaves(_ c: DemoCanvas) {
        c.sky([0x9ED8F5, 0xE6F6FD], bottom: 0.45)
        c.glow(0.7, 0.2, radius: 0.25, 0xFFF4C2, 0.8)
        c.disc(0.7, 0.2, radius: 0.05, 0xFFF8DC)
        let blues = [0x1F5F8B, 0x2878A8, 0x3C9AC6, 0x67B9DD, 0x9AD5EC]
        for (i, color) in blues.enumerated() {
            let base = 0.42 + CGFloat(i) * 0.12
            var crest: [(CGFloat, CGFloat)] = []
            for k in 0...8 {
                let wave = 0.025 * sin(CGFloat(k) * 1.3 + CGFloat(i) * 1.7)
                crest.append((CGFloat(k) / 8, base + wave))
            }
            c.ridge(crest.map { ($0.0, $0.1 - 0.012) }, 0xFFFFFF, 0.55)
            c.ridge(crest, color)
        }
    }
}

// MARK: - Drawing

/// Positions are fractions of the picture (x of its width, y of its height).
/// Sizes and radii are fractions of its width.
private struct DemoCanvas {
    let ctx: CGContext
    let size: CGSize

    var w: CGFloat { size.width }
    var h: CGFloat { size.height }
    /// Turns a size in widths into a fraction of the height.
    var aspect: CGFloat { w / h }

    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * w, y: y * h) }

    func color(_ rgb: Int, _ alpha: CGFloat = 1) -> CGColor {
        UIColor(rgb: rgb).withAlphaComponent(alpha).cgColor
    }

    /// A top-to-bottom gradient across a band of the picture.
    func sky(_ colors: [Int], top: CGFloat = 0, bottom: CGFloat = 1) {
        let band = CGRect(x: 0, y: top * h, width: w, height: (bottom - top) * h)
        ctx.saveGState()
        ctx.clip(to: band)
        linear(colors, from: CGPoint(x: 0, y: band.minY), to: CGPoint(x: 0, y: band.maxY))
        ctx.restoreGState()
    }

    func linear(_ colors: [Int], from start: CGPoint, to end: CGPoint) {
        let cgColors = colors.map { color($0) } as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cgColors, locations: nil) else {
            return
        }
        ctx.drawLinearGradient(gradient, start: start, end: end,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    func glow(_ x: CGFloat, _ y: CGFloat, radius: CGFloat, _ rgb: Int, _ alpha: CGFloat = 0.55) {
        let center = point(x, y)
        let colors = [color(rgb, alpha), color(rgb, 0)] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: nil) else {
            return
        }
        ctx.drawRadialGradient(gradient, startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: radius * w, options: [])
    }

    func disc(_ x: CGFloat, _ y: CGFloat, radius: CGFloat, _ rgb: Int, _ alpha: CGFloat = 1) {
        let r = radius * w
        ctx.setFillColor(color(rgb, alpha))
        ctx.fillEllipse(in: CGRect(x: x * w - r, y: y * h - r, width: 2 * r, height: 2 * r))
    }

    func oval(_ x: CGFloat, _ y: CGFloat, width: CGFloat, height: CGFloat, _ rgb: Int, _ alpha: CGFloat = 1) {
        let ow = width * w
        let oh = height * w
        ctx.setFillColor(color(rgb, alpha))
        ctx.fillEllipse(in: CGRect(x: x * w - ow / 2, y: y * h - oh / 2, width: ow, height: oh))
    }

    func ring(_ x: CGFloat, _ y: CGFloat, width: CGFloat, height: CGFloat, lineWidth: CGFloat,
              _ rgb: Int, _ alpha: CGFloat = 1) {
        let ow = width * w
        let oh = height * w
        ctx.setStrokeColor(color(rgb, alpha))
        ctx.setLineWidth(lineWidth * w)
        ctx.strokeEllipse(in: CGRect(x: x * w - ow / 2, y: y * h - oh / 2, width: ow, height: oh))
    }

    /// `x`, `y`, `width` and `height` are all fractions of the picture's own sides.
    func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat, _ rgb: Int, _ alpha: CGFloat = 1) {
        ctx.setFillColor(color(rgb, alpha))
        ctx.fill(CGRect(x: x * w, y: y * h, width: width * w, height: height * h))
    }

    func polygon(_ points: [(CGFloat, CGFloat)], _ rgb: Int, _ alpha: CGFloat = 1) {
        guard let first = points.first else { return }
        ctx.beginPath()
        ctx.move(to: point(first.0, first.1))
        for next in points.dropFirst() {
            ctx.addLine(to: point(next.0, next.1))
        }
        ctx.closePath()
        ctx.setFillColor(color(rgb, alpha))
        ctx.fillPath()
    }

    func line(_ from: (CGFloat, CGFloat), _ to: (CGFloat, CGFloat), width: CGFloat, _ rgb: Int, _ alpha: CGFloat = 1) {
        ctx.setStrokeColor(color(rgb, alpha))
        ctx.setLineWidth(width * w)
        ctx.setLineCap(.round)
        ctx.beginPath()
        ctx.move(to: point(from.0, from.1))
        ctx.addLine(to: point(to.0, to.1))
        ctx.strokePath()
    }

    /// The upper half of a circle, stroked.
    func arc(_ x: CGFloat, _ y: CGFloat, radius: CGFloat, width: CGFloat, _ rgb: Int, _ alpha: CGFloat = 1) {
        ctx.setStrokeColor(color(rgb, alpha))
        ctx.setLineWidth(width * w)
        ctx.setLineCap(.butt)
        ctx.beginPath()
        ctx.addArc(center: point(x, y), radius: radius * w, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
        ctx.strokePath()
    }

    /// The upper half of a circle, filled.
    func dome(_ x: CGFloat, _ y: CGFloat, radius: CGFloat, _ rgb: Int, _ alpha: CGFloat = 1) {
        ctx.beginPath()
        ctx.addArc(center: point(x, y), radius: radius * w, startAngle: .pi, endAngle: 2 * .pi, clockwise: false)
        ctx.closePath()
        ctx.setFillColor(color(rgb, alpha))
        ctx.fillPath()
    }

    /// A smooth ridge through the points, left to right, filled down to the bottom edge.
    func ridge(_ points: [(CGFloat, CGFloat)], _ rgb: Int, _ alpha: CGFloat = 1) {
        ctx.beginPath()
        addRidge(points)
        ctx.setFillColor(color(rgb, alpha))
        ctx.fillPath()
    }

    func ridge(_ points: [(CGFloat, CGFloat)], gradient colors: [Int]) {
        let top = points.map { $0.1 }.min() ?? 0
        ctx.saveGState()
        ctx.beginPath()
        addRidge(points)
        ctx.clip()
        linear(colors, from: point(0, top), to: point(0, 1))
        ctx.restoreGState()
    }

    private func addRidge(_ points: [(CGFloat, CGFloat)]) {
        let pts = points.map { point($0.0, $0.1) }
        guard let first = pts.first, let last = pts.last else { return }
        ctx.move(to: CGPoint(x: first.x, y: h))
        ctx.addLine(to: first)
        for i in pts.indices.dropFirst() {
            let previous = pts[i - 1]
            let mid = CGPoint(x: (previous.x + pts[i].x) / 2, y: (previous.y + pts[i].y) / 2)
            ctx.addQuadCurve(to: mid, control: previous)
        }
        ctx.addLine(to: last)
        ctx.addLine(to: CGPoint(x: last.x, y: h))
        ctx.closePath()
    }

    // MARK: Things

    func cloud(_ x: CGFloat, _ y: CGFloat, size s: CGFloat) {
        let a = aspect
        oval(x, y, width: 0.2 * s, height: 0.06 * s, 0xFFFFFF)
        disc(x - 0.04 * s, y - 0.02 * s * a, radius: 0.04 * s, 0xFFFFFF)
        disc(x + 0.025 * s, y - 0.03 * s * a, radius: 0.05 * s, 0xFFFFFF)
    }

    func pumpkin(_ x: CGFloat, _ y: CGFloat, size s: CGFloat) {
        let a = aspect
        oval(x, y + s * 0.6 * a, width: s * 2.6, height: s * 0.5, 0x3E5A26, 0.45)
        oval(x - s * 0.5, y, width: s * 1.3, height: s * 1.5, 0xE07A1F)
        oval(x + s * 0.5, y, width: s * 1.3, height: s * 1.5, 0xE07A1F)
        oval(x, y, width: s * 1.5, height: s * 1.6, 0xF28C28)
        oval(x - s * 0.25, y - s * 0.3 * a, width: s * 0.4, height: s * 0.7, 0xFFB05C, 0.55)
        rect(x - s * 0.08, y - s * 1.0 * a, s * 0.16, s * 0.28 * a, 0x5B7A2E)
    }

    func tree(_ x: CGFloat, _ base: CGFloat, size s: CGFloat, leaves: Int, fruit: Int?, rng: inout SeededRandom) {
        let a = aspect
        oval(x, base, width: 0.14 * s, height: 0.025 * s, 0x2E4A22, 0.3)
        rect(x - 0.012 * s, base - 0.12 * s * a, 0.024 * s, 0.12 * s * a, 0x7A5235)
        disc(x - 0.055 * s, base - 0.14 * s * a, radius: 0.06 * s, leaves)
        disc(x + 0.055 * s, base - 0.14 * s * a, radius: 0.06 * s, leaves)
        disc(x, base - 0.19 * s * a, radius: 0.075 * s, leaves)
        disc(x - 0.025 * s, base - 0.22 * s * a, radius: 0.035 * s, 0xFFFFFF, 0.12)
        guard let fruit else { return }
        for _ in 0..<9 {
            let fx = x + rng.next(-0.09, 0.09) * s
            let fy = base - rng.next(0.1, 0.24) * s * a
            disc(fx, fy, radius: 0.01 * s, fruit)
        }
    }

    func player(_ x: CGFloat, _ y: CGFloat, shirt: Int, scale s: CGFloat) {
        let a = aspect
        oval(x, y + 0.11 * s * a, width: 0.06 * s, height: 0.016 * s, 0x2E6B30, 0.4)
        line((x - 0.01 * s, y + 0.035 * s * a), (x - 0.016 * s, y + 0.1 * s * a), width: 0.011 * s, 0x2F3640)
        line((x + 0.01 * s, y + 0.035 * s * a), (x + 0.02 * s, y + 0.1 * s * a), width: 0.011 * s, 0x2F3640)
        oval(x, y, width: 0.045 * s, height: 0.085 * s, shirt)
        disc(x, y - 0.06 * s * a, radius: 0.016 * s, 0xC68B65)
    }
}

/// A small fixed-seed generator, so each picture comes out the same every launch.
private struct SeededRandom {
    private var state: UInt64

    init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    /// A number in 0..<1.
    mutating func next() -> CGFloat {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return CGFloat(state >> 11) / CGFloat(UInt64(1) << 53)
    }

    mutating func next(_ low: CGFloat, _ high: CGFloat) -> CGFloat {
        low + (high - low) * next()
    }
}
#endif
