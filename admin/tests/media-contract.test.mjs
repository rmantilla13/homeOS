// The media routes against a local stand-in for Supabase (auth + the
// is_family_member RPC) and the Blob control API, through the real
// @vercel/blob SDK. Pins the request and response fields the iOS app
// (FamilyStore.uploadToBlob, signedURL) and the display read.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { after, before, test } from "node:test";
import { handleMediaUpload, handleMediaUrls } from "../lib/media/api.ts";
import { blobReady } from "../lib/env.ts";

const FAMILY = "00000000-0000-4000-8000-00000000f001";
const OTHER_FAMILY = "00000000-0000-4000-8000-00000000f002";
const MEDIA = "11111111-1111-4111-8111-111111111111";
const USER = "22222222-2222-4222-8222-222222222222";
const GOOD_TOKEN = "good-token";
const STORE = "teststore";

const seen = { signedTokens: [], rpcs: [] };
let server;
let origin;

function send(res, status, body) {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
}

function base64url(text) {
  return Buffer.from(text).toString("base64").replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

before(async () => {
  server = createServer(async (req, res) => {
    let raw = "";
    for await (const chunk of req) raw += chunk;
    const body = raw ? JSON.parse(raw) : null;
    if (req.method === "GET" && req.url === "/auth/v1/user") {
      if (req.headers.authorization !== `Bearer ${GOOD_TOKEN}`) {
        return send(res, 401, { code: 401, error_code: "bad_jwt", msg: "invalid JWT" });
      }
      return send(res, 200, { id: USER, aud: "authenticated", role: "authenticated", email: "parent@example.com" });
    }
    if (req.method === "POST" && req.url === "/rest/v1/rpc/is_family_member") {
      seen.rpcs.push({ body, auth: req.headers.authorization });
      return send(res, 200, body?.fid === FAMILY);
    }
    if (req.method === "POST" && req.url === "/blob/signed-token") {
      seen.signedTokens.push(body);
      const payload = { storeId: STORE, ...body };
      return send(res, 200, {
        delegationToken: `${base64url(JSON.stringify(payload))}.stub-hmac`,
        clientSigningToken: "stub-signing-key",
        validUntil: body.validUntil,
      });
    }
    send(res, 404, { error: `stub has no ${req.method} ${req.url}` });
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  origin = `http://127.0.0.1:${server.address().port}`;
  process.env.NEXT_PUBLIC_SUPABASE_URL = origin;
  process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY = "anon-key";
  process.env.BLOB_READ_WRITE_TOKEN = `vercel_blob_rw_${STORE}_secret`;
  process.env.VERCEL_BLOB_API_URL = `${origin}/blob`;
  process.env.VERCEL_BLOB_RETRIES = "0";
});

after(() => new Promise((resolve) => server.close(resolve)));

function post(path, body, token = GOOD_TOKEN) {
  const headers = { "content-type": "application/json" };
  if (token) headers.authorization = `Bearer ${token}`;
  return new Request(`https://admin.example${path}`, { method: "POST", headers, body: JSON.stringify(body) });
}

test("upload hands the phone an id, a family path and a presigned PUT", async (t) => {
  t.mock.method(console, "info", () => {});
  const bytes = 123_456_789;
  const response = await handleMediaUpload(
    post("/api/media/upload", { family_id: FAMILY, content_type: "video/quicktime", bytes }),
  );
  assert.equal(response.status, 200);
  const ticket = await response.json();
  // Exactly the keys FamilyStore.uploadToBlob reads.
  assert.deepEqual(Object.keys(ticket).sort(), ["content_type", "id", "pathname", "upload_url"]);
  assert.match(ticket.id, /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/);
  assert.equal(ticket.pathname, `${FAMILY}/${ticket.id}.mov`);
  assert.equal(ticket.content_type, "video/quicktime");

  const url = new URL(ticket.upload_url);
  assert.equal(`${url.origin}${url.pathname}`, `${origin}/blob/`);
  assert.equal(url.searchParams.get("pathname"), ticket.pathname);
  assert.equal(url.searchParams.get("vercel-blob-allowed-content-types"), "video/quicktime");
  assert.equal(url.searchParams.get("vercel-blob-maximum-size-in-bytes"), String(bytes));
  assert.equal(url.searchParams.get("vercel-blob-allow-overwrite"), "false");
  assert.ok(url.searchParams.get("vercel-blob-delegation"));
  assert.ok(url.searchParams.get("vercel-blob-signature"));

  const issued = seen.signedTokens.at(-1);
  assert.equal(issued.pathname, ticket.pathname);
  assert.deepEqual(issued.operations, ["put"]);
  assert.deepEqual(issued.allowedContentTypes, ["video/quicktime"]);
  assert.equal(issued.maximumSizeInBytes, bytes);
  // Membership is checked as the caller, with the caller's JWT.
  assert.deepEqual(seen.rpcs.at(-1), { body: { fid: FAMILY }, auth: `Bearer ${GOOD_TOKEN}` });
});

test("an image/jpg upload is signed as image/jpeg, the type the media_items row accepts", async (t) => {
  t.mock.method(console, "info", () => {});
  const response = await handleMediaUpload(
    post("/api/media/upload", { family_id: FAMILY, content_type: "image/jpg", bytes: 2048 }),
  );
  assert.equal(response.status, 200);
  const ticket = await response.json();
  assert.equal(ticket.content_type, "image/jpeg");
  assert.equal(ticket.pathname, `${FAMILY}/${ticket.id}.jpg`);
  assert.equal(new URL(ticket.upload_url).searchParams.get("vercel-blob-allowed-content-types"), "image/jpeg");
});

test("refusals are clean JSON errors and leave a line in the log", async (t) => {
  const warn = t.mock.method(console, "warn", () => {});
  const body = { family_id: FAMILY, content_type: "video/mp4", bytes: 10 };

  const unsigned = await handleMediaUpload(post("/api/media/upload", body, null));
  assert.equal(unsigned.status, 401);
  assert.deepEqual(await unsigned.json(), { error: "Sign in required." });

  const badToken = await handleMediaUpload(post("/api/media/upload", body, "expired"));
  assert.equal(badToken.status, 401);

  const outsider = await handleMediaUpload(post("/api/media/upload", { ...body, family_id: OTHER_FAMILY }));
  assert.equal(outsider.status, 403);
  assert.match((await outsider.json()).error, /aren't in that family/);

  const lines = warn.mock.calls.map((call) => call.arguments.join(" "));
  assert.deepEqual(lines, [
    "media upload: 401 Sign in required.",
    "media upload: 401 Sign in required.",
    "media upload: 403 You aren't in that family.",
  ]);
});

test("urls signs member paths in order and blanks the rest", async () => {
  const paths = [`${FAMILY}/${MEDIA}.mov`, `${OTHER_FAMILY}/${MEDIA}.jpg`, "not-a-path", `${FAMILY}/${MEDIA}.jpg`];
  const response = await handleMediaUrls(post("/api/media/urls", { paths }));
  assert.equal(response.status, 200);
  const { urls } = await response.json();
  assert.equal(urls.length, paths.length);
  assert.equal(urls[1], "");
  assert.equal(urls[2], "");
  for (const [index, ext] of [[0, "mov"], [3, "jpg"]]) {
    const url = new URL(urls[index]);
    assert.equal(`${url.origin}${url.pathname}`, `https://${STORE}.private.blob.vercel-storage.com/${FAMILY}/${MEDIA}.${ext}`);
    assert.ok(url.searchParams.get("vercel-blob-signature"));
  }
  assert.deepEqual(seen.signedTokens.at(-1).operations, ["get"]);
});

test("Blob counts as configured with a read-write token, or a store id plus OIDC", () => {
  const keys = ["BLOB_READ_WRITE_TOKEN", "BLOB_STORE_ID", "VERCEL_OIDC_TOKEN", "VERCEL"];
  const saved = Object.fromEntries(keys.map((key) => [key, process.env[key]]));
  const set = (values) => {
    for (const key of keys) {
      if (values[key] === undefined) delete process.env[key];
      else process.env[key] = values[key];
    }
  };
  try {
    set({});
    assert.equal(blobReady(), false);
    set({ BLOB_READ_WRITE_TOKEN: "vercel_blob_rw_x_y" });
    assert.equal(blobReady(), true);
    set({ BLOB_STORE_ID: "store_x" });
    assert.equal(blobReady(), false, "a store id alone, off Vercel, has no credentials");
    set({ BLOB_STORE_ID: "store_x", VERCEL_OIDC_TOKEN: "token" });
    assert.equal(blobReady(), true, "vercel env pull");
    // A deployed function: the OIDC token comes in the request header, not process.env.
    set({ BLOB_STORE_ID: "store_x", VERCEL: "1" });
    assert.equal(blobReady(), true);
    set({ VERCEL: "1" });
    assert.equal(blobReady(), false);
  } finally {
    set(saved);
  }
});
