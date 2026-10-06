// Unit tests for the shared HTTP helpers: `deno test _shared/`.

import { assertEquals } from "jsr:@std/assert@1";
import { bearerToken, corsHeaders, isUuid, json, preflight } from "./http.ts";

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
