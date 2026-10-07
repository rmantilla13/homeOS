// Family-member API for private photo and video blobs. Phones and wall
// displays call these with their Supabase JWT. The admin proxy lets
// /api/media through before the platform-admin gate. Profile avatars stay
// in Supabase.

import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { BlobNotFoundError, del, issueSignedToken, list, presignUrl } from "@vercel/blob";
import { blobReady, mediaCallbackOrigin, supabaseConfig } from "../env.ts";
import {
  THUMB_CONTENT_TYPE,
  mediaPathname,
  parseDeleteRequest,
  parseMediaPath,
  parsePathList,
  parseProcessRequest,
  parseUploadRequest,
  pathnameOf,
  thumbPathname,
} from "./video.ts";
import { presignedPut } from "./sign.ts";
import { type ProcessingDeps, requestJob } from "./processing.ts";

const UPLOAD_TTL_MS = 2 * 60 * 60 * 1000;
const PLAYBACK_TTL_MS = 6 * 60 * 60 * 1000;

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

async function readJson(request: Request): Promise<{ body: unknown } | { error: Response }> {
  const text = await request.text();
  if (text.length > 65_536) return { error: json({ error: "Request body too large." }, 413) };
  try {
    return { body: text ? JSON.parse(text) : null };
  } catch {
    return { error: json({ error: "Invalid JSON." }, 400) };
  }
}

// A signed-in family member (a person or a paired display), or an error response.
async function caller(request: Request): Promise<{ client: SupabaseClient } | Response> {
  const config = supabaseConfig();
  if (!config) return json({ error: "Supabase isn't configured." }, 503);
  const token = bearer(request);
  if (!token) return json({ error: "Sign in required." }, 401);
  const client = createClient(config.url, config.anonKey, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  try {
    const { data, error } = await client.auth.getUser(token);
    if (error || !data.user) return json({ error: "Sign in required." }, 401);
    return { client };
  } catch (err) {
    console.error("media auth failed:", err);
    return json({ error: "Couldn't check your sign-in. Try again in a moment." }, 503);
  }
}

async function inFamily(client: SupabaseClient, familyId: string): Promise<true | Response> {
  const { data, error } = await client.rpc("is_family_member", { fid: familyId });
  if (error) {
    console.error("is_family_member failed:", error.message);
    return json({ error: "Couldn't check family membership." }, 503);
  }
  if (data !== true) return json({ error: "You aren't in that family." }, 403);
  return true;
}

function storageDown(): Response {
  return json({ error: "Media storage isn't configured." }, 503);
}

// Vercel's runtime logs only show what a function prints, so a refused
// request would otherwise leave no trace there. One line per refusal, with
// the status and the message the caller saw (no tokens or paths).
async function logRefusal(route: string, response: Response): Promise<Response> {
  if (response.status >= 400) {
    const detail = await response
      .clone()
      .json()
      .then((body: unknown) => {
        const error = (body as { error?: unknown } | null)?.error;
        return typeof error === "string" ? error : "";
      })
      .catch(() => "");
    console.warn(`media ${route}: ${response.status} ${detail}`.trim());
  }
  return response;
}

export async function handleMediaUpload(request: Request): Promise<Response> {
  return logRefusal("upload", await mediaUpload(request));
}

async function mediaUpload(request: Request): Promise<Response> {
  const parsed = await readJson(request);
  if ("error" in parsed) return parsed.error;
  const upload = parseUploadRequest(parsed.body);
  if (!upload.ok) return json({ error: upload.error }, 400);

  const who = await caller(request);
  if (who instanceof Response) return who;
  const allowed = await inFamily(who.client, upload.value.familyId);
  if (allowed !== true) return allowed;
  if (!blobReady()) return storageDown();

  const { familyId, contentType, bytes, extension, thumbnailBytes } = upload.value;
  if (upload.value.thumbnailIgnored) {
    console.warn("media upload: thumbnail_bytes must be between 1 byte and 256 KB; signing without a poster");
  }
  const id = crypto.randomUUID();
  const pathname = mediaPathname(familyId, id, extension);
  const posterPathname = thumbPathname(familyId, id);
  const validUntil = Date.now() + UPLOAD_TTL_MS;
  // Both are signed at once to save the phone a round trip. The poster is a
  // nicety: when it can't be signed, the file still uploads without one.
  const [file, poster] = await Promise.allSettled([
    presignedPut(pathname, contentType, bytes, validUntil),
    thumbnailBytes === null ? null : presignedPut(posterPathname, THUMB_CONTENT_TYPE, thumbnailBytes, validUntil),
  ]);
  if (file.status === "rejected") {
    console.error("media upload URL failed:", file.reason);
    return json({ error: "Couldn't start the upload." }, 502);
  }
  if (poster.status === "rejected") console.error("media poster URL failed:", poster.reason);
  const posterUrl = poster.status === "fulfilled" ? poster.value : null;
  const thumbnail = posterUrl ? { pathname: posterPathname, upload_url: posterUrl, content_type: THUMB_CONTENT_TYPE } : null;
  // The phone's half of the trail: a ticket here with no media_items row
  // afterwards means the Blob PUT or the row insert failed on the phone.
  console.info(
    `media upload: signed ${contentType}, ${bytes} bytes` + (thumbnail ? `, poster ${thumbnailBytes} bytes` : ", no poster"),
  );
  return json({
    id,
    pathname,
    upload_url: file.value,
    content_type: contentType,
    ...(thumbnail ? { thumbnail } : {}),
  });
}

export async function handleMediaUrls(request: Request): Promise<Response> {
  return logRefusal("urls", await mediaUrls(request));
}

async function mediaUrls(request: Request): Promise<Response> {
  const parsed = await readJson(request);
  if ("error" in parsed) return parsed.error;
  const list = parsePathList(parsed.body);
  if (!list.ok) return json({ error: list.error }, 400);

  const who = await caller(request);
  if (who instanceof Response) return who;

  const parsedPaths = list.paths.map((entry) => (typeof entry === "string" ? parseMediaPath(entry) : null));
  const familyIds = [...new Set(parsedPaths.flatMap((path) => (path ? [path.familyId] : [])))];
  const allowed = new Set<string>();
  for (const familyId of familyIds) {
    const member = await inFamily(who.client, familyId);
    if (member === true) allowed.add(familyId);
    else if (member.status !== 403) return member;
  }
  if (!parsedPaths.some((path) => path && allowed.has(path.familyId))) {
    return json({ urls: parsedPaths.map(() => "") });
  }
  if (!blobReady()) return storageDown();

  const validUntil = Date.now() + PLAYBACK_TTL_MS;
  try {
    const issued = await issueSignedToken({ pathname: "*", operations: ["get"], validUntil });
    const urls: string[] = [];
    for (const path of parsedPaths) {
      if (!path || !allowed.has(path.familyId)) {
        urls.push("");
        continue;
      }
      const { presignedUrl } = await presignUrl(issued, {
        access: "private",
        operation: "get",
        pathname: pathnameOf(path),
        validUntil,
      });
      urls.push(presignedUrl);
    }
    return json({ urls });
  } catch (err) {
    console.error("media playback URLs failed:", err);
    return json({ error: "Couldn't sign media URLs." }, 502);
  }
}

export async function handleMediaDelete(request: Request): Promise<Response> {
  return logRefusal("delete", await mediaDelete(request));
}

async function mediaDelete(request: Request): Promise<Response> {
  const parsed = await readJson(request);
  if ("error" in parsed) return parsed.error;
  const target = parseDeleteRequest(parsed.body);
  if (!target.ok) return json({ error: target.error }, 400);

  const who = await caller(request);
  if (who instanceof Response) return who;
  const allowed = await inFamily(who.client, target.familyId);
  if (allowed !== true) return allowed;
  if (!blobReady()) return storageDown();

  // The poster goes first. If the file then fails, the phone keeps the row
  // and it still plays, just without a poster. A poster that won't go is
  // only logged: it is small, and family cleanup removes the whole folder.
  // One del() per object, so a missing poster (rows from before posters)
  // can't get in the way of the file.
  try {
    await del(target.thumbnailPathname);
  } catch (err) {
    if (!(err instanceof BlobNotFoundError)) console.error("media poster delete failed:", err);
  }
  try {
    await del(target.pathname);
  } catch (err) {
    if (!(err instanceof BlobNotFoundError)) {
      console.error("media delete failed:", err);
      return json({ error: "Couldn't delete that file." }, 502);
    }
  }
  await deleteLeftovers(target.prefix);
  return json({ ok: true });
}

// Anything else under the item's prefix: the original a wall copy replaced
// (kept for six hours), or a copy from a job that was still running. Only
// logged when it fails; family cleanup removes the whole folder.
async function deleteLeftovers(prefix: string): Promise<void> {
  try {
    const { blobs } = await list({ prefix, limit: 20 });
    const left = blobs.map((blob) => blob.pathname).filter((pathname) => pathname.startsWith(prefix));
    if (left.length > 0) await del(left);
  } catch (err) {
    console.error("media leftover delete failed:", err);
  }
}

// A phone uploaded a video it couldn't optimize and asks for a wall copy.
// The answer is only informative ({ state }): the sweep makes the copy
// anyway, so the phone doesn't wait on this or show its errors.
export async function handleMediaProcess(request: Request, deps?: ProcessingDeps | null): Promise<Response> {
  return logRefusal("process", await mediaProcess(request, deps));
}

async function mediaProcess(request: Request, deps?: ProcessingDeps | null): Promise<Response> {
  const parsed = await readJson(request);
  if ("error" in parsed) return parsed.error;
  const target = parseProcessRequest(parsed.body);
  if (!target.ok) return json({ error: target.error }, 400);

  const who = await caller(request);
  if (who instanceof Response) return who;
  const allowed = await inFamily(who.client, target.familyId);
  if (allowed !== true) return allowed;

  const origin = mediaCallbackOrigin() ?? new URL(request.url).origin;
  const outcome = await requestJob(who.client, target, origin, deps);
  return json(outcome.body, outcome.status);
}
