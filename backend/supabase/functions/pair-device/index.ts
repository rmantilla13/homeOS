// pair-device: binds a wall display to a family.
//
//   1. start   (display, no auth)   { secretHash }            -> { code, expiresAt }
//   2. claim   (parent, user JWT)   { code, familyId, name }  -> { deviceId }
//   3. redeem  (display, no auth)   { code, secret }          -> { status: "pending" }
//                                                             |  { status: "paired", session, familyId, deviceId }
//
// The display keeps `secret` private and only ever sends its SHA-256 at start,
// so seeing the 6-digit code on screen is not enough to steal the session.

import { createClient } from "jsr:@supabase/supabase-js@2";
import { json, preflight, readJson } from "../_shared/http.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const admin = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

async function sha256Hex(text: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text));
  return Array.from(new Uint8Array(digest), (b) => b.toString(16).padStart(2, "0")).join("");
}

function randomCode(): string {
  const n = crypto.getRandomValues(new Uint32Array(1))[0] % 1_000_000;
  return n.toString().padStart(6, "0");
}

function randomPassword(): string {
  return Array.from(crypto.getRandomValues(new Uint8Array(32)), (b) => b.toString(16).padStart(2, "0")).join("");
}

async function start(body: { secretHash?: string }) {
  if (!body.secretHash || !/^[0-9a-f]{64}$/.test(body.secretHash)) {
    return json({ error: "secretHash must be a hex SHA-256" }, 400);
  }
  // Clear out expired codes opportunistically.
  await admin.from("pairing_codes").delete().lt("expires_at", new Date().toISOString());

  for (let attempt = 0; attempt < 5; attempt++) {
    const code = randomCode();
    const { data, error } = await admin
      .from("pairing_codes")
      .insert({ code, secret_hash: body.secretHash })
      .select("code, expires_at")
      .single();
    if (!error) return json({ code: data.code, expiresAt: data.expires_at });
    if (error.code !== "23505") return json({ error: error.message }, 500); // not a collision
  }
  return json({ error: "could not allocate a code, try again" }, 503);
}

async function claim(req: Request, body: { code?: string; familyId?: string; name?: string }) {
  const jwt = req.headers.get("Authorization")?.replace(/^Bearer /, "");
  const { data: userData } = jwt ? await admin.auth.getUser(jwt) : { data: { user: null } };
  const user = userData.user;
  if (!user) return json({ error: "sign in required" }, 401);
  if (!body.code || !body.familyId) return json({ error: "code and familyId required" }, 400);

  const { data: parent } = await admin
    .from("members")
    .select("id")
    .eq("family_id", body.familyId)
    .eq("user_id", user.id)
    .eq("role", "parent")
    .maybeSingle();
  if (!parent) return json({ error: "only parents can pair displays" }, 403);

  const { data: pc } = await admin
    .from("pairing_codes")
    .select("*")
    .eq("code", body.code)
    .gt("expires_at", new Date().toISOString())
    .maybeSingle();
  if (!pc) return json({ error: "code not found or expired" }, 404);
  if (pc.device_id) return json({ error: "code already used" }, 409);

  const deviceUserId = crypto.randomUUID();
  const { data: created, error: userErr } = await admin.auth.admin.createUser({
    id: deviceUserId,
    email: `device-${deviceUserId}@devices.homeos.invalid`,
    password: randomPassword(),
    email_confirm: true,
    app_metadata: { kind: "device", family_id: body.familyId },
  });
  if (userErr) return json({ error: userErr.message }, 500);

  const { data: device, error: devErr } = await admin
    .from("devices")
    .insert({ family_id: body.familyId, user_id: created.user.id, name: body.name ?? "Wall display" })
    .select("id")
    .single();
  if (devErr) {
    await admin.auth.admin.deleteUser(created.user.id);
    return json({ error: devErr.message }, 500);
  }

  await admin
    .from("pairing_codes")
    .update({ family_id: body.familyId, device_id: device.id, claimed_by: user.id })
    .eq("code", body.code);

  return json({ deviceId: device.id });
}

async function redeem(body: { code?: string; secret?: string }) {
  if (!body.code || !body.secret) return json({ error: "code and secret required" }, 400);

  const { data: pc } = await admin.from("pairing_codes").select("*").eq("code", body.code).maybeSingle();
  if (!pc || pc.secret_hash !== (await sha256Hex(body.secret))) {
    return json({ error: "invalid code" }, 404);
  }
  if (!pc.device_id) {
    if (new Date(pc.expires_at) < new Date()) return json({ error: "code expired" }, 410);
    return json({ status: "pending" });
  }

  const { data: device } = await admin.from("devices").select("id, user_id, family_id").eq("id", pc.device_id).single();
  if (!device) return json({ error: "device missing" }, 500);

  // Rotate the device password and sign in once to mint the session.
  const password = randomPassword();
  const { data: u, error: updErr } = await admin.auth.admin.updateUserById(device.user_id, { password });
  if (updErr || !u.user.email) return json({ error: updErr?.message ?? "device user missing" }, 500);

  const anon = createClient(SUPABASE_URL, ANON_KEY, { auth: { persistSession: false } });
  const { data: signIn, error: signErr } = await anon.auth.signInWithPassword({ email: u.user.email, password });
  if (signErr || !signIn.session) return json({ error: signErr?.message ?? "sign-in failed" }, 500);

  await admin.from("pairing_codes").delete().eq("code", body.code);

  return json({
    status: "paired",
    familyId: device.family_id,
    deviceId: device.id,
    session: {
      accessToken: signIn.session.access_token,
      refreshToken: signIn.session.refresh_token,
      expiresAt: signIn.session.expires_at,
    },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return preflight();
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  const read = await readJson(req);
  if ("error" in read) return read.error;
  if (typeof read.body !== "object" || read.body === null || Array.isArray(read.body)) {
    return json({ error: "body must be a JSON object" }, 400);
  }
  const body = read.body as Record<string, string>;
  // Anything unexpected still answers with JSON and the CORS headers.
  try {
    switch (body.action) {
      case "start":
        return await start(body);
      case "claim":
        return await claim(req, body);
      case "redeem":
        return await redeem(body);
      default:
        return json({ error: "action must be start, claim or redeem" }, 400);
    }
  } catch (err) {
    console.error(`pair-device ${body.action} failed:`, err);
    return json({ error: "something went wrong" }, 500);
  }
});
