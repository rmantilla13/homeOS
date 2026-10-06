import "server-only";
import { DataError } from "@/lib/errors";
import { buildDemoState, demoMediaUrl, USAGE_DAYS, type DemoFamily, type DemoState } from "@/lib/demo/fixtures";
import type {
  AuditEntry,
  FamilyDetail,
  FamilyLimitsPatch,
  FamilyRow,
  FamilyStatus,
  MediaItem,
  MediaKind,
  NewInvite,
  Overview,
  PlatformInvite,
  Settings,
  SignedMedia,
  UsageDay,
  UserRow,
} from "@/lib/types";

// The in-memory backend behind demo mode. It mirrors the admin_* RPCs and the
// admin edge function closely enough to click through every flow; changes
// live in this server process only and reset on restart.

const globalForDemo = globalThis as typeof globalThis & { __homeosAdminDemo?: DemoState };

function state(): DemoState {
  globalForDemo.__homeosAdminDemo ??= buildDemoState();
  return globalForDemo.__homeosAdminDemo;
}

const DAY = 86_400_000;
const sinceDays = (iso: string | null | undefined, days: number) => !!iso && Date.now() - Date.parse(iso) < days * DAY;
const matches = (q: string | null, ...fields: (string | null | undefined)[]) =>
  !q || fields.some((f) => f?.toLowerCase().includes(q));
const norm = (search?: string | null) => search?.trim().toLowerCase() || null;

function lastDays(usage: UsageDay[], days: number): UsageDay[] {
  return usage.slice(-Math.min(days, usage.length));
}

function audit(action: string, targetType: string | null, targetId: string | null, details: Record<string, unknown>) {
  const s = state();
  s.audit.unshift({
    id: s.nextAuditId++,
    created_at: new Date().toISOString(),
    admin_email: s.admin.email,
    action,
    target_type: targetType,
    target_id: targetId,
    details,
  });
}

function findFamily(id: string): DemoFamily {
  const family = state().families.find((f) => f.id === id);
  if (!family) throw new DataError("family not found");
  return family;
}

const storageBytes = (f: DemoFamily) => f.media.reduce((n, m) => n + m.byte_size, 0);
const storageLimit = (f: DemoFamily) => f.storage_limit_bytes ?? state().settings.storage_limit_bytes;
const itemLimit = (f: DemoFamily) => f.media_item_limit ?? state().settings.media_item_limit;
const overQuota = (f: DemoFamily) => storageBytes(f) > storageLimit(f) || f.media.length > itemLimit(f);

function toMediaItem(m: DemoFamily["media"][number]): MediaItem {
  return {
    id: m.id,
    kind: m.kind,
    storage_path: m.storage_path,
    thumbnail_path: m.thumbnail_path,
    content_type: m.content_type,
    byte_size: m.byte_size,
    width: m.width,
    height: m.height,
    duration_seconds: m.duration_seconds,
    caption: m.caption,
    taken_at: m.taken_at,
    created_at: m.created_at,
    show_on_frame: m.show_on_frame,
    uploaded_by_name: m.uploaded_by_name,
  };
}

function inviteStatus(i: PlatformInvite): PlatformInvite["status"] {
  if (i.revoked_at) return "revoked";
  if (i.use_count >= i.max_uses) return "used";
  if (Date.parse(i.expires_at) <= Date.now()) return "expired";
  return "active";
}

// ───────────────────────────── Reads ─────────────────────────────

export function demoAdmin() {
  return state().admin;
}

export function demoOverview(): Overview {
  const s = state();
  const requests7 = s.families.reduce((n, f) => n + lastDays(f.usage, 7).reduce((m, d) => m + d.requests, 0), 0);
  const tokens7 = s.families.reduce(
    (n, f) => n + lastDays(f.usage, 7).reduce((m, d) => m + d.input_tokens + d.output_tokens, 0),
    0,
  );
  return {
    families: s.families.length,
    families_active_7d: s.families.filter((f) => sinceDays(f.last_activity, 7)).length,
    suspended_families: s.families.filter((f) => f.status === "suspended").length,
    users: s.users.length,
    devices: s.families.reduce((n, f) => n + f.devices.length, 0),
    devices_seen_24h: s.families.reduce(
      (n, f) => n + f.devices.filter((d) => sinceDays(d.last_seen_at, 1)).length,
      0,
    ),
    members: s.families.reduce((n, f) => n + f.members.length, 0),
    open_platform_invites: s.invites.filter((i) => inviteStatus(i) === "active").length,
    assistant_requests_7d: requests7,
    assistant_tokens_7d: tokens7,
    assistant_enabled: s.settings.assistant_enabled,
    media_items: s.families.reduce((n, f) => n + f.media.length, 0),
    storage_bytes: s.families.reduce((n, f) => n + storageBytes(f), 0),
    families_over_quota: s.families.filter(overQuota).length,
  };
}

export function demoUsageByDay(days: number): UsageDay[] {
  const n = Math.max(1, Math.min(days, USAGE_DAYS));
  const families = state().families;
  const template = families[0]?.usage ?? [];
  return lastDays(template, n).map((d, i, slice) => {
    const index = template.length - slice.length + i;
    const rows = families.map((f) => f.usage[index]);
    return {
      day: d.day,
      requests: rows.reduce((m, r) => m + r.requests, 0),
      input_tokens: rows.reduce((m, r) => m + r.input_tokens, 0),
      output_tokens: rows.reduce((m, r) => m + r.output_tokens, 0),
      families: rows.filter((r) => r.requests > 0).length,
    };
  });
}

export function demoListFamilies(search: string | null, lim: number, off: number): FamilyRow[] {
  const q = norm(search);
  return state()
    .families.filter((f) => matches(q, f.name) || f.id === q)
    .sort((a, b) => b.created_at.localeCompare(a.created_at))
    .slice(off, off + lim)
    .map((f) => ({
      id: f.id,
      name: f.name,
      status: f.status,
      created_at: f.created_at,
      member_count: f.members.length,
      parent_count: f.members.filter((m) => m.role === "parent").length,
      device_count: f.devices.length,
      assistant_requests_30d: lastDays(f.usage, 30).reduce((n, d) => n + d.requests, 0),
      last_activity: f.last_activity ?? null,
      media_count: f.media.length,
      storage_bytes: storageBytes(f),
      storage_limit_bytes: storageLimit(f),
      media_item_limit: itemLimit(f),
    }));
}

export function demoFamilyDetail(id: string): FamilyDetail | null {
  const s = state();
  const f = s.families.find((x) => x.id === id);
  if (!f) return null;
  const { members, devices, invites, usage, media, ...family } = f;
  return {
    family: {
      ...family,
      assistant_daily_limit_effective: f.assistant_daily_limit ?? s.settings.assistant_daily_limit,
      storage_bytes: storageBytes(f),
      storage_limit_effective: storageLimit(f),
      media_count: media.length,
      media_item_limit_effective: itemLimit(f),
    },
    members,
    devices,
    invites: invites.map((i) =>
      i.status === "active" && Date.parse(i.expires_at) <= Date.now() ? { ...i, status: "expired" } : i,
    ),
    usage_by_day: lastDays(usage, 30),
  };
}

export function demoListUsers(search: string | null, lim: number, off: number): UserRow[] {
  const s = state();
  const q = norm(search);
  const people: UserRow[] = s.users.map((u) => ({
    id: u.id,
    email: u.email,
    display_name: u.display_name,
    created_at: u.created_at,
    last_sign_in_at: u.last_sign_in_at,
    banned: u.banned,
    is_admin: u.is_admin,
    is_device: false,
    families: s.families
      .flatMap((f) => f.members.filter((m) => m.user_id === u.id).map((m) => ({ id: f.id, name: f.name, role: m.role })))
      .sort((a, b) => a.name.localeCompare(b.name)),
  }));
  const devices: UserRow[] = s.families.flatMap((f) =>
    f.devices.map((d) => ({
      id: d.user_id,
      email: `device-${d.user_id}@devices.homeos.invalid`,
      display_name: d.name,
      created_at: d.created_at,
      last_sign_in_at: d.last_seen_at,
      banned: s.bannedDevices.includes(d.user_id),
      is_admin: false,
      is_device: true,
      families: [{ id: f.id, name: f.name, role: "device" }],
    })),
  );
  return [...people, ...devices]
    .filter((u) => matches(q, u.email, u.display_name) || u.id === q)
    .sort((a, b) => b.created_at.localeCompare(a.created_at))
    .slice(off, off + lim);
}

export function demoListInvites(includeInactive: boolean): PlatformInvite[] {
  return state()
    .invites.map((i) => ({ ...i, status: inviteStatus(i) }))
    .filter((i) => includeInactive || i.status === "active")
    .sort((a, b) => b.created_at.localeCompare(a.created_at));
}

export function demoSettings(): Settings {
  return { ...state().settings };
}

export function demoListMedia(familyId: string, kind: MediaKind | null, lim: number, off: number): MediaItem[] {
  const f = findFamily(familyId);
  return f.media
    .filter((m) => !kind || m.kind === kind)
    .sort((a, b) => b.taken_at.localeCompare(a.taken_at) || b.created_at.localeCompare(a.created_at) || a.id.localeCompare(b.id))
    .slice(off, off + lim)
    .map(toMediaItem);
}

export function demoSignMedia(familyId: string, ids: string[]): SignedMedia[] {
  const want = new Set(ids);
  return findFamily(familyId).media
    .filter((m) => want.has(m.id) && (m.thumbnail_path != null || m.kind === "photo"))
    .map((m) => ({ id: m.id, url: demoMediaUrl(m) }));
}

export function demoListAudit(lim: number, off: number): AuditEntry[] {
  return state().audit.slice(off, off + lim);
}

// ─────────────────────────── Mutations ───────────────────────────

export function demoSetFamilyStatus(id: string, status: FamilyStatus, reason: string | null) {
  const f = findFamily(id);
  f.status = status;
  f.suspended_at = status === "suspended" ? (f.suspended_at ?? new Date().toISOString()) : null;
  f.suspended_reason = status === "suspended" ? reason : null;
  audit("set_family_status", "family", id, { status, reason });
}

export function demoDeleteFamily(id: string) {
  const s = state();
  const f = findFamily(id);
  s.families = s.families.filter((x) => x.id !== id);
  audit("delete_family", "family", id, { name: f.name, device_accounts_removed: f.devices.length });
}

export function demoCreateInvite(email: string | null, note: string | null, maxUses: number, expiresInDays: number): NewInvite {
  const alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
  const bytes = crypto.getRandomValues(new Uint8Array(8));
  const raw = Array.from(bytes, (b) => alphabet[b % 32]).join("");
  const invite: PlatformInvite = {
    id: crypto.randomUUID(),
    code: `${raw.slice(0, 4)}-${raw.slice(4)}`,
    email,
    note,
    max_uses: maxUses,
    use_count: 0,
    expires_at: new Date(Date.now() + expiresInDays * DAY).toISOString(),
    created_at: new Date().toISOString(),
    revoked_at: null,
    created_by_email: state().admin.email,
    status: "active",
  };
  state().invites.unshift(invite);
  audit("create_platform_invite", "platform_invite", invite.id, {
    code: invite.code, email, note, max_uses: maxUses, expires_at: invite.expires_at,
  });
  return { id: invite.id, code: invite.code, expires_at: invite.expires_at };
}

export function demoEmailInvite(email: string, note: string | null): NewInvite {
  const invite = demoCreateInvite(email, note, 1, 30);
  audit("invite_email", "platform_invite", invite.id, { email, email_sent: true, demo: true });
  return invite;
}

export function demoRevokeInvite(id: string) {
  const invite = state().invites.find((i) => i.id === id);
  if (!invite) throw new DataError("invite not found");
  invite.revoked_at ??= new Date().toISOString();
  audit("revoke_platform_invite", "platform_invite", id, { code: invite.code });
}

export function demoDeleteMedia(id: string) {
  const s = state();
  for (const f of s.families) {
    const item = f.media.find((m) => m.id === id);
    if (!item) continue;
    f.media = f.media.filter((m) => m.id !== id);
    audit("delete_media", "media", id, {
      family_id: f.id, storage_path: item.storage_path, thumbnail_path: item.thumbnail_path,
      byte_size: item.byte_size, kind: item.kind,
    });
    audit("delete_media_files", "media", id, {
      family_id: f.id, bucket: "family-media", files_removed: item.thumbnail_path ? 2 : 1,
    });
    return;
  }
  throw new DataError("media not found");
}

export function demoRevokeDevice(id: string) {
  const s = state();
  for (const f of s.families) {
    const device = f.devices.find((d) => d.id === id);
    if (!device) continue;
    f.devices = f.devices.filter((d) => d.id !== id);
    audit("revoke_device", "device", id, {
      family_id: f.id, name: device.name, user_id: device.user_id, auth_user_removed: true,
    });
    audit("revoke_device_auth", "device", id, {
      family_id: f.id, name: device.name, user_id: device.user_id, auth_user_removed: true,
    });
    return;
  }
  throw new DataError("device not found");
}

export function demoSetFamilyLimits(id: string, patch: FamilyLimitsPatch) {
  const f = findFamily(id);
  const changes: Record<string, number | null> = {};
  if (patch.assistant_daily_limit !== undefined && patch.assistant_daily_limit !== f.assistant_daily_limit) {
    f.assistant_daily_limit = patch.assistant_daily_limit;
    changes.assistant_daily_limit = patch.assistant_daily_limit;
  }
  if (patch.storage_limit_bytes !== undefined && patch.storage_limit_bytes !== f.storage_limit_bytes) {
    f.storage_limit_bytes = patch.storage_limit_bytes;
    changes.storage_limit_bytes = patch.storage_limit_bytes;
  }
  if (patch.media_item_limit !== undefined && patch.media_item_limit !== f.media_item_limit) {
    f.media_item_limit = patch.media_item_limit;
    changes.media_item_limit = patch.media_item_limit;
  }
  if (Object.keys(changes).length > 0) audit("set_family_limits", "family", id, changes);
}

export function demoUpdateSettings(patch: Partial<Pick<Settings, "invite_only" | "assistant_enabled" | "assistant_daily_limit" | "storage_limit_bytes" | "media_max_bytes" | "media_item_limit">>): Settings {
  const s = state();
  s.settings = { ...s.settings, ...patch, updated_at: new Date().toISOString(), updated_by: s.admin.id };
  audit("update_settings", "settings", null, patch);
  return { ...s.settings };
}

export function demoSetAdmin(target: string, makeAdmin: boolean) {
  const s = state();
  const user = s.users.find((u) => u.id === target);
  if (!user) {
    if (s.families.some((f) => f.devices.some((d) => d.user_id === target))) {
      throw new DataError("a display account can't be an admin");
    }
    throw new DataError("user not found");
  }
  if (!makeAdmin && user.is_admin && s.users.filter((u) => u.is_admin).length === 1) {
    throw new DataError("can't remove the last admin");
  }
  user.is_admin = makeAdmin;
  audit("set_admin", "user", target, { make_admin: makeAdmin, email: user.email });
}

export function demoUserAction(action: "ban_user" | "unban_user" | "delete_user", userId: string) {
  const s = state();
  if (userId === s.admin.id && action !== "unban_user") {
    throw new DataError(action === "delete_user" ? "you can't delete your own account" : "you can't ban yourself");
  }
  const user = s.users.find((u) => u.id === userId);
  const deviceFamily = s.families.find((f) => f.devices.some((d) => d.user_id === userId));
  if (!user && !deviceFamily) throw new DataError("user not found");
  const email = user?.email ?? `device-${userId}@devices.homeos.invalid`;

  if (action === "delete_user") {
    if (user) {
      s.users = s.users.filter((u) => u.id !== userId);
      for (const f of s.families) for (const m of f.members) if (m.user_id === userId) m.user_id = null;
    }
    if (deviceFamily) deviceFamily.devices = deviceFamily.devices.filter((d) => d.user_id !== userId);
  } else if (user) {
    user.banned = action === "ban_user";
  } else {
    s.bannedDevices = s.bannedDevices.filter((id) => id !== userId);
    if (action === "ban_user") s.bannedDevices.push(userId);
  }
  audit(action, "user", userId, { email });
}
