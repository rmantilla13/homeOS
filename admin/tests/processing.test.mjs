// Wall-copy jobs (lib/media/processing.ts and /api/media/process): starting a
// sandbox, the sandbox's report, and the cron sweep, with stand-ins for the
// media-jobs function, Blob and the sandbox. The phone's request also goes
// through a local stand-in for Supabase (auth, membership, the row).
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { after, afterEach, before, beforeEach, test } from "node:test";
import { handleMediaProcess } from "../lib/media/api.ts";
import {
  MAX_RUNNING,
  SLACK_BYTES,
  realDeps,
  handleProcessDone,
  handleProcessSweep,
  jobToken,
  parseReport,
  sandboxName,
  sandboxTimeoutMs,
  startJob,
} from "../lib/media/processing.ts";

const FAMILY = "00000000-0000-4000-8000-00000000f001";
const OTHER_FAMILY = "00000000-0000-4000-8000-00000000f002";
const MEDIA = "11111111-1111-4111-8111-111111111111";
const USER = "22222222-2222-4222-8222-222222222222";
const SECRET = "x".repeat(48);
const GOOD_TOKEN = "good-token";
const WALL = `${FAMILY}/${MEDIA}-wall.mp4`;
const THUMB = `${FAMILY}/${MEDIA}-thumb.jpg`;

const job = (overrides = {}) => ({
  media_id: MEDIA,
  family_id: FAMILY,
  storage_path: `${FAMILY}/${MEDIA}.mov`,
  thumbnail_path: null,
  byte_size: 500_000_000,
  content_type: "video/quicktime",
  attempt: 1,
  ...overrides,
});

// Records every call; `answers` decides what media-jobs says.
function fakeDeps({ answers = {}, blob = {}, startFails = false } = {}) {
  const calls = { jobs: [], puts: [], gets: [], removed: [], started: [], stopped: [] };
  const deps = {
    jobs: async (body) => {
      calls.jobs.push(body);
      const answer = answers[body.action];
      if (typeof answer === "function") return answer(body);
      return answer ?? { status: 200, body: {} };
    },
    presignPut: async (pathname, contentType, maxBytes) => {
      calls.puts.push({ pathname, contentType, maxBytes });
      return `https://blob.example/put/${pathname}`;
    },
    presignGet: async (pathname) => {
      calls.gets.push(pathname);
      return `https://blob.example/get/${pathname}`;
    },
    size: async (pathname) => blob[pathname] ?? null,
    remove: async (pathnames) => {
      calls.removed.push(...pathnames);
    },
    startSandbox: async (name, workerJob, options) => {
      if (startFails) throw new Error("no capacity");
      calls.started.push({ name, workerJob, options });
    },
    stopSandbox: async (name) => {
      calls.stopped.push(name);
    },
  };
  return { deps, calls };
}

const saved = {};
const ENV = ["MEDIA_JOBS_SECRET", "CRON_SECRET", "MEDIA_CALLBACK_ORIGIN", "VERCEL_PROJECT_PRODUCTION_URL", "MEDIA_SANDBOX_VCPUS"];
beforeEach(() => {
  for (const name of ENV) saved[name] = process.env[name];
  process.env.MEDIA_JOBS_SECRET = SECRET;
  process.env.CRON_SECRET = "cron-secret";
  delete process.env.MEDIA_CALLBACK_ORIGIN;
  delete process.env.VERCEL_PROJECT_PRODUCTION_URL;
  delete process.env.MEDIA_SANDBOX_VCPUS;
});
afterEach(() => {
  for (const name of ENV) {
    if (saved[name] === undefined) delete process.env[name];
    else process.env[name] = saved[name];
  }
});

function report(overrides = {}) {
  const body = { media_id: MEDIA, family_id: FAMILY, attempt: 1, sandbox: "ohana-video-11111111-1-abcdef", status: "copy", ...overrides };
  return { ...body, token: overrides.token ?? jobToken(SECRET, body) };
}

const done = (body) =>
  new Request("https://ohanaos.co/api/media/process/done", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: typeof body === "string" ? body : JSON.stringify(body),
  });

// ───────────────────────────── Helpers ─────────────────────────────

test("a token names one attempt in one sandbox", () => {
  const a = jobToken(SECRET, { media_id: MEDIA, family_id: FAMILY, attempt: 1, sandbox: "s" });
  assert.match(a, /^[0-9a-f]{64}$/);
  assert.equal(a, jobToken(SECRET, { media_id: MEDIA, family_id: FAMILY, attempt: 1, sandbox: "s" }));
  assert.notEqual(a, jobToken(SECRET, { media_id: MEDIA, family_id: FAMILY, attempt: 2, sandbox: "s" }));
  assert.notEqual(a, jobToken(SECRET, { media_id: MEDIA, family_id: FAMILY, attempt: 1, sandbox: "t" }));
  assert.notEqual(a, jobToken("y".repeat(48), { media_id: MEDIA, family_id: FAMILY, attempt: 1, sandbox: "s" }));
});

test("sandbox names and timeouts", () => {
  assert.match(sandboxName({ media_id: MEDIA, attempt: 3 }), /^ohana-video-11111111-3-[0-9a-f]{6}$/);
  assert.equal(sandboxTimeoutMs(500_000_000), 19 * 60_000, "about 1 s per MB on top of 10 minutes");
  assert.equal(sandboxTimeoutMs(10_000), 11 * 60_000);
  assert.equal(sandboxTimeoutMs(5_000_000_000), 55 * 60_000, "under the hour after which a job is stale");
  assert.equal(sandboxTimeoutMs(null), 46 * 60_000, "an unknown size is treated as the 2 GiB cap");
});

test("parseReport keeps only what it understands", () => {
  const parsed = parseReport({ ...report({ width: 1920, height: 99999, poster: "yes", error: "e".repeat(900) }) });
  assert.equal(parsed.width, 1920);
  assert.equal(parsed.height, null);
  assert.equal(parsed.poster, false, "only true counts");
  assert.equal(parsed.retry, true);
  assert.equal(parsed.error.length, 400);
  for (const bad of [null, {}, report({ status: "maybe" }), report({ attempt: 0 }), report({ media_id: "x" }), report({ sandbox: "a b" })]) {
    assert.equal(parseReport(bad), null, JSON.stringify(bad));
  }
});

// ───────────────────────────── Starting ─────────────────────────────

test("startJob signs only this video's URLs and hands the worker its job", async (t) => {
  t.mock.method(console, "info", () => {});
  process.env.MEDIA_SANDBOX_VCPUS = "4";
  const { deps, calls } = fakeDeps();
  assert.equal(await startJob(job(), "https://ohanaos.co", SECRET, deps), true);
  assert.deepEqual(calls.gets, [`${FAMILY}/${MEDIA}.mov`]);
  assert.deepEqual(calls.puts, [
    { pathname: WALL, contentType: "video/mp4", maxBytes: 500_000_000 + SLACK_BYTES },
    { pathname: THUMB, contentType: "image/jpeg", maxBytes: 256 * 1024 },
  ]);
  assert.equal(calls.started.length, 1);
  const { name, workerJob, options } = calls.started[0];
  assert.equal(workerJob.sandbox, name);
  assert.equal(workerJob.callback_url, "https://ohanaos.co/api/media/process/done");
  assert.equal(workerJob.source_ext, "mov");
  assert.equal(workerJob.max_bytes, 500_000_000 + SLACK_BYTES);
  assert.equal(workerJob.poster_url, `https://blob.example/put/${THUMB}`);
  assert.equal(workerJob.token, jobToken(SECRET, { media_id: MEDIA, family_id: FAMILY, attempt: 1, sandbox: name }));
  assert.deepEqual(options, { timeoutMs: 19 * 60_000, vcpus: 4 });
  assert.equal(calls.jobs.length, 0);
});

test("a row with a poster gets no poster URL", async (t) => {
  t.mock.method(console, "info", () => {});
  const { deps, calls } = fakeDeps();
  await startJob(job({ thumbnail_path: THUMB }), "https://ohanaos.co", SECRET, deps);
  assert.deepEqual(calls.puts.map((p) => p.pathname), [WALL]);
  assert.equal(calls.started[0].workerJob.poster_url, null);
  assert.equal(calls.started[0].options.vcpus, 8, "8 vCPUs by default");
});

test("a sandbox that won't start gives the job back for another try", async (t) => {
  t.mock.method(console, "error", () => {});
  const { deps, calls } = fakeDeps({ startFails: true });
  assert.equal(await startJob(job({ attempt: 2 }), "https://ohanaos.co", SECRET, deps), false);
  assert.deepEqual(calls.jobs, [{ action: "fail", media_id: MEDIA, attempt: 2, error: "couldn't start: no capacity" }]);
});

// ───────────────────────────── Reports ─────────────────────────────

test("a copy is recorded at the size Blob reports, not the worker's", async (t) => {
  t.mock.method(console, "info", () => {});
  const { deps, calls } = fakeDeps({ blob: { [WALL]: 42_000_000, [THUMB]: 40_000 } });
  const response = await handleProcessDone(done(report({ width: 1920, height: 1080, poster: true, bytes: 1 })), deps);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true, state: "done", started: 0 });
  assert.deepEqual(calls.jobs[0], {
    action: "finish", media_id: MEDIA, attempt: 1, thumbnail_path: THUMB,
    path: WALL, bytes: 42_000_000, width: 1920, height: 1080,
  });
  assert.deepEqual(calls.stopped, ["ohana-video-11111111-1-abcdef"], "the sandbox is stopped");
  assert.deepEqual(calls.jobs[1], { action: "claim", limit: 1, max_running: MAX_RUNNING }, "then the next waiting video is claimed");
});

test("a finished job starts the next waiting video straight away", async (t) => {
  t.mock.method(console, "info", () => {});
  const next = job({ media_id: "55555555-5555-4555-8555-555555555555", storage_path: `${FAMILY}/55555555-5555-4555-8555-555555555555.mov` });
  const { deps, calls } = fakeDeps({
    blob: { [WALL]: 42_000_000 },
    answers: { claim: { status: 200, body: { jobs: [next] } } },
  });
  const response = await handleProcessDone(done(report()), deps);
  assert.deepEqual(await response.json(), { ok: true, state: "done", started: 1 });
  assert.equal(calls.started.length, 1);
  assert.equal(calls.started[0].workerJob.media_id, next.media_id);
});

test("a poster the worker claims but Blob doesn't have isn't recorded", async (t) => {
  t.mock.method(console, "info", () => {});
  const { deps, calls } = fakeDeps({ blob: { [WALL]: 42_000_000 } });
  await handleProcessDone(done(report({ poster: true })), deps);
  assert.equal(calls.jobs[0].thumbnail_path, null);
});

test("a video that already fits is finished without a path", async (t) => {
  t.mock.method(console, "info", () => {});
  const { deps, calls } = fakeDeps({ blob: { [THUMB]: 40_000 } });
  const response = await handleProcessDone(done(report({ status: "fits", poster: true })), deps);
  assert.equal(response.status, 200);
  assert.deepEqual(calls.jobs[0], { action: "finish", media_id: MEDIA, attempt: 1, thumbnail_path: THUMB });
});

test("a failure is handed back, with or without another try", async (t) => {
  t.mock.method(console, "warn", () => {});
  const { deps, calls } = fakeDeps({ answers: { fail: { status: 200, body: { state: "failed" } } } });
  const response = await handleProcessDone(done(report({ status: "failed", retry: false, error: "the file has no video stream" })), deps);
  assert.deepEqual(await response.json(), { ok: true, state: "failed", started: 0 });
  assert.deepEqual(calls.jobs[0], { action: "fail", media_id: MEDIA, attempt: 1, error: "the file has no video stream", retry: false });
  assert.equal(calls.stopped.length, 1);
});

test("a copy that never reached Blob goes back to pending", async () => {
  const { deps, calls } = fakeDeps();
  const response = await handleProcessDone(done(report()), deps);
  assert.deepEqual(await response.json(), { ok: true, state: "pending", started: 0 });
  assert.deepEqual(calls.jobs[0], { action: "fail", media_id: MEDIA, attempt: 1, error: "the copy isn't in Blob" });
});

test("refusals: a deleted row takes its copy, a stale attempt leaves it, anything else fails the job", async (t) => {
  const error = t.mock.method(console, "error", () => {});
  const refusing = (message) => ({ answers: { finish: { status: 409, body: { error: message } } }, blob: { [WALL]: 9 } });

  const gone = fakeDeps(refusing("media not found"));
  assert.deepEqual(await (await handleProcessDone(done(report()), gone.deps)).json(), { ok: true, state: "gone", started: 0 });
  assert.deepEqual(gone.calls.removed, [WALL, THUMB]);

  const stale = fakeDeps(refusing("that job is not running"));
  assert.deepEqual(await (await handleProcessDone(done(report()), stale.deps)).json(), { ok: true, state: "stale", started: 0 });
  assert.deepEqual(stale.calls.removed, [], "a newer attempt writes the same path");

  const bigger = fakeDeps(refusing("the copy can't be bigger than the original"));
  assert.deepEqual(await (await handleProcessDone(done(report()), bigger.deps)).json(), { ok: true, state: "failed", started: 0 });
  assert.deepEqual(bigger.calls.removed, [WALL]);
  assert.deepEqual(bigger.calls.jobs.find((call) => call.action === "fail"), {
    action: "fail", media_id: MEDIA, attempt: 1, error: "the copy can't be bigger than the original", retry: false,
  });
  assert.equal(error.mock.callCount(), 1);
});

test("when media-jobs is down the worker is told to try again and its sandbox stays up", async (t) => {
  t.mock.method(console, "error", () => {});
  const { deps, calls } = fakeDeps({ answers: { finish: { status: 503, body: {} } }, blob: { [WALL]: 9 } });
  const response = await handleProcessDone(done(report()), deps);
  assert.equal(response.status, 502);
  assert.deepEqual(calls.stopped, []);
});

test("reports need the right token, a body that parses, and processing set up", async (t) => {
  t.mock.method(console, "warn", () => {});
  const { deps, calls } = fakeDeps();
  assert.equal((await handleProcessDone(done(report({ token: "0".repeat(64) })), deps)).status, 401);
  const forged = report();
  assert.equal((await handleProcessDone(done({ ...forged, attempt: 2 }), deps)).status, 401, "the token covers the attempt");
  assert.equal((await handleProcessDone(done({ ...forged, family_id: OTHER_FAMILY }), deps)).status, 401, "and the family");
  assert.equal((await handleProcessDone(done("{nope"), deps)).status, 400);
  assert.equal((await handleProcessDone(done({ hello: 1 }), deps)).status, 400);
  assert.equal(calls.jobs.length, 0, "none of them reached media-jobs");

  delete process.env.MEDIA_JOBS_SECRET;
  assert.equal((await handleProcessDone(done(report()), deps)).status, 503);
  process.env.MEDIA_JOBS_SECRET = "too-short";
  assert.equal((await handleProcessDone(done(report()), deps)).status, 503, "a short secret counts as unset");
});

// ───────────────────────────── Sweep ─────────────────────────────

const sweep = (auth = "Bearer cron-secret") =>
  new Request("https://homeos-admin.vercel.app/api/media/process/sweep", { headers: auth ? { authorization: auth } : {} });

test("the sweep starts claimed jobs and deletes originals that are due", async (t) => {
  t.mock.method(console, "info", () => {});
  process.env.VERCEL_PROJECT_PRODUCTION_URL = "ohanaos.co";
  const due = [
    { media_id: MEDIA, replaced_path: `${FAMILY}/${MEDIA}.mov` },
    { media_id: "33333333-3333-4333-8333-333333333333", replaced_path: `${FAMILY}/33333333-3333-4333-8333-333333333333-wall.mp4` },
  ];
  const { deps, calls } = fakeDeps({
    answers: {
      claim: { status: 200, body: { jobs: [job(), job({ media_id: "44444444-4444-4444-8444-444444444444", attempt: 2 })] } },
      replaced_due: { status: 200, body: { items: due } },
    },
  });
  const response = await handleProcessSweep(sweep(), deps);
  assert.deepEqual(await response.json(), { ok: true, started: 2, deleted: 2 });
  assert.deepEqual(calls.jobs[0], { action: "claim", limit: MAX_RUNNING, max_running: MAX_RUNNING });
  assert.equal(calls.started.length, 2);
  assert.equal(calls.started[0].workerJob.callback_url, "https://ohanaos.co/api/media/process/done", "the production domain, not *.vercel.app");
  assert.deepEqual(calls.removed, [`${FAMILY}/${MEDIA}.mov`], "never a wall copy, even if one were listed");
  assert.deepEqual(
    calls.jobs.filter((call) => call.action === "replaced_cleared").map((call) => call.path),
    due.map((item) => item.replaced_path),
  );
});

test("the sweep needs CRON_SECRET, and does nothing until processing is set up", async () => {
  const { deps, calls } = fakeDeps();
  assert.equal((await handleProcessSweep(sweep(null), deps)).status, 401);
  assert.equal((await handleProcessSweep(sweep("Bearer wrong"), deps)).status, 401);
  delete process.env.CRON_SECRET;
  assert.equal((await handleProcessSweep(sweep(), deps)).status, 503);
  process.env.CRON_SECRET = "cron-secret";
  delete process.env.MEDIA_JOBS_SECRET;
  const skipped = await handleProcessSweep(sweep(), deps);
  assert.equal(skipped.status, 200);
  assert.equal((await skipped.json()).skipped, "Video processing isn't configured.");
  assert.equal(calls.jobs.length, 0);
});

// ───────────────────────────── The phone's request ─────────────────────────────

const rows = new Map();
const jobCalls = [];
let server;
before(async () => {
  server = createServer(async (req, res) => {
    const send = (status, body) => {
      res.writeHead(status, { "content-type": "application/json" });
      res.end(JSON.stringify(body));
    };
    let raw = "";
    for await (const chunk of req) raw += chunk;
    const url = new URL(req.url, "http://stub");
    if (req.method === "GET" && url.pathname === "/auth/v1/user") {
      if (req.headers.authorization !== `Bearer ${GOOD_TOKEN}`) return send(401, { code: 401, msg: "invalid JWT" });
      return send(200, { id: USER, aud: "authenticated", role: "authenticated" });
    }
    if (req.method === "POST" && url.pathname === "/rest/v1/rpc/is_family_member") {
      return send(200, JSON.parse(raw).fid === FAMILY);
    }
    if (req.method === "POST" && url.pathname === "/functions/v1/media-jobs") {
      jobCalls.push({ body: JSON.parse(raw), secret: req.headers["x-media-jobs-secret"], apikey: req.headers.apikey });
      return send(200, { jobs: [] });
    }
    if (req.method === "GET" && url.pathname === "/rest/v1/media_items") {
      const id = (url.searchParams.get("id") ?? "").replace(/^eq\./, "");
      const row = rows.get(id);
      return send(200, row ? [row] : []);
    }
    send(404, { error: `stub has no ${req.method} ${url.pathname}` });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  process.env.NEXT_PUBLIC_SUPABASE_URL = `http://127.0.0.1:${server.address().port}`;
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY = "anon-key";
});
after(() => new Promise((resolve) => server.close(resolve)));

const ask = (pathname, token = GOOD_TOKEN) =>
  new Request("https://ohanaos.co/api/media/process", {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
    body: JSON.stringify({ pathname }),
  });

const row = (overrides = {}) => ({
  id: MEDIA,
  kind: "video",
  file_store: "blob",
  storage_path: `${FAMILY}/${MEDIA}.mov`,
  processing: "pending",
  ...overrides,
});

test("the phone's request claims its video and starts a sandbox", async (t) => {
  t.mock.method(console, "info", () => {});
  rows.set(MEDIA, row());
  t.after(() => rows.clear());
  const { deps, calls } = fakeDeps({ answers: { claim: { status: 200, body: { jobs: [job()] } } } });
  const response = await handleMediaProcess(ask(`${FAMILY}/${MEDIA}.mov`), deps);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { state: "processing" });
  assert.deepEqual(calls.jobs[0], { action: "claim", media_id: MEDIA, max_running: MAX_RUNNING });
  assert.equal(calls.started.length, 1);
  assert.equal(calls.started[0].workerJob.callback_url, "https://ohanaos.co/api/media/process/done");
});

test("no free slot: the sweep will do it", async (t) => {
  rows.set(MEDIA, row({ processing: null }));
  t.after(() => rows.clear());
  const { deps, calls } = fakeDeps({ answers: { claim: { status: 200, body: { jobs: [] } } } });
  assert.deepEqual(await (await handleMediaProcess(ask(`${FAMILY}/${MEDIA}.mov`), deps)).json(), { state: "queued" });
  assert.equal(calls.started.length, 0);
});

test("a video that is done, running or failed is only reported", async (t) => {
  t.after(() => rows.clear());
  for (const state of ["done", "processing", "failed"]) {
    rows.set(MEDIA, row({ processing: state }));
    const { deps, calls } = fakeDeps();
    assert.deepEqual(await (await handleMediaProcess(ask(`${FAMILY}/${MEDIA}.mov`), deps)).json(), { state });
    assert.equal(calls.jobs.length, 0, state);
  }
});

test("the phone's request is refused for anything that isn't its own Blob video", async (t) => {
  t.mock.method(console, "warn", () => {});
  t.after(() => rows.clear());
  const { deps, calls } = fakeDeps();
  assert.equal((await handleMediaProcess(ask(`${FAMILY}/${MEDIA}.jpg`), deps)).status, 400, "a photo path");
  assert.equal((await handleMediaProcess(ask(`${FAMILY}/${MEDIA}.mov`, "bad"), deps)).status, 401);
  assert.equal((await handleMediaProcess(ask(`${OTHER_FAMILY}/${MEDIA}.mov`), deps)).status, 403);
  assert.equal((await handleMediaProcess(ask(`${FAMILY}/${MEDIA}.mov`), deps)).status, 404, "no such row");
  rows.set(MEDIA, row({ storage_path: `${FAMILY}/${MEDIA}-wall.mp4` }));
  assert.equal((await handleMediaProcess(ask(`${FAMILY}/${MEDIA}.mov`), deps)).status, 404, "the row moved on already");
  rows.set(MEDIA, row({ file_store: "supabase" }));
  assert.equal((await handleMediaProcess(ask(`${FAMILY}/${MEDIA}.mov`), deps)).status, 400, "a file still in Storage");
  assert.equal(calls.jobs.length, 0);

  rows.set(MEDIA, row());
  assert.equal((await handleMediaProcess(ask(`${FAMILY}/${MEDIA}.mov`), null)).status, 503, "not set up");
});

test("the real client calls media-jobs with the secret, and only when everything is set up", async (t) => {
  const savedToken = process.env.BLOB_READ_WRITE_TOKEN;
  t.after(() => {
    if (savedToken === undefined) delete process.env.BLOB_READ_WRITE_TOKEN;
    else process.env.BLOB_READ_WRITE_TOKEN = savedToken;
  });
  delete process.env.BLOB_READ_WRITE_TOKEN;
  assert.equal(realDeps(), null, "no Blob store");
  process.env.BLOB_READ_WRITE_TOKEN = "vercel_blob_rw_store_secret";
  const deps = realDeps();
  assert.ok(deps);
  assert.deepEqual(await deps.jobs({ action: "claim" }), { status: 200, body: { jobs: [] } });
  assert.deepEqual(jobCalls.at(-1), { body: { action: "claim" }, secret: SECRET, apikey: "anon-key" });
  delete process.env.MEDIA_JOBS_SECRET;
  assert.equal(realDeps(), null, "no secret");
});
