// Run with `npm test` (Node 22 strips the TypeScript types itself).
import assert from "node:assert/strict";
import { test } from "node:test";
import { handleMediaDelete, handleMediaUpload, handleMediaUrls } from "../lib/media/api.ts";
import {
  PHOTO_MAX_BYTES,
  VIDEO_MAX_BYTES,
  mediaExtension,
  mediaPathname,
  parseDeleteRequest,
  parseMediaPath,
  parseUploadRequest,
} from "../lib/media/video.ts";

const FAMILY = "00000000-0000-0000-0000-00000000f001";
const MEDIA = "11111111-1111-4111-8111-111111111111";

test("accepts the photo and video formats phones send", () => {
  const cases = [
    ["image/jpeg", "jpg"],
    ["image/jpg", "jpg"],
    ["image/png", "png"],
    ["image/webp", "webp"],
    ["image/heic", "heic"],
    ["image/gif", "gif"],
    [" Image/JPEG ", "jpg"],
    ["video/mp4", "mp4"],
    ["video/quicktime", "mov"],
    ["video/m4v", "m4v"],
    ["video/x-m4v", "m4v"],
    ["video/webm", "webm"],
    ["video/x-matroska", "mkv"],
    ["video/mkv", "mkv"],
    ["video/3gpp", "3gp"],
    ["video/3gp", "3gp"],
    ["video/3gpp2", "3g2"],
    ["video/3g2", "3g2"],
    [" Video/MP4 ", "mp4"],
  ];
  for (const [type, ext] of cases) assert.equal(mediaExtension(type), ext, type);
});

test("rejects unknown types", () => {
  for (const type of ["image/bmp", "video/avi", "text/html", "video/mp4; codecs=avc1", ""]) {
    assert.equal(mediaExtension(type), null, type);
  }
});

test("upload body: size cap and family id", () => {
  const video = parseUploadRequest({ family_id: FAMILY.toUpperCase(), content_type: "video/mp4", bytes: VIDEO_MAX_BYTES });
  assert.equal(video.ok, true);
  if (video.ok) {
    assert.equal(video.value.familyId, FAMILY);
    assert.equal(video.value.extension, "mp4");
    assert.equal(video.value.bytes, VIDEO_MAX_BYTES);
  }
  const photo = parseUploadRequest({ family_id: FAMILY, content_type: "image/jpeg", bytes: PHOTO_MAX_BYTES });
  assert.equal(photo.ok, true);
  if (photo.ok) assert.equal(photo.value.extension, "jpg");
  // allowed_media_types() lists image/jpeg only; the alias is signed as that.
  const alias = parseUploadRequest({ family_id: FAMILY, content_type: " Image/JPG ", bytes: 10 });
  assert.equal(alias.ok, true);
  if (alias.ok) assert.equal(alias.value.contentType, "image/jpeg");
  assert.equal(parseUploadRequest({ family_id: FAMILY, content_type: "image/jpeg", bytes: PHOTO_MAX_BYTES + 1 }).ok, false);
  assert.equal(parseUploadRequest({ family_id: FAMILY, content_type: "text/html", bytes: 10 }).ok, false);
  assert.equal(parseUploadRequest({ family_id: FAMILY, content_type: "video/mp4", bytes: 0 }).ok, false);
  assert.equal(parseUploadRequest({ family_id: FAMILY, content_type: "video/mp4", bytes: VIDEO_MAX_BYTES + 1 }).ok, false);
  assert.equal(parseUploadRequest({ family_id: FAMILY, content_type: "video/mp4", bytes: 1.5 }).ok, false);
  assert.equal(parseUploadRequest({ family_id: "not-a-uuid", content_type: "video/mp4", bytes: 10 }).ok, false);
  assert.equal(parseUploadRequest(null).ok, false);
});

test("pathnames stay inside one family folder", () => {
  const pathname = mediaPathname(FAMILY, MEDIA, "mov");
  assert.equal(pathname, `${FAMILY}/${MEDIA}.mov`);
  const parsed = parseMediaPath(pathname.toUpperCase());
  assert.deepEqual(parsed, { familyId: FAMILY, mediaId: MEDIA, ext: "mov" });
  assert.deepEqual(parseMediaPath(mediaPathname(FAMILY, MEDIA, "jpg")), {
    familyId: FAMILY,
    mediaId: MEDIA,
    ext: "jpg",
  });

  const attacks = [
    `${FAMILY}/../${MEDIA}.mp4`,
    `../${FAMILY}/${MEDIA}.mp4`,
    `/${FAMILY}/${MEDIA}.mp4`,
    `${FAMILY}/${MEDIA}.txt`,
    `${FAMILY}/${MEDIA}.mp4/extra`,
    `${FAMILY}\\${MEDIA}.mp4`,
    `${FAMILY}/%2e%2e/${MEDIA}.mp4`,
    `not-a-uuid/${MEDIA}.mp4`,
    `${FAMILY}/not-a-uuid.mp4`,
    "",
  ];
  for (const value of attacks) assert.equal(parseMediaPath(value), null, value);

  const other = "22222222-2222-4222-8222-222222222222";
  const foreign = parseMediaPath(mediaPathname(other, MEDIA, "mp4"));
  assert.equal(foreign?.familyId === FAMILY, false);
});

test("delete body normalizes a media path and refuses other files", () => {
  const video = parseDeleteRequest({ pathname: `${FAMILY.toUpperCase()}/${MEDIA}.MP4` });
  assert.equal(video.ok, true);
  if (video.ok) {
    assert.equal(video.pathname, `${FAMILY}/${MEDIA}.mp4`);
    assert.equal(video.familyId, FAMILY);
  }
  const photo = parseDeleteRequest({ pathname: `${FAMILY}/${MEDIA}.JPG` });
  assert.equal(photo.ok, true);
  if (photo.ok) assert.equal(photo.pathname, `${FAMILY}/${MEDIA}.jpg`);
  assert.equal(parseDeleteRequest({ pathname: `${FAMILY}/${MEDIA}.txt` }).ok, false);
  assert.equal(parseDeleteRequest({ pathname: `${FAMILY}/../../etc/passwd` }).ok, false);
  assert.equal(parseDeleteRequest({}).ok, false);
});

test("media routes fail closed without Supabase", async () => {
  const savedUrl = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const savedKey = process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  delete process.env.NEXT_PUBLIC_SUPABASE_URL;
  delete process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
  try {
    const headers = { "content-type": "application/json", authorization: "Bearer token" };
    const upload = await handleMediaUpload(
      new Request("https://admin.example/api/media/upload", {
        method: "POST",
        headers,
        body: JSON.stringify({ family_id: FAMILY, content_type: "video/mp4", bytes: 100 }),
      }),
    );
    assert.equal(upload.status, 503);
    const uploadBody = await upload.json();
    assert.match(uploadBody.error, /Supabase/);

    const urls = await handleMediaUrls(
      new Request("https://admin.example/api/media/urls", {
        method: "POST",
        headers,
        body: JSON.stringify({ paths: [`${FAMILY}/${MEDIA}.mp4`] }),
      }),
    );
    assert.equal(urls.status, 503);

    const removed = await handleMediaDelete(
      new Request("https://admin.example/api/media/delete", {
        method: "POST",
        headers,
        body: JSON.stringify({ pathname: `${FAMILY}/${MEDIA}.mp4` }),
      }),
    );
    assert.equal(removed.status, 503);

    process.env.NEXT_PUBLIC_SUPABASE_URL = "https://example.supabase.co";
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY = "anon-key";
    const unsigned = await handleMediaUpload(
      new Request("https://admin.example/api/media/upload", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ family_id: FAMILY, content_type: "video/mp4", bytes: 100 }),
      }),
    );
    assert.equal(unsigned.status, 401);
    const unsignedBody = await unsigned.json();
    assert.match(unsignedBody.error, /Sign in/);
  } finally {
    if (savedUrl === undefined) delete process.env.NEXT_PUBLIC_SUPABASE_URL;
    else process.env.NEXT_PUBLIC_SUPABASE_URL = savedUrl;
    if (savedKey === undefined) delete process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY;
    else process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY = savedKey;
  }
});

test("a bad upload is rejected before any storage call", async () => {
  const response = await handleMediaUpload(
    new Request("https://admin.example/api/media/upload", {
      method: "POST",
      headers: { "content-type": "application/json" },
        body: JSON.stringify({ family_id: FAMILY, content_type: "text/html", bytes: 100 }),
    }),
  );
  assert.equal(response.status, 400);
  const body = await response.json();
  assert.match(body.error, /format/);
});
