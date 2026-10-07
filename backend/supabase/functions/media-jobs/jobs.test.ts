// Unit tests for media-jobs: `deno test media-jobs/`.

import { assert, assertEquals } from "jsr:@std/assert@1";
import { type Deps, parseAction, runAction, secretMatches } from "./jobs.ts";

const MEDIA = "0d1d0000-0000-4000-8000-000000000001";
const SECRET = "s".repeat(40);

function fake(result: { data: unknown; error: { message: string; code?: string } | null }) {
  const calls: { name: string; params: Record<string, unknown> }[] = [];
  const deps: Deps = {
    rpc: (name, params) => {
      calls.push({ name, params });
      return Promise.resolve(result);
    },
  };
  return { deps, calls };
}

Deno.test("secretMatches: only the configured secret, and only a long one", async () => {
  assert(await secretMatches(SECRET, SECRET));
  assert(!(await secretMatches(SECRET + "x", SECRET)));
  assert(!(await secretMatches("", SECRET)));
  assert(!(await secretMatches(null, SECRET)));
  assert(!(await secretMatches(SECRET, undefined)));
  assert(!(await secretMatches("short", "short")), "a short secret never matches");
});

Deno.test("claim: defaults and limits", () => {
  const call = parseAction({ action: "claim" });
  assert(!("status" in call));
  assertEquals(call.fn, "media_job_claim");
  assertEquals(call.params, { p_media_id: null, p_limit: 1, p_max_running: 2 });
  const one = parseAction({ action: "claim", media_id: MEDIA, limit: 3, max_running: 4 });
  assert(!("status" in one));
  assertEquals(one.params, { p_media_id: MEDIA, p_limit: 3, p_max_running: 4 });
  for (const body of [
    { action: "claim", media_id: "nope" },
    { action: "claim", limit: 0 },
    { action: "claim", limit: 11 },
    { action: "claim", max_running: 9 },
    { action: "claim", limit: 1.5 },
  ]) {
    const refused = parseAction(body);
    assert("status" in refused && refused.status === 400, JSON.stringify(body));
  }
});

Deno.test("finish: a copy needs its bytes; 'already fits' needs neither", () => {
  const copy = parseAction({
    action: "finish",
    media_id: MEDIA,
    attempt: 2,
    path: "f/x-wall.mp4",
    bytes: 1000,
    width: 1920,
    height: 1080,
    thumbnail_path: "f/x-thumb.jpg",
  });
  assert(!("status" in copy));
  assertEquals(copy.params, {
    p_media_id: MEDIA,
    p_attempt: 2,
    p_path: "f/x-wall.mp4",
    p_bytes: 1000,
    p_width: 1920,
    p_height: 1080,
    p_thumbnail_path: "f/x-thumb.jpg",
  });
  const fits = parseAction({ action: "finish", media_id: MEDIA, attempt: 1 });
  assert(!("status" in fits));
  assertEquals(fits.params.p_path, null);
  assertEquals(fits.params.p_bytes, null);

  const noBytes = parseAction({ action: "finish", media_id: MEDIA, attempt: 1, path: "f/x-wall.mp4" });
  assert("status" in noBytes && noBytes.status === 400);
  const badAttempt = parseAction({ action: "finish", media_id: MEDIA, attempt: 0 });
  assert("status" in badAttempt && badAttempt.status === 400);
  const badBytes = parseAction({ action: "finish", media_id: MEDIA, attempt: 1, path: "p", bytes: -1 });
  assert("status" in badBytes && badBytes.status === 400);
});

Deno.test("fail: retries unless told not to; the reason is kept short", () => {
  const retry = parseAction({ action: "fail", media_id: MEDIA, attempt: 1, error: "x".repeat(900) });
  assert(!("status" in retry));
  assertEquals(retry.params.p_retry, true);
  assertEquals((retry.params.p_error as string).length, 500);
  const final = parseAction({ action: "fail", media_id: MEDIA, attempt: 1, error: "", retry: false });
  assert(!("status" in final));
  assertEquals(final.params, { p_media_id: MEDIA, p_attempt: 1, p_error: "failed", p_retry: false });
});

Deno.test("unknown actions and bodies are 400", () => {
  for (const body of [null, "claim", { action: "drop_table" }, { action: "replaced_cleared", media_id: MEDIA }]) {
    const refused = parseAction(body);
    assert("status" in refused && refused.status === 400, JSON.stringify(body));
  }
});

Deno.test("runAction: shapes the answer", async () => {
  const claimed = fake({ data: [{ media_id: MEDIA, attempt: 1 }], error: null });
  assertEquals(await runAction(claimed.deps, { action: "claim", media_id: MEDIA }), {
    status: 200,
    body: { jobs: [{ media_id: MEDIA, attempt: 1 }] },
  });
  assertEquals(claimed.calls[0].name, "media_job_claim");

  const failed = fake({ data: "pending", error: null });
  assertEquals((await runAction(failed.deps, { action: "fail", media_id: MEDIA, attempt: 1, error: "x" })).body, {
    state: "pending",
  });

  const due = fake({ data: null, error: null });
  assertEquals((await runAction(due.deps, { action: "replaced_due" })).body, { items: [] });

  const cleared = fake({ data: true, error: null });
  assertEquals(
    (await runAction(cleared.deps, { action: "replaced_cleared", media_id: MEDIA, path: "f/x.mov" })).body,
    { cleared: true },
  );
});

Deno.test("runAction: a refusal is 409 with its message; anything else is 500", async () => {
  const refused = fake({ data: null, error: { code: "P0001", message: "that job is not running" } });
  assertEquals(await runAction(refused.deps, { action: "finish", media_id: MEDIA, attempt: 1 }), {
    status: 409,
    body: { error: "that job is not running" },
  });
  const broken = fake({ data: null, error: { code: "42883", message: "function does not exist" } });
  const errors: unknown[] = [];
  const original = console.error;
  console.error = (...args: unknown[]) => errors.push(args);
  try {
    assertEquals((await runAction(broken.deps, { action: "claim" })).status, 500);
  } finally {
    console.error = original;
  }
  assertEquals(errors.length, 1);
});

Deno.test("a bad request never reaches the database", async () => {
  const untouched = fake({ data: null, error: null });
  assertEquals((await runAction(untouched.deps, { action: "claim", limit: 99 })).status, 400);
  assertEquals(untouched.calls.length, 0);
});
