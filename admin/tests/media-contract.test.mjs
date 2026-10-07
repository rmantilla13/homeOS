// The media routes against a local stand-in for Supabase (auth + the
// is_family_member RPC) and the Blob control API, through the real
// @vercel/blob SDK. Pins the request and response fields the iOS app
// (FamilyStore.uploadToBlob, signedURL) and the display read.
import assert from "node:assert/strict";
import { createServer } from "node:http";
import { after, before, test } from "node:test";
import { handleMediaDelete, handleMediaUpload, handleMediaUrls } from "../lib/media/api.ts";
import { blobReady } from "../lib/env.ts";

const FAMILY = "00000000-0000-4000-8000-00000000f001";
const OTHER_FAMILY = "00000000-0000-4000-8000-00000000f002";
const MEDIA = "11111111-1111-4111-8111-111111111111";
const USER = "22222222-2222-4222-8222-222222222222";
const GOOD_TOKEN = "good-token";
const STORE = "teststore";

const seen = { signedTokens: [], rpcs: [], deletes: [] };
// Tests set these (pathname -> boolean) to make the Blob stub refuse a call.
const stubFails = { sign: null, deleteMissing: null, deleteForbidden: null };
// Pathnames the Blob stub lists (delete looks for an item's leftovers).
const stubBlobs = new Set();
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
      if (stubFails.sign?.(body.pathname)) return send(res, 403, { error: { code: "forbidden", message: "Access denied" } });
      const payload = { storeId: STORE, ...body };
      return send(res, 200, {
        delegationToken: `${base64url(JSON.stringify(payload))}.stub-hmac`,
        clientSigningToken: "stub-signing-key",
        validUntil: body.validUntil,
      });
    }
    if (req.method === "GET" && /^\/blob\/?\?/.test(req.url)) {
      const prefix = new URL(req.url, origin).searchParams.get("prefix") ?? "";
      const blobs = [...stubBlobs].filter((pathname) => pathname.startsWith(prefix)).map((pathname) => ({
        url: `https://${STORE}.private.blob.vercel-storage.com/${pathname}`,
        downloadUrl: `https://${STORE}.private.blob.vercel-storage.com/${pathname}?download=1`,
        pathname,
        size: 1,
        uploadedAt: new Date().toISOString(),
        etag: "stub",
      }));
      return send(res, 200, { blobs, hasMore: false });
    }
    if (req.method === "POST" && req.url === "/blob/delete") {
      seen.deletes.push(body);
      const [pathname] = body.urls;
      if (stubFails.deleteMissing?.(pathname)) return send(res, 404, { error: { code: "not_found", message: "Not found" } });
      if (stubFails.deleteForbidden?.(pathname)) return send(res, 403, { error: { code: "forbidden", message: "Access denied" } });
      return send(res, 200, {});
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

function failing(t, kind, when) {
  stubFails[kind] = when;
  t.after(() => {
    stubFails[kind] = null;
  });
}

const isPoster = (pathname) => pathname.endsWith("-thumb.jpg");

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

test("with thumbnail_bytes the ticket adds a presigned PUT for <family>/<id>-thumb.jpg", async (t) => {
  const info = t.mock.method(console, "info", () => {});
  const before = seen.signedTokens.length;
  const response = await handleMediaUpload(
    post("/api/media/upload", { family_id: FAMILY, content_type: "video/mp4", bytes: 5_000_000, thumbnail_bytes: 41_234 }),
  );
  assert.equal(response.status, 200);
  const ticket = await response.json();
  assert.deepEqual(Object.keys(ticket).sort(), ["content_type", "id", "pathname", "thumbnail", "upload_url"]);
  assert.equal(ticket.pathname, `${FAMILY}/${ticket.id}.mp4`);
  assert.deepEqual(Object.keys(ticket.thumbnail).sort(), ["content_type", "pathname", "upload_url"]);
  assert.equal(ticket.thumbnail.pathname, `${FAMILY}/${ticket.id}-thumb.jpg`);
  assert.equal(ticket.thumbnail.content_type, "image/jpeg");
  const url = new URL(ticket.thumbnail.upload_url);
  assert.equal(`${url.origin}${url.pathname}`, `${origin}/blob/`);
  assert.equal(url.searchParams.get("pathname"), ticket.thumbnail.pathname);
  assert.equal(url.searchParams.get("vercel-blob-allowed-content-types"), "image/jpeg");
  assert.equal(url.searchParams.get("vercel-blob-maximum-size-in-bytes"), "41234");
  assert.equal(url.searchParams.get("vercel-blob-allow-overwrite"), "false");
  // The file's PUT is unchanged.
  assert.equal(new URL(ticket.upload_url).searchParams.get("vercel-blob-maximum-size-in-bytes"), "5000000");

  // Two delegations, each scoped to one pathname, type and size. They are
  // requested together, so their order isn't fixed.
  const issued = seen.signedTokens.slice(before).sort((a, b) => Number(isPoster(a.pathname)) - Number(isPoster(b.pathname)));
  assert.deepEqual(
    issued.map((x) => [x.pathname, x.operations, x.allowedContentTypes, x.maximumSizeInBytes]),
    [
      [ticket.pathname, ["put"], ["video/mp4"], 5_000_000],
      [ticket.thumbnail.pathname, ["put"], ["image/jpeg"], 41_234],
    ],
  );
  assert.deepEqual(info.mock.calls.at(-1).arguments, ["media upload: signed video/mp4, 5000000 bytes, poster 41234 bytes"]);
});

test("a bad poster size drops the poster, never the upload", async (t) => {
  t.mock.method(console, "info", () => {});
  const warn = t.mock.method(console, "warn", () => {});
  for (const bad of [262_145, 0, 1.5, "40000"]) {
    const before = seen.signedTokens.length;
    const response = await handleMediaUpload(
      post("/api/media/upload", { family_id: FAMILY, content_type: "image/jpeg", bytes: 10, thumbnail_bytes: bad }),
    );
    assert.equal(response.status, 200, String(bad));
    const ticket = await response.json();
    assert.deepEqual(Object.keys(ticket).sort(), ["content_type", "id", "pathname", "upload_url"], String(bad));
    assert.deepEqual(
      seen.signedTokens.slice(before).map((x) => x.pathname),
      [ticket.pathname],
      "only the file is signed",
    );
  }
  assert.deepEqual(
    warn.mock.calls.map((call) => call.arguments.join(" ")),
    Array(4).fill("media upload: thumbnail_bytes must be between 1 byte and 256 KB; signing without a poster"),
  );
});

test("a poster that can't be signed is left out; a file that can't be signed is a 502", async (t) => {
  t.mock.method(console, "info", () => {});
  t.mock.method(console, "warn", () => {});
  const error = t.mock.method(console, "error", () => {});
  const body = { family_id: FAMILY, content_type: "video/quicktime", bytes: 1000, thumbnail_bytes: 2000 };

  failing(t, "sign", isPoster);
  const noPoster = await handleMediaUpload(post("/api/media/upload", body));
  assert.equal(noPoster.status, 200);
  const ticket = await noPoster.json();
  assert.deepEqual(Object.keys(ticket).sort(), ["content_type", "id", "pathname", "upload_url"]);
  assert.equal(new URL(ticket.upload_url).searchParams.get("pathname"), ticket.pathname);
  assert.deepEqual(error.mock.calls.map((call) => call.arguments[0]), ["media poster URL failed:"]);

  failing(t, "sign", (pathname) => !isPoster(pathname));
  const noFile = await handleMediaUpload(post("/api/media/upload", body));
  assert.equal(noFile.status, 502);
  assert.deepEqual(await noFile.json(), { error: "Couldn't start the upload." });
  assert.equal(error.mock.calls.at(-1).arguments[0], "media upload URL failed:");
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

test("urls signs posters like files", async () => {
  const paths = [
    `${FAMILY}/${MEDIA}-thumb.jpg`,
    `${OTHER_FAMILY}/${MEDIA}-thumb.jpg`,
    `${FAMILY}/${MEDIA}-thumb.png`,
    `${FAMILY.toUpperCase()}/${MEDIA}-THUMB.JPG`,
    `${FAMILY}/${MEDIA}.mp4`,
  ];
  const response = await handleMediaUrls(post("/api/media/urls", { paths }));
  assert.equal(response.status, 200);
  const { urls } = await response.json();
  assert.equal(urls.length, paths.length);
  const signed = (index) => {
    const url = new URL(urls[index]);
    assert.ok(url.searchParams.get("vercel-blob-signature"));
    return `${url.origin}${url.pathname}`;
  };
  const host = `https://${STORE}.private.blob.vercel-storage.com`;
  assert.equal(signed(0), `${host}/${FAMILY}/${MEDIA}-thumb.jpg`);
  assert.deepEqual(urls.slice(1, 3), ["", ""]);
  assert.equal(signed(3), `${host}/${FAMILY}/${MEDIA}-thumb.jpg`, "signed under the lowercase name");
  assert.equal(signed(4), `${host}/${FAMILY}/${MEDIA}.mp4`);
});

test("deleting a file deletes its poster first", async () => {
  const before = seen.deletes.length;
  const response = await handleMediaDelete(post("/api/media/delete", { pathname: `${FAMILY}/${MEDIA}.MOV` }));
  assert.equal(response.status, 200);
  assert.deepEqual(await response.json(), { ok: true });
  assert.deepEqual(seen.deletes.slice(before), [{ urls: [`${FAMILY}/${MEDIA}-thumb.jpg`] }, { urls: [`${FAMILY}/${MEDIA}.mov`] }]);
});

test("a poster that won't delete never blocks the file; a file that won't is a 502", async (t) => {
  t.mock.method(console, "warn", () => {});
  const error = t.mock.method(console, "error", () => {});
  const remove = async () => {
    const before = seen.deletes.length;
    const response = await handleMediaDelete(post("/api/media/delete", { pathname: `${FAMILY}/${MEDIA}.mp4` }));
    return { status: response.status, body: await response.json(), calls: seen.deletes.slice(before).map((x) => x.urls[0]) };
  };
  const both = [`${FAMILY}/${MEDIA}-thumb.jpg`, `${FAMILY}/${MEDIA}.mp4`];

  // Rows from before posters have none.
  failing(t, "deleteMissing", isPoster);
  assert.deepEqual(await remove(), { status: 200, body: { ok: true }, calls: both });
  assert.equal(error.mock.callCount(), 0);

  failing(t, "deleteMissing", null);
  failing(t, "deleteForbidden", isPoster);
  assert.deepEqual(await remove(), { status: 200, body: { ok: true }, calls: both });
  assert.deepEqual(error.mock.calls.map((call) => call.arguments[0]), ["media poster delete failed:"]);

  failing(t, "deleteForbidden", (pathname) => !isPoster(pathname));
  assert.deepEqual(await remove(), { status: 502, body: { error: "Couldn't delete that file." }, calls: both });

  // A file that is already gone is still a success, as before.
  failing(t, "deleteForbidden", null);
  failing(t, "deleteMissing", () => true);
  assert.deepEqual(await remove(), { status: 200, body: { ok: true }, calls: both });
});

test("delete also takes what a wall copy left behind", async (t) => {
  t.mock.method(console, "warn", () => {});
  const error = t.mock.method(console, "error", () => {});
  // The row is on its server-made copy; the original waits for the sweep.
  stubBlobs.add(`${FAMILY}/${MEDIA}.mov`);
  stubBlobs.add(`${OTHER_FAMILY}/${MEDIA}.mov`);
  t.after(() => stubBlobs.clear());
  const before = seen.deletes.length;
  const response = await handleMediaDelete(post("/api/media/delete", { pathname: `${FAMILY}/${MEDIA}-wall.mp4` }));
  assert.equal(response.status, 200);
  assert.deepEqual(
    seen.deletes.slice(before).map((call) => call.urls),
    [[`${FAMILY}/${MEDIA}-thumb.jpg`], [`${FAMILY}/${MEDIA}-wall.mp4`], [`${FAMILY}/${MEDIA}.mov`]],
    "poster, copy, then the original under the same item, and nothing in another family",
  );
  assert.equal(error.mock.callCount(), 0);
});

test("delete takes a file in the caller's family, never a poster on its own", async (t) => {
  t.mock.method(console, "warn", () => {});
  const before = seen.deletes.length;
  const poster = await handleMediaDelete(post("/api/media/delete", { pathname: `${FAMILY}/${MEDIA}-thumb.jpg` }));
  assert.equal(poster.status, 400);
  assert.deepEqual(await poster.json(), { error: "That isn't a media path." });
  const outsider = await handleMediaDelete(post("/api/media/delete", { pathname: `${OTHER_FAMILY}/${MEDIA}.mp4` }));
  assert.equal(outsider.status, 403);
  assert.equal(seen.deletes.length, before, "nothing was deleted");
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
