// Rules for family photos and videos in the private Vercel Blob store.
// Profile avatars stay in the Supabase `avatars` bucket.
// Pathnames are `<family_id>/<media_id>.<ext>`, the same shape as Storage objects.
// Each item's poster is `<family_id>/<media_id>-thumb.jpg` (a JPEG, at most 256 KiB).
// A video the server made a wall copy of moves to `<family_id>/<media_id>-wall.mp4`
// (lib/media/processing.ts).

export const VIDEO_MAX_BYTES = 2 * 1024 * 1024 * 1024;
export const PHOTO_MAX_BYTES = 50 * 1024 * 1024;
export const THUMB_MAX_BYTES = 256 * 1024;
export const THUMB_CONTENT_TYPE = "image/jpeg";

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

// `thumb` is true for an item's poster, `<uuid>/<uuid>-thumb.jpg`, and
// `wall` for a server-made copy, `<uuid>/<uuid>-wall.mp4`.
export type MediaPath = { familyId: string; mediaId: string; ext: string; thumb: boolean; wall: boolean };

// Rejects traversal, extra folders, and anything that isn't
// `<uuid>/<uuid>.<photo or video ext>`, `<uuid>/<uuid>-thumb.jpg` or
// `<uuid>/<uuid>-wall.mp4`. Ids come back lowercase.
export function parseMediaPath(pathname: string): MediaPath | null {
  if (pathname.includes("..") || pathname.includes("\\") || pathname.includes("%") || pathname.startsWith("/")) {
    return null;
  }
  const match =
    /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})\/([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})(-thumb\.jpg|-wall\.mp4|\.(?:jpg|jpeg|png|webp|heic|gif|mp4|mov|m4v|webm|mkv|3gp|3g2))$/i.exec(
      pathname,
    );
  if (!match) return null;
  const tail = match[3].toLowerCase();
  const thumb = tail === "-thumb.jpg";
  const wall = tail === "-wall.mp4";
  const ext = thumb ? "jpg" : wall ? "mp4" : tail.slice(1);
  return { familyId: match[1].toLowerCase(), mediaId: match[2].toLowerCase(), ext, thumb, wall };
}

export function mediaPathname(familyId: string, mediaId: string, ext: string): string {
  return `${familyId.toLowerCase()}/${mediaId.toLowerCase()}.${ext}`;
}

export function thumbPathname(familyId: string, mediaId: string): string {
  return `${familyId.toLowerCase()}/${mediaId.toLowerCase()}-thumb.jpg`;
}

export function wallPathname(familyId: string, mediaId: string): string {
  return `${familyId.toLowerCase()}/${mediaId.toLowerCase()}-wall.mp4`;
}

// The canonical (lowercase) pathname of a parsed file, poster or wall copy.
export function pathnameOf(path: MediaPath): string {
  if (path.thumb) return thumbPathname(path.familyId, path.mediaId);
  if (path.wall) return wallPathname(path.familyId, path.mediaId);
  return mediaPathname(path.familyId, path.mediaId, path.ext);
}

// Every object an item can have starts with this: its file, poster, wall
// copy, and an original still waiting to be deleted after a swap.
export function itemPrefix(familyId: string, mediaId: string): string {
  return `${familyId.toLowerCase()}/${mediaId.toLowerCase()}`;
}

export type UploadRequest = {
  familyId: string;
  contentType: string;
  bytes: number;
  extension: string;
  // Size of the JPEG poster the phone will PUT next to the file, or null
  // (older apps send none).
  thumbnailBytes: number | null;
  // thumbnail_bytes was sent but isn't a usable size. The poster is only a
  // nicety, so the file is still signed; the route logs this.
  thumbnailIgnored: boolean;
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
  const poster = record.thumbnail_bytes;
  const thumbnailBytes =
    typeof poster === "number" && Number.isInteger(poster) && poster >= 1 && poster <= THUMB_MAX_BYTES ? poster : null;
  const thumbnailIgnored = thumbnailBytes === null && poster !== undefined && poster !== null;
  return { ok: true, value: { familyId, contentType, bytes, extension, thumbnailBytes, thumbnailIgnored } };
}

export function parsePathList(body: unknown): { ok: true; paths: unknown[] } | { ok: false; error: string } {
  if (!body || typeof body !== "object") return { ok: false, error: "Expected a JSON object." };
  const paths = (body as Record<string, unknown>).paths;
  if (!Array.isArray(paths)) return { ok: false, error: "paths must be an array." };
  if (paths.length > 200) return { ok: false, error: "Ask for at most 200 files at a time." };
  return { ok: true, paths };
}

// Phones delete by the file's path; its poster goes with it. A poster path
// on its own is refused, so a row can't be left pointing at a deleted poster.
export function parseDeleteRequest(
  body: unknown,
):
  | { ok: true; pathname: string; thumbnailPathname: string; prefix: string; familyId: string }
  | { ok: false; error: string } {
  if (!body || typeof body !== "object") return { ok: false, error: "Expected a JSON object." };
  const pathname = (body as Record<string, unknown>).pathname;
  if (typeof pathname !== "string") return { ok: false, error: "That isn't a media path." };
  const parsed = parseMediaPath(pathname);
  if (!parsed || parsed.thumb) return { ok: false, error: "That isn't a media path." };
  return {
    ok: true,
    pathname: pathnameOf(parsed),
    thumbnailPathname: thumbPathname(parsed.familyId, parsed.mediaId),
    prefix: itemPrefix(parsed.familyId, parsed.mediaId),
    familyId: parsed.familyId,
  };
}

// A phone asks for a wall copy of a video it just recorded, by the file's
// path. Posters are refused; so is a path that is already a wall copy.
export function parseProcessRequest(
  body: unknown,
): { ok: true; pathname: string; familyId: string; mediaId: string } | { ok: false; error: string } {
  if (!body || typeof body !== "object") return { ok: false, error: "Expected a JSON object." };
  const pathname = (body as Record<string, unknown>).pathname;
  const parsed = typeof pathname === "string" ? parseMediaPath(pathname) : null;
  if (!parsed || parsed.thumb || parsed.wall || isPhotoExtension(parsed.ext)) {
    return { ok: false, error: "That isn't a video path." };
  }
  return { ok: true, pathname: pathnameOf(parsed), familyId: parsed.familyId, mediaId: parsed.mediaId };
}
