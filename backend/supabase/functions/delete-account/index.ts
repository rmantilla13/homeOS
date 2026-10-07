// delete-account: deletes the caller's own account, for the iOS app's
// Profile → Delete account (App Store guideline 5.1.1(v)). The admin app's
// /api/account/delete calls it with the person's JWT, then removes the Blob
// photos and videos of any family that went with the account.
//
//   POST (any body) -> { ok: true, families_deleted: [family_id], files_error? }
//
// Errors are { error } with 401 (no session), 400 (refused: the last parent
// of a family with other accounts, a display, a platform admin), 500, 503
// (Auth unreachable), or 502 when the data is gone but the login isn't yet;
// asking again finishes it. A 502 still carries families_deleted.
//
// The rows go through delete_my_account() as the caller; files and the auth
// user through the service role. See account.ts for the order.

import { createClient } from "jsr:@supabase/supabase-js@2";
import { authenticate, bearerToken, json, preflight } from "../_shared/http.ts";
import { deleteAccount } from "./account.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const MEDIA_BUCKET = "family-media"; // '<family_id>/<file>'
const AVATAR_BUCKET = "avatars"; // '<user_id>/<file>' and member photos at '<family_id>/<file>'

const service = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return preflight();
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const token = bearerToken(req);
  if (!token) return json({ error: "sign in required" }, 401);
  const db = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const auth = await authenticate(db, token);
  if ("error" in auth) return auth.error;

  try {
    const outcome = await deleteAccount({
      deleteRows: () => db.rpc("delete_my_account"),
      avatars: service.storage.from(AVATAR_BUCKET),
      familyMedia: service.storage.from(MEDIA_BUCKET),
      deleteUser: (id) => service.auth.admin.deleteUser(id),
    }, auth.user.id);
    return json(outcome.body, outcome.status);
  } catch (err) {
    console.error("delete-account failed:", err);
    return json({ error: "something went wrong" }, 500);
  }
});
