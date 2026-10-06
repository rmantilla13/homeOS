// Rules for family photos and videos in the private Vercel Blob store.
// Profile avatars stay in the Supabase `avatars` bucket.
// Pathnames are `<family_id>/<media_id>.<ext>`, the same shape as Storage objects.

export const VIDEO_MAX_BYTES = 2 * 1024 * 1024 * 1024;
export const PHOTO_MAX_BYTES = 50 * 1024 * 1024;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

// iOS re-encodes photos to JPEG and sends video/quicktime for .mov,
// video/<ext> otherwise. The extra video entries accept that and the usual
// container types.
const MEDIA_CONTENT_TYPES: Record<string, string> = {
  "image/jpeg": "jpg",
  "image/jpg": "jpg",
  "image/png": "png",
  "image/webp": "webp",
  "image/heic": "heic",
  "image/gif": "gif",
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

const PHOTO_EXTENSIONS = new Set(["jpg", "jpeg", "png", "webp", "heic", "gif"]);

// Aliases that public.allowed_media_types() doesn't list. A row with one
// would be refused after the bytes were already in Blob, so the upload is
// signed for the name the database does list.
const CANONICAL_CONTENT_TYPES: Record<string, string> = {
  "image/jpg": "image/jpeg",
};

export function mediaExtension(contentType: string): string | null {
  return MEDIA_CONTENT_TYPES[contentType.trim().toLowerCase()] ?? null;
}

export function canonicalContentType(contentType: string): string {
  const type = contentType.trim().toLowerCase();
  return CANONICAL_CONTENT_TYPES[type] ?? type;
}

export function isPhotoExtension(ext: string): boolean {
  return PHOTO_EXTENSIONS.has(ext);
}

export type MediaPath = { familyId: string; mediaId: string; ext: string };

// Rejects traversal, extra folders, and anything that isn't
// `<uuid>/<uuid>.<photo or video ext>`. Ids come back lowercase.
export function parseMediaPath(pathname: string): MediaPath | null {
  if (pathname.includes("..") || pathname.includes("\\") || pathname.includes("%") || pathname.startsWith("/")) {
    return null;
  }
  const match =
    /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\.(jpg|jpeg|png|webp|heic|gif|mp4|mov|m4v|webm|mkv|3gp|3g2)$/i.exec(
      pathname,
    );
  if (!match) return null;
  return { familyId: match[1].toLowerCase(), mediaId: match[2].toLowerCase(), ext: match[3].toLowerCase() };
}

export function mediaPathname(familyId: string, mediaId: string, ext: string): string {
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
  const contentType = typeof record.content_type === "string" ? canonicalContentType(record.content_type) : "";
  const extension = mediaExtension(contentType);
  if (!extension) return { ok: false, error: "That file format isn't supported." };
  const maxBytes = isPhotoExtension(extension) ? PHOTO_MAX_BYTES : VIDEO_MAX_BYTES;
  const bytes = record.bytes;
  if (typeof bytes !== "number" || !Number.isInteger(bytes) || bytes < 1 || bytes > maxBytes) {
    const limit = isPhotoExtension(extension) ? "50 MB" : "2 GB";
    const noun = isPhotoExtension(extension) ? "Photo" : "Video";
    return { ok: false, error: `${noun} must be between 1 byte and ${limit}.` };
  }
  return { ok: true, value: { familyId, contentType, bytes, extension } };
}

export function parsePathList(body: unknown): { ok: true; paths: unknown[] } | { ok: false; error: string } {
  if (!body || typeof body !== "object") return { ok: false, error: "Expected a JSON object." };
  const paths = (body as Record<string, unknown>).paths;
  if (!Array.isArray(paths)) return { ok: false, error: "paths must be an array." };
  if (paths.length > 200) return { ok: false, error: "Ask for at most 200 files at a time." };
  return { ok: true, paths };
}

export function parseDeleteRequest(body: unknown): { ok: true; pathname: string; familyId: string } | { ok: false; error: string } {
  if (!body || typeof body !== "object") return { ok: false, error: "Expected a JSON object." };
  const pathname = (body as Record<string, unknown>).pathname;
  if (typeof pathname !== "string") return { ok: false, error: "That isn't a media path." };
  const parsed = parseMediaPath(pathname);
  if (!parsed) return { ok: false, error: "That isn't a media path." };
  return { ok: true, pathname: mediaPathname(parsed.familyId, parsed.mediaId, parsed.ext), familyId: parsed.familyId };
}
