import "server-only";
import { FunctionsHttpError, type SupabaseClient } from "@supabase/supabase-js";
import { redirect } from "next/navigation";
import { connection } from "next/server";
import { cache } from "react";
import * as demo from "@/lib/demo/store";
import { demoMode, supabaseConfig } from "@/lib/env";
import { DataError } from "@/lib/errors";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import type {
  Admin,
  AuditEntry,
  FamilyDetail,
  FamilyInvite,
  FamilyInviteStatus,
  FamilyLimitsPatch,
  FamilyRow,
  FamilyStatus,
  MediaItem,
  MediaKind,
  MediaLibraryItem,
  NewInvite,
  Overview,
  Page,
  PlatformInvite,
  Settings,
  SignedMedia,
  UsageDay,
  UserRow,
} from "@/lib/types";

// The console's only door to data. Every page and server action calls these
// functions; each one picks the source per request: the in-memory fixtures in
// demo mode (lib/demo), otherwise Supabase as the signed-in admin. The
// database enforces admin rights itself (every admin_* RPC checks
// is_platform_admin()), so nothing here relies on the proxy having run.

export { DataError };
export const PAGE_SIZE = 50;

type Source = { demo: true } | { demo: false; db: SupabaseClient };

const NOT_CONFIGURED =
  "Supabase isn't configured. Set NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY (see docs/ADMIN.md).";
export const NOT_ADMIN = "That account isn't a homeOS platform admin.";

// One source per request. connection() keeps every caller out of static
// prerendering, so the environment is always read at request time.
const source = cache(async (): Promise<Source> => {
  await connection();
  if (demoMode()) return { demo: true };
  const config = supabaseConfig();
  if (!config) throw new DataError(NOT_CONFIGURED);
  return { demo: false, db: await createSupabaseServerClient(config) };
});

export async function isDemo(): Promise<boolean> {
  await connection();
  return demoMode();
}

async function rpc<T>(db: SupabaseClient, fn: string, args?: Record<string, unknown>): Promise<T> {
  const { data, error } = await db.rpc(fn, args);
  if (error) {
    console.error(`rpc ${fn} failed:`, error.message);
    throw new DataError(error.message);
  }
  return data as T;
}

// Calls the `admin` edge function (spec §2.2) with the admin's own JWT; the
// function holds the service role key, this app never does.
async function adminFunction<T>(db: SupabaseClient, body: Record<string, unknown>): Promise<T> {
  const { data, error } = await db.functions.invoke("admin", { body });
  if (error) {
    let message = error.message;
    let code: string | undefined;
    if (error instanceof FunctionsHttpError) {
      try {
        const payload = (await error.context.json()) as { error?: string; code?: string };
        if (payload.error) message = payload.error;
        code = payload.code;
      } catch {
        // Not JSON; keep the generic message.
      }
    }
    console.error(`admin function ${String(body.action)} failed:`, message);
    throw new DataError(message, code);
  }
  return data as T;
}

const num = (v: unknown) => (typeof v === "number" ? v : Number(v ?? 0) || 0);
// PostgREST sends bigint as a string. Quotas stay well inside Number's range.
const big = (v: unknown): number => {
  if (typeof v === "bigint") return Number(v);
  if (typeof v === "string" && /^-?\d+$/.test(v)) return Number(v);
  return num(v);
};
const optionalBig = (v: unknown): number | undefined => (v == null || v === "" ? undefined : big(v));
const pageArgs = (page: number) => ({ lim: PAGE_SIZE + 1, off: Math.max(page - 1, 0) * PAGE_SIZE });
function paged<T>(rows: T[], page: number): Page<T> {
  return { rows: rows.slice(0, PAGE_SIZE), page, hasMore: rows.length > PAGE_SIZE };
}

// ───────────────────────────── Auth ─────────────────────────────

type AdminState = { status: "admin"; admin: Admin } | { status: "signed_out" } | { status: "not_admin" };

const adminState = cache(async (): Promise<AdminState> => {
  const src = await source();
  if (src.demo) return { status: "admin", admin: demo.demoAdmin() };
  const { data } = await src.db.auth.getClaims();
  const claims = data?.claims;
  if (!claims?.sub) return { status: "signed_out" };
  const { data: isAdmin, error } = await src.db.rpc("is_platform_admin");
  if (error || isAdmin !== true) return { status: "not_admin" };
  return { status: "admin", admin: { id: claims.sub, email: typeof claims.email === "string" ? claims.email : "" } };
});

// The signed-in platform admin, or a redirect to /login.
export async function requireAdmin(): Promise<Admin> {
  let state: AdminState;
  try {
    state = await adminState();
  } catch (err) {
    if (err instanceof DataError) redirect("/login?error=config");
    throw err;
  }
  if (state.status === "signed_out") redirect("/login");
  if (state.status === "not_admin") redirect("/login?error=not_admin");
  return state.admin;
}

// Signs in with email and password; only platform admins may stay signed in.
export async function signIn(email: string, password: string): Promise<{ error?: string }> {
  await connection();
  if (demoMode()) return {};
  const config = supabaseConfig();
  if (!config) return { error: NOT_CONFIGURED };
  const db = await createSupabaseServerClient(config);
  const { error } = await db.auth.signInWithPassword({ email, password });
  if (error) {
    return { error: error.code === "invalid_credentials" ? "Wrong email or password." : error.message };
  }
  const { data: isAdmin } = await db.rpc("is_platform_admin");
  if (isAdmin !== true) {
    await db.auth.signOut({ scope: "local" });
    return { error: NOT_ADMIN };
  }
  return {};
}

export async function signOut(): Promise<void> {
  const src = await source();
  if (!src.demo) await src.db.auth.signOut({ scope: "local" });
}

// ───────────────────────────── Reads ─────────────────────────────

export async function getOverview(): Promise<Overview> {
  const src = await source();
  const o = src.demo ? demo.demoOverview() : await rpc<Overview>(src.db, "admin_overview");
  return {
    families: num(o.families),
    families_active_7d: num(o.families_active_7d),
    suspended_families: num(o.suspended_families),
    users: num(o.users),
    devices: num(o.devices),
    members: num(o.members),
    open_platform_invites: num(o.open_platform_invites),
    assistant_requests_7d: num(o.assistant_requests_7d),
    assistant_tokens_7d: num(o.assistant_tokens_7d),
    devices_seen_24h: num(o.devices_seen_24h),
    assistant_enabled: o.assistant_enabled !== false,
    media_items: num(o.media_items),
    storage_bytes: big(o.storage_bytes),
    families_over_quota: num(o.families_over_quota),
  };
}

const toUsageDay = (d: UsageDay): UsageDay => ({
  day: String(d.day).slice(0, 10),
  requests: num(d.requests),
  input_tokens: num(d.input_tokens),
  output_tokens: num(d.output_tokens),
  ...(d.families === undefined ? {} : { families: num(d.families) }),
});

export async function getUsageByDay(days = 30): Promise<UsageDay[]> {
  const src = await source();
  const rows = src.demo ? demo.demoUsageByDay(days) : await rpc<UsageDay[]>(src.db, "admin_usage_by_day", { days });
  return (rows ?? []).map(toUsageDay);
}

export async function listFamilies(search: string | null, page: number): Promise<Page<FamilyRow>> {
  const src = await source();
  const { lim, off } = pageArgs(page);
  const rows = src.demo
    ? demo.demoListFamilies(search, lim, off)
    : await rpc<FamilyRow[]>(src.db, "admin_list_families", { search: search || null, lim, off });
  return paged(
    (rows ?? []).map((r) => ({
      ...r,
      member_count: num(r.member_count),
      parent_count: num(r.parent_count),
      device_count: num(r.device_count),
      assistant_requests_30d: num(r.assistant_requests_30d),
      media_count: num(r.media_count),
      storage_bytes: big(r.storage_bytes),
      storage_limit_bytes: big(r.storage_limit_bytes),
      media_item_limit: num(r.media_item_limit),
    })),
    page,
  );
}

function familyInviteStatus(i: Partial<FamilyInvite>): FamilyInviteStatus {
  if (i.status) return i.status;
  if (i.accepted_at) return "accepted";
  if (i.revoked_at) return "revoked";
  if (i.expires_at && Date.parse(i.expires_at) <= Date.now()) return "expired";
  return "active";
}

// Cached per request: the page and its generateMetadata both ask.
export const getFamilyDetail = cache(async (id: string): Promise<FamilyDetail | null> => {
  if (!/^[0-9a-f-]{36}$/i.test(id)) return null;
  const src = await source();
  if (src.demo) return demo.demoFamilyDetail(id);
  const { data, error } = await src.db.rpc("admin_family_detail", { family: id });
  if (error) {
    if (/family not found/i.test(error.message)) return null;
    console.error("rpc admin_family_detail failed:", error.message);
    throw new DataError(error.message);
  }
  const d = data as FamilyDetail;
  const f = d.family;
  return {
    family: {
      ...f,
      assistant_daily_limit: f.assistant_daily_limit == null ? null : num(f.assistant_daily_limit),
      assistant_daily_limit_effective: f.assistant_daily_limit_effective == null ? null : num(f.assistant_daily_limit_effective),
      storage_limit_bytes: f.storage_limit_bytes == null ? null : big(f.storage_limit_bytes),
      media_item_limit: f.media_item_limit == null ? null : num(f.media_item_limit),
      storage_bytes: optionalBig(f.storage_bytes),
      storage_limit_effective: optionalBig(f.storage_limit_effective),
      media_count: f.media_count == null ? undefined : num(f.media_count),
      media_item_limit_effective: f.media_item_limit_effective == null ? undefined : num(f.media_item_limit_effective),
    },
    members: d.members ?? [],
    devices: d.devices ?? [],
    invites: (d.invites ?? []).map((i) => ({ ...i, status: familyInviteStatus(i) })),
    usage_by_day: (d.usage_by_day ?? []).map(toUsageDay),
  };
});

export async function listUsers(search: string | null, page: number): Promise<Page<UserRow>> {
  const src = await source();
  const { lim, off } = pageArgs(page);
  const rows = src.demo
    ? demo.demoListUsers(search, lim, off)
    : await rpc<UserRow[]>(src.db, "admin_list_users", { search: search || null, lim, off });
  return paged((rows ?? []).map((u) => ({ ...u, families: u.families ?? [] })), page);
}

export async function listPlatformInvites(includeInactive: boolean): Promise<PlatformInvite[]> {
  const src = await source();
  const rows = src.demo
    ? demo.demoListInvites(includeInactive)
    : await rpc<PlatformInvite[]>(src.db, "admin_list_platform_invites", { include_inactive: includeInactive });
  return (rows ?? []).map((i) => ({ ...i, max_uses: num(i.max_uses), use_count: num(i.use_count) }));
}

export async function getSettings(): Promise<Settings> {
  const src = await source();
  const s = src.demo ? demo.demoSettings() : await rpc<Settings>(src.db, "admin_get_settings");
  return {
    invite_only: s.invite_only,
    assistant_enabled: s.assistant_enabled,
    assistant_daily_limit: num(s.assistant_daily_limit),
    // Defaults match the migration, so a form opened before those columns
    // exist doesn't write zeros over the real settings.
    storage_limit_bytes: s.storage_limit_bytes == null ? 5368709120 : big(s.storage_limit_bytes),
    media_max_bytes: s.media_max_bytes == null ? 536870912 : big(s.media_max_bytes),
    media_item_limit: s.media_item_limit == null ? 5000 : num(s.media_item_limit),
    updated_at: s.updated_at ?? null,
    updated_by: s.updated_by ?? null,
  };
}

const MEDIA_PAGE = 48;

function mapMedia<T extends MediaItem>(m: T): T {
  return {
    ...m,
    byte_size: m.byte_size == null ? null : big(m.byte_size),
    duration_seconds: m.duration_seconds == null ? null : num(m.duration_seconds),
    width: m.width == null ? null : num(m.width),
    height: m.height == null ? null : num(m.height),
  };
}

export async function listMedia(familyId: string, kind: MediaKind | null, page: number): Promise<Page<MediaItem>> {
  const src = await source();
  const lim = MEDIA_PAGE + 1;
  const off = Math.max(page - 1, 0) * MEDIA_PAGE;
  const rows = src.demo
    ? demo.demoListMedia(familyId, kind, lim, off)
    : await rpc<MediaItem[]>(src.db, "admin_list_media", { family: familyId, only_kind: kind, lim, off });
  const list = (rows ?? []).map(mapMedia);
  return { rows: list.slice(0, MEDIA_PAGE), page, hasMore: list.length > MEDIA_PAGE };
}

// Photos and videos from every family. The page stays under sign_media's
// 60-id cap so each family's posters can be signed in one call.
export async function listAllMedia(kind: MediaKind | null, page: number): Promise<Page<MediaLibraryItem>> {
  const src = await source();
  const lim = MEDIA_PAGE + 1;
  const off = Math.max(page - 1, 0) * MEDIA_PAGE;
  const rows = src.demo
    ? demo.demoListAllMedia(kind, lim, off)
    : await rpc<MediaLibraryItem[]>(src.db, "admin_list_all_media", { only_kind: kind, lim, off });
  const list = (rows ?? []).map((m) => ({
    ...mapMedia(m),
    family_id: m.family_id,
    family_name: m.family_name ?? "",
  }));
  return { rows: list.slice(0, MEDIA_PAGE), page, hasMore: list.length > MEDIA_PAGE };
}

// Short-lived thumbnail URLs from the admin function. An empty page doesn't
// call it. Videos with no poster come back without a url.
export async function signMedia(familyId: string, ids: string[]): Promise<SignedMedia[]> {
  if (ids.length === 0) return [];
  const src = await source();
  if (src.demo) return demo.demoSignMedia(familyId, ids);
  const result = await adminFunction<{ urls?: SignedMedia[] }>(src.db, {
    action: "sign_media",
    family_id: familyId,
    media_ids: ids.slice(0, 60),
  });
  return result.urls ?? [];
}

export async function listAudit(page: number, pageSize = PAGE_SIZE): Promise<Page<AuditEntry>> {
  const src = await source();
  const lim = pageSize + 1;
  const off = Math.max(page - 1, 0) * pageSize;
  const rows = src.demo
    ? demo.demoListAudit(lim, off)
    : await rpc<AuditEntry[]>(src.db, "admin_list_audit", { lim, off });
  const list = (rows ?? []).map((e) => ({ ...e, id: num(e.id), details: e.details ?? {} }));
  return { rows: list.slice(0, pageSize), page, hasMore: list.length > pageSize };
}

// ─────────────────────────── Mutations ───────────────────────────
// Server actions call these after requireAdmin(); the RPCs and the admin
// function check admin rights again and write the audit log.

export async function setFamilyStatus(id: string, status: FamilyStatus, reason: string | null): Promise<void> {
  const src = await source();
  if (src.demo) return demo.demoSetFamilyStatus(id, status, reason);
  await rpc(src.db, "admin_set_family_status", { family: id, status, reason });
}

// Through the admin function (spec §2.2), which calls admin_delete_family as
// this admin and then removes the family's photos and videos from Storage;
// SQL alone would leave the files behind.
export async function deleteFamily(id: string): Promise<void> {
  const src = await source();
  if (src.demo) return demo.demoDeleteFamily(id);
  await adminFunction(src.db, { action: "delete_family", family_id: id });
}

export async function createPlatformInvite(input: {
  email: string | null;
  note: string | null;
  maxUses: number;
  expiresInDays: number;
}): Promise<NewInvite> {
  const src = await source();
  if (src.demo) return demo.demoCreateInvite(input.email, input.note, input.maxUses, input.expiresInDays);
  const rows = await rpc<NewInvite[] | NewInvite>(src.db, "admin_create_platform_invite", {
    email: input.email,
    note: input.note,
    max_uses: input.maxUses,
    expires_in_days: input.expiresInDays,
  });
  const invite = Array.isArray(rows) ? rows[0] : rows;
  if (!invite) throw new DataError("The invite wasn't created.");
  return invite;
}

// Creates a platform invite and has Supabase Auth email it (admin → invite_email).
export async function emailPlatformInvite(email: string, note: string | null): Promise<{ code: string }> {
  const src = await source();
  if (src.demo) return { code: demo.demoEmailInvite(email, note).code };
  const result = await adminFunction<{ code: string }>(src.db, { action: "invite_email", email, note });
  return { code: result.code };
}

export async function revokePlatformInvite(id: string): Promise<void> {
  const src = await source();
  if (src.demo) return demo.demoRevokeInvite(id);
  await rpc(src.db, "admin_revoke_platform_invite", { invite: id });
}

export async function deleteMedia(id: string): Promise<void> {
  const src = await source();
  if (src.demo) return demo.demoDeleteMedia(id);
  await adminFunction(src.db, { action: "delete_media", media_id: id });
}

export async function revokeDevice(id: string): Promise<void> {
  const src = await source();
  if (src.demo) return demo.demoRevokeDevice(id);
  await adminFunction(src.db, { action: "revoke_device", device_id: id });
}

export async function setFamilyLimits(id: string, patch: FamilyLimitsPatch): Promise<void> {
  const src = await source();
  if (src.demo) return demo.demoSetFamilyLimits(id, patch);
  const numberOrNull = (v: number | null | undefined) => (typeof v === "number" ? v : null);
  await rpc(src.db, "admin_set_family_limits", {
    family: id,
    assistant_daily_limit: numberOrNull(patch.assistant_daily_limit),
    storage_limit_bytes: numberOrNull(patch.storage_limit_bytes),
    media_item_limit: numberOrNull(patch.media_item_limit),
    use_platform_assistant_limit: patch.assistant_daily_limit === null,
    use_platform_storage_limit: patch.storage_limit_bytes === null,
    use_platform_media_item_limit: patch.media_item_limit === null,
  });
}

export async function updateSettings(
  patch: Partial<Pick<Settings, "invite_only" | "assistant_enabled" | "assistant_daily_limit" | "storage_limit_bytes" | "media_max_bytes" | "media_item_limit">>,
): Promise<void> {
  const src = await source();
  if (src.demo) {
    demo.demoUpdateSettings(patch);
    return;
  }
  await rpc(src.db, "admin_update_settings", {
    invite_only: patch.invite_only ?? null,
    assistant_enabled: patch.assistant_enabled ?? null,
    assistant_daily_limit: patch.assistant_daily_limit ?? null,
    storage_limit_bytes: patch.storage_limit_bytes ?? null,
    media_max_bytes: patch.media_max_bytes ?? null,
    media_item_limit: patch.media_item_limit ?? null,
  });
}

export async function setAdmin(userId: string, makeAdmin: boolean): Promise<void> {
  const src = await source();
  if (src.demo) return demo.demoSetAdmin(userId, makeAdmin);
  await rpc(src.db, "admin_set_admin", { target: userId, make_admin: makeAdmin });
}

export type AccountAction = "ban_user" | "unban_user" | "delete_user";

export async function accountAction(action: AccountAction, userId: string): Promise<void> {
  const src = await source();
  if (src.demo) return demo.demoUserAction(action, userId);
  await adminFunction(src.db, { action, user_id: userId });
}
