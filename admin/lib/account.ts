// Deleting your own account, for the iOS app (Profile → Delete account). The
// phone calls POST /api/account/delete on this app with its Supabase JWT,
// because this app is the one that can reach the Blob store. The Supabase
// delete-account edge function removes the rows, the Storage files and the
// login; this then removes the Blob photos and videos of any family that went
// with the account. The admin proxy lets the route through before the
// platform-admin gate. See docs/PLATFORM.md → "Deleting your account".

import { supabaseConfig } from "./env.ts";

/** lib/media/cleanup.ts deleteFamilyBlobs, passed in so tests need no Blob store. */
export type RemoveFamilyBlobs = (familyId: string) => Promise<void>;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

function bearer(request: Request): string | null {
  const match = /^Bearer\s+(\S+)$/i.exec((request.headers.get("authorization") ?? "").trim());
  return match?.[1] ?? null;
}

export async function handleAccountDelete(request: Request, removeFamilyBlobs: RemoveFamilyBlobs): Promise<Response> {
  const config = supabaseConfig();
  if (!config) return json({ error: "Supabase isn't configured." }, 503);
  const token = bearer(request);
  if (!token) return json({ error: "Sign in required." }, 401);

  let reply: Response;
  try {
    reply = await fetch(`${config.url.replace(/\/+$/, "")}/functions/v1/delete-account`, {
      method: "POST",
      headers: { authorization: `Bearer ${token}`, apikey: config.anonKey, "content-type": "application/json" },
      body: "{}",
    });
  } catch (err) {
    console.error("account delete: delete-account unreachable:", err);
    return json({ error: "Couldn't reach Ohana's servers. Try again in a moment." }, 503);
  }
  const body = (await reply.json().catch(() => null)) as { error?: unknown; families_deleted?: unknown } | null;

  // Families that went with the account, even when the login itself still
  // failed (502): their rows are gone either way, so their files go too.
  const families = Array.isArray(body?.families_deleted)
    ? body.families_deleted.filter((id): id is string => typeof id === "string" && UUID.test(id))
    : [];
  let blobsLeft = false;
  for (const id of families) {
    try {
      await removeFamilyBlobs(id);
    } catch (err) {
      blobsLeft = true;
      console.error(`account delete: Blob cleanup for family ${id} failed:`, err);
    }
  }

  if (!reply.ok) {
    const error = typeof body?.error === "string" && body.error ? body.error : `Account deletion failed (HTTP ${reply.status}).`;
    console.warn(`account delete: ${reply.status} ${error}`);
    return json({ error }, reply.status >= 400 && reply.status < 600 ? reply.status : 502);
  }
  console.info(`account delete: done, ${families.length} famil${families.length === 1 ? "y" : "ies"} removed`);
  return json({ ok: true, families_deleted: families, ...(blobsLeft ? { files_left: true } : {}) });
}
