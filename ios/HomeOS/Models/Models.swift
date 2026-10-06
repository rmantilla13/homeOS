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
        case durationSeconds = "duration_seconds"
        case takenAt = "taken_at"
        case showOnFrame = "show_on_frame"
        case createdAt = "created_at"
    }

    var isVideo: Bool { kind == "video" }
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

    enum CodingKeys: String, CodingKey {
        case id, kind, width, height
        case familyId = "family_id"
        case storagePath = "storage_path"
        case durationSeconds = "duration_seconds"
        case takenAt = "taken_at"
        case uploadedBy = "uploaded_by"
    }
}

/// Facts about a picked file, read on the phone before upload.
struct MediaMetadata {
    var width: Int?
    var height: Int?
    var durationSeconds: Double?
    var takenAt: Date?
}

// MARK: Assistant

/// One turn in the assistant chat. Kept on the phone only.
struct ChatMessage: Identifiable, Hashable {
    enum Role: String { case user, assistant }

    let id = UUID()
    var role: Role
    var text: String
    var actions: [AssistantAction] = []
    var isError = false
}

struct AssistantAction: Codable, Hashable {
    var type: String
    var summary: String
}

/// Response of the `assistant` edge function.
struct AssistantReply: Decodable {
    var reply: String
    var actions: [AssistantAction]?
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
