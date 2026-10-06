// admin: account actions for the admin console that need Supabase Auth's
// admin API, and so the service role key, which never leaves the server.
//
//   { action: "invite_email", email, note?, redirect_to? } -> { ok: true, code, invite_id, expires_at }
//   { action: "ban_user" | "unban_user" | "delete_user", user_id } -> { ok: true }
//   { action: "delete_family", family_id } -> { ok: true, files_removed, files_error? }
//
// Errors are { error } with 400 (bad body), 401 (no session), 403 (not a
// platform admin), 404 (no such user or family), 413 (body too big), 503
// (Auth unreachable), or the status Auth answered with.
//
// SQL can't remove Storage files, so delete_family also empties
// family-media/<family_id>/ and delete_user empties avatars/<user_id>/.
// The caller is checked with their own JWT (is_platform_admin()); the work is
// done with the service role, and every action is written to admin_audit_log.

import { type AuthError, createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { authenticate, bearerToken, json, preflight, readJson } from "../_shared/http.ts";
import { removeFolder } from "./files.ts";
import { type AdminRequest, parseAdminRequest } from "./request.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const BAN_FOREVER = "876000h"; // 100 years
const MEDIA_BUCKET = "family-media"; // '<family_id>/<file>'
const AVATAR_BUCKET = "avatars"; // '<user_id>/<file>'

const service = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

// Auth's own 4xx answers are passed on; anything else is a bad gateway.
const authStatus = (error: AuthError) => (error.status && error.status >= 400 && error.status < 500 ? error.status : 502);

async function audit(adminId: string, action: string, targetType: string, targetId: string, details: Record<string, unknown>) {
  const { error } = await service.from("admin_audit_log")
    .insert({ admin_id: adminId, action, target_type: targetType, target_id: targetId, details });
  if (error) console.error(`audit insert failed for ${action}:`, error.message);
}

// Creates a platform invite for `email` and has Supabase Auth email it. The
// invite is created with the admin's own client, so its created_by and the
// RPC's audit row name the admin.
async function inviteEmail(
  db: SupabaseClient, adminId: string, r: Extract<AdminRequest, { action: "invite_email" }>,
): Promise<Response> {
  const { data, error } = await db.rpc("admin_create_platform_invite", { email: r.email, note: r.note });
  if (error) return json({ error: error.message }, error.code === "P0001" ? 400 : 500);
  const invite = (Array.isArray(data) ? data[0] : data) as { id: string; code: string; expires_at: string } | null;
  if (!invite) return json({ error: "the invite wasn't created" }, 500);

  // The code rides along in user_metadata so the sign-up hook lets them in
  // and the app can prefill it.
  const { error: mailErr } = await service.auth.admin.inviteUserByEmail(r.email, {
    data: { invite_code: invite.code },
    redirectTo: r.redirectTo ?? undefined,
  });
  await audit(adminId, "invite_email", "platform_invite", invite.id, {
    email: r.email,
    email_sent: !mailErr,
    ...(mailErr ? { error: mailErr.message } : {}),
  });
  if (mailErr) {
    return json({
      error: `The invite ${invite.code} was created, but the email couldn't be sent: ${mailErr.message}`,
      code: invite.code,
      invite_id: invite.id,
    }, authStatus(mailErr));
  }
  return json({ ok: true, code: invite.code, invite_id: invite.id, expires_at: invite.expires_at });
}

async function userAction(adminId: string, r: Extract<AdminRequest, { userId: string }>): Promise<Response> {
  if (r.userId === adminId && r.action !== "unban_user") {
    return json({ error: r.action === "delete_user" ? "you can't delete your own account" : "you can't ban yourself" }, 400);
  }
  const { data: target, error: lookupErr } = await service.auth.admin.getUserById(r.userId);
  if (lookupErr || !target.user) {
    if (lookupErr && lookupErr.status !== 404) return json({ error: lookupErr.message }, authStatus(lookupErr));
    return json({ error: "user not found" }, 404);
  }

  const { error } = r.action === "delete_user"
    ? await service.auth.admin.deleteUser(r.userId)
    : await service.auth.admin.updateUserById(r.userId, { ban_duration: r.action === "ban_user" ? BAN_FOREVER : "none" });
  // A deleted account's profile photo goes too.
  const files = r.action === "delete_user" && !error
    ? await removeFolder(service.storage.from(AVATAR_BUCKET), r.userId)
    : null;
  if (files?.error) console.error(`avatar cleanup for ${r.userId} failed:`, files.error);
  await audit(adminId, r.action, "user", r.userId, {
    email: target.user.email ?? null,
    ...(error ? { ok: false, error: error.message } : {}),
    ...(files ? { avatar_files_removed: files.removed, ...(files.error ? { files_error: files.error } : {}) } : {}),
  });
  if (error) return json({ error: error.message }, authStatus(error));
  return json({ ok: true });
}

// Deletes the family's rows with the admin's own JWT (admin_delete_family
// checks admin rights again and writes its own audit row), then its photos
// and videos, which only the Storage API can remove. A cleanup failure
// doesn't undo the deletion; it's logged and audited.
async function deleteFamily(db: SupabaseClient, adminId: string, familyId: string): Promise<Response> {
  const { error } = await db.rpc("admin_delete_family", { family: familyId });
  if (error) {
    if (/family not found/i.test(error.message)) return json({ error: "family not found" }, 404);
    return json({ error: error.message }, error.code === "P0001" ? 400 : 500);
  }
  const files = await removeFolder(service.storage.from(MEDIA_BUCKET), familyId);
  if (files.error) console.error(`family-media cleanup for ${familyId} failed:`, files.error);
  await audit(adminId, "delete_family_files", "family", familyId, {
    bucket: MEDIA_BUCKET,
    files_removed: files.removed,
    ...(files.error ? { error: files.error } : {}),
  });
  return json({ ok: true, files_removed: files.removed, ...(files.error ? { files_error: files.error } : {}) });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return preflight();
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const token = bearerToken(req);
  if (!token) return json({ error: "sign in required" }, 401);
  const read = await readJson(req);
  if ("error" in read) return read.error;

  const db = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const auth = await authenticate(db, token);
  if ("error" in auth) return auth.error;
  const { user } = auth;
  const { data: isAdmin, error: adminErr } = await db.rpc("is_platform_admin");
  if (adminErr) {
    console.error("is_platform_admin failed:", adminErr.message);
    return json({ error: "couldn't check admin rights" }, 500);
  }
  if (isAdmin !== true) return json({ error: "admin only" }, 403);

  const request = parseAdminRequest(read.body);
  if ("error" in request) return json({ error: request.error }, 400);

  try {
    if (request.action === "invite_email") return await inviteEmail(db, user.id, request);
    if (request.action === "delete_family") return await deleteFamily(db, user.id, request.familyId);
    return await userAction(user.id, request);
  } catch (err) {
    console.error(`admin ${request.action} failed:`, err);
    return json({ error: "something went wrong" }, 500);
  }
});
