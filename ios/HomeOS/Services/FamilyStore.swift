import Foundation
import Observation
import Supabase

let supabase = SupabaseClient(supabaseURL: Config.supabaseURL, supabaseKey: Config.supabaseAnonKey)

/// App-wide state: auth, the current family, and its data. Views read from
/// here and call its async actions; row-level security scopes every query
/// to the signed-in user's family.
@Observable
@MainActor
final class FamilyStore {
    enum Phase { case loading, signedOut, needsFamily, ready }

    var phase: Phase = .loading
    var errorMessage: String?

    var family: Family?
    var members: [Member] = []
    var devices: [Device] = []
    var events: [FamilyEvent] = []
    var tasks: [FamilyTask] = []
    /// The last 30 days of completions plus anything still pending.
    var completions: [TaskCompletion] = []
    var rewards: [Reward] = []
    var redemptions: [RewardRedemption] = []
    var points: [UUID: Int] = [:]
    var media: [MediaItem] = []
    var lists: [FamilyList] = []
    var listItems: [ListItem] = []
    var meals: [MealPlan] = []
    var memories: [FamilyMemory] = []

    // Assistant conversation (phone only; the edge function is stateless).
    var chat: [ChatMessage] = []
    var isThinking = false

    @ObservationIgnored private var signedURLs: [String: (url: URL, expires: Date)] = [:]

    var me: Member? {
        guard let uid = supabase.auth.currentUser?.id else { return nil }
        return members.first { $0.userId == uid }
    }
    var isParent: Bool { me?.role == .parent }
    var kids: [Member] { members.filter { $0.role == .child } }
    var pendingCompletions: [TaskCompletion] { completions.filter { $0.status == "pending" } }

    func member(_ id: UUID?) -> Member? { members.first { $0.id == id } }
    func reward(_ id: UUID) -> Reward? { rewards.first { $0.id == id } }
    func task(_ id: UUID) -> FamilyTask? { tasks.first { $0.id == id } }

    // MARK: Lifecycle

    func start() async {
        for await (event, session) in supabase.auth.authStateChanges {
            guard [.initialSession, .signedIn, .signedOut].contains(event) else { continue }
            if session == nil {
                reset()
                phase = .signedOut
            } else {
                await loadFamily()
            }
        }
    }

    private func reset() {
        family = nil
        members = []; devices = []; events = []; tasks = []; completions = []
        rewards = []; redemptions = []; points = [:]; media = []
        lists = []; listItems = []; meals = []; memories = []
        chat = []; signedURLs = [:]
    }

    func loadFamily() async {
        do {
            let families: [Family] = try await supabase.from("families").select().limit(1).execute().value
            guard let family = families.first else {
                phase = .needsFamily
                return
            }
            self.family = family
            await refresh()
            phase = .ready
        } catch {
            report(error)
        }
    }

    func refresh() async {
        guard family != nil else { return }
        let iso = ISO8601DateFormatter()
        let today = Calendar.current.startOfDay(for: .now)
        let eventsFrom = iso.string(from: today.addingTimeInterval(-45 * 86_400))
        let eventsTo = iso.string(from: today.addingTimeInterval(120 * 86_400))
        let completionsFrom = DayKey.string(today.addingTimeInterval(-30 * 86_400))
        let mealsFrom = DayKey.string(today.addingTimeInterval(-86_400))
        let mealsTo = DayKey.string(today.addingTimeInterval(8 * 86_400))
        do {
            async let members: [Member] = supabase.from("members").select().order("sort_order").execute().value
            async let devices: [Device] = supabase.from("devices").select("id, name, last_seen_at").order("created_at").execute().value
            async let events: [FamilyEvent] = supabase.from("events")
                .select("*, event_members(member_id)")
                .gte("starts_at", value: eventsFrom)
                .lt("starts_at", value: eventsTo)
                .order("starts_at")
                .limit(1000)
                .execute().value
            async let tasks: [FamilyTask] = supabase.from("tasks").select().eq("archived", value: false).order("created_at").execute().value
            async let recent: [TaskCompletion] = supabase.from("task_completions").select()
                .gte("for_date", value: completionsFrom).execute().value
            async let pending: [TaskCompletion] = supabase.from("task_completions").select()
                .eq("status", value: "pending").execute().value
            async let rewards: [Reward] = supabase.from("rewards").select().eq("active", value: true).order("cost").execute().value
            async let redemptions: [RewardRedemption] = supabase.from("reward_redemptions").select()
                .eq("status", value: "requested").order("created_at").execute().value
            async let points: [MemberPoints] = supabase.from("member_points").select().execute().value
            async let lists: [FamilyList] = supabase.from("lists").select().order("sort_order").execute().value
            async let items: [ListItem] = supabase.from("list_items").select().order("created_at").limit(500).execute().value
            async let meals: [MealPlan] = supabase.from("meal_plans").select()
                .gte("date", value: mealsFrom).lte("date", value: mealsTo).execute().value
            async let memories: [FamilyMemory] = supabase.from("family_memories").select().order("created_at", ascending: false).execute().value

            self.members = try await members
            self.devices = try await devices
            self.events = try await events
            self.tasks = try await tasks
            let recentCompletions = try await recent
            let olderPending = try await pending.filter { p in !recentCompletions.contains { $0.id == p.id } }
            self.completions = recentCompletions + olderPending
            self.rewards = try await rewards
            self.redemptions = try await redemptions
            self.points = Dictionary((try await points).map { ($0.memberId, $0.balance) }, uniquingKeysWith: { a, _ in a })
            self.lists = try await lists
            self.listItems = try await items
            self.meals = try await meals
            self.memories = try await memories
            await refreshMedia()
        } catch {
            report(error)
        }
    }

    func refreshMedia() async {
        do {
            media = try await supabase.from("media_items").select()
                .order("created_at", ascending: false).limit(300).execute().value
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        errorMessage = error.localizedDescription
        print("homeOS error:", error)
    }

    // MARK: Auth & setup

    // TODO(M1): Sign in with Apple.
    func signIn(email: String, password: String) async {
        do { try await supabase.auth.signIn(email: email, password: password) } catch { report(error) }
    }

    func signUp(email: String, password: String) async {
        do { try await supabase.auth.signUp(email: email, password: password) } catch { report(error) }
    }

    func signOut() async {
        try? await supabase.auth.signOut()
    }

    func createFamily(name: String, myName: String) async {
        struct Params: Encodable {
            let family_name: String
            let my_name: String
            let tz: String
        }
        do {
            let _: UUID = try await supabase
                .rpc("create_family", params: Params(family_name: name, my_name: myName, tz: TimeZone.current.identifier))
                .execute().value
            await loadFamily()
        } catch {
            report(error)
        }
    }

    func addMember(name: String, role: MemberRole, color: String) async {
        guard let family else { return }
        let order = (members.map(\.sortOrder).max() ?? 0) + 1
        await perform {
            try await supabase.from("members")
                .insert(NewMember(familyId: family.id, displayName: name, role: role, color: color, sortOrder: order))
                .execute()
        }
    }

    // MARK: Calendar

    func addEvent(title: String, location: String?, start: Date, end: Date, allDay: Bool, memberIds: Set<UUID>) async {
        guard let family else { return }
        let event = NewEvent(familyId: family.id, title: title, location: location, startsAt: start,
                             endsAt: max(end, start), allDay: allDay, createdBy: me?.id)
        await perform {
            try await supabase.from("events").insert(event).execute()
            if !memberIds.isEmpty {
                let links = memberIds.map { ["event_id": event.id.uuidString, "member_id": $0.uuidString] }
                try await supabase.from("event_members").insert(links).execute()
            }
        }
    }

    func deleteEvent(_ event: FamilyEvent) async {
        events.removeAll { $0.id == event.id }
        await perform { try await supabase.from("events").delete().eq("id", value: event.id.uuidString).execute() }
    }

    /// Events overlapping a calendar day. All-day events count on each day they span.
    func eventsOn(_ day: Date) -> [FamilyEvent] {
        let start = Calendar.current.startOfDay(for: day)
        let end = start.addingTimeInterval(86_400)
        return events
            .filter { $0.startsAt < end && ($0.endsAt > start || $0.startsAt >= start) }
            .sorted { ($0.allDay ? 0 : 1, $0.startsAt) < ($1.allDay ? 0 : 1, $1.startsAt) }
    }

    func upcomingEvents(limit: Int) -> [FamilyEvent] {
        let now = Date.now
        return Array(events.filter { $0.endsAt >= now }.prefix(limit))
    }

    // MARK: Chores

    func addTask(_ task: NewTask) async {
        await perform { try await supabase.from("tasks").insert(task).execute() }
    }

    func archiveTask(_ task: FamilyTask) async {
        tasks.removeAll { $0.id == task.id }
        await perform {
            try await supabase.from("tasks").update(["archived": true]).eq("id", value: task.id.uuidString).execute()
        }
    }

    /// Whether a chore shows up on a given day, from its simple RRULE.
    func isDue(_ task: FamilyTask, on date: Date = .now) -> Bool {
        let key = DayKey.string(date)
        guard let rule = task.rrule else {
            // One-time chores: from their due date until someone finishes them.
            if let due = task.dueDate, due > key { return false }
            return !completions.contains { $0.taskId == task.id && $0.forDate < key && $0.status != "rejected" }
        }
        if rule.contains("FREQ=WEEKLY"), let byDay = rule.components(separatedBy: "BYDAY=").dropFirst().first {
            let codes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
            let today = codes[Calendar.current.component(.weekday, from: date) - 1]
            return byDay.split(separator: ";").first?.split(separator: ",").contains { $0 == today } ?? true
        }
        return true
    }

    /// Today's completion of a chore by a member (or by anyone, for unassigned chores).
    func completion(of task: FamilyTask, by memberId: UUID?, on date: Date = .now) -> TaskCompletion? {
        let key = DayKey.string(date)
        return completions
            .filter { $0.taskId == task.id && $0.forDate == key && (memberId == nil || $0.memberId == memberId) }
            .min { rank($0.status) < rank($1.status) }
    }

    private func rank(_ status: String) -> Int {
        switch status {
        case "approved": return 0
        case "pending": return 1
        default: return 2
        }
    }

    func dueTasks(for member: Member?) -> [FamilyTask] {
        tasks.filter { $0.assigneeId == member?.id && isDue($0) }
    }

    func choreProgress(for member: Member) -> (done: Int, total: Int) {
        let due = dueTasks(for: member)
        let done = due.filter { completion(of: $0, by: member.id)?.status == "approved" }.count
        return (done, due.count)
    }

    /// Mark a chore done for a member today. A parent's own tap counts as approval.
    func markDone(_ task: FamilyTask, by member: Member) async {
        let today = DayKey.today
        let id = UUID()
        let rejected = completions.first {
            $0.taskId == task.id && $0.memberId == member.id && $0.forDate == today && $0.status == "rejected"
        }
        let approveNow = task.requiresApproval && isParent
        completions.removeAll { $0.id == rejected?.id }
        completions.append(TaskCompletion(id: id, taskId: task.id, memberId: member.id, forDate: today,
                                          status: task.requiresApproval && !isParent ? "pending" : "approved"))
        struct Review: Encodable { let completion: UUID; let approve: Bool }
        await perform {
            // A rejected try today holds the (task, member, day) unique key; clear it first.
            if let rejected {
                try await supabase.from("task_completions").delete().eq("id", value: rejected.id.uuidString).execute()
            }
            try await supabase.from("task_completions")
                .insert(NewCompletion(id: id, taskId: task.id, memberId: member.id, forDate: today))
                .execute()
            if approveNow {
                try await supabase.rpc("review_completion", params: Review(completion: id, approve: true)).execute()
            }
        }
    }

    /// Parents only (RLS). Deleting an approved completion reverses its points.
    func undo(_ completion: TaskCompletion) async {
        completions.removeAll { $0.id == completion.id }
        await perform {
            try await supabase.from("task_completions").delete().eq("id", value: completion.id.uuidString).execute()
        }
    }

    func review(_ completion: TaskCompletion, approve: Bool) async {
        if let i = completions.firstIndex(where: { $0.id == completion.id }) {
            completions[i].status = approve ? "approved" : "rejected"
        }
        struct Params: Encodable { let completion: UUID; let approve: Bool }
        await perform { try await supabase.rpc("review_completion", params: Params(completion: completion.id, approve: approve)).execute() }
    }

    // MARK: Rewards & points

    func addReward(title: String, icon: String?, cost: Int) async {
        guard let family else { return }
        await perform { try await supabase.from("rewards").insert(NewReward(familyId: family.id, title: title, icon: icon, cost: cost)).execute() }
    }

    func archiveReward(_ reward: Reward) async {
        rewards.removeAll { $0.id == reward.id }
        await perform {
            try await supabase.from("rewards").update(["active": false]).eq("id", value: reward.id.uuidString).execute()
        }
    }

    func adjustPoints(member: Member, delta: Int, reason: String) async {
        points[member.id, default: 0] += delta
        struct Params: Encodable { let member: UUID; let delta: Int; let reason: String }
        await perform { try await supabase.rpc("adjust_points", params: Params(member: member.id, delta: delta, reason: reason)).execute() }
    }

    /// Spends a member's points on a reward; a parent then fulfills or cancels it.
    func redeem(_ reward: Reward, for member: Member) async {
        struct Params: Encodable { let reward: UUID; let member: UUID }
        await perform { try await supabase.rpc("redeem_reward", params: Params(reward: reward.id, member: member.id)).execute() }
    }

    func resolve(_ redemption: RewardRedemption, fulfilled: Bool) async {
        redemptions.removeAll { $0.id == redemption.id }
        struct Params: Encodable { let redemption: UUID; let fulfilled: Bool }
        await perform {
            try await supabase.rpc("resolve_redemption", params: Params(redemption: redemption.id, fulfilled: fulfilled)).execute()
        }
    }

    // MARK: Lists

    func items(in list: FamilyList) -> [ListItem] {
        listItems.filter { $0.listId == list.id }
    }

    func addList(name: String) async {
        guard let family else { return }
        await perform {
            try await supabase.from("lists").insert(NewList(familyId: family.id, name: name, kind: "shopping")).execute()
        }
    }

    func deleteList(_ list: FamilyList) async {
        lists.removeAll { $0.id == list.id }
        await perform { try await supabase.from("lists").delete().eq("id", value: list.id.uuidString).execute() }
    }

    func addItem(_ text: String, to list: FamilyList) async {
        await perform {
            try await supabase.from("list_items").insert(NewListItem(listId: list.id, text: text, addedBy: me?.id)).execute()
        }
    }

    func toggle(_ item: ListItem) async {
        let done = !item.done
        if let i = listItems.firstIndex(where: { $0.id == item.id }) { listItems[i].done = done }
        await perform {
            try await supabase.from("list_items").update(["done": done]).eq("id", value: item.id.uuidString).execute()
        }
    }

    func deleteItem(_ item: ListItem) async {
        listItems.removeAll { $0.id == item.id }
        await perform { try await supabase.from("list_items").delete().eq("id", value: item.id.uuidString).execute() }
    }

    func clearDone(in list: FamilyList) async {
        listItems.removeAll { $0.listId == list.id && $0.done }
        await perform {
            try await supabase.from("list_items").delete()
                .eq("list_id", value: list.id.uuidString).eq("done", value: true).execute()
        }
    }

    // MARK: Meals

    func meal(_ slot: MealSlot, on day: String) -> MealPlan? {
        meals.first { $0.date == day && $0.meal == slot }
    }

    /// An empty title clears the meal.
    func setMeal(_ slot: MealSlot, on day: String, title: String) async {
        guard let family else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            guard let existing = meal(slot, on: day) else { return }
            meals.removeAll { $0.id == existing.id }
            await perform { try await supabase.from("meal_plans").delete().eq("id", value: existing.id.uuidString).execute() }
        } else {
            await perform {
                try await supabase.from("meal_plans")
                    .upsert(MealUpsert(familyId: family.id, date: day, meal: slot, title: title), onConflict: "family_id,date,meal")
                    .execute()
            }
        }
    }

    // MARK: Family memory

    func addMemory(_ content: String) async {
        guard let family else { return }
        await perform { try await supabase.from("family_memories").insert(NewMemory(familyId: family.id, content: content)).execute() }
    }

    func deleteMemory(_ memory: FamilyMemory) async {
        memories.removeAll { $0.id == memory.id }
        await perform { try await supabase.from("family_memories").delete().eq("id", value: memory.id.uuidString).execute() }
    }

    // MARK: Media

    /// Uploads a photo or video to `<family_id>/<media_id>.<ext>` and records it.
    /// Returns false on failure. Call `refreshMedia()` after a batch.
    @discardableResult
    func upload(data: Data, isVideo: Bool, fileExtension: String, metadata: MediaMetadata) async -> Bool {
        guard let family else { return false }
        let id = UUID()
        let ext = fileExtension.lowercased()
        let path = "\(family.id.uuidString.lowercased())/\(id.uuidString.lowercased()).\(ext)"
        let contentType = isVideo
            ? "video/\(ext == "mov" ? "quicktime" : ext)"
            : "image/\(ext == "jpg" ? "jpeg" : ext)"
        let row = NewMediaItem(id: id, familyId: family.id, storagePath: path, kind: isVideo ? "video" : "photo",
                               width: metadata.width, height: metadata.height,
                               durationSeconds: metadata.durationSeconds, takenAt: metadata.takenAt, uploadedBy: me?.id)
        do {
            _ = try await supabase.storage.from(Config.mediaBucket)
                .upload(path, data: data, options: FileOptions(contentType: contentType))
            try await supabase.from("media_items").insert(row).execute()
            return true
        } catch {
            report(error)
            return false
        }
    }

    func setShowOnFrame(_ item: MediaItem, _ show: Bool) async {
        if let i = media.firstIndex(where: { $0.id == item.id }) { media[i].showOnFrame = show }
        do {
            try await supabase.from("media_items").update(["show_on_frame": show]).eq("id", value: item.id.uuidString).execute()
        } catch {
            report(error)
            await refreshMedia()
        }
    }

    func deleteMedia(_ item: MediaItem) async {
        media.removeAll { $0.id == item.id }
        do {
            try await supabase.from("media_items").delete().eq("id", value: item.id.uuidString).execute()
            _ = try await supabase.storage.from(Config.mediaBucket).remove(paths: [item.storagePath])
        } catch {
            report(error)
            await refreshMedia()
        }
    }

    /// Signed URLs last an hour; reuse them until they're close to expiring.
    func signedURL(for item: MediaItem) async -> URL? {
        if let cached = signedURLs[item.storagePath], cached.expires > Date.now.addingTimeInterval(300) {
            return cached.url
        }
        guard let url = try? await supabase.storage.from(Config.mediaBucket)
            .createSignedURL(path: item.storagePath, expiresIn: 3600) else { return nil }
        signedURLs[item.storagePath] = (url: url, expires: Date.now.addingTimeInterval(3600))
        return url
    }

    // MARK: Assistant

    /// Sends the conversation to the `assistant` edge function and appends its reply.
    func ask(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isThinking else { return }
        chat.append(ChatMessage(role: .user, text: text))
        isThinking = true
        defer { isThinking = false }

        struct Turn: Encodable { let role: String; let text: String }
        struct Body: Encodable { let messages: [Turn] }
        let turns = chat.filter { !$0.isError }.suffix(20).map { Turn(role: $0.role.rawValue, text: $0.text) }

        do {
            let reply: AssistantReply = try await supabase.functions.invoke(
                "assistant", options: FunctionInvokeOptions(body: Body(messages: turns)))
            let actions = reply.actions ?? []
            chat.append(ChatMessage(role: .assistant, text: reply.reply, actions: actions))
            if !actions.isEmpty { await refresh() }
        } catch {
            print("homeOS assistant error:", error)
            chat.append(ChatMessage(role: .assistant, text: "I couldn't reach homeOS just now. Check your connection and try again.",
                                    isError: true))
        }
    }

    func resetChat() {
        chat = []
    }

    // MARK: Display pairing

    /// Claims the 6-digit code shown on a new wall display.
    func pairDisplay(code: String, name: String) async -> Bool {
        guard let family else { return false }
        struct Claim: Encodable { let action = "claim"; let code: String; let familyId: UUID; let name: String }
        do {
            try await supabase.functions.invoke("pair-device", options: FunctionInvokeOptions(body: Claim(code: code, familyId: family.id, name: name)))
            await refresh()
            return true
        } catch {
            report(error)
            return false
        }
    }

    // MARK: Helpers

    /// Runs a write, then reloads. On failure the optimistic local change is
    /// replaced by the server's state.
    private func perform(_ work: () async throws -> Void) async {
        do {
            try await work()
        } catch {
            report(error)
        }
        await refresh()
    }
}
