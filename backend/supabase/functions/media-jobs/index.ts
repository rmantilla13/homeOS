// media-jobs: the server's side of making wall copies of videos. Only the
// admin app calls it, from /api/media/process and its sweep, with the shared
// secret in `x-media-jobs-secret`. It holds the service role so the admin
// app doesn't have to, and can only run the media_job_* functions.
//
//   POST { action: "claim", media_id?, limit?, max_running? }  -> { jobs: [...] }
//   POST { action: "finish", media_id, attempt, path?, bytes?, width?, height?, thumbnail_path? }
//   POST { action: "fail", media_id, attempt, error, retry? }  -> { state }
//   POST { action: "replaced_due", limit? }                    -> { items: [{ media_id, replaced_path }] }
//   POST { action: "replaced_cleared", media_id, path }        -> { cleared }
//
// 401 without the secret, 503 when MEDIA_JOBS_SECRET isn't set (or is
// shorter than 32 characters), 409 when a job function refuses.

import { createClient } from "jsr:@supabase/supabase-js@2";
import { json, preflight, readJson } from "../_shared/http.ts";
import { MIN_SECRET_LENGTH, runAction, secretMatches } from "./jobs.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const SECRET = Deno.env.get("MEDIA_JOBS_SECRET");

const service = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return preflight();
  if (req.method !== "POST") return json({ error: "POST only" }, 405);
  if (!SECRET || SECRET.length < MIN_SECRET_LENGTH) {
    return json({ error: "media jobs aren't configured" }, 503);
  }
  if (!(await secretMatches(req.headers.get("x-media-jobs-secret"), SECRET))) {
    return json({ error: "not allowed" }, 401);
  }
  const parsed = await readJson(req);
  if ("error" in parsed) return parsed.error;
  try {
    const outcome = await runAction({ rpc: (name, params) => service.rpc(name, params) }, parsed.body);
    return json(outcome.body, outcome.status);
  } catch (err) {
    console.error("media-jobs failed:", err);
    return json({ error: "something went wrong" }, 500);
  }
});
