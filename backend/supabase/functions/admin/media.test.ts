// Unit tests for which media objects an admin may sign: `deno test admin/`.

import { assertEquals } from "jsr:@std/assert@1";
import { mediaObjectPath, signableMediaPath } from "./media.ts";

const FAMILY = "0b9f6c2e-7d1a-4f3b-9a8e-2c5d4e6f7a8b";
const OTHER = "1c0a7d3f-8e2b-4a4c-8b9f-3d6e5f7a8b9c";

Deno.test("mediaObjectPath: one folder, this family, a plain file name", () => {
  assertEquals(mediaObjectPath(FAMILY, `${FAMILY}/picnic.jpg`), `${FAMILY}/picnic.jpg`);
  assertEquals(mediaObjectPath(FAMILY.toUpperCase(), `${FAMILY}/a.jpg`), `${FAMILY}/a.jpg`);
  assertEquals(mediaObjectPath(FAMILY, `${OTHER}/picnic.jpg`), null);
  assertEquals(mediaObjectPath(FAMILY, `${FAMILY}/nested/a.jpg`), null);
  assertEquals(mediaObjectPath(FAMILY, `${FAMILY}/../${OTHER}/a.jpg`), null);
  assertEquals(mediaObjectPath(FAMILY, `${FAMILY}/..`), null);
  assertEquals(mediaObjectPath(FAMILY, `${FAMILY}/.hidden`), null);
  assertEquals(mediaObjectPath(FAMILY, FAMILY), null);
  assertEquals(mediaObjectPath(FAMILY, ""), null);
  assertEquals(mediaObjectPath("not-a-uuid", `${FAMILY}/a.jpg`), null);
  assertEquals(mediaObjectPath(FAMILY, null), null);
});

Deno.test("signableMediaPath: thumbnail first, else a photo, never a bare video", () => {
  const photo = { kind: "photo", storage_path: `${FAMILY}/p.jpg`, thumbnail_path: `${FAMILY}/p-thumb.jpg` };
  assertEquals(signableMediaPath(FAMILY, photo), `${FAMILY}/p-thumb.jpg`);
  assertEquals(signableMediaPath(FAMILY, { ...photo, thumbnail_path: null }), `${FAMILY}/p.jpg`);
  assertEquals(signableMediaPath(FAMILY, { ...photo, thumbnail_path: `${OTHER}/x.jpg` }), `${FAMILY}/p.jpg`);
  const video = { kind: "video", storage_path: `${FAMILY}/v.mov`, thumbnail_path: null as string | null };
  assertEquals(signableMediaPath(FAMILY, video), null);
  assertEquals(signableMediaPath(FAMILY, { ...video, thumbnail_path: `${FAMILY}/v-thumb.jpg` }), `${FAMILY}/v-thumb.jpg`);
  assertEquals(signableMediaPath(OTHER, photo), null);
});
