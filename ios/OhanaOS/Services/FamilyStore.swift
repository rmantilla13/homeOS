import Foundation
import Observation
import Supabase

let supabase = SupabaseClient(supabaseURL: Config.supabaseURL, supabaseKey: Config.supabaseAnonKey)

/// Event fields a family member may change. An empty place is stored as null.
/// `rrule` and `created_by` are not sent, so a repeating event stays repeating.
private struct EventPatch: Encodable {
    var title: String
    var location: String?
    var startsAt: Date
    var endsAt: Date
    var allDay: Bool

    enum CodingKeys: String, CodingKey {
        case title, location
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case allDay = "all_day"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        if let location {
            try container.encode(location, forKey: .location)
        } else {
            try container.encodeNil(forKey: .location)
        }
        try container.encode(startsAt, forKey: .startsAt)
        try container.encode(endsAt, forKey: .endsAt)
        try container.encode(allDay, forKey: .allDay)
    }
}

/// Whether a person allowed their questions to go to the AI assistant on this
/// iPhone. One answer per account, kept in UserDefaults. Siri reads it too.
enum AIConsent {
    /// The account in the session saved on this iPhone. Siri reads it without
    /// the store. The session may have expired; only the id is needed here.
    static var savedUserId: UUID? { supabase.auth.currentSession?.user.id }

    static func key(for userId: UUID) -> String {
        "ohanaos.aiConsent.\(userId.uuidString.lowercased())"
    }

    static func isAllowed(for userId: UUID) -> Bool {
        UserDefaults.standard.bool(forKey: key(for: userId))
    }

    static func set(_ allowed: Bool, for userId: UUID) {
        if allowed {
            UserDefaults.standard.set(true, forKey: key(for: userId))
        } else {
            UserDefaults.standard.removeObject(forKey: key(for: userId))
        }
    }
}

/// App-wide state: auth, the current family, and its data. Views read from
/// here and call its async actions; row-level security scopes every query
/// to the signed-in user's families, and each query also names the family on
/// screen, for people who belong to more than one.
@Observable
@MainActor
final class FamilyStore {
    enum Phase { case loading, signedOut, needsFamily, ready }
    enum SignUpResult { case signedIn, confirmEmail, failed }

    var phase: Phase = .loading
    var errorMessage: String?

    var family: Family?
    /// Every family you belong to; `family` is the one on screen.
    var families: [Family] = []
    var members: [Member] = []
    var devices: [Device] = []
    /// One row per occurrence; the server expands repeating events.
    var events: [FamilyEvent] = []
    var tasks: [FamilyTask] = []
    /// The chores up on `dueDay` ("yyyy-MM-dd"), as the server's `chores_due` worked them out.
    private(set) var dueTaskIds: Set<UUID> = []
    private(set) var dueDay: String?
    @ObservationIgnored private var loadingNewDay = false
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
    /// Your profile and those of people who share a family with you.
    var profiles: [Profile] = []
    /// The family's invites, newest first (parents only).
    var invites: [FamilyInvite] = []

    // Invite-only onboarding.
    /// A code from an `ohanaos://invite` link or typed on the welcome screen.
    /// Survives relaunches (e.g. while confirming an email) until it's used.
    private(set) var pendingInviteCode: String? = UserDefaults.standard.string(forKey: Keys.pendingInvite)
    /// What `preview_invite` said about `pendingInviteCode`.
    var pendingPreview: InvitePreview?
    /// The name typed at sign-up, for the member row a family invite creates.
    @ObservationIgnored private var pendingDisplayName: String?
    /// Set when someone has just signed up or in: a pending family invite is
    /// then accepted without asking again.
    @ObservationIgnored private var redeemAfterAuth = false

    // Assistant.
    /// Your conversations, most recent first.
    var threads: [AssistantThread] = []
    /// The open conversation; nil until the first reply of a new chat names it.
    var currentThreadId: UUID?
    var chat: [ChatMessage] = []
    /// A reply is on its way (from send until `done` or `error`).
    var isReplying = false
    @ObservationIgnored private var replyTask: Task<Void, Never>?
    /// Bumped when a chat is closed mid-reply, so late events are dropped.
    @ObservationIgnored private var replyGeneration = 0
    private let assistant = AssistantClient()
    /// Bumped when AI consent changes, so views showing `hasAIConsent` update.
    private var aiConsentChanges = 0

    @ObservationIgnored private var signedURLs: [String: (url: URL, expires: Date)] = [:]

    private enum Keys {
        static let pendingInvite = "ohanaos.pendingInviteCode"
        static let familyId = "ohanaos.familyId"
    }

    /// The signed-in account's user id.
    private var currentUserId: UUID? {
        #if DEBUG
        if DemoMode.isOn { return DemoMode.userId }
        #endif
        return supabase.auth.currentUser?.id
    }

    var me: Member? {
        guard let uid = currentUserId else { return nil }
        return members.first { $0.userId == uid }
    }
    var isParent: Bool { me?.role == .parent }
    var kids: [Member] { members.filter { $0.role == .child } }
    var pendingCompletions: [TaskCompletion] { completions.filter { $0.status == "pending" } }

    var email: String? {
        #if DEBUG
        if DemoMode.isOn { return DemoMode.email }
        #endif
        return supabase.auth.currentUser?.email
    }
    var myProfile: Profile? { profile(for: currentUserId) }
    /// Waiting for the first words of a reply.
    var isThinking: Bool { chat.last.map { $0.isStreaming && $0.text.isEmpty } ?? false }

    func member(_ id: UUID?) -> Member? { members.first { $0.id == id } }
    func reward(_ id: UUID) -> Reward? { rewards.first { $0.id == id } }
    func task(_ id: UUID) -> FamilyTask? { tasks.first { $0.id == id } }
    func profile(for userId: UUID?) -> Profile? {
        guard let userId else { return nil }
        return profiles.first { $0.id == userId }
    }

    /// The family picked last time, so people in two families land on the same one.
    private var preferredFamilyId: UUID? {
        get { UserDefaults.standard.string(forKey: Keys.familyId).flatMap(UUID.init(uuidString:)) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: Keys.familyId) }
    }

    // MARK: Lifecycle

    func start() async {
        #if DEBUG
        // Demo mode (-OhanaDemo YES): a sample family, no Supabase, no network.
        if DemoMode.isOn {
            loadDemo()
            return
        }
        #endif
        guard Config.isConfigured else {
            errorMessage = Config.unconfiguredMessage
            return
        }
        for await (event, session) in supabase.auth.authStateChanges {
            guard [.initialSession, .signedIn, .signedOut].contains(event) else { continue }
            var signedIn = session != nil
            // The initial session is also nil when the saved one couldn't be
            // refreshed. Offline, that's still a signed-in account: show "Try
            // again" rather than the welcome screen. A refusal means signed out.
            if !signedIn, event == .initialSession, supabase.auth.currentSession != nil {
                do {
                    _ = try await supabase.auth.session
                    signedIn = true
                } catch is URLError {
                    errorMessage = AssistantError.unreachable.message
                    continue
                } catch {
                    // The server turned the saved session down.
                }
            }
            if signedIn {
                await loadFamily()
            } else {
                clearSession()
                phase = .signedOut
            }
        }
    }

    private func clearSession() {
        clearFamilyData()
        family = nil
        families = []
        profiles = []
        pendingPreview = nil
        pendingDisplayName = nil
        redeemAfterAuth = false
        newChat()
        threads = []
        signedURLs = [:]
    }

    private func clearFamilyData() {
        members = []; devices = []; events = []; tasks = []; completions = []
        dueTaskIds = []; dueDay = nil
        rewards = []; redemptions = []; points = [:]; media = []
        lists = []; listItems = []; meals = []; memories = []; invites = []
    }

    /// Picks the family to show (or the setup screens when there's none) and loads it.
    func loadFamily() async {
        #if DEBUG
        if DemoMode.isOn { return }
        #endif
        guard Config.isConfigured else {
            errorMessage = Config.unconfiguredMessage
            return
        }
        do {
            let all: [Family] = try await supabase.from("families").select().order("created_at").execute().value
            families = all
            guard let chosen = all.first(where: { $0.id == preferredFamilyId }) ?? all.first else {
                family = nil
                clearFamilyData()
                await loadProfiles()
                if redeemAfterAuth {
                    redeemAfterAuth = false
                    if await redeemPendingInvite() { return }
                }
                phase = .needsFamily
                return
            }
            redeemAfterAuth = false
            if family?.id != chosen.id {
                clearFamilyData()
                newChat()
                threads = []
            }
            family = chosen
            preferredFamilyId = chosen.id
            await refresh()
            phase = .ready
        } catch {
            report(error)
        }
    }

    func switchFamily(to other: Family) async {
        guard other.id != family?.id else { return }
        preferredFamilyId = other.id
        await loadFamily()
    }

    func refresh() async {
        #if DEBUG
        if DemoMode.isOn { return }
        #endif
        guard let family else { return }
        let fid = family.id.uuidString
        let iso = ISO8601DateFormatter()
        let today = Calendar.current.startOfDay(for: .now)
        let eventsFrom = iso.string(from: today.addingTimeInterval(-45 * 86_400))
        let eventsTo = iso.string(from: today.addingTimeInterval(120 * 86_400))
        let completionsFrom = DayKey.string(today.addingTimeInterval(-30 * 86_400))
        let mealsFrom = DayKey.string(today.addingTimeInterval(-86_400))
        let mealsTo = DayKey.string(today.addingTimeInterval(8 * 86_400))
        let dayKey = DayKey.string(today)
        struct ChoreDay: Encodable { let fid: UUID; let day: String }
        do {
            async let members: [Member] = supabase.from("members").select().eq("family_id", value: fid)
                .order("sort_order").execute().value
            async let devices: [Device] = supabase.from("devices").select("id, name, last_seen_at").eq("family_id", value: fid)
                .order("created_at").execute().value
            async let events: [FamilyEvent] = Self.eventOccurrences(family.id, from: eventsFrom, to: eventsTo)
            // Every chore, for managing them; `due` says which are up today.
            async let tasks: [FamilyTask] = supabase.from("tasks").select().eq("family_id", value: fid)
                .eq("archived", value: false).order("created_at").execute().value
            async let due: [FamilyTask] = supabase
                .rpc("chores_due", params: ChoreDay(fid: family.id, day: dayKey))
                .execute().value
            async let recent: [TaskCompletion] = supabase.from("task_completions").select().eq("family_id", value: fid)
                .gte("for_date", value: completionsFrom).execute().value
            async let pending: [TaskCompletion] = supabase.from("task_completions").select().eq("family_id", value: fid)
                .eq("status", value: "pending").execute().value
            async let rewards: [Reward] = supabase.from("rewards").select().eq("family_id", value: fid)
                .eq("active", value: true).order("cost").execute().value
            async let redemptions: [RewardRedemption] = supabase.from("reward_redemptions").select().eq("family_id", value: fid)
                .eq("status", value: "requested").order("created_at").execute().value
            async let points: [MemberPoints] = supabase.from("member_points").select().eq("family_id", value: fid).execute().value
            async let lists: [FamilyList] = supabase.from("lists").select().eq("family_id", value: fid)
                .order("sort_order").execute().value
            // list_items has no family_id: filter through its list. Newest first, so
            // a long history of checked-off items can't push new ones past the limit.
            async let items: [ListItem] = supabase.from("list_items")
                .select("*, lists!inner(family_id)")
                .eq("lists.family_id", value: fid)
                .order("created_at", ascending: false)
                .limit(500)
                .execute().value
            async let meals: [MealPlan] = supabase.from("meal_plans").select().eq("family_id", value: fid)
                .gte("date", value: mealsFrom).lte("date", value: mealsTo).execute().value
            async let memories: [FamilyMemory] = supabase.from("family_memories").select().eq("family_id", value: fid)
                .order("created_at", ascending: false).execute().value
            async let profiles: [Profile] = supabase.from("profiles").select("id, display_name, avatar_path, updated_at").execute().value

            self.members = try await members
            self.devices = try await devices
            self.events = try await events
            self.tasks = try await tasks
            self.dueTaskIds = Set((try await due).map(\.id))
            self.dueDay = dayKey
            let recentCompletions = try await recent
            let olderPending = try await pending.filter { p in !recentCompletions.contains { $0.id == p.id } }
            self.completions = recentCompletions + olderPending
            self.rewards = try await rewards
            self.redemptions = try await redemptions
            self.points = Dictionary((try await points).map { ($0.memberId, $0.balance) }, uniquingKeysWith: { a, _ in a })
            let familyLists = try await lists
            self.lists = familyLists
            // Keep the ones on this family's lists, oldest first as they were added.
            let listIds = Set(familyLists.map(\.id))
            self.listItems = try await items.reversed().filter { listIds.contains($0.listId) }
            self.meals = try await meals
            self.memories = try await memories
            self.profiles = try await profiles
            await loadInvites()
            await refreshMedia()
        } catch {
            report(error)
        }
    }

    /// One row per occurrence overlapping the window, repeats included, in
    /// start order. Each carries its member_ids. PostgREST cuts a response off
    /// at 1000 rows (`max_rows`), which daily repeats over the window can pass,
    /// so this reads a page at a time until one comes back short.
    private static func eventOccurrences(_ familyId: UUID, from: String, to: String) async throws -> [FamilyEvent] {
        struct EventWindow: Encodable { let fid: UUID; let range_start: String; let range_end: String }
        let window = EventWindow(fid: familyId, range_start: from, range_end: to)
        let pageSize = 1000
        var rows: [FamilyEvent] = []
        var page: [FamilyEvent]
        repeat {
            page = try await supabase.rpc("event_occurrences", params: window)
                .range(from: rows.count, to: rows.count + pageSize - 1)
                .execute().value
            rows += page
        } while page.count == pageSize
        return rows
    }

    func refreshMedia() async {
        #if DEBUG
        if DemoMode.isOn { return }
        #endif
        guard let family else { return }
        do {
            let rows: [MediaItem] = try await supabase.from("media_items").select()
                .eq("family_id", value: family.id.uuidString)
                .order("created_at", ascending: false).limit(300).execute().value
            // One signing request for the page instead of one per grid tile.
            await prefetchSignedURLs(for: rows)
            guard self.family?.id == family.id else { return }
            media = rows
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        // Closing a screen or ending pull-to-refresh cancels requests; that's no error.
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        errorMessage = Self.message(for: error)
        print("OhanaOS error:", error)
    }

    /// The RPCs raise short lowercase sentences meant for people ("invite code expired").
    private static func message(for error: Error) -> String {
        if let error = error as? PostgrestError { return error.message.sentenceCased }
        if let error = error as? MediaAPIError { return error.message }
        // Edge functions answer a 4xx/5xx with {"error": "..."}; show that, not the status code.
        struct FunctionErrorBody: Decodable { let error: String }
        if let functionsError = error as? FunctionsError, case let .httpError(_, data) = functionsError,
           let body = try? JSONDecoder().decode(FunctionErrorBody.self, from: data) {
            return body.error.sentenceCased
        }
        return error.localizedDescription
    }

    // MARK: Auth & invites

    // TODO(M1): Sign in with Apple.
    func signIn(email: String, password: String) async {
        redeemAfterAuth = true
        do {
            try await supabase.auth.signIn(email: email, password: password)
        } catch {
            redeemAfterAuth = false
            report(error)
        }
    }

    /// Creates an account carrying the pending invite code, which lets it
    /// past the invite-only sign-up hook.
    func signUp(email: String, password: String, name: String) async -> SignUpResult {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var data: [String: AnyJSON] = ["display_name": .string(name)]
        if let code = pendingInviteCode { data["invite_code"] = .string(code) }
        pendingDisplayName = name
        redeemAfterAuth = true
        do {
            let response = try await supabase.auth.signUp(email: email, password: password, data: data,
                                                          redirectTo: Config.authCallbackURL)
            if case .session = response { return .signedIn }
            // Email confirmation is on: the session arrives when they confirm and sign in.
            return .confirmEmail
        } catch {
            redeemAfterAuth = false
            report(error)
            return .failed
        }
    }

    func signOut() async {
        #if DEBUG
        if DemoMode.isOn { return }
        #endif
        setPendingInvite(nil)
        try? await supabase.auth.signOut()
    }

    /// Deletes your account, then signs out. Your login, profile, photo and
    /// chats go. A family where you're the only login goes too, with
    /// everything in it; in any other family your member row stays, unlinked,
    /// as when you leave. The server refuses the last parent of a family that
    /// has other logins. It runs through the admin app (`/api/account/delete`),
    /// which also clears that family's photos and videos from Blob.
    func deleteAccount() async -> Bool {
        #if DEBUG
        if DemoMode.isOn { return false }
        #endif
        do {
            _ = try await adminAppJSON("/api/account/delete", [:], service: "the Ohana server")
        } catch {
            report(error)
            return false
        }
        preferredFamilyId = nil
        // The account is gone, so its answer about the assistant goes too.
        revokeAI()
        // The server has removed the login and its sessions; this forgets the one on the phone.
        await signOut()
        return true
    }

    /// `ohanaos://invite/<CODE>` prefills the invite; `ohanaos://auth-callback`
    /// finishes an email confirmation or an admin's email invite.
    func handleOpenURL(_ url: URL) {
        #if DEBUG
        // Demo mode never signs in or redeems a code.
        if DemoMode.isOn { return }
        #endif
        if let code = InviteCode.from(url: url) {
            setPendingInvite(code)
            return
        }
        guard url.scheme?.lowercased() == Config.urlScheme, url.host?.lowercased() == "auth-callback" else { return }
        Task { await self.completeAuthCallback(url) }
    }

    private func completeAuthCallback(_ url: URL) async {
        // Admin email invites carry implicit-grant tokens in the fragment;
        // confirmations of sign-ups made in the app carry a PKCE code.
        var fragment = URLComponents()
        fragment.percentEncodedQuery = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedFragment
        let items = fragment.queryItems ?? []
        let value: (String) -> String? = { name in items.first { $0.name == name }?.value }
        if let problem = value("error_description") ?? value("error") {
            errorMessage = problem.replacingOccurrences(of: "+", with: " ")
            return
        }
        // Any app or web page can open an ohanaos:// link, so tokens in one must
        // never quietly swap the account already signed in on this iPhone.
        if value("access_token") != nil, supabase.auth.currentSession != nil {
            errorMessage = "You're already signed in. Sign out first to use that link."
            return
        }
        redeemAfterAuth = true
        do {
            if let accessToken = value("access_token"), let refreshToken = value("refresh_token") {
                try await supabase.auth.setSession(accessToken: accessToken, refreshToken: refreshToken)
            } else {
                try await supabase.auth.session(from: url)
            }
        } catch {
            redeemAfterAuth = false
            report(error)
        }
    }

    func setPendingInvite(_ code: String?) {
        let code = code.map(InviteCode.format).flatMap { $0.isEmpty ? nil : $0 }
        if code != pendingInviteCode { pendingPreview = nil }
        pendingInviteCode = code
        UserDefaults.standard.set(code, forKey: Keys.pendingInvite)
    }

    /// Asks the server what a code is for. Works signed out. Nil when the request failed.
    func previewInvite(_ code: String) async -> InvitePreview? {
        struct Params: Encodable { let code: String }
        #if DEBUG
        if DemoMode.isOn { return nil }
        #endif
        do {
            let preview: InvitePreview = try await supabase
                .rpc("preview_invite", params: Params(code: InviteCode.normalize(code)))
                .execute().value
            return preview
        } catch {
            report(error)
            return nil
        }
    }

    /// Remembers a code and checks it; the result lands in `pendingPreview`.
    func checkInvite(_ code: String) async {
        setPendingInvite(code)
        guard let code = pendingInviteCode else { return }
        let preview = await previewInvite(code)
        if pendingInviteCode == code { pendingPreview = preview }
    }

    /// Right after signing up or in: accept a family invite, or leave a
    /// platform invite for the Create Family screen. True if a family was joined.
    private func redeemPendingInvite() async -> Bool {
        if pendingInviteCode == nil, case let .string(code)? = supabase.auth.currentUser?.userMetadata["invite_code"] {
            // Confirmed on another device, or an admin's email invite.
            setPendingInvite(code)
        }
        guard let code = pendingInviteCode, let preview = await previewInvite(code) else { return false }
        pendingPreview = preview
        guard preview.valid, preview.kind == .family else { return false }
        return await acceptInvite(code, displayName: pendingDisplayName)
    }

    /// Joins a family with a family invite code and shows that family.
    @discardableResult
    func acceptInvite(_ code: String, displayName: String? = nil) async -> Bool {
        struct Params: Encodable { let code: String; let display_name: String? }
        #if DEBUG
        if DemoMode.isOn { return false }
        #endif
        let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let familyId: UUID = try await supabase
                .rpc("accept_family_invite", params: Params(code: InviteCode.normalize(code),
                                                            display_name: name?.isEmpty == false ? name : nil))
                .execute().value
            setPendingInvite(nil)
            pendingDisplayName = nil
            preferredFamilyId = familyId
            await loadFamily()
            return true
        } catch {
            report(error)
            return false
        }
    }

    /// Starts a family. While the platform is invite-only this needs a platform invite.
    func createFamily(name: String, myName: String, inviteCode: String?) async {
        struct Params: Encodable {
            let family_name: String
            let my_name: String
            let tz: String
            let invite_code: String?
        }
        #if DEBUG
        if DemoMode.isOn { return }
        #endif
        do {
            let familyId: UUID = try await supabase
                .rpc("create_family", params: Params(family_name: name, my_name: myName, tz: TimeZone.current.identifier,
                                                     invite_code: inviteCode.map(InviteCode.normalize)))
                .execute().value
            setPendingInvite(nil)
            preferredFamilyId = familyId
            await loadFamily()
        } catch {
            report(error)
        }
    }

    // MARK: Profile

    func loadProfiles() async {
        #if DEBUG
        if DemoMode.isOn { return }
        #endif
        do {
            profiles = try await supabase.from("profiles").select("id, display_name, avatar_path, updated_at").execute().value
        } catch {
            report(error)
        }
    }

    /// Renames you; `renameMember` also renames your member row (the name on the wall).
    func updateDisplayName(_ name: String, renameMember: Bool) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uid = currentUserId, !name.isEmpty else { return false }
        let ok = await perform {
            try await supabase.from("profiles").update(["display_name": name]).eq("id", value: uid.uuidString).execute()
            if renameMember, let me = self.me {
                try await supabase.from("members").update(["display_name": name]).eq("id", value: me.id.uuidString).execute()
            }
        }
        if family == nil { await loadProfiles() }
        return ok
    }

    /// Uploads a square JPEG to `avatars/<uid>/avatar.jpg` and points the profile at it.
    func uploadAvatar(_ jpeg: Data) async -> Bool {
        guard let uid = currentUserId else { return false }
        // Storage policies compare the folder with auth.uid()::text, which is lowercase.
        let path = "\(uid.uuidString.lowercased())/avatar.jpg"
        let ok = await perform {
            _ = try await supabase.storage.from(Config.avatarBucket)
                .upload(path, data: jpeg, options: FileOptions(cacheControl: "60", contentType: "image/jpeg", upsert: true))
            try await supabase.from("profiles").update(["avatar_path": path]).eq("id", value: uid.uuidString).execute()
        }
        AvatarCache.shared.forget(path: path)
        if family == nil { await loadProfiles() }
        return ok
    }

    func removeAvatar() async {
        guard let uid = currentUserId, let path = myProfile?.avatarPath else { return }
        await perform {
            let clear: [String: AnyJSON] = ["avatar_path": .null]
            try await supabase.from("profiles").update(clear).eq("id", value: uid.uuidString).execute()
            _ = try await supabase.storage.from(Config.avatarBucket).remove(paths: [path])
        }
        AvatarCache.shared.forget(path: path)
    }

    /// A profile's photo in the `avatars` bucket, versioned by `updated_at`.
    func photo(of profile: Profile?) -> (path: String, version: String)? {
        guard let profile, let path = profile.avatarPath else { return nil }
        return (path, profile.updatedAt.map { String($0.timeIntervalSince1970) } ?? "")
    }

    /// A member's photo: their account's profile photo if they have one, else
    /// the one a parent set. That one is a new file each time, so its path is
    /// its version.
    func avatarPath(for member: Member?) -> (path: String, version: String)? {
        if let profilePhoto = photo(of: profile(for: member?.userId)) { return profilePhoto }
        guard let path = member?.avatarPath else { return nil }
        return (path: path, version: "")
    }

    // MARK: Member photos

    /// Parents give a member without a login a photo. It goes to a new file in
    /// the family's folder, `avatars/<family_id>/<member_id>-<random>.jpg`,
    /// so other phones don't keep showing the old one from their cache; then
    /// the old file goes.
    func setMemberPhoto(_ jpeg: Data, for member: Member) async -> Bool {
        let old = self.member(member.id)?.avatarPath ?? member.avatarPath
        var path: String?
        let ok = await perform {
            let uploaded = try await self.uploadMemberPhoto(jpeg, for: member.id, in: member.familyId)
            do {
                try await supabase.from("members").update(["avatar_path": uploaded])
                    .eq("id", value: member.id.uuidString).execute()
            } catch {
                await self.removeMemberPhotoFile(uploaded, in: member.familyId)
                throw error
            }
            path = uploaded
        }
        if ok, let old, let path, old != path { await removeMemberPhotoFile(old, in: member.familyId) }
        return ok
    }

    func removeMemberPhoto(for member: Member) async -> Bool {
        guard let path = self.member(member.id)?.avatarPath ?? member.avatarPath else { return true }
        if let i = members.firstIndex(where: { $0.id == member.id }) { members[i].avatarPath = nil }
        let ok = await perform {
            let clear: [String: AnyJSON] = ["avatar_path": .null]
            try await supabase.from("members").update(clear).eq("id", value: member.id.uuidString).execute()
        }
        if ok { await removeMemberPhotoFile(path, in: member.familyId) }
        return ok
    }

    /// Uploads a member photo to a new file and returns its path. The member
    /// row doesn't need to exist yet.
    private func uploadMemberPhoto(_ jpeg: Data, for memberId: UUID, in familyId: UUID) async throws -> String {
        // Storage policies compare the folder with family ids as text, which are lowercase.
        let token = UUID().uuidString.prefix(8).lowercased()
        let path = "\(familyId.uuidString.lowercased())/\(memberId.uuidString.lowercased())-\(token).jpg"
        _ = try await supabase.storage.from(Config.avatarBucket)
            .upload(path, data: jpeg, options: FileOptions(cacheControl: "3600", contentType: "image/jpeg", upsert: false))
        return path
    }

    /// Best effort: a file left behind goes with the family's folder later.
    private func removeMemberPhotoFile(_ path: String, in familyId: UUID) async {
        AvatarCache.shared.forget(path: path)
        #if DEBUG
        if DemoMode.isOn { return }
        #endif
        guard path.hasPrefix("\(familyId.uuidString.lowercased())/") else { return }
        _ = try? await supabase.storage.from(Config.avatarBucket).remove(paths: [path])
    }

    // MARK: Members

    /// Parents edit anyone; everyone else edits only their own name and color.
    func canEdit(_ member: Member) -> Bool { isParent || member.id == me?.id }

    /// Members without a login, who a parent can invite to claim their row.
    var membersWithoutAccounts: [Member] { members.filter { $0.userId == nil } }

    func updateMember(_ member: Member, name: String, color: String, role: MemberRole) async -> Bool {
        struct Changes: Encodable {
            let display_name: String
            let color: String
            let role: MemberRole?  // left out unless a parent is editing
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        let changes = Changes(display_name: name, color: color, role: isParent ? role : nil)
        if let i = members.firstIndex(where: { $0.id == member.id }) {
            members[i].displayName = name
            members[i].color = color
            if isParent { members[i].role = role }
        }
        return await perform {
            try await supabase.from("members").update(changes).eq("id", value: member.id.uuidString).execute()
        }
    }

    /// Parents only. The member's chores, completions, points and photo go with
    /// them; the server refuses to remove the last parent with an account.
    func removeMember(_ member: Member) async -> Bool {
        let photo = self.member(member.id)?.avatarPath ?? member.avatarPath
        members.removeAll { $0.id == member.id }
        let ok = await perform {
            try await supabase.from("members").delete().eq("id", value: member.id.uuidString).execute()
        }
        if ok, let photo { await removeMemberPhotoFile(photo, in: member.familyId) }
        return ok
    }

    /// Unlinks your account. Your member row, points and history stay on the screen.
    func leaveFamily() async -> Bool {
        guard let family else { return false }
        struct Params: Encodable { let family: UUID }
        #if DEBUG
        if DemoMode.isOn { return false }
        #endif
        do {
            try await supabase.rpc("leave_family", params: Params(family: family.id)).execute()
        } catch {
            report(error)
            return false
        }
        preferredFamilyId = nil
        self.family = nil
        clearFamilyData()
        newChat()
        threads = []
        await loadFamily()
        return true
    }

    // MARK: Invites

    func loadInvites() async {
        #if DEBUG
        if DemoMode.isOn { return }
        #endif
        guard let family, isParent else {
            invites = []
            return
        }
        do {
            invites = try await supabase.from("family_invites").select()
                .eq("family_id", value: family.id.uuidString)
                .order("created_at", ascending: false)
                .limit(50)
                .execute().value
        } catch {
            report(error)
        }
    }

    /// A family invite. With `member`, whoever accepts gets that member's row (and role).
    func createInvite(role: MemberRole, for member: Member?, email: String?, expiresInDays: Int) async -> CreatedInvite? {
        guard let family else { return nil }
        struct Params: Encodable {
            let family: UUID
            let role: MemberRole
            let member: UUID?
            let email: String?
            let expires_in_days: Int
        }
        let email = email?.trimmingCharacters(in: .whitespacesAndNewlines)
        let params = Params(family: family.id, role: member?.role ?? role, member: member?.id,
                            email: email?.isEmpty == false ? email : nil, expires_in_days: expiresInDays)
        #if DEBUG
        if DemoMode.isOn { return nil }
        #endif
        do {
            let rows: [CreatedInvite] = try await supabase.rpc("create_family_invite", params: params).execute().value
            await loadInvites()
            return rows.first
        } catch {
            report(error)
            return nil
        }
    }

    func revokeInvite(_ invite: FamilyInvite) async {
        struct Params: Encodable { let invite: UUID }
        if let i = invites.firstIndex(where: { $0.id == invite.id }) { invites[i].revokedAt = .now }
        #if DEBUG
        if DemoMode.isOn { return }
        #endif
        do {
            try await supabase.rpc("revoke_family_invite", params: Params(invite: invite.id)).execute()
        } catch {
            report(error)
        }
        await loadInvites()
    }

    /// Parents add someone to the family screen, with a photo when `photo` is
    /// a JPEG. The photo goes up first, so either both are saved or neither.
    func addMember(name: String, role: MemberRole, color: String, photo: Data? = nil) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let family, !name.isEmpty else { return false }
        let order = (members.map(\.sortOrder).max() ?? 0) + 1
        var new = NewMember(familyId: family.id, displayName: name, role: role, color: color, sortOrder: order)
        members.append(Member(id: new.id, familyId: family.id, userId: nil, displayName: name, role: role,
                              color: color, sortOrder: order))
        return await perform {
            if let photo {
                new.avatarPath = try await self.uploadMemberPhoto(photo, for: new.id, in: family.id)
            }
            do {
                try await supabase.from("members").insert(new).execute()
            } catch {
                if let path = new.avatarPath { await self.removeMemberPhotoFile(path, in: family.id) }
                throw error
            }
        }
    }

    // MARK: Calendar

    func addEvent(title: String, location: String?, start: Date, end: Date, allDay: Bool, memberIds: Set<UUID>) async {
        guard let family else { return }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let event = NewEvent(familyId: family.id, title: title, location: blankToNil(location), startsAt: start,
                             endsAt: max(end, start), allDay: allDay, createdBy: me?.id)
        await perform {
            try await supabase.from("events").insert(event).execute()
            if !memberIds.isEmpty {
                let links = memberIds.map { ["event_id": event.id.uuidString, "member_id": $0.uuidString] }
                try await supabase.from("event_members").insert(links).execute()
            }
        }
    }

    /// Changes the title, place, time, and who an event is for. Recurrence (`rrule`) is left as stored.
    /// `event` may be one repeat of a series: the change then applies to the
    /// whole series (`seriesTimes`), and every repeat keeps the new time and length.
    func updateEvent(_ event: FamilyEvent, title: String, location: String?, start: Date, end: Date, allDay: Bool, memberIds: Set<UUID>) async {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        let end = max(end, start)
        let series = event.isRecurring ? Self.seriesTimes(moving: event, to: start, end) : (start: start, end: end)
        let eventId = event.eventId.uuidString
        await perform {
            try await supabase.from("events")
                .update(EventPatch(title: title, location: blankToNil(location), startsAt: series.start,
                                    endsAt: series.end, allDay: allDay))
                .eq("id", value: eventId)
                .execute()
            try await supabase.from("event_members").delete().eq("event_id", value: eventId).execute()
            if !memberIds.isEmpty {
                let links = memberIds.map { ["event_id": eventId, "member_id": $0.uuidString] }
                try await supabase.from("event_members").insert(links).execute()
            }
        }
    }

    /// The stored times for a series whose repeat `occurrence` is edited to
    /// `start`–`end`. The server repeats a series at its local time of day and
    /// local length, so the move is local too: the start goes as many calendar
    /// days as the repeat did, at the new time of day, and the end follows at
    /// the new length. Moved across a DST change, a 4:30pm series stays at
    /// 4:30pm and an all-day one at midnight. Unchanged times keep it as stored.
    private static func seriesTimes(moving occurrence: FamilyEvent, to start: Date, _ end: Date) -> (start: Date, end: Date) {
        if start == occurrence.startsAt && end == occurrence.endsAt {
            return (occurrence.seriesStartsAt, occurrence.seriesEndsAt)
        }
        let calendar = Calendar.current
        // Counted noon to noon, so a clock change at midnight can't lose a day.
        func days(from a: Date, to b: Date) -> Int {
            guard let noonA = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: a),
                  let noonB = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: b) else { return 0 }
            return calendar.dateComponents([.day], from: noonA, to: noonB).day ?? 0
        }
        // `count` calendar days after `day`, at `time`'s time of day.
        func moved(_ day: Date, by count: Int, at time: Date) -> Date? {
            let clock = calendar.dateComponents([.hour, .minute, .second], from: time)
            return calendar.date(byAdding: .day, value: count, to: day).flatMap {
                calendar.date(bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0, second: clock.second ?? 0, of: $0)
            }
        }
        let seriesStart = moved(occurrence.seriesStartsAt, by: days(from: occurrence.startsAt, to: start), at: start)
            ?? occurrence.seriesStartsAt.addingTimeInterval(start.timeIntervalSince(occurrence.startsAt))
        let seriesEnd = moved(seriesStart, by: days(from: start, to: end), at: end)
            ?? seriesStart.addingTimeInterval(end.timeIntervalSince(start))
        return (seriesStart, max(seriesEnd, seriesStart))
    }

    /// Deletes the stored event, so every repeat of a repeating one goes too.
    func deleteEvent(_ event: FamilyEvent) async {
        events.removeAll { $0.eventId == event.eventId }
        await perform { try await supabase.from("events").delete().eq("id", value: event.eventId.uuidString).execute() }
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
        let title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        var task = task
        task.title = title
        if task.createdBy == nil { task.createdBy = me?.id }
        await perform { try await supabase.from("tasks").insert(task).execute() }
    }

    func archiveTask(_ task: FamilyTask) async {
        tasks.removeAll { $0.id == task.id }
        await perform {
            try await supabase.from("tasks").update(["archived": true]).eq("id", value: task.id.uuidString).execute()
        }
    }

    /// Whether the chores on hand were worked out for today. After midnight
    /// they're yesterday's until `refreshIfNewDay` gets through (it can't
    /// offline), and screens say so rather than "No chores today".
    var choresLoadedToday: Bool { dueDay == DayKey.today }

    /// Whether a chore is up today. The server works that out (`chores_due`:
    /// repeats, and one-time chores until someone finishes them) for the day
    /// the data was loaded, so only today is supported. Past midnight nothing
    /// is due until `refreshIfNewDay` loads the new day.
    func isDue(_ task: FamilyTask) -> Bool {
        choresLoadedToday && dueTaskIds.contains(task.id)
    }

    /// Chores that aren't up today: another day's repeat, or a rule that has
    /// run out. Empty while today's haven't loaded, as every chore would look like one.
    var choresNotDueToday: [FamilyTask] {
        choresLoadedToday ? tasks.filter { !dueTaskIds.contains($0.id) } : []
    }

    /// Reloads when the chores on screen were worked out for an earlier day:
    /// back in the foreground the next morning, at midnight, or back online
    /// after that load failed. Those can come together; one reload serves them.
    func refreshIfNewDay() async {
        guard family != nil, !choresLoadedToday, !loadingNewDay else { return }
        #if DEBUG
        // Demo mode has no server to ask; the sample rules give the new day's chores.
        if DemoMode.isOn {
            markDemoChoresDue()
            return
        }
        #endif
        loadingNewDay = true
        defer { loadingNewDay = false }
        await refresh()
    }

    #if DEBUG
    /// Demo mode: today's chores come from the sample chores' own rules
    /// (`demoDueTaskIds`), as there is no `chores_due` to call.
    func markDemoChoresDue() {
        dueTaskIds = demoDueTaskIds(on: .now)
        dueDay = DayKey.today
    }
    #endif

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
        // Only a parent may delete a rejected try (RLS), and it holds the day's
        // unique key, so anyone else's retry would just fail on that key.
        if rejected != nil && !isParent {
            errorMessage = "A parent turned this one down today. Ask them to undo it, then try again."
            return
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
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let family, !title.isEmpty, cost > 0 else { return }
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

    private struct MediaAPIError: Error {
        let message: String
    }

    /// Where photos and videos go, for messages ("ohanaos.co").
    private static var mediaHost: String { Config.mediaAPIURL.host ?? "the media service" }

    /// Uploads a photo or video and records it. Both go to the private Blob
    /// store through the admin app. Returns false on failure. Call
    /// `refreshMedia()` after a batch. Photos are small JPEGs. Videos stream
    /// from a file (`upload(file:)`) so a long clip isn't held in memory.
    @discardableResult
    func upload(data: Data, isVideo: Bool, fileExtension: String, metadata: MediaMetadata) async -> Bool {
        guard let family else { return false }
        let contentType = isVideo ? Self.videoContentType(fileExtension) : Self.photoContentType(fileExtension)
        return await uploadToBlob(bytes: data.count, contentType: contentType, kind: isVideo ? "video" : "photo",
                                  metadata: metadata, familyId: family.id) { request in
            try await URLSession.shared.upload(for: request, from: data)
        }
    }

    /// Streams a video file to Blob. The caller deletes `file` afterwards.
    @discardableResult
    func upload(file: URL, fileExtension: String, metadata: MediaMetadata) async -> Bool {
        guard let family else { return false }
        let bytes: Int
        do {
            bytes = try Self.fileByteCount(file)
        } catch {
            report(error)
            return false
        }
        let contentType = Self.videoContentType(fileExtension)
        return await uploadToBlob(bytes: bytes, contentType: contentType, kind: "video",
                                  metadata: metadata, familyId: family.id) { request in
            try await URLSession.shared.upload(for: request, fromFile: file)
        }
    }

    private static func fileByteCount(_ url: URL) throws -> Int {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        guard let size, size > 0 else {
            throw MediaAPIError(message: "That video is empty.")
        }
        return size
    }

    private func uploadToBlob(bytes: Int, contentType: String, kind: String, metadata: MediaMetadata, familyId: UUID,
                              put: (URLRequest) async throws -> (Data, URLResponse)) async -> Bool {
        var uploadedPath: String?
        do {
            let ticket = try await mediaJSON("upload", [
                "family_id": familyId.uuidString.lowercased(),
                "content_type": contentType,
                "bytes": bytes,
            ])
            guard let idString = ticket["id"] as? String, let id = UUID(uuidString: idString),
                  let path = ticket["pathname"] as? String,
                  let uploadString = ticket["upload_url"] as? String, let uploadURL = URL(string: uploadString) else {
                throw MediaAPIError(message: "The media service at \(Self.mediaHost) sent an unexpected reply. Try again later.")
            }
            // The type the upload was signed for. Blob checks the PUT's header
            // against it, and the row records the same one.
            let signedType = (ticket["content_type"] as? String) ?? contentType
            uploadedPath = path
            var request = URLRequest(url: uploadURL)
            request.httpMethod = "PUT"
            request.setValue(signedType, forHTTPHeaderField: "Content-Type")
            // After the last byte of a long video, Blob can take a while to
            // answer. The default 60 s idle limit would call that a failure.
            request.timeoutInterval = 300
            let reply: (Data, URLResponse)
            do {
                reply = try await put(request)
            } catch {
                throw Self.transferError(error, to: "media storage")
            }
            let status = (reply.1 as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                throw MediaAPIError(message: Self.storageRefusal(status: status, body: reply.0))
            }
            // byte_size is what the family quota counts. Blob objects are not in Storage.
            let row = NewMediaItem(id: id, familyId: familyId, storagePath: path, kind: kind,
                                   width: metadata.width, height: metadata.height,
                                   durationSeconds: metadata.durationSeconds, takenAt: metadata.takenAt,
                                   uploadedBy: me?.id, byteSize: bytes, contentType: signedType, fileStore: "blob")
            try await supabase.from("media_items").insert(row).execute()
            return true
        } catch {
            if let uploadedPath {
                _ = try? await mediaJSON("delete", ["pathname": uploadedPath])
            }
            report(error)
            return false
        }
    }

    /// JPEG after `preparePhoto`. Other still-image types are accepted if a
    /// caller already encoded them.
    private static func photoContentType(_ fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "gif": return "image/gif"
        default: return "image/\(fileExtension.lowercased())"
        }
    }

    /// Canonical types for the admin app's allowlist. `.mov` is QuickTime;
    /// the other extensions use their usual container type.
    private static func videoContentType(_ fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "mov": return "video/quicktime"
        case "mp4": return "video/mp4"
        case "m4v": return "video/m4v"
        case "webm": return "video/webm"
        case "mkv": return "video/x-matroska"
        case "3gp": return "video/3gpp"
        case "3g2": return "video/3gpp2"
        default: return "video/\(fileExtension.lowercased())"
        }
    }

    /// `path` on the admin app's origin (`Config.mediaAPIURL`), which serves
    /// `/api/media/*` and `/api/account/delete`. A path in the configured URL
    /// is dropped, so it can't turn into `/x/api/media/...`.
    private func adminAppEndpoint(_ path: String) -> URL? {
        let base = Config.mediaAPIURL
        var components = URLComponents()
        components.scheme = base.scheme
        components.host = base.host
        components.port = base.port
        components.path = path
        return components.url
    }

    private func mediaJSON(_ name: String, _ body: [String: Any]) async throws -> [String: Any] {
        try await adminAppJSON("/api/media/" + name, body, service: "the media service")
    }

    /// POSTs JSON to the admin app with your session. `service` names it in
    /// messages: "the media service at ohanaos.co".
    private func adminAppJSON(_ path: String, _ body: [String: Any], service: String) async throws -> [String: Any] {
        #if DEBUG
        if DemoMode.isOn { throw MediaAPIError(message: "Demo mode doesn't send anything to \(service).") }
        #endif
        guard let url = adminAppEndpoint(path) else {
            throw MediaAPIError(message: "This build has no valid media service address (MEDIA_API_URL).")
        }
        let token = try await supabase.auth.session.accessToken
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let reply: (Data, URLResponse)
        do {
            reply = try await URLSession.shared.data(for: request)
        } catch {
            throw Self.transferError(error, to: "\(service) at \(Self.mediaHost)")
        }
        let json = (try? JSONSerialization.jsonObject(with: reply.0) as? [String: Any]) ?? [:]
        let status = (reply.1 as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            if status == 401 {
                // Signed in here, refused there: an expired session, or a build
                // whose admin app belongs to another Supabase project.
                throw MediaAPIError(message: "\(service.sentenceCased) at \(Self.mediaHost) didn't accept your sign-in. Sign out and back in, then try again.")
            }
            if let message = json["error"] as? String, !message.isEmpty {
                // Media errors are sentences already; the edge function's are lowercase.
                throw MediaAPIError(message: message.sentenceCased)
            }
            // Not the admin app's JSON: a wrong address, a missing route or a proxy page.
            throw MediaAPIError(message: "\(service.sentenceCased) at \(Self.mediaHost) answered HTTP \(status). Check that the app points at the Ohana admin app, then try again.")
        }
        return json
    }

    /// A request that never got an HTTP answer, in words people can act on.
    /// Cancellation passes through unchanged so `report` stays quiet about it.
    private static func transferError(_ error: Error, to service: String) -> Error {
        guard let urlError = error as? URLError, urlError.code != .cancelled else { return error }
        switch urlError.code {
        case .notConnectedToInternet, .dataNotAllowed:
            return MediaAPIError(message: "You're offline. Connect to the internet and try again.")
        case .networkConnectionLost, .timedOut:
            // Also what a transfer reports after iOS suspends the app mid-upload.
            return MediaAPIError(message: "The connection to \(service) dropped before it finished. Keep Ohana open and the phone unlocked while photos and videos upload, then try again.")
        default:
            return MediaAPIError(message: "Couldn't reach \(service). \(urlError.localizedDescription)")
        }
    }

    /// Blob refuses an upload with {"error": {"code", "message"}}.
    private static func storageRefusal(status: Int, body: Data) -> String {
        let json = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let detail = ((json["error"] as? [String: Any])?["message"] as? String) ?? (json["error"] as? String)
        if let detail, !detail.isEmpty {
            return "Media storage refused the file (HTTP \(status)): \(detail)"
        }
        return "Media storage refused the file (HTTP \(status)). Try again in a moment."
    }

    func setShowOnFrame(_ item: MediaItem, _ show: Bool) async {
        if let i = media.firstIndex(where: { $0.id == item.id }) { media[i].showOnFrame = show }
        #if DEBUG
        if DemoMode.isOn { return }
        #endif
        do {
            try await supabase.from("media_items").update(["show_on_frame": show]).eq("id", value: item.id.uuidString).execute()
        } catch {
            report(error)
            await refreshMedia()
        }
    }

    /// Deletes one photo or video: the `media_items` row (family-member RLS, not the admin console)
    /// and its objects in the `family-media` bucket.
    func deleteMedia(_ item: MediaItem) async {
        await deleteMedia([item])
    }

    /// Deletes several items the same way as `deleteMedia(_:)`. One confirmation in the UI covers the batch.
    func deleteMedia(_ items: [MediaItem]) async {
        var unique: [MediaItem] = []
        var seen = Set<UUID>()
        for item in items where seen.insert(item.id).inserted { unique.append(item) }
        guard !unique.isEmpty else { return }
        let ids = Set(unique.map(\.id))
        media.removeAll { ids.contains($0.id) }
        #if DEBUG
        if DemoMode.isOn { return }
        #endif
        var removed: [MediaItem] = []
        do {
            for item in unique {
                if item.inBlob {
                    _ = try await mediaJSON("delete", ["pathname": item.storagePath])
                }
                try await supabase.from("media_items").delete().eq("id", value: item.id.uuidString).execute()
                removed.append(item)
            }
            try await removeStoredFiles(storagePaths(for: removed.filter { !$0.inBlob }))
        } catch {
            // Rows already deleted should not keep their files if a later row fails.
            if !removed.isEmpty {
                try? await removeStoredFiles(storagePaths(for: removed.filter { !$0.inBlob }))
            }
            report(error)
            await refreshMedia()
        }
    }

    private func removeStoredFiles(_ paths: [String]) async throws {
        var start = 0
        while start < paths.count {
            let end = min(start + 100, paths.count)
            _ = try await supabase.storage.from(Config.mediaBucket).remove(paths: Array(paths[start..<end]))
            start = end
        }
    }

    /// The file plus its poster, without repeating a path.
    private func storagePaths(for items: [MediaItem]) -> [String] {
        var paths: [String] = []
        var seen = Set<String>()
        for item in items {
            var candidates = [item.storagePath]
            if let thumb = item.thumbnailPath { candidates.append(thumb) }
            for path in candidates where !path.isEmpty && seen.insert(path).inserted {
                paths.append(path)
            }
        }
        return paths
    }

    /// Signed URLs last an hour; reuse them until they're close to expiring.
    /// Blob files come from the media service. Rows still in Storage use a
    /// Storage signed URL.
    func signedURL(for item: MediaItem) async -> URL? {
        #if DEBUG
        // Demo images are drawn on the phone (DemoMedia); there is nothing to sign.
        if DemoMode.isOn { return nil }
        #endif
        if let cached = signedURLs[item.storagePath], cached.expires > Date.now.addingTimeInterval(300) {
            return cached.url
        }
        if item.inBlob {
            do {
                let json = try await mediaJSON("urls", ["paths": [item.storagePath]])
                guard let urlString = (json["urls"] as? [String])?.first, let url = URL(string: urlString), !urlString.isEmpty else {
                    return nil
                }
                signedURLs[item.storagePath] = (url: url, expires: Date.now.addingTimeInterval(3600))
                return url
            } catch {
                report(error)
                return nil
            }
        }
        guard let url = try? await supabase.storage.from(Config.mediaBucket)
            .createSignedURL(path: item.storagePath, expiresIn: 3600) else { return nil }
        signedURLs[item.storagePath] = (url: url, expires: Date.now.addingTimeInterval(3600))
        return url
    }

    /// Fills the URL cache for Blob rows, up to 200 paths per request (the
    /// media service's limit), so opening Media doesn't sign once per tile.
    /// A failure is only logged: each tile then asks on its own and reports.
    private func prefetchSignedURLs(for items: [MediaItem]) async {
        let soon = Date.now.addingTimeInterval(300)
        var paths: [String] = []
        var seen = Set<String>()
        for item in items where item.inBlob {
            guard seen.insert(item.storagePath).inserted else { continue }
            if let cached = signedURLs[item.storagePath], cached.expires > soon { continue }
            paths.append(item.storagePath)
        }
        var start = 0
        while start < paths.count {
            let end = min(start + 200, paths.count)
            let chunk = Array(paths[start..<end])
            start = end
            do {
                let json = try await mediaJSON("urls", ["paths": chunk])
                let urls = (json["urls"] as? [String]) ?? []
                for (path, string) in zip(chunk, urls) {
                    guard !string.isEmpty, let url = URL(string: string) else { continue }
                    signedURLs[path] = (url: url, expires: Date.now.addingTimeInterval(3600))
                }
            } catch {
                print("OhanaOS media URLs:", error)
                return
            }
        }
    }

    // MARK: Assistant

    var currentThread: AssistantThread? { threads.first { $0.id == currentThreadId } }

    /// Your own conversations in this family (RLS hides everyone else's).
    func loadThreads() async {
        #if DEBUG
        if DemoMode.isOn { return }
        #endif
        guard let family else { return }
        do {
            threads = try await supabase.from("assistant_threads")
                .select("id, title, updated_at")
                .eq("family_id", value: family.id.uuidString)
                .eq("archived", value: false)
                .order("updated_at", ascending: false)
                .limit(100)
                .execute().value
        } catch {
            report(error)
        }
    }

    func openThread(_ thread: AssistantThread) async {
        guard thread.id != currentThreadId || chat.isEmpty else { return }
        cancelReply()
        currentThreadId = thread.id
        chat = []
        #if DEBUG
        if DemoMode.isOn {
            chat = demoTranscript(for: thread.id)
            return
        }
        #endif
        do {
            let rows: [AssistantMessageRow] = try await supabase.from("assistant_messages")
                .select("id, role, content, actions")
                .eq("thread_id", value: thread.id.uuidString)
                .order("id", ascending: false)
                .limit(200)
                .execute().value
            guard currentThreadId == thread.id else { return }
            // Anything sent while the history loaded (and its streaming reply) stays after it.
            chat = rows.reversed().map(\.chatMessage) + chat
        } catch {
            report(error)
        }
    }

    /// Starts over; the next message opens a new thread.
    func newChat() {
        cancelReply()
        currentThreadId = nil
        chat = []
    }

    func deleteThread(_ thread: AssistantThread) async {
        if currentThreadId == thread.id { newChat() }
        threads.removeAll { $0.id == thread.id }
        #if DEBUG
        if DemoMode.isOn { return }
        #endif
        do {
            try await supabase.from("assistant_threads").delete().eq("id", value: thread.id.uuidString).execute()
        } catch {
            report(error)
            await loadThreads()
        }
    }

    /// Whether the signed-in person allowed their questions to go to the AI
    /// assistant on this iPhone. Asked once per account, before the first
    /// question. False when signed out.
    var hasAIConsent: Bool {
        _ = aiConsentChanges
        #if DEBUG
        if DemoMode.isOn { return true }
        #endif
        guard let uid = currentUserId else { return false }
        return AIConsent.isAllowed(for: uid)
    }

    func allowAI() {
        #if DEBUG
        // Demo consent stays on; the bump snaps Profile's switch back.
        if DemoMode.isOn { aiConsentChanges += 1; return }
        #endif
        guard let uid = currentUserId else { return }
        AIConsent.set(true, for: uid)
        aiConsentChanges += 1
    }

    /// Stops questions going to the assistant from this iPhone until allowed again.
    func revokeAI() {
        #if DEBUG
        // Demo consent stays on; the bump snaps Profile's switch back.
        if DemoMode.isOn { aiConsentChanges += 1; return }
        #endif
        guard let uid = currentUserId else { return }
        AIConsent.set(false, for: uid)
        aiConsentChanges += 1
    }

    /// Sends a message in the open thread and streams the reply into `chat`.
    /// Sends nothing until the person has allowed the assistant (`allowAI`).
    func ask(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isReplying, hasAIConsent else { return }
        #if DEBUG
        if DemoMode.isOn {
            chat.append(ChatMessage(role: .user, text: text))
            chat.append(ChatMessage(role: .assistant, text: DemoMode.offlineReply))
            return
        }
        #endif
        isReplying = true  // before the task starts, so a double tap can't send twice
        let task = Task { await self.streamReply(to: text) }
        replyTask = task
        await task.value
    }

    private func cancelReply() {
        replyTask?.cancel()
        replyTask = nil
        replyGeneration += 1
        isReplying = false
    }

    private func streamReply(to text: String) async {
        let generation = replyGeneration
        isReplying = true
        chat.append(ChatMessage(role: .user, text: text))
        let placeholder = ChatMessage(role: .assistant, text: "", isStreaming: true)
        chat.append(placeholder)

        do {
            try await assistant.stream(text, threadId: currentThreadId, familyId: family?.id) { event in
                self.apply(event, to: placeholder.id, generation: generation, prompt: text)
            }
        } catch {
            if !Task.isCancelled {
                print("OhanaOS assistant error:", error)
                let message = (error as? AssistantError ?? AssistantError.unreachable).message
                updateReply(placeholder.id, generation: generation) {
                    $0.text = message
                    $0.isError = true
                }
            }
        }
        guard generation == replyGeneration else { return }

        // The stream closed early: keep what arrived, or say it failed.
        updateReply(placeholder.id, generation: generation) {
            if $0.isStreaming && $0.text.isEmpty {
                $0.text = AssistantError.unreachable.message
                $0.isError = true
            }
            $0.isStreaming = false
        }
        isReplying = false
        replyTask = nil
        let didSomething = chat.first { $0.id == placeholder.id }?.actions.isEmpty == false
        if didSomething { await refresh() }
        await loadThreads()
    }

    private func apply(_ event: AssistantEvent, to replyId: UUID, generation: Int, prompt: String) {
        guard generation == replyGeneration else { return }
        switch event {
        case .thread(let id):
            currentThreadId = id
            if !threads.contains(where: { $0.id == id }) {
                // Shown right away; loadThreads() brings the server's title after `done`.
                threads.insert(AssistantThread(id: id, title: String(prompt.prefix(48)), updatedAt: .now), at: 0)
            }
        case .delta(let text):
            updateReply(replyId, generation: generation) { $0.text += text }
        case .action(let action):
            updateReply(replyId, generation: generation) { $0.actions.append(action) }
        case .done(let reply):
            // The final reply replaces what streamed (the server may have tidied it).
            updateReply(replyId, generation: generation) {
                $0.text = reply.reply
                if let actions = reply.actions { $0.actions = actions }
                $0.isStreaming = false
            }
            if let id = reply.threadId { currentThreadId = id }
        case .error(let message):
            updateReply(replyId, generation: generation) {
                $0.text = message
                $0.isError = true
                $0.isStreaming = false
            }
        }
    }

    private func updateReply(_ id: UUID, generation: Int, _ change: (inout ChatMessage) -> Void) {
        guard generation == replyGeneration, let i = chat.firstIndex(where: { $0.id == id }) else { return }
        change(&chat[i])
    }

    // MARK: Display pairing

    /// Claims the 6-digit code shown on a new wall display.
    func pairDisplay(code: String, name: String) async -> Bool {
        guard let family else { return false }
        struct Claim: Encodable { let action = "claim"; let code: String; let familyId: UUID; let name: String }
        #if DEBUG
        if DemoMode.isOn { return false }
        #endif
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

    private func blankToNil(_ text: String?) -> String? {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Runs a write, then reloads. On failure the optimistic local change is
    /// replaced by the server's state. Returns whether the write succeeded.
    @discardableResult
    private func perform(_ work: () async throws -> Void) async -> Bool {
        #if DEBUG
        // Demo mode keeps the local change and sends nothing.
        if DemoMode.isOn { return true }
        #endif
        var ok = true
        do {
            try await work()
        } catch {
            report(error)
            ok = false
        }
        await refresh()
        return ok
    }
}
