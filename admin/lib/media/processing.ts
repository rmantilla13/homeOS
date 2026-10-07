// Server-made wall copies of videos (docs/PLATFORM_SPEC.md §1.14).
//
//   requestJob          a phone uploaded a video it couldn't optimize
//                       (POST /api/media/process, handled in api.ts)
//   handleProcessDone   a sandbox reports back (POST /api/media/process/done)
//   handleProcessSweep  Vercel Cron, every 10 minutes (GET /api/media/process/sweep)
//
// Job state lives in Postgres behind the media-jobs edge function, which
// this app reaches with MEDIA_JOBS_SECRET; it never holds the service role
// key. Each job runs worker.mjs in its own Vercel Sandbox, which only ever
// gets presigned URLs for its one video. A row moves onto its copy only
// after Blob says the copy is there, and at the size Blob reports.

import { createHmac, randomBytes, timingSafeEqual } from "node:crypto";
import { readFile } from "node:fs/promises";
import path from "node:path";
import type { SupabaseClient } from "@supabase/supabase-js";
import { BlobNotFoundError, del, head } from "@vercel/blob";
import { Sandbox } from "@vercel/sandbox";
import {
  blobReady,
  cronSecret,
  mediaCallbackOrigin,
  mediaFfmpegEnv,
  mediaJobsSecret,
  mediaSandboxVcpus,
  supabaseConfig,
  type SupabaseConfig,
} from "../env.ts";
import { presignedGet, presignedPut } from "./sign.ts";
import { THUMB_CONTENT_TYPE, THUMB_MAX_BYTES, VIDEO_MAX_BYTES, parseMediaPath, thumbPathname, wallPathname } from "./video.ts";

// At most this many sandboxes at once, for the whole platform.
export const MAX_RUNNING = 2;
// A copy with only its index moved can be a few KB bigger; media_job_finish allows 1 MiB.
export const SLACK_BYTES = 1024 * 1024;
const URL_TTL_MS = 2 * 60 * 60 * 1000;
const WORK_DIR = "/vercel/sandbox";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** A claimed job, as media_job_claim returns it. */
export type Job = {
  media_id: string;
  family_id: string;
  storage_path: string;
  thumbnail_path: string | null;
  byte_size: number | null;
  content_type: string | null;
  attempt: number;
};

/** What worker.mjs reads from job.json. */
export type WorkerJob = {
  media_id: string;
  family_id: string;
  attempt: number;
  sandbox: string;
  token: string;
  source_url: string;
  source_ext: string;
  output_url: string;
  poster_url: string | null;
  callback_url: string;
  max_bytes: number;
};

export type JobsAnswer = { status: number; body: Record<string, unknown> };

/** Everything outside this file, so the tests can stand in for it. */
export interface ProcessingDeps {
  jobs(body: Record<string, unknown>): Promise<JobsAnswer>;
  presignPut(pathname: string, contentType: string, maxBytes: number, validUntil: number): Promise<string>;
  presignGet(pathname: string, validUntil: number): Promise<string>;
  /** The object's size in Blob, or null when it isn't there. */
  size(pathname: string): Promise<number | null>;
  remove(pathnames: string[]): Promise<void>;
  startSandbox(name: string, job: WorkerJob, options: { timeoutMs: number; vcpus: number }): Promise<void>;
  stopSandbox(name: string): Promise<void>;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

const message = (err: unknown) => (err instanceof Error ? err.message : String(err));

// ───────────────────────────── Tokens ─────────────────────────────

// The callback carries this. Only this app (with the secret) can make it,
// and it names one attempt in one sandbox.
export function jobToken(
  secret: string,
  job: { media_id: string; family_id: string; attempt: number; sandbox: string },
): string {
  return createHmac("sha256", secret)
    .update(`v1:${job.media_id}:${job.family_id}:${job.attempt}:${job.sandbox}`)
    .digest("hex");
}

function sameText(a: string, b: string): boolean {
  const x = Buffer.from(a);
  const y = Buffer.from(b);
  return x.length === y.length && timingSafeEqual(x, y);
}

export function sandboxName(job: Pick<Job, "media_id" | "attempt">): string {
  return `ohana-video-${job.media_id.slice(0, 8)}-${job.attempt}-${randomBytes(3).toString("hex")}`;
}

// Generous: about 1 s per MB on top of 10 minutes, and under the hour after
// which media_job_claim treats the job as stale.
export function sandboxTimeoutMs(bytes: number | null): number {
  const megabytes = (bytes ?? VIDEO_MAX_BYTES) / 1_000_000;
  return Math.min(55, 10 + Math.ceil(megabytes / 60)) * 60_000;
}

// ───────────────────────────── Starting ─────────────────────────────

// Signs the URLs, starts the sandbox, and gives the job back as pending when
// that fails (the sweep tries again). True when the sandbox is running.
export async function startJob(job: Job, origin: string, secret: string, deps: ProcessingDeps): Promise<boolean> {
  const sandbox = sandboxName(job);
  const validUntil = Date.now() + URL_TTL_MS;
  const maxBytes = (job.byte_size ?? VIDEO_MAX_BYTES) + SLACK_BYTES;
  try {
    const [sourceUrl, outputUrl, posterUrl] = await Promise.all([
      deps.presignGet(job.storage_path, validUntil),
      deps.presignPut(wallPathname(job.family_id, job.media_id), "video/mp4", maxBytes, validUntil),
      job.thumbnail_path
        ? null
        : deps.presignPut(thumbPathname(job.family_id, job.media_id), THUMB_CONTENT_TYPE, THUMB_MAX_BYTES, validUntil),
    ]);
    const workerJob: WorkerJob = {
      media_id: job.media_id,
      family_id: job.family_id,
      attempt: job.attempt,
      sandbox,
      token: jobToken(secret, { ...job, sandbox }),
      source_url: sourceUrl,
      source_ext: job.storage_path.split(".").pop()?.toLowerCase() ?? "mov",
      output_url: outputUrl,
      poster_url: posterUrl,
      callback_url: `${origin}/api/media/process/done`,
      max_bytes: maxBytes,
    };
    await deps.startSandbox(sandbox, workerJob, { timeoutMs: sandboxTimeoutMs(job.byte_size), vcpus: mediaSandboxVcpus() });
    console.info(`media process: started ${sandbox}, ${job.byte_size ?? "?"} bytes, attempt ${job.attempt}`);
    return true;
  } catch (err) {
    console.error(`media process: couldn't start ${sandbox}:`, err);
    await deps
      .jobs({ action: "fail", media_id: job.media_id, attempt: job.attempt, error: `couldn't start: ${message(err)}` })
      .catch((e) => console.error("media process: couldn't hand the job back:", e));
    return false;
  }
}

const jobsOf = (answer: JobsAnswer): Job[] => (Array.isArray(answer.body.jobs) ? (answer.body.jobs as Job[]) : []);

// The phone's request, after api.ts checked the caller is in the family. The
// row is read as the caller, so it has to be theirs to see.
export async function requestJob(
  client: SupabaseClient,
  target: { pathname: string; mediaId: string },
  origin: string,
  deps: ProcessingDeps | null = realDeps(),
): Promise<{ status: number; body: Record<string, unknown> }> {
  const secret = mediaJobsSecret();
  if (!secret || !deps) return { status: 503, body: { error: "Video processing isn't configured." } };

  const { data: row, error } = await client
    .from("media_items")
    .select("id, kind, file_store, storage_path, processing")
    .eq("id", target.mediaId)
    .maybeSingle();
  if (error) {
    console.error("media process: reading the row failed:", error.message);
    return { status: 503, body: { error: "Couldn't read that video." } };
  }
  if (!row || row.storage_path !== target.pathname) {
    return { status: 404, body: { error: "That video isn't in the library." } };
  }
  if (row.kind !== "video" || row.file_store !== "blob") {
    return { status: 400, body: { error: "Only videos in Blob storage get a wall copy." } };
  }
  if (row.processing === "done" || row.processing === "failed" || row.processing === "processing") {
    return { status: 200, body: { state: row.processing } };
  }

  const claim = await deps.jobs({ action: "claim", media_id: target.mediaId, max_running: MAX_RUNNING });
  if (claim.status !== 200) {
    console.error(`media process: claim answered ${claim.status}`, claim.body.error ?? "");
    return { status: 502, body: { error: "Couldn't queue that video." } };
  }
  const [job] = jobsOf(claim);
  // No free slot (or no tries left): the sweep picks it up.
  if (!job) return { status: 200, body: { state: "queued" } };
  const started = await startJob(job, origin, secret, deps);
  return { status: 200, body: { state: started ? "processing" : "queued" } };
}

// ───────────────────────────── Reports ─────────────────────────────

type Report = {
  media_id: string;
  family_id: string;
  attempt: number;
  sandbox: string;
  token: string;
  status: "copy" | "fits" | "failed";
  width: number | null;
  height: number | null;
  poster: boolean;
  retry: boolean;
  error: string | null;
};

const dimension = (value: unknown) =>
  typeof value === "number" && Number.isInteger(value) && value >= 1 && value <= 16384 ? value : null;

export function parseReport(body: unknown): Report | null {
  if (!body || typeof body !== "object") return null;
  const b = body as Record<string, unknown>;
  const mediaId = typeof b.media_id === "string" ? b.media_id.toLowerCase() : "";
  const familyId = typeof b.family_id === "string" ? b.family_id.toLowerCase() : "";
  if (!UUID.test(mediaId) || !UUID.test(familyId)) return null;
  if (typeof b.attempt !== "number" || !Number.isInteger(b.attempt) || b.attempt < 1) return null;
  if (typeof b.sandbox !== "string" || !/^[A-Za-z0-9_-]{1,128}$/.test(b.sandbox)) return null;
  if (typeof b.token !== "string") return null;
  if (b.status !== "copy" && b.status !== "fits" && b.status !== "failed") return null;
  return {
    media_id: mediaId,
    family_id: familyId,
    attempt: b.attempt,
    sandbox: b.sandbox,
    token: b.token,
    status: b.status,
    width: dimension(b.width),
    height: dimension(b.height),
    poster: b.poster === true,
    retry: b.retry !== false,
    error: typeof b.error === "string" ? b.error.slice(0, 400) : null,
  };
}

type Settled = { state: string; transient?: boolean };

// Turns a verified report into a job outcome. Blob is asked for the copy's
// size and whether the poster arrived; the worker's word is never enough.
async function settle(report: Report, deps: ProcessingDeps): Promise<Settled> {
  const base = { media_id: report.media_id, attempt: report.attempt };
  const wall = wallPathname(report.family_id, report.media_id);
  const thumb = thumbPathname(report.family_id, report.media_id);

  if (report.status === "failed") {
    const answer = await deps.jobs({ action: "fail", ...base, error: report.error ?? "failed", retry: report.retry });
    if (answer.status >= 500) return { state: "error", transient: true };
    console.warn(`media process: ${report.media_id} attempt ${report.attempt} failed: ${report.error ?? "?"}`);
    return { state: String(answer.body.state ?? "stale") };
  }

  const thumbnail = report.poster && (await deps.size(thumb)) ? thumb : null;
  let finish: Record<string, unknown> = { action: "finish", ...base, thumbnail_path: thumbnail };
  let bytes: number | null = null;
  if (report.status === "copy") {
    bytes = await deps.size(wall);
    if (!bytes) {
      await deps.jobs({ action: "fail", ...base, error: "the copy isn't in Blob" });
      return { state: "pending" };
    }
    finish = { ...finish, path: wall, bytes, width: report.width, height: report.height };
  }

  const answer = await deps.jobs(finish);
  if (answer.status === 200) {
    console.info(
      `media process: ${report.media_id} done` + (bytes ? `, copy ${bytes} bytes` : ", it already fits") + (thumbnail ? ", poster added" : ""),
    );
    return { state: "done" };
  }
  if (answer.status >= 500) return { state: "error", transient: true };
  const refusal = String(answer.body.error ?? "");
  if (/media not found/.test(refusal)) {
    // Deleted while the job ran. Its copy and poster go too.
    await deps.remove([wall, thumb]);
    return { state: "gone" };
  }
  if (/not running/.test(refusal)) {
    // A newer attempt owns the job (and the same -wall.mp4 path): leave it.
    return { state: "stale" };
  }
  console.error(`media process: ${report.media_id} finish refused: ${refusal}`);
  if (bytes) await deps.remove([wall]);
  await deps.jobs({ action: "fail", ...base, error: refusal || "finish refused", retry: false });
  return { state: "failed" };
}

export async function handleProcessDone(request: Request, deps: ProcessingDeps | null = realDeps()): Promise<Response> {
  const secret = mediaJobsSecret();
  if (!secret || !deps) return json({ error: "Video processing isn't configured." }, 503);
  const text = await request.text();
  if (text.length > 16_384) return json({ error: "Request body too large." }, 413);
  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch {
    return json({ error: "Invalid JSON." }, 400);
  }
  const report = parseReport(body);
  if (!report) return json({ error: "That isn't a job report." }, 400);
  if (!sameText(report.token, jobToken(secret, report))) {
    console.warn("media process: a report with a bad token");
    return json({ error: "Not allowed." }, 401);
  }

  let settled: Settled;
  try {
    settled = await settle(report, deps);
  } catch (err) {
    console.error(`media process: settling ${report.media_id} failed:`, err);
    settled = { state: "error", transient: true };
  }
  // The worker tries the callback again on a 5xx, so its sandbox stays up
  // until the job is settled. Otherwise it is done with.
  if (settled.transient) return json({ error: "Couldn't record that. Try again." }, 502);
  await deps.stopSandbox(report.sandbox).catch((err) => console.warn(`media process: stopping ${report.sandbox}:`, message(err)));
  // A slot just opened: start the next waiting video now rather than at the
  // next sweep, so a backlog goes through one job after another.
  const next = await claimAndStart(1, mediaCallbackOrigin() ?? new URL(request.url).origin, secret, deps).catch((err) => {
    console.error("media process: starting the next job failed:", err);
    return 0;
  });
  return json({ ok: true, state: settled.state, started: next });
}

// Claims up to `limit` waiting videos (never more than MAX_RUNNING running)
// and starts them. Returns how many sandboxes started.
async function claimAndStart(limit: number, origin: string, secret: string, deps: ProcessingDeps): Promise<number> {
  const claim = await deps.jobs({ action: "claim", limit, max_running: MAX_RUNNING });
  if (claim.status !== 200) throw new Error(`claim answered ${claim.status}`);
  let started = 0;
  for (const job of jobsOf(claim)) {
    if (await startJob(job, origin, secret, deps)) started++;
  }
  return started;
}

// ───────────────────────────── Sweep ─────────────────────────────

// Starts what the phones didn't (older apps, a phone that went away, jobs
// that failed or went stale), then deletes originals swapped out at least
// six hours ago, once no display can still be playing them.
export async function handleProcessSweep(request: Request, deps: ProcessingDeps | null = realDeps()): Promise<Response> {
  const expected = cronSecret();
  if (!expected) return json({ error: "CRON_SECRET isn't set." }, 503);
  if (!sameText(request.headers.get("authorization") ?? "", `Bearer ${expected}`)) {
    return json({ error: "Not allowed." }, 401);
  }
  const secret = mediaJobsSecret();
  if (!secret || !deps) return json({ ok: true, skipped: "Video processing isn't configured." });
  const origin = mediaCallbackOrigin() ?? new URL(request.url).origin;

  let started = 0;
  let deleted = 0;
  try {
    started = await claimAndStart(MAX_RUNNING, origin, secret, deps);

    const due = await deps.jobs({ action: "replaced_due", limit: 100 });
    const items = Array.isArray(due.body.items) ? (due.body.items as { media_id: string; replaced_path: string }[]) : [];
    for (const item of items) {
      const parsed = parseMediaPath(item.replaced_path);
      // Only ever an original: never a poster or a wall copy.
      if (parsed && !parsed.thumb && !parsed.wall) await deps.remove([item.replaced_path]);
      await deps.jobs({ action: "replaced_cleared", media_id: item.media_id, path: item.replaced_path });
      deleted++;
    }
  } catch (err) {
    console.error("media sweep failed:", err);
    return json({ error: "The sweep failed.", started, deleted }, 502);
  }
  if (started || deleted) console.info(`media sweep: started ${started}, deleted ${deleted} originals`);
  return json({ ok: true, started, deleted });
}

// ───────────────────────────── The real thing ─────────────────────────────

async function callJobs(config: SupabaseConfig, secret: string, body: Record<string, unknown>): Promise<JobsAnswer> {
  const response = await fetch(`${config.url}/functions/v1/media-jobs`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      apikey: config.anonKey,
      authorization: `Bearer ${config.anonKey}`,
      "x-media-jobs-secret": secret,
    },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(20_000),
  });
  const data: unknown = await response.json().catch(() => ({}));
  return { status: response.status, body: data && typeof data === "object" ? (data as Record<string, unknown>) : {} };
}

/** worker.mjs, traced into the deployment by next.config.ts. */
export function workerSource(): Promise<string> {
  return readFile(path.join(process.cwd(), "lib/media/worker.mjs"), "utf8");
}

/** A fresh, non-persistent sandbox running worker.mjs on one job. Also used by scripts/media-sandbox-check.mjs. */
export async function startWorkerSandbox(
  name: string,
  job: WorkerJob | null,
  options: { timeoutMs: number; vcpus: number },
): Promise<Sandbox> {
  const worker = await workerSource();
  const sandbox = await Sandbox.create({
    name,
    persistent: false,
    timeout: options.timeoutMs,
    resources: { vcpus: options.vcpus },
    tags: { app: "ohana", job: "video" },
  });
  try {
    const files = [{ path: `${WORK_DIR}/worker.mjs`, content: worker }];
    if (job) files.push({ path: `${WORK_DIR}/job.json`, content: JSON.stringify(job) });
    await sandbox.writeFiles(files);
    if (job) {
      await sandbox.runCommand({
        cmd: "node",
        args: ["worker.mjs", "job.json"],
        cwd: WORK_DIR,
        env: mediaFfmpegEnv(),
        detached: true,
      });
    }
    return sandbox;
  } catch (err) {
    await sandbox.stop().catch(() => {});
    throw err;
  }
}

export function realDeps(): ProcessingDeps | null {
  const secret = mediaJobsSecret();
  const config = supabaseConfig();
  if (!secret || !config || !blobReady()) return null;
  return {
    jobs: (body) => callJobs(config, secret, body),
    presignPut: (pathname, contentType, maxBytes, validUntil) =>
      presignedPut(pathname, contentType, maxBytes, validUntil, true),
    presignGet: presignedGet,
    size: async (pathname) => {
      try {
        return (await head(pathname)).size;
      } catch (err) {
        if (err instanceof BlobNotFoundError) return null;
        throw err;
      }
    },
    remove: async (pathnames) => {
      try {
        if (pathnames.length > 0) await del(pathnames);
      } catch (err) {
        if (!(err instanceof BlobNotFoundError)) throw err;
      }
    },
    startSandbox: async (name, job, options) => {
      await startWorkerSandbox(name, job, options);
    },
    stopSandbox: async (name) => {
      await (await Sandbox.get({ name })).stop();
    },
  };
}
