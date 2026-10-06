import Foundation

// Mirrors backend/supabase/migrations. Date-only columns stay as "yyyy-MM-dd" strings.

struct Family: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var timezone: String
}

enum MemberRole: String, Codable, CaseIterable {
    case parent, child, other
}

struct Member: Codable, Identifiable, Hashable {
    let id: UUID
    var familyId: UUID
    var userId: UUID?
    var displayName: String
    var role: MemberRole
    var color: String
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id, role, color
        case familyId = "family_id"
        case userId = "user_id"
        case displayName = "display_name"
        case sortOrder = "sort_order"
    }
}

struct NewMember: Encodable {
    var familyId: UUID
    var displayName: String
    var role: MemberRole
    var color: String
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case role, color
        case familyId = "family_id"
        case displayName = "display_name"
        case sortOrder = "sort_order"
    }
}

struct Device: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var lastSeenAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name
        case lastSeenAt = "last_seen_at"
    }
}

// MARK: Calendar

struct FamilyEvent: Codable, Identifiable, Hashable {
    let id: UUID
    var familyId: UUID
    var title: String
    var location: String?
    var startsAt: Date
    var endsAt: Date
    var allDay: Bool
    var color: String?
    var rrule: String?
    var members: [EventMemberRef]?

    enum CodingKeys: String, CodingKey {
        case id, title, location, color, rrule
        case familyId = "family_id"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case allDay = "all_day"
        case members = "event_members"
    }

    var memberIds: [UUID] { (members ?? []).map(\.memberId) }
}

struct EventMemberRef: Codable, Hashable {
    var memberId: UUID
    enum CodingKeys: String, CodingKey { case memberId = "member_id" }
}

struct NewEvent: Encodable {
    var id = UUID()
    var familyId: UUID
    var title: String
    var location: String?
    var startsAt: Date
    var endsAt: Date
    var allDay: Bool
    var createdBy: UUID?

    enum CodingKeys: String, CodingKey {
        case id, title, location
        case familyId = "family_id"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case allDay = "all_day"
        case createdBy = "created_by"
    }
}

// MARK: Chores

struct FamilyTask: Codable, Identifiable, Hashable {
    let id: UUID
    var familyId: UUID
    var title: String
    var icon: String?
    var assigneeId: UUID?
    var points: Int
    var dueDate: String?
    var rrule: String?
    var requiresApproval: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, icon, points, rrule
        case familyId = "family_id"
        case assigneeId = "assignee_id"
        case dueDate = "due_date"
        case requiresApproval = "requires_approval"
    }
}

struct NewTask: Encodable {
    var familyId: UUID
    var title: String
    var icon: String?
    var assigneeId: UUID?
    var points: Int
    var rrule: String?
    var requiresApproval: Bool

    enum CodingKeys: String, CodingKey {
        case title, icon, points, rrule
        case familyId = "family_id"
        case assigneeId = "assignee_id"
        case requiresApproval = "requires_approval"
    }
}

struct TaskCompletion: Codable, Identifiable, Hashable {
    let id: UUID
    var taskId: UUID
    var memberId: UUID
    var forDate: String
    var status: String  // pending | approved | rejected

    enum CodingKeys: String, CodingKey {
        case id, status
        case taskId = "task_id"
        case memberId = "member_id"
        case forDate = "for_date"
    }
}

/// family_id and status are filled in by the prepare_completion trigger.
struct NewCompletion: Encodable {
    var id: UUID
    var taskId: UUID
    var memberId: UUID
    var forDate: String

    enum CodingKeys: String, CodingKey {
        case id
        case taskId = "task_id"
        case memberId = "member_id"
        case forDate = "for_date"
    }
}

// MARK: Rewards

struct Reward: Codable, Identifiable, Hashable {
    let id: UUID
    var familyId: UUID
    var title: String
    var icon: String?
    var cost: Int
    var active: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, icon, cost, active
        case familyId = "family_id"
    }
}

struct NewReward: Encodable {
    var familyId: UUID
    var title: String
    var icon: String?
    var cost: Int

    enum CodingKeys: String, CodingKey {
        case title, icon, cost
        case familyId = "family_id"
    }
}

struct RewardRedemption: Codable, Identifiable, Hashable {
    let id: UUID
    var rewardId: UUID
    var memberId: UUID
    var cost: Int
    var status: String  // requested | fulfilled | cancelled
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, cost, status
        case rewardId = "reward_id"
        case memberId = "member_id"
        case createdAt = "created_at"
    }
}

struct MemberPoints: Codable, Hashable {
    var memberId: UUID
    var balance: Int

    enum CodingKeys: String, CodingKey {
        case balance
        case memberId = "member_id"
    }
}

// MARK: Lists & meals

struct FamilyList: Codable, Identifiable, Hashable {
    let id: UUID
    var familyId: UUID
    var name: String
    var kind: String
    var sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id, name, kind
        case familyId = "family_id"
        case sortOrder = "sort_order"
    }
}

struct NewList: Encodable {
    var familyId: UUID
    var name: String
    var kind: String

    enum CodingKeys: String, CodingKey {
        case name, kind
        case familyId = "family_id"
    }
}

struct ListItem: Codable, Identifiable, Hashable {
    let id: UUID
    var listId: UUID
    var text: String
    var quantity: String?
    var done: Bool

    enum CodingKeys: String, CodingKey {
        case id, text, quantity, done
        case listId = "list_id"
    }
}

struct NewListItem: Encodable {
    var listId: UUID
    var text: String
    var addedBy: UUID?

    enum CodingKeys: String, CodingKey {
        case text
        case listId = "list_id"
        case addedBy = "added_by"
    }
}

enum MealSlot: String, Codable, CaseIterable, Identifiable {
    case breakfast, lunch, dinner, snack
    var id: String { rawValue }
}

struct MealPlan: Codable, Identifiable, Hashable {
    let id: UUID
    var familyId: UUID
    var date: String
    var meal: MealSlot
    var title: String
    var notes: String?

    enum CodingKeys: String, CodingKey {
        case id, date, meal, title, notes
        case familyId = "family_id"
    }
}

/// Upserted on (family_id, date, meal), like the assistant's set_meal tool.
struct MealUpsert: Encodable {
    var familyId: UUID
    var date: String
    var meal: MealSlot
    var title: String

    enum CodingKeys: String, CodingKey {
        case date, meal, title
        case familyId = "family_id"
    }
}

// MARK: Family memory

struct FamilyMemory: Codable, Identifiable, Hashable {
    let id: UUID
    var content: String
    var source: String
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, content, source
        case createdAt = "created_at"
    }
}

struct NewMemory: Encodable {
    var familyId: UUID
    var content: String
    var source = "manual"

    enum CodingKeys: String, CodingKey {
        case content, source
        case familyId = "family_id"
    }
}

// MARK: Media

struct MediaItem: Codable, Identifiable, Hashable {
    let id: UUID
    var familyId: UUID
    var storagePath: String
    var kind: String  // photo | video
    /// `supabase` (still in the family-media bucket) or `blob` (private Vercel Blob).
    var fileStore: String
    var width: Int?
    var height: Int?
    var durationSeconds: Double?
    var caption: String?
    var takenAt: Date?
    var showOnFrame: Bool
    var createdAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, kind, caption, width, height
        case familyId = "family_id"
        case storagePath = "storage_path"
        case fileStore = "file_store"
        case durationSeconds = "duration_seconds"
        case takenAt = "taken_at"
        case showOnFrame = "show_on_frame"
        case createdAt = "created_at"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        familyId = try c.decode(UUID.self, forKey: .familyId)
        storagePath = try c.decode(String.self, forKey: .storagePath)
        kind = try c.decode(String.self, forKey: .kind)
        fileStore = try c.decodeIfPresent(String.self, forKey: .fileStore) ?? "supabase"
        width = try c.decodeIfPresent(Int.self, forKey: .width)
        height = try c.decodeIfPresent(Int.self, forKey: .height)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        caption = try c.decodeIfPresent(String.self, forKey: .caption)
        takenAt = try c.decodeIfPresent(Date.self, forKey: .takenAt)
        showOnFrame = try c.decodeIfPresent(Bool.self, forKey: .showOnFrame) ?? true
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(familyId, forKey: .familyId)
        try c.encode(storagePath, forKey: .storagePath)
        try c.encode(kind, forKey: .kind)
        try c.encode(fileStore, forKey: .fileStore)
        try c.encodeIfPresent(width, forKey: .width)
        try c.encodeIfPresent(height, forKey: .height)
        try c.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try c.encodeIfPresent(caption, forKey: .caption)
        try c.encodeIfPresent(takenAt, forKey: .takenAt)
        try c.encode(showOnFrame, forKey: .showOnFrame)
        try c.encodeIfPresent(createdAt, forKey: .createdAt)
    }

    var isVideo: Bool { kind == "video" }
    var inBlob: Bool { fileStore == "blob" }
    /// When it happened, falling back to when it was uploaded.
    var date: Date { takenAt ?? createdAt ?? .distantPast }
}

struct NewMediaItem: Encodable {
    var id: UUID
    var familyId: UUID
    var storagePath: String
    var kind: String
    var width: Int?
    var height: Int?
    var durationSeconds: Double?
    var takenAt: Date?
    var uploadedBy: UUID?
    /// Omitted for photos so the column default (`supabase`) applies.
    var fileStore: String?

    enum CodingKeys: String, CodingKey {
        case id, kind, width, height
        case familyId = "family_id"
        case storagePath = "storage_path"
        case durationSeconds = "duration_seconds"
        case takenAt = "taken_at"
        case uploadedBy = "uploaded_by"
        case fileStore = "file_store"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(familyId, forKey: .familyId)
        try c.encode(storagePath, forKey: .storagePath)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(width, forKey: .width)
        try c.encodeIfPresent(height, forKey: .height)
        try c.encodeIfPresent(durationSeconds, forKey: .durationSeconds)
        try c.encodeIfPresent(takenAt, forKey: .takenAt)
        try c.encodeIfPresent(uploadedBy, forKey: .uploadedBy)
        try c.encodeIfPresent(fileStore, forKey: .fileStore)
    }
}

/// Facts about a picked file, read on the phone before upload.
struct MediaMetadata {
    var width: Int?
    var height: Int?
    var durationSeconds: Double?
    var takenAt: Date?
}

// MARK: Accounts & invites

/// A person's account details (`profiles`). Device accounts don't have one.
struct Profile: Codable, Identifiable, Hashable {
    let id: UUID
    var displayName: String
    var avatarPath: String?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case avatarPath = "avatar_path"
        case updatedAt = "updated_at"
    }
}

/// What `preview_invite` says about a code. Works before signing in.
struct InvitePreview: Decodable, Hashable {
    enum Kind: String, Decodable {
        case family    // join an existing family
        case platform  // start a new family
    }

    var valid: Bool
    var kind: Kind?
    var familyName: String?
    var role: MemberRole?
    var invitedBy: String?
    var expiresAt: Date?
    var reason: String?

    enum CodingKeys: String, CodingKey {
        case valid, kind, role, reason
        case familyName = "family_name"
        case invitedBy = "invited_by"
        case expiresAt = "expires_at"
    }

    /// "You're invited to The Smiths as a parent", or why the code can't be used.
    var headline: String {
        guard valid else { return (reason ?? "invite code not valid").sentenceCased }
        switch kind {
        case .family:
            let asRole = role.map { " as \($0.withArticle)" } ?? ""
            return "You're invited to \(familyName ?? "a family")\(asRole)"
        case .platform, nil:
            return "This code lets you start a new family"
        }
    }
}

/// A row of `family_invites` (parents only). `code` is stored without the dash.
struct FamilyInvite: Codable, Identifiable, Hashable {
    let id: UUID
    var code: String
    var role: MemberRole
    var memberId: UUID?
    var email: String?
    var createdAt: Date
    var expiresAt: Date
    var acceptedBy: UUID?
    var acceptedAt: Date?
    var revokedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, code, role, email
        case memberId = "member_id"
        case createdAt = "created_at"
        case expiresAt = "expires_at"
        case acceptedBy = "accepted_by"
        case acceptedAt = "accepted_at"
        case revokedAt = "revoked_at"
    }

    enum Status { case pending, accepted, expired, revoked }

    var status: Status {
        if acceptedAt != nil { return .accepted }
        if revokedAt != nil { return .revoked }
        if expiresAt <= .now { return .expired }
        return .pending
    }

    var displayCode: String { InviteCode.format(code) }
}

/// What `create_family_invite` returns; `code` is already in display form.
struct CreatedInvite: Decodable, Hashable, Identifiable {
    let id: UUID
    var code: String
    var expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case id, code
        case expiresAt = "expires_at"
    }
}

/// Invite codes: 8 characters shown as `XXXX-XXXX`, compared without case,
/// spaces or dashes (`normalize_invite_code` on the server).
enum InviteCode {
    /// "abcd-efgh " → "ABCDEFGH".
    static func normalize(_ raw: String) -> String {
        String(raw.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
    }

    /// "abcdefgh" → "ABCD-EFGH". Anything that isn't 8 characters is left normalized.
    static func format(_ raw: String) -> String {
        let code = normalize(raw)
        guard code.count == 8 else { return code }
        return "\(code.prefix(4))-\(code.suffix(4))"
    }

    /// The code in a `homeos://invite/<CODE>` link.
    static func from(url: URL) -> String? {
        guard url.scheme?.lowercased() == "homeos", url.host?.lowercased() == "invite" else { return nil }
        let code = normalize(url.pathComponents.first { $0 != "/" } ?? "")
        return code.isEmpty ? nil : format(code)
    }

    static func link(_ code: String) -> URL? {
        URL(string: "homeos://invite/\(format(code))")
    }

    /// What the share sheet sends with a family invite.
    static func shareText(code: String, familyName: String?, expiresAt: Date) -> String {
        let display = format(code)
        let family = familyName.map { "\($0) on homeOS" } ?? "our family on homeOS"
        let url = Self.link(display)?.absoluteString ?? "homeos://invite/\(display)"
        let expiry = expiresAt.formatted(date: .abbreviated, time: .omitted)
        return """
        Join \(family)! Open \(url) on your iPhone, or enter the invite code \(display) in the homeOS app. \
        The code works until \(expiry).
        """
    }
}

extension MemberRole {
    /// "a parent", "a child", "a family member".
    var withArticle: String {
        switch self {
        case .parent: return "a parent"
        case .child: return "a child"
        case .other: return "a family member"
        }
    }

    var title: String { self == .other ? "Other" : rawValue.capitalized }
}

extension String {
    /// "invite code expired" → "Invite code expired". The RPCs' messages are lowercase.
    var sentenceCased: String { self.prefix(1).uppercased() + String(self.dropFirst()) }

    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: Assistant

/// One turn in the assistant chat, shown as a bubble.
struct ChatMessage: Identifiable, Hashable {
    enum Role: String { case user, assistant }

    let id = UUID()
    var role: Role
    var text: String
    var actions: [AssistantAction] = []
    var isError = false
    /// The reply is still arriving over the stream.
    var isStreaming = false
}

struct AssistantAction: Codable, Hashable {
    var type: String
    var summary: String
}

/// The reply of the `assistant` function: the whole JSON body when not
/// streaming, or the `done` event's data.
struct AssistantReply: Decodable, Hashable {
    var reply: String
    var actions: [AssistantAction]?
    var threadId: UUID?
    var messageId: Int?

    enum CodingKeys: String, CodingKey {
        case reply, actions
        case threadId = "thread_id"
        case messageId = "message_id"
    }
}

/// A conversation in the assistant history (`assistant_threads`, your own only).
struct AssistantThread: Codable, Identifiable, Hashable {
    let id: UUID
    var title: String
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, title
        case updatedAt = "updated_at"
    }
}

/// A stored message (`assistant_messages`).
struct AssistantMessageRow: Decodable, Identifiable {
    let id: Int
    var role: String
    var content: String
    var actions: [AssistantAction]

    enum CodingKeys: String, CodingKey {
        case id, role, content, actions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        role = try c.decode(String.self, forKey: .role)
        content = try c.decode(String.self, forKey: .content)
        // Actions are jsonb; tolerate anything unexpected rather than losing the thread.
        actions = (try? c.decode([AssistantAction].self, forKey: .actions)) ?? []
    }

    var chatMessage: ChatMessage {
        ChatMessage(role: role == "user" ? .user : .assistant, text: content, actions: actions)
    }
}

// MARK: Dates

/// "yyyy-MM-dd" keys for date-only columns, in the phone's time zone.
enum DayKey {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func string(_ date: Date) -> String { formatter.string(from: date) }
    static func date(_ key: String) -> Date? { formatter.date(from: key) }
    static var today: String { string(.now) }
}
