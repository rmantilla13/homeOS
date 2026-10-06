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

    enum CodingKeys: String, CodingKey {
        case role, color
        case familyId = "family_id"
        case displayName = "display_name"
    }
}

struct FamilyEvent: Codable, Identifiable, Hashable {
    let id: UUID
    var familyId: UUID
    var title: String
    var location: String?
    var startsAt: Date
    var endsAt: Date
    var allDay: Bool
    var members: [EventMemberRef]?

    enum CodingKeys: String, CodingKey {
        case id, title, location
        case familyId = "family_id"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case allDay = "all_day"
        case members = "event_members"
    }
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

struct FamilyTask: Codable, Identifiable, Hashable {
    let id: UUID
    var familyId: UUID
    var title: String
    var icon: String?
    var assigneeId: UUID?
    var points: Int
    var rrule: String?
    var requiresApproval: Bool

    enum CodingKeys: String, CodingKey {
        case id, title, icon, points, rrule
        case familyId = "family_id"
        case assigneeId = "assignee_id"
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
    var status: String

    enum CodingKeys: String, CodingKey {
        case id, status
        case taskId = "task_id"
        case memberId = "member_id"
        case forDate = "for_date"
    }
}

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

struct MemberPoints: Codable, Hashable {
    var memberId: UUID
    var balance: Int

    enum CodingKeys: String, CodingKey {
        case balance
        case memberId = "member_id"
    }
}

struct MediaItem: Codable, Identifiable, Hashable {
    let id: UUID
    var familyId: UUID
    var storagePath: String
    var kind: String
    var caption: String?
    var takenAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, kind, caption
        case familyId = "family_id"
        case storagePath = "storage_path"
        case takenAt = "taken_at"
    }
}
