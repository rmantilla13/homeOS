// Family-member API for private video blobs. Phones and wall displays call
// these with their Supabase JWT. The admin proxy lets /api/media through
// before the platform-admin gate. Photos never use this module.

import { createClient, type SupabaseClient } from "@supabase/supabase-js";
import { BlobNotFoundError, del, issueSignedToken, presignUrl } from "@vercel/blob";
import { blobReady, supabaseConfig } from "../env.ts";
import { parseDeleteRequest, parsePathList, parseUploadRequest, parseVideoPath, videoPathname } from "./video.ts";

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
  return json({ error: "Video storage isn't configured." }, 503);
}

export async function handleMediaUpload(request: Request): Promise<Response> {
  const parsed = await readJson(request);
  if ("error" in parsed) return parsed.error;
  const upload = parseUploadRequest(parsed.body);
  if (!upload.ok) return json({ error: upload.error }, 400);

  const who = await caller(request);
  if (who instanceof Response) return who;
  const allowed = await inFamily(who.client, upload.value.familyId);
  if (allowed !== true) return allowed;
  if (!blobReady()) return storageDown();

  const id = crypto.randomUUID();
  const pathname = videoPathname(upload.value.familyId, id, upload.value.extension);
  const validUntil = Date.now() + UPLOAD_TTL_MS;
  try {
    const issued = await issueSignedToken({
      pathname,
      operations: ["put"],
      validUntil,
      allowedContentTypes: [upload.value.contentType],
      maximumSizeInBytes: upload.value.bytes,
    });
    const { presignedUrl } = await presignUrl(issued, {
      access: "private",
      operation: "put",
      pathname,
      validUntil,
      allowedContentTypes: [upload.value.contentType],
      maximumSizeInBytes: upload.value.bytes,
      allowOverwrite: false,
      addRandomSuffix: false,
    });
    return json({
      id,
      pathname,
      upload_url: presignedUrl,
      content_type: upload.value.contentType,
    });
  } catch (err) {
    console.error("video upload URL failed:", err);
    return json({ error: "Couldn't start the video upload." }, 502);
  }
}

export async function handleMediaUrls(request: Request): Promise<Response> {
  const parsed = await readJson(request);
  if ("error" in parsed) return parsed.error;
  const list = parsePathList(parsed.body);
  if (!list.ok) return json({ error: list.error }, 400);

  const who = await caller(request);
  if (who instanceof Response) return who;

  const parsedPaths = list.paths.map((entry) => (typeof entry === "string" ? parseVideoPath(entry) : null));
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
      const pathname = videoPathname(path.familyId, path.mediaId, path.ext);
      const { presignedUrl } = await presignUrl(issued, {
        access: "private",
        operation: "get",
        pathname,
        validUntil,
      });
      urls.push(presignedUrl);
    }
    return json({ urls });
  } catch (err) {
    console.error("video playback URLs failed:", err);
    return json({ error: "Couldn't sign video URLs." }, 502);
  }
}

export async function handleMediaDelete(request: Request): Promise<Response> {
  const parsed = await readJson(request);
  if ("error" in parsed) return parsed.error;
  const target = parseDeleteRequest(parsed.body);
  if (!target.ok) return json({ error: target.error }, 400);

  const who = await caller(request);
  if (who instanceof Response) return who;
  const allowed = await inFamily(who.client, target.familyId);
  if (allowed !== true) return allowed;
  if (!blobReady()) return storageDown();

  try {
    await del(target.pathname);
  } catch (err) {
    if (!(err instanceof BlobNotFoundError)) {
      console.error("video delete failed:", err);
      return json({ error: "Couldn't delete that video." }, 502);
    }
  }
  return json({ ok: true });
}
