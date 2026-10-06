// Rules for family videos stored in the private Vercel Blob store.
// Photos never come through here; they stay in the Supabase family-media bucket.
// Pathnames are `<family_id>/<media_id>.<ext>`, the same shape as Storage objects.

export const VIDEO_MAX_BYTES = 2 * 1024 * 1024 * 1024;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

// iOS sends video/quicktime for .mov and video/<ext> otherwise. The extra
// entries (video/mkv, video/3gp, video/3g2, video/x-m4v) accept that and the
// usual container types.
const VIDEO_CONTENT_TYPES: Record<string, string> = {
  "video/mp4": "mp4",
  "video/quicktime": "mov",
  "video/m4v": "m4v",
  "video/x-m4v": "m4v",
  "video/webm": "webm",
  "video/x-matroska": "mkv",
  "video/mkv": "mkv",
  "video/3gpp": "3gp",
  "video/3gp": "3gp",
  "video/3gpp2": "3g2",
  "video/3g2": "3g2",
};

export function videoExtension(contentType: string): string | null {
  return VIDEO_CONTENT_TYPES[contentType.trim().toLowerCase()] ?? null;
}

export type VideoPath = { familyId: string; mediaId: string; ext: string };

// Rejects traversal, extra folders, photos, and anything that isn't
// `<uuid>/<uuid>.<video ext>`. Ids come back lowercase.
export function parseVideoPath(pathname: string): VideoPath | null {
  if (pathname.includes("..") || pathname.includes("\\") || pathname.includes("%") || pathname.startsWith("/")) {
    return null;
  }
  const match =
    /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.(mp4|mov|m4v|webm|mkv|3gp|3g2)$/i.exec(
      pathname,
    );
  if (!match) return null;
  return { familyId: match[1].toLowerCase(), mediaId: match[2].toLowerCase(), ext: match[3].toLowerCase() };
}

export function videoPathname(familyId: string, mediaId: string, ext: string): string {
  return `${familyId.toLowerCase()}/${mediaId.toLowerCase()}.${ext}`;
}

export type UploadRequest = {
  familyId: string;
  contentType: string;
  bytes: number;
  extension: string;
};

export function parseUploadRequest(body: unknown): { ok: true; value: UploadRequest } | { ok: false; error: string } {
  if (!body || typeof body !== "object") return { ok: false, error: "Expected a JSON object." };
  const record = body as Record<string, unknown>;
  const familyId = typeof record.family_id === "string" ? record.family_id.trim().toLowerCase() : "";
  if (!UUID.test(familyId)) return { ok: false, error: "family_id must be a UUID." };
  const contentType = typeof record.content_type === "string" ? record.content_type.trim().toLowerCase() : "";
  const extension = videoExtension(contentType);
  if (!extension) return { ok: false, error: "That video format isn't supported." };
  const bytes = record.bytes;
  if (typeof bytes !== "number" || !Number.isInteger(bytes) || bytes < 1 || bytes > VIDEO_MAX_BYTES) {
    return { ok: false, error: "Video must be between 1 byte and 2 GB." };
  }
  return { ok: true, value: { familyId, contentType, bytes, extension } };
}

export function parsePathList(body: unknown): { ok: true; paths: unknown[] } | { ok: false; error: string } {
  if (!body || typeof body !== "object") return { ok: false, error: "Expected a JSON object." };
  const paths = (body as Record<string, unknown>).paths;
  if (!Array.isArray(paths)) return { ok: false, error: "paths must be an array." };
  if (paths.length > 200) return { ok: false, error: "Ask for at most 200 videos at a time." };
  return { ok: true, paths };
}

export function parseDeleteRequest(body: unknown): { ok: true; pathname: string; familyId: string } | { ok: false; error: string } {
  if (!body || typeof body !== "object") return { ok: false, error: "Expected a JSON object." };
  const pathname = (body as Record<string, unknown>).pathname;
  if (typeof pathname !== "string") return { ok: false, error: "That isn't a video path." };
  const parsed = parseVideoPath(pathname);
  if (!parsed) return { ok: false, error: "That isn't a video path." };
  return { ok: true, pathname: videoPathname(parsed.familyId, parsed.mediaId, parsed.ext), familyId: parsed.familyId };
}
