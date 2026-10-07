// POST /api/account/delete against a local stand-in for the delete-account
// edge function. Pins what the iOS app (FamilyStore.deleteAccount) sends and
// reads, and that a deleted family's Blob files are removed.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { after, before, beforeEach, test } from "node:test";
import { handleAccountDelete } from "../lib/account.ts";

const FAMILY = "00000000-0000-4000-8000-00000000f001";
const GOOD_TOKEN = "good-token";

let server;
let reply;
const seen = [];

before(async () => {
  server = createServer(async (req, res) => {
    let raw = "";
    for await (const chunk of req) raw += chunk;
    seen.push({ method: req.method, url: req.url, auth: req.headers.authorization, apikey: req.headers.apikey, body: raw });
    if (req.headers.authorization !== `Bearer ${GOOD_TOKEN}`) {
      res.writeHead(401, { "content-type": "application/json" });
      return res.end(JSON.stringify({ error: "sign in required" }));
    }
    res.writeHead(reply.status, { "content-type": "application/json" });
    res.end(typeof reply.body === "string" ? reply.body : JSON.stringify(reply.body));
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  process.env.NEXT_PUBLIC_SUPABASE_URL = `http://127.0.0.1:${server.address().port}/`;
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY = "anon-key";
});

after(() => new Promise((resolve) => server.close(resolve)));

beforeEach((t) => {
  seen.length = 0;
  reply = { status: 200, body: { ok: true, families_deleted: [] } };
  t.mock.method(console, "info", () => {});
  t.mock.method(console, "warn", () => {});
});

function post(token = GOOD_TOKEN) {
  const headers = { "content-type": "application/json" };
  if (token) headers.authorization = `Bearer ${token}`;
  return new Request("https://admin.example/api/account/delete", { method: "POST", headers, body: "{}" });
}

function recorder(fail = false) {
  const removed = [];
  const fn = async (id) => {
    removed.push(id);
    if (fail) throw new Error("blob down");
  };
  return { fn, removed };
}

test("forwards the caller's JWT to delete-account and answers ok", async () => {
  const blobs = recorder();
  const response = await handleAccountDelete(post(), blobs.fn);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true, families_deleted: [] });
  assert.deepEqual(seen, [{
    method: "POST", url: "/functions/v1/delete-account", auth: `Bearer ${GOOD_TOKEN}`, apikey: "anon-key", body: "{}",
  }]);
  assert.deepEqual(blobs.removed, []);
});

test("a family that went with the account loses its Blob files", async () => {
  reply = { status: 200, body: { ok: true, families_deleted: [FAMILY, "not-a-uuid", 5] } };
  const blobs = recorder();
  const response = await handleAccountDelete(post(), blobs.fn);
  assert.deepEqual(await response.json(), { ok: true, families_deleted: [FAMILY] });
  assert.deepEqual(blobs.removed, [FAMILY]);
});

test("a Blob failure doesn't undo the deletion", async (t) => {
  t.mock.method(console, "error", () => {});
  reply = { status: 200, body: { ok: true, families_deleted: [FAMILY] } };
  const response = await handleAccountDelete(post(), recorder(true).fn);
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true, families_deleted: [FAMILY], files_left: true });
});

test("the edge function's refusals pass through with their status", async () => {
  reply = { status: 400, body: { error: "you're the only parent with a login in Home. Make someone else there a parent first" } };
  const response = await handleAccountDelete(post(), recorder().fn);
  assert.equal(response.status, 400);
  assert.deepEqual(await response.json(), {
    error: "you're the only parent with a login in Home. Make someone else there a parent first",
  });
});

test("a 502 after the rows went still clears that family's Blob files", async () => {
  reply = { status: 502, body: { error: "your data is deleted, but your login couldn't be removed yet; try again in a moment", families_deleted: [FAMILY] } };
  const blobs = recorder();
  const response = await handleAccountDelete(post(), blobs.fn);
  assert.equal(response.status, 502);
  assert.deepEqual(blobs.removed, [FAMILY]);
});

test("no token, a bad token, or a non-JSON answer", async () => {
  const unsigned = await handleAccountDelete(post(null), recorder().fn);
  assert.equal(unsigned.status, 401);
  assert.deepEqual(await unsigned.json(), { error: "Sign in required." });
  assert.equal(seen.length, 0, "nothing is forwarded without a token");

  const badToken = await handleAccountDelete(post("expired"), recorder().fn);
  assert.equal(badToken.status, 401);
  assert.deepEqual(await badToken.json(), { error: "sign in required" });

  reply = { status: 504, body: "<html>gateway timeout</html>" };
  const html = await handleAccountDelete(post(), recorder().fn);
  assert.equal(html.status, 504);
  assert.deepEqual(await html.json(), { error: "Account deletion failed (HTTP 504)." });
});
