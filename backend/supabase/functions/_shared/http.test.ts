// Unit tests for the shared HTTP helpers: `deno test _shared/`.

import { assertEquals } from "jsr:@std/assert@1";
import { authenticate, bearerToken, corsHeaders, isUuid, json, MAX_BODY_BYTES, preflight, readJson } from "./http.ts";

Deno.test("preflight and json carry the CORS headers", async () => {
  for (const res of [preflight(), json({ ok: true }, 201)]) {
    assertEquals(res.headers.get("Access-Control-Allow-Origin"), "*");
    assertEquals(res.headers.get("Access-Control-Allow-Headers"), "authorization, apikey, content-type, x-client-info");
    assertEquals(res.headers.get("Access-Control-Allow-Methods"), "POST, OPTIONS");
  }
  const res = json({ error: "nope" }, 403);
  assertEquals(res.status, 403);
  assertEquals(res.headers.get("Content-Type"), "application/json");
  assertEquals(await res.json(), { error: "nope" });
  assertEquals(Object.keys(corsHeaders).length, 3);
});

Deno.test("bearerToken", () => {
  const req = (auth?: string) => new Request("http://x", auth ? { headers: { Authorization: auth } } : {});
  assertEquals(bearerToken(req("Bearer abc.def.ghi")), "abc.def.ghi");
  assertEquals(bearerToken(req("bearer abc")), "abc");
  assertEquals(bearerToken(req("Basic abc")), null);
  assertEquals(bearerToken(req("Bearer ")), null);
  assertEquals(bearerToken(req()), null);
});

Deno.test("isUuid", () => {
  assertEquals(isUuid("0b6f3a52-1c1e-4d7e-9b1a-2f0c8e9d7a61"), true);
  assertEquals(isUuid("0B6F3A52-1C1E-4D7E-9B1A-2F0C8E9D7A61"), true);
  assertEquals(isUuid("0b6f3a52-1c1e-4d7e-9b1a"), false);
  assertEquals(isUuid(42), false);
});

Deno.test("readJson: parses bodies up to the cap", async () => {
  const post = (body: BodyInit) => new Request("http://x", { method: "POST", body });
  assertEquals(await readJson(post('{"a":1}')), { body: { a: 1 } });
  assertEquals(await readJson(post("null")), { body: null });
  const exact = JSON.stringify("x".repeat(MAX_BODY_BYTES - 2));
  assertEquals(exact.length, MAX_BODY_BYTES);
  const r = await readJson(post(exact));
  assertEquals("body" in r && (r.body as string).length, MAX_BODY_BYTES - 2);
});

Deno.test("readJson: 413 over the cap (declared or streamed), 400 for bad JSON", async () => {
  const check = async (req: Request, status: number) => {
    const r = await readJson(req, 16);
    if (!("error" in r)) throw new Error("expected an error response");
    assertEquals(r.error.status, status);
    assertEquals(r.error.headers.get("Access-Control-Allow-Origin"), "*");
  };
  await check(new Request("http://x", { method: "POST", body: "x".repeat(17) }), 413);
  // No Content-Length: the stream itself is cut off at the cap.
  const chunks = new ReadableStream<Uint8Array>({
    start(c) {
      for (let i = 0; i < 4; i++) c.enqueue(new TextEncoder().encode('"abcdefgh'));
      c.close();
    },
  });
  await check(new Request("http://x", { method: "POST", body: chunks }), 413);
  await check(new Request("http://x", { method: "POST", body: "not json" }), 400);
  await check(new Request("http://x", { method: "POST" }), 400);
});

Deno.test("authenticate: a user, a bad token (401) and an Auth outage (503)", async () => {
  const client = (data: { user: { id: string } | null }, error: { status?: number } | null) => ({
    auth: { getUser: () => Promise.resolve({ data, error }) },
  });
  assertEquals(await authenticate(client({ user: { id: "u1" } }, null), "t"), { user: { id: "u1" } });
  for (const [error, status] of [
    [{ status: 401 }, 401], [{ status: 403 }, 401], [null, 401],
    [{ status: 500 }, 503], [{ status: 503 }, 503], [{ status: 0 }, 503], [{}, 503],
  ] as const) {
    const r = await authenticate(client({ user: null }, error), "t");
    if (!("error" in r)) throw new Error("expected an error response");
    assertEquals(r.error.status, status, JSON.stringify(error));
    assertEquals(r.error.headers.get("Access-Control-Allow-Origin"), "*");
  }
});
