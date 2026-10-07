// The platform boot video: one short silent MP4 every wall display plays.
// Kept free of the HTTP handler so the checks can be unit-tested
// (boot-video.test.ts). The admin function uploads with the service role;
// displays download `boot-video/current.mp4` with the anon key.

export const BOOT_BUCKET = "boot-video";
export const BOOT_OBJECT = "current.mp4";
export const BOOT_MAX_BYTES = 20 * 1024 * 1024;
export const BOOT_MIN_MS = 500;
export const BOOT_MAX_MS = 12_000;
export const BOOT_URL_SECONDS = 10 * 60;

const PENDING = /^pending\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.mp4$/;
const CONTAINERS = new Set(["moov", "trak", "mdia", "minf", "stbl", "edts", "dinf", "moof", "mvex", "udta"]);

export function isPendingBootPath(path: string): boolean {
  return PENDING.test(path);
}

export function newPendingBootPath(): string {
  return `pending/${crypto.randomUUID()}.mp4`;
}

function ascii(bytes: Uint8Array, offset: number, length: number): string {
  let s = "";
  for (let i = 0; i < length; i++) s += String.fromCharCode(bytes[offset + i] ?? 0);
  return s;
}

function u32(bytes: Uint8Array, offset: number): number {
  return new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength).getUint32(offset);
}

// Movie header duration, in milliseconds. version 0 stores 32-bit times;
// version 1 stores 64-bit times. A zero timescale is not a duration.
function readMvhd(bytes: Uint8Array, start: number, end: number): number | null {
  if (start >= end) return null;
  const version = bytes[start];
  if (version === 0) {
    if (start + 20 > end) return null;
    const timescale = u32(bytes, start + 12);
    const duration = u32(bytes, start + 16);
    if (timescale === 0) return null;
    return (duration / timescale) * 1000;
  }
  if (version === 1) {
    if (start + 32 > end) return null;
    const timescale = u32(bytes, start + 20);
    const hi = u32(bytes, start + 24);
    const lo = u32(bytes, start + 28);
    if (timescale === 0) return null;
    return ((hi * 2 ** 32 + lo) / timescale) * 1000;
  }
  return null;
}

function readHandler(bytes: Uint8Array, start: number, end: number): string | null {
  if (start + 12 > end) return null;
  return ascii(bytes, start + 8, 4);
}

// Walks MP4 boxes. A boot clip must be an mp4, have a video track, have no
// audio track (the panel's speakers hiss), and last a few seconds.
export function assessBootVideo(bytes: Uint8Array): { durationMs: number } | { error: string } {
  if (bytes.byteLength > BOOT_MAX_BYTES) return { error: "boot video must be 20 MB or smaller" };
  if (bytes.byteLength < 12 || ascii(bytes, 4, 4) !== "ftyp") return { error: "that file isn't an mp4" };

  let durationMs: number | null = null;
  let hasVideo = false;
  let hasAudio = false;

  const walk = (start: number, end: number): string | null => {
    let off = start;
    while (off + 8 <= end) {
      const size32 = u32(bytes, off);
      let header = 8;
      let size = size32;
      if (size32 === 1) {
        if (off + 16 > end) return "that file isn't an mp4";
        size = u32(bytes, off + 8) * 2 ** 32 + u32(bytes, off + 12);
        header = 16;
      } else if (size32 === 0) {
        size = end - off;
      }
      if (!Number.isFinite(size) || size < header || off + size > end) return "that file isn't an mp4";
      const kind = ascii(bytes, off + 4, 4);
      const payload = off + header;
      const payloadEnd = off + size;
      if (kind === "mvhd" && durationMs === null) {
        const d = readMvhd(bytes, payload, payloadEnd);
        if (d !== null) durationMs = d;
      } else if (kind === "hdlr") {
        const handler = readHandler(bytes, payload, payloadEnd);
        if (handler === "vide") hasVideo = true;
        if (handler === "soun") hasAudio = true;
      } else if (CONTAINERS.has(kind)) {
        const err = walk(payload, payloadEnd);
        if (err) return err;
      }
      off += size;
    }
    return null;
  };

  const err = walk(0, bytes.byteLength);
  if (err) return { error: err };
  if (!hasVideo) return { error: "boot video needs a video track" };
  if (hasAudio) return { error: "boot video must be silent" };
  if (durationMs === null || !Number.isFinite(durationMs)) return { error: "couldn't read the video length" };
  const rounded = Math.round(durationMs);
  if (rounded < BOOT_MIN_MS || rounded > BOOT_MAX_MS) {
    return { error: "boot video must be between 0.5 and 12 seconds" };
  }
  return { durationMs: rounded };
}
