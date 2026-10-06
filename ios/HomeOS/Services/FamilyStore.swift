import Foundation
import Observation
import Supabase

let supabase = SupabaseClient(supabaseURL: Config.supabaseURL, supabaseKey: Config.supabaseAnonKey)

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
    /// Your profile and those of people who share a family with you.
    var profiles: [Profile] = []
    /// The family's invites, newest first (parents only).
    var invites: [FamilyInvite] = []

    // Invite-only onboarding.
    /// A code from a `homeos://invite` link or typed on the welcome screen.
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

    @ObservationIgnored private var signedURLs: [String: (url: URL, expires: Date)] = [:]

    private enum Keys {
        static let pendingInvite = "homeos.pendingInviteCode"
        static let familyId = "homeos.familyId"
    }

    var me: Member? {
        guard let uid = supabase.auth.currentUser?.id else { return nil }
        return members.first { $0.userId == uid }
    }
    var isParent: Bool { me?.role == .parent }
    var kids: [Member] { members.filter { $0.role == .child } }
    var pendingCompletions: [TaskCompletion] { completions.filter { $0.status == "pending" } }

    var email: String? { supabase.auth.currentUser?.email }
    var myProfile: Profile? { profile(for: supabase.auth.currentUser?.id) }
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
        rewards = []; redemptions = []; points = [:]; media = []
        lists = []; listItems = []; meals = []; memories = []; invites = []
    }

    /// Picks the family to show (or the setup screens when there's none) and loads it.
    func loadFamily() async {
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
        guard let family else { return }
        let fid = family.id.uuidString
        let iso = ISO8601DateFormatter()
        let today = Calendar.current.startOfDay(for: .now)
        let eventsFrom = iso.string(from: today.addingTimeInterval(-45 * 86_400))
        let eventsTo = iso.string(from: today.addingTimeInterval(120 * 86_400))
        let completionsFrom = DayKey.string(today.addingTimeInterval(-30 * 86_400))
        let mealsFrom = DayKey.string(today.addingTimeInterval(-86_400))
        let mealsTo = DayKey.string(today.addingTimeInterval(8 * 86_400))
        do {
            async let members: [Member] = supabase.from("members").select().eq("family_id", value: fid)
                .order("sort_order").execute().value
            async let devices: [Device] = supabase.from("devices").select("id, name, last_seen_at").eq("family_id", value: fid)
                .order("created_at").execute().value
            async let events: [FamilyEvent] = supabase.from("events")
                .select("*, event_members(member_id)")
                .eq("family_id", value: fid)
                .gte("starts_at", value: eventsFrom)
                .lt("starts_at", value: eventsTo)
                .order("starts_at")
                .limit(1000)
                .execute().value
            async let tasks: [FamilyTask] = supabase.from("tasks").select().eq("family_id", value: fid)
                .eq("archived", value: false).order("created_at").execute().value
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

    func refreshMedia() async {
        guard let family else { return }
        do {
            media = try await supabase.from("media_items").select().eq("family_id", value: family.id.uuidString)
                .order("created_at", ascending: false).limit(300).execute().value
        } catch {
            report(error)
        }
    }

    private func report(_ error: Error) {
        // Closing a screen or ending pull-to-refresh cancels requests; that's no error.
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return }
        errorMessage = Self.message(for: error)
        print("homeOS error:", error)
    }

    /// The RPCs raise short lowercase sentences meant for people ("invite code expired").
    private static func message(for error: Error) -> String {
        if let error = error as? PostgrestError { return error.message.sentenceCased }
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
        setPendingInvite(nil)
        try? await supabase.auth.signOut()
    }

    /// `homeos://invite/<CODE>` prefills the invite; `homeos://auth-callback`
    /// finishes an email confirmation or an admin's email invite.
    func handleOpenURL(_ url: URL) {
        if let code = InviteCode.from(url: url) {
            setPendingInvite(code)
            return
        }
        guard url.scheme?.lowercased() == "homeos", url.host?.lowercased() == "auth-callback" else { return }
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
        // Any app or web page can open a homeos:// link, so tokens in one must
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
        do {
            profiles = try await supabase.from("profiles").select("id, display_name, avatar_path, updated_at").execute().value
        } catch {
            report(error)
        }
    }

    /// Renames you; `renameMember` also renames your member row (the name on the wall).
    func updateDisplayName(_ name: String, renameMember: Bool) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uid = supabase.auth.currentUser?.id, !name.isEmpty else { return false }
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
        guard let uid = supabase.auth.currentUser?.id else { return false }
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
        guard let uid = supabase.auth.currentUser?.id, let path = myProfile?.avatarPath else { return }
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

    /// A member's photo comes from their account's profile, if they have one.
    func avatarPath(for member: Member?) -> (path: String, version: String)? {
        photo(of: profile(for: member?.userId))
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

    /// Parents only. The member's chores, completions and points go with them;
    /// the server refuses to remove the last parent with an account.
    func removeMember(_ member: Member) async -> Bool {
        members.removeAll { $0.id == member.id }
        return await perform {
            try await supabase.from("members").delete().eq("id", value: member.id.uuidString).execute()
        }
    }

    /// Unlinks your account. Your member row, points and history stay on the screen.
    func leaveFamily() async -> Bool {
        guard let family else { return false }
        struct Params: Encodable { let family: UUID }
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
        do {
            try await supabase.rpc("revoke_family_invite", params: Params(invite: invite.id)).execute()
        } catch {
            report(error)
        }
        await loadInvites()
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
        let folder = family.id.uuidString.lowercased()
        let path = "\(folder)/\(id.uuidString.lowercased()).\(ext)"
        let contentType = isVideo
            ? "video/\(ext == "mov" ? "quicktime" : ext)"
            : "image/\(ext == "jpg" ? "jpeg" : ext)"
        let thumb = metadata.thumbnail
        let thumbPath = thumb == nil ? nil : "\(folder)/\(id.uuidString.lowercased())-thumb.jpg"
        // byte_size is the file plus its poster, which is what the quota counts.
        let row = NewMediaItem(id: id, familyId: family.id, storagePath: path, kind: isVideo ? "video" : "photo",
                               width: metadata.width, height: metadata.height,
                               durationSeconds: metadata.durationSeconds, takenAt: metadata.takenAt, uploadedBy: me?.id,
                               byteSize: data.count + (thumb?.count ?? 0), contentType: contentType, thumbnailPath: thumbPath)
        var uploaded: [String] = []
        do {
            _ = try await supabase.storage.from(Config.mediaBucket)
                .upload(path, data: data, options: FileOptions(contentType: contentType))
            uploaded.append(path)
            if let thumb, let thumbPath {
                _ = try await supabase.storage.from(Config.mediaBucket)
                    .upload(thumbPath, data: thumb, options: FileOptions(contentType: "image/jpeg"))
                uploaded.append(thumbPath)
            }
            try await supabase.from("media_items").insert(row).execute()
            return true
        } catch {
            if !uploaded.isEmpty {
                _ = try? await supabase.storage.from(Config.mediaBucket).remove(paths: uploaded)
            }
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
            var paths = [item.storagePath]
            if let thumb = item.thumbnailPath, thumb != item.storagePath { paths.append(thumb) }
            _ = try await supabase.storage.from(Config.mediaBucket).remove(paths: paths)
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

    var currentThread: AssistantThread? { threads.first { $0.id == currentThreadId } }

    /// Your own conversations in this family (RLS hides everyone else's).
    func loadThreads() async {
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
        do {
            try await supabase.from("assistant_threads").delete().eq("id", value: thread.id.uuidString).execute()
        } catch {
            report(error)
            await loadThreads()
        }
    }

    /// Sends a message in the open thread and streams the reply into `chat`.
    func ask(_ text: String) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isReplying else { return }
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
                print("homeOS assistant error:", error)
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
    /// replaced by the server's state. Returns whether the write succeeded.
    @discardableResult
    private func perform(_ work: () async throws -> Void) async -> Bool {
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
