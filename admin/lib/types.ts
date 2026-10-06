// Shapes returned by the admin_* RPCs (docs/PLATFORM_SPEC.md §1.6). Fields the
// spec doesn't name are optional so the console tolerates older backends.

export type Admin = { id: string; email: string };

export type Overview = {
  families: number;
  families_active_7d: number;
  suspended_families: number;
  users: number;
  devices: number;
  devices_seen_24h: number;
  members: number;
  open_platform_invites: number;
  assistant_requests_7d: number;
  assistant_tokens_7d: number;
  assistant_enabled: boolean;
  media_items: number;
  storage_bytes: number;
  families_over_quota: number;
};

export type UsageDay = {
  day: string; // YYYY-MM-DD (UTC)
  requests: number;
  input_tokens: number;
  output_tokens: number;
  families?: number;
};

export type FamilyStatus = "active" | "suspended";
export type MemberRole = "parent" | "child" | "other";

export type FamilyRow = {
  id: string;
  name: string;
  status: FamilyStatus;
  created_at: string;
  member_count: number;
  parent_count: number;
  device_count: number;
  assistant_requests_30d: number;
  last_activity: string | null;
  media_count: number;
  storage_bytes: number;
  /** Effective quota: the family's override, or the platform default. */
  storage_limit_bytes: number;
  /** Effective item cap. */
  media_item_limit: number;
};

export type Family = {
  id: string;
  name: string;
  timezone: string;
  created_at: string;
  status: FamilyStatus;
  suspended_at: string | null;
  suspended_reason: string | null;
  assistant_daily_limit: number | null;
  assistant_daily_limit_effective?: number | null;
  /** Null means the platform default. */
  storage_limit_bytes: number | null;
  media_item_limit: number | null;
  storage_bytes?: number;
  storage_limit_effective?: number;
  media_count?: number;
  media_item_limit_effective?: number;
  last_activity?: string | null;
};

export type Member = {
  id: string;
  user_id: string | null;
  display_name: string;
  role: MemberRole;
  color: string;
  created_at: string;
  email?: string | null;
  profile_name?: string | null;
};

export type Device = {
  id: string;
  user_id: string;
  name: string;
  last_seen_at: string | null;
  created_at: string;
};

export type FamilyInviteStatus = "active" | "accepted" | "expired" | "revoked";

export type FamilyInvite = {
  id: string;
  code: string;
  role: MemberRole;
  member_id: string | null;
  email: string | null;
  created_at: string;
  expires_at: string;
  accepted_at: string | null;
  revoked_at: string | null;
  invited_by_email?: string | null;
  status: FamilyInviteStatus;
};

export type FamilyDetail = {
  family: Family;
  members: Member[];
  devices: Device[];
  invites: FamilyInvite[];
  usage_by_day: UsageDay[];
};

export type UserFamily = { id: string; name: string; role: string };

export type UserRow = {
  id: string;
  email: string | null;
  display_name: string | null;
  created_at: string;
  last_sign_in_at: string | null;
  banned: boolean;
  is_admin: boolean;
  is_device: boolean;
  families: UserFamily[];
};

export type PlatformInviteStatus = "active" | "used" | "expired" | "revoked";

export type PlatformInvite = {
  id: string;
  code: string; // display form, XXXX-XXXX
  email: string | null;
  note: string | null;
  max_uses: number;
  use_count: number;
  expires_at: string;
  created_at: string;
  revoked_at: string | null;
  created_by_email: string | null;
  status: PlatformInviteStatus;
};

export type Settings = {
  invite_only: boolean;
  assistant_enabled: boolean;
  assistant_daily_limit: number;
  storage_limit_bytes: number;
  media_max_bytes: number;
  media_item_limit: number;
  updated_at: string | null;
  updated_by: string | null;
};

export type MediaKind = "photo" | "video";

export type MediaItem = {
  id: string;
  kind: MediaKind;
  storage_path: string;
  thumbnail_path: string | null;
  content_type: string | null;
  byte_size: number | null;
  width: number | null;
  height: number | null;
  duration_seconds: number | null;
  caption: string | null;
  taken_at: string | null;
  created_at: string;
  show_on_frame: boolean;
  uploaded_by_name: string | null;
};

/** One row of the cross-family media list (`admin_list_all_media`). */
export type MediaLibraryItem = MediaItem & {
  family_id: string;
  family_name: string;
};

export type SignedMedia = { id: string; url: string };

/** What setFamilyLimits changes. Null clears the override; omit a key to leave it. */
export type FamilyLimitsPatch = {
  assistant_daily_limit?: number | null;
  storage_limit_bytes?: number | null;
  media_item_limit?: number | null;
};

export type AuditEntry = {
  id: number;
  created_at: string;
  admin_email: string | null;
  action: string;
  target_type: string | null;
  target_id: string | null;
  details: Record<string, unknown>;
};

export type Page<T> = { rows: T[]; page: number; hasMore: boolean };

export type NewInvite = { id: string; code: string; expires_at: string };
