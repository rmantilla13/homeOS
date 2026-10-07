import "server-only";
import { FunctionsHttpError, type SupabaseClient } from "@supabase/supabase-js";
import { redirect } from "next/navigation";
import { connection } from "next/server";
import { cache } from "react";
import * as demo from "@/lib/demo/store";
import { demoMode, supabaseConfig } from "@/lib/env";
import { DataError } from "@/lib/errors";
import { deleteFamilyBlobs } from "@/lib/media/cleanup";
import { APP_AUTH_CALLBACK_URL } from "@/lib/site";
import { createSupabaseServerClient } from "@/lib/supabase/server";
import type {
  Admin,
  AuditEntry,
  BootVideo,
  FamilyDetail,
  FamilyInvite,
  FamilyInviteStatus,
  FamilyRow,
  FamilyStatus,
  NewInvite,
  Overview,
  Page,
  PlatformInvite,
  Settings,
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
export const NOT_ADMIN = "That account isn't an Ohana platform admin.";

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

function record<T extends object>(value: unknown, fn: string): T {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new DataError(`${fn} didn't come back from the database. Apply the platform migrations (docs/ADMIN.md).`);
  }
  return value as T;
}

function list<T>(value: unknown, fn: string): T[] {
  if (value == null) return [];
  if (!Array.isArray(value)) {
    throw new DataError(`${fn} didn't come back as a list. Apply the platform migrations (docs/ADMIN.md).`);
  }
  return value as T[];
}
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
    // Only a missing project config is a sign-in problem. Other DataErrors
    // (a failed session read, for example) keep their sentence on the page.
    if (err instanceof DataError && err.message === NOT_CONFIGURED) redirect("/login?error=config");
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
  const o = src.demo ? demo.demoOverview() : record<Overview>(await rpc(src.db, "admin_overview"), "admin_overview");
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
  const rows = src.demo
    ? demo.demoUsageByDay(days)
    : list<UsageDay>(await rpc(src.db, "admin_usage_by_day", { days }), "admin_usage_by_day");
  return rows.map(toUsageDay);
}

export async function listFamilies(search: string | null, page: number): Promise<Page<FamilyRow>> {
  const src = await source();
  const { lim, off } = pageArgs(page);
  const rows = src.demo
    ? demo.demoListFamilies(search, lim, off)
    : list<FamilyRow>(await rpc(src.db, "admin_list_families", { search: search || null, lim, off }), "admin_list_families");
  return paged(
    rows.map((r) => ({
      ...r,
      member_count: num(r.member_count),
      parent_count: num(r.parent_count),
      device_count: num(r.device_count),
      assistant_requests_30d: num(r.assistant_requests_30d),
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
  const d = record<FamilyDetail>(data, "admin_family_detail");
  if (!d.family) {
    throw new DataError("admin_family_detail didn't include the family. Apply the platform migrations (docs/ADMIN.md).");
  }
  return {
    family: d.family,
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
    : list<UserRow>(await rpc(src.db, "admin_list_users", { search: search || null, lim, off }), "admin_list_users");
  return paged(rows.map((u) => ({ ...u, families: u.families ?? [] })), page);
}

export async function listPlatformInvites(includeInactive: boolean): Promise<PlatformInvite[]> {
  const src = await source();
  const rows = src.demo
    ? demo.demoListInvites(includeInactive)
    : list<PlatformInvite>(
        await rpc(src.db, "admin_list_platform_invites", { include_inactive: includeInactive }),
        "admin_list_platform_invites",
      );
  return rows.map((i) => ({ ...i, max_uses: num(i.max_uses), use_count: num(i.use_count) }));
}

export async function getSettings(): Promise<Settings> {
  const src = await source();
  const s = src.demo ? demo.demoSettings() : record<Settings>(await rpc(src.db, "admin_get_settings"), "admin_get_settings");
  return {
    invite_only: s.invite_only,
    assistant_enabled: s.assistant_enabled,
    assistant_daily_limit: num(s.assistant_daily_limit),
    updated_at: s.updated_at ?? null,
    updated_by: s.updated_by ?? null,
  };
}

export async function listAudit(page: number, pageSize = PAGE_SIZE): Promise<Page<AuditEntry>> {
  const src = await source();
  const lim = pageSize + 1;
  const off = Math.max(page - 1, 0) * pageSize;
  const rows = src.demo
    ? demo.demoListAudit(lim, off)
    : list<AuditEntry>(await rpc(src.db, "admin_list_audit", { lim, off }), "admin_list_audit");
  const entries = rows.map((e) => ({ ...e, id: num(e.id), details: e.details ?? {} }));
  return { rows: entries.slice(0, pageSize), page, hasMore: entries.length > pageSize };
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
// this admin and then removes anything still in the family's Storage folder.
// Photos and videos live in Blob, which this app removes afterwards. SQL
// alone would leave the files.
export async function deleteFamily(id: string): Promise<void> {
  const src = await source();
  if (src.demo) return demo.demoDeleteFamily(id);
  await adminFunction(src.db, { action: "delete_family", family_id: id });
  await deleteFamilyBlobs(id);
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
// The email's link opens the iOS app, which signs the person in.
export async function emailPlatformInvite(email: string, note: string | null): Promise<{ code: string }> {
  const src = await source();
  if (src.demo) return { code: demo.demoEmailInvite(email, note).code };
  const result = await adminFunction<{ code: string }>(src.db, {
    action: "invite_email", email, note, redirect_to: APP_AUTH_CALLBACK_URL,
  });
  return { code: result.code };
}

export async function revokePlatformInvite(id: string): Promise<void> {
  const src = await source();
  if (src.demo) return demo.demoRevokeInvite(id);
  await rpc(src.db, "admin_revoke_platform_invite", { invite: id });
}

export async function getBootVideo(): Promise<BootVideo | null> {
  const src = await source();
  if (src.demo) return demo.demoBootVideo();
  const result = await adminFunction<{ video: BootVideo | null }>(src.db, { action: "get_boot_video" });
  const video = result?.video;
  if (!video) return null;
  return {
    byte_size: num(video.byte_size),
    duration_ms: num(video.duration_ms),
    updated_at: video.updated_at,
    preview_url: typeof video.preview_url === "string" ? video.preview_url : null,
  };
}

export async function updateSettings(
  patch: Partial<Pick<Settings, "invite_only" | "assistant_enabled" | "assistant_daily_limit">>,
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
  });
}

export async function createBootVideoUpload(): Promise<{ path: string; signedUrl: string; token: string }> {
  const src = await source();
  if (src.demo) throw new DataError("Demo mode doesn't upload to storage.");
  const result = await adminFunction<{ path?: string; signed_url?: string; token?: string }>(src.db, {
    action: "create_boot_video_upload",
  });
  if (!result?.path || !result.signed_url || !result.token) throw new DataError("The upload didn't start.");
  return { path: result.path, signedUrl: result.signed_url, token: result.token };
}

export async function commitBootVideo(path: string): Promise<void> {
  const src = await source();
  if (src.demo) throw new DataError("Demo mode doesn't upload to storage.");
  await adminFunction(src.db, { action: "commit_boot_video", path });
}

export async function setDemoBootVideo(byteSize: number, durationMs: number): Promise<void> {
  const src = await source();
  if (!src.demo) throw new DataError("That action is only for demo mode.");
  demo.demoSetBootVideo(byteSize, durationMs);
}

export async function removeBootVideo(): Promise<void> {
  const src = await source();
  if (src.demo) {
    demo.demoRemoveBootVideo();
    return;
  }
  await adminFunction(src.db, { action: "remove_boot_video" });
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
