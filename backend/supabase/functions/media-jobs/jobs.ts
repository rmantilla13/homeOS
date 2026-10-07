// What media-jobs does once the caller is known, kept free of I/O setup so it
// can be unit-tested with fakes (jobs.test.ts). Each action is one media_job_*
// function from 20261012000001_video_processing.sql, called with the service
// role. Those functions do the checking (states, attempts, paths, sizes);
// this only shapes the request and the answer.

import { isUuid } from "../_shared/http.ts";

type Failure = { message: string; code?: string };

export interface Deps {
  /** service.rpc(name, params) */
  rpc(name: string, params: Record<string, unknown>): PromiseLike<{ data: unknown; error: Failure | null }>;
}

export type Outcome = { status: number; body: Record<string, unknown> };

// The secret is at least this long, so a short placeholder can't be used.
export const MIN_SECRET_LENGTH = 32;

// Constant-time: both sides are hashed first, so neither the length nor the
// first differing byte shows in the timing.
export async function secretMatches(given: string | null, expected: string | undefined): Promise<boolean> {
  if (!given || !expected || expected.length < MIN_SECRET_LENGTH) return false;
  const encoder = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(given)),
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
  ]);
  const x = new Uint8Array(a);
  const y = new Uint8Array(b);
  let diff = 0;
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i];
  return diff === 0;
}

const bad = (error: string): Outcome => ({ status: 400, body: { error } });

const int = (value: unknown, min: number, max: number): number | null =>
  typeof value === "number" && Number.isInteger(value) && value >= min && value <= max ? value : null;

const optionalInt = (value: unknown, min: number, max: number): number | null | undefined =>
  value === undefined || value === null ? null : (int(value, min, max) ?? undefined);

const optionalPath = (value: unknown): string | null | undefined =>
  value === undefined || value === null ? null : typeof value === "string" && value.length <= 300 ? value : undefined;

type Call = { fn: string; params: Record<string, unknown>; shape(data: unknown): Record<string, unknown> };

export function parseAction(body: unknown): Call | Outcome {
  if (!body || typeof body !== "object") return bad("expected a JSON object");
  const b = body as Record<string, unknown>;
  switch (b.action) {
    case "claim": {
      const mediaId = b.media_id === undefined || b.media_id === null ? null : b.media_id;
      if (mediaId !== null && !isUuid(mediaId)) return bad("media_id must be a uuid");
      const limit = b.limit === undefined ? 1 : int(b.limit, 1, 10);
      const maxRunning = b.max_running === undefined ? 2 : int(b.max_running, 1, 8);
      if (limit === null) return bad("limit must be 1 to 10");
      if (maxRunning === null) return bad("max_running must be 1 to 8");
      return {
        fn: "media_job_claim",
        params: { p_media_id: mediaId, p_limit: limit, p_max_running: maxRunning },
        shape: (data) => ({ jobs: Array.isArray(data) ? data : [] }),
      };
    }
    case "finish": {
      if (!isUuid(b.media_id)) return bad("media_id must be a uuid");
      const attempt = int(b.attempt, 1, 1000);
      if (attempt === null) return bad("attempt must be a positive integer");
      const path = optionalPath(b.path);
      const thumbnail = optionalPath(b.thumbnail_path);
      const bytes = optionalInt(b.bytes, 1, Number.MAX_SAFE_INTEGER);
      const width = optionalInt(b.width, 1, 16384);
      const height = optionalInt(b.height, 1, 16384);
      if (path === undefined || thumbnail === undefined) return bad("paths must be strings");
      if (bytes === undefined) return bad("bytes must be a positive integer");
      if (path !== null && bytes === null) return bad("a copy needs its bytes");
      return {
        fn: "media_job_finish",
        params: {
          p_media_id: b.media_id,
          p_attempt: attempt,
          p_path: path,
          p_bytes: bytes,
          p_width: width ?? null,
          p_height: height ?? null,
          p_thumbnail_path: thumbnail,
        },
        shape: (data) => (data && typeof data === "object" ? (data as Record<string, unknown>) : {}),
      };
    }
    case "fail": {
      if (!isUuid(b.media_id)) return bad("media_id must be a uuid");
      const attempt = int(b.attempt, 1, 1000);
      if (attempt === null) return bad("attempt must be a positive integer");
      const error = typeof b.error === "string" && b.error.trim() ? b.error.slice(0, 500) : "failed";
      return {
        fn: "media_job_fail",
        params: { p_media_id: b.media_id, p_attempt: attempt, p_error: error, p_retry: b.retry !== false },
        shape: (data) => ({ state: typeof data === "string" ? data : null }),
      };
    }
    case "replaced_due": {
      const limit = b.limit === undefined ? 100 : int(b.limit, 1, 1000);
      if (limit === null) return bad("limit must be 1 to 1000");
      return {
        fn: "media_job_replaced_due",
        params: { p_limit: limit },
        shape: (data) => ({ items: Array.isArray(data) ? data : [] }),
      };
    }
    case "replaced_cleared": {
      if (!isUuid(b.media_id)) return bad("media_id must be a uuid");
      if (typeof b.path !== "string" || !b.path) return bad("path is required");
      return {
        fn: "media_job_replaced_cleared",
        params: { p_media_id: b.media_id, p_path: b.path },
        shape: (data) => ({ cleared: data === true }),
      };
    }
    default:
      return bad("unknown action");
  }
}

// Errors the job functions raise on purpose (a stale attempt, a copy that
// isn't smaller) are refusals, answered 409 with their message. Anything
// else is logged and answered 500.
export async function runAction(deps: Deps, body: unknown): Promise<Outcome> {
  const call = parseAction(body);
  if ("status" in call) return call;
  const { data, error } = await deps.rpc(call.fn, call.params);
  if (error) {
    if (error.code === "P0001") return { status: 409, body: { error: error.message } };
    console.error(`media-jobs ${call.fn} failed:`, error.message);
    return { status: 500, body: { error: "something went wrong" } };
  }
  return { status: 200, body: call.shape(data) };
}
