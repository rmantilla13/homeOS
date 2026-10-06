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
    var events: [FamilyEvent] = []
    var tasks: [FamilyTask] = []
    var pendingCompletions: [TaskCompletion] = []
    var rewards: [Reward] = []
    var points: [UUID: Int] = [:]
    var media: [MediaItem] = []

    var me: Member? {
        guard let uid = supabase.auth.currentUser?.id else { return nil }
        return members.first { $0.userId == uid }
    }
    var isParent: Bool { me?.role == .parent }
    var kids: [Member] { members.filter { $0.role == .child } }

    func member(_ id: UUID?) -> Member? { members.first { $0.id == id } }

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
        members = []; events = []; tasks = []; pendingCompletions = []
        rewards = []; points = [:]; media = []
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
        do {
            async let members: [Member] = supabase.from("members").select().order("sort_order").execute().value
            async let events: [FamilyEvent] = supabase.from("events")
                .select("*, event_members(member_id)")
                .gte("starts_at", value: ISO8601DateFormatter().string(from: Calendar.current.startOfDay(for: .now).addingTimeInterval(-7 * 86_400)))
                .order("starts_at")
                .execute().value
            async let tasks: [FamilyTask] = supabase.from("tasks").select().eq("archived", value: false).order("created_at").execute().value
            async let pending: [TaskCompletion] = supabase.from("task_completions").select().eq("status", value: "pending").execute().value
            async let rewards: [Reward] = supabase.from("rewards").select().eq("active", value: true).order("cost").execute().value
            async let points: [MemberPoints] = supabase.from("member_points").select().execute().value
            async let media: [MediaItem] = supabase.from("media_items").select().order("created_at", ascending: false).limit(60).execute().value

            self.members = try await members
            self.events = try await events
            self.tasks = try await tasks
            self.pendingCompletions = try await pending
            self.rewards = try await rewards
            self.points = Dictionary(uniqueKeysWithValues: (try await points).map { ($0.memberId, $0.balance) })
            self.media = try await media
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
        await perform {
            try await supabase.from("members").insert(NewMember(familyId: family.id, displayName: name, role: role, color: color)).execute()
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
        await perform { try await supabase.from("events").delete().eq("id", value: event.id.uuidString).execute() }
    }

    // MARK: Chores & rewards

    func addTask(_ task: NewTask) async {
        await perform { try await supabase.from("tasks").insert(task).execute() }
    }

    func review(_ completion: TaskCompletion, approve: Bool) async {
        struct Params: Encodable { let completion: UUID; let approve: Bool }
        await perform { try await supabase.rpc("review_completion", params: Params(completion: completion.id, approve: approve)).execute() }
    }

    func addReward(title: String, icon: String?, cost: Int) async {
        guard let family else { return }
        await perform { try await supabase.from("rewards").insert(NewReward(familyId: family.id, title: title, icon: icon, cost: cost)).execute() }
    }

    func adjustPoints(member: Member, delta: Int, reason: String) async {
        struct Params: Encodable { let member: UUID; let delta: Int; let reason: String }
        await perform { try await supabase.rpc("adjust_points", params: Params(member: member.id, delta: delta, reason: reason)).execute() }
    }

    // MARK: Media

    /// Uploads a photo or video to `<family_id>/<media_id>.<ext>` and records it.
    func upload(data: Data, isVideo: Bool, fileExtension: String, takenAt: Date?) async {
        guard let family else { return }
        let id = UUID()
        let path = "\(family.id.uuidString.lowercased())/\(id.uuidString.lowercased()).\(fileExtension)"
        let contentType = isVideo ? "video/\(fileExtension == "mov" ? "quicktime" : fileExtension)" : "image/\(fileExtension == "jpg" ? "jpeg" : fileExtension)"
        struct Row: Encodable {
            let id: UUID
            let family_id: UUID
            let storage_path: String
            let kind: String
            let taken_at: Date?
            let uploaded_by: UUID?
        }
        await perform {
            _ = try await supabase.storage.from(Config.mediaBucket)
                .upload(path, data: data, options: FileOptions(contentType: contentType))
            try await supabase.from("media_items")
                .insert(Row(id: id, family_id: family.id, storage_path: path, kind: isVideo ? "video" : "photo",
                            taken_at: takenAt, uploaded_by: me?.id))
                .execute()
        }
    }

    func signedURL(for item: MediaItem) async -> URL? {
        try? await supabase.storage.from(Config.mediaBucket).createSignedURL(path: item.storagePath, expiresIn: 3600)
    }

    // MARK: Display pairing

    /// Claims the 6-digit code shown on a new wall display.
    func pairDisplay(code: String, name: String) async -> Bool {
        guard let family else { return false }
        struct Claim: Encodable { let action = "claim"; let code: String; let familyId: UUID; let name: String }
        do {
            try await supabase.functions.invoke("pair-device", options: FunctionInvokeOptions(body: Claim(code: code, familyId: family.id, name: name)))
            return true
        } catch {
            report(error)
            return false
        }
    }

    // MARK: Helpers

    private func perform(_ work: () async throws -> Void) async {
        do {
            try await work()
            await refresh()
        } catch {
            report(error)
        }
    }
}
