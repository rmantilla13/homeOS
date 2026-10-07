// Unit tests for the shared Storage cleanup: `deno test _shared/`.

import { assertEquals } from "jsr:@std/assert@1";
import { type Bucket, removeFolder, removePaths } from "./files.ts";

// An in-memory bucket that behaves like Storage's list/remove: list shows one
// folder level, a page at a time; remove deletes exact paths and returns them.
function fakeBucket(paths: string[], fail: { list?: string; remove?: string; noop?: boolean } = {}) {
  const objects = new Set(paths);
  const calls = { list: 0, remove: 0 };
  const bucket: Bucket = {
    list(folder, { limit }) {
      calls.list++;
      if (fail.list) return Promise.resolve({ data: null, error: { message: fail.list } });
      const entries = new Map<string, string | null>();
      for (const p of objects) {
        if (!p.startsWith(`${folder}/`)) continue;
        const rest = p.slice(folder.length + 1);
        const slash = rest.indexOf("/");
        if (slash === -1) entries.set(rest, crypto.randomUUID());
        else entries.set(rest.slice(0, slash), null); // a sub-folder
      }
      const data = [...entries].sort().slice(0, limit).map(([name, id]) => ({ name, id }));
      return Promise.resolve({ data, error: null });
    },
    remove(list) {
      calls.remove++;
      if (fail.remove) return Promise.resolve({ data: null, error: { message: fail.remove } });
      const gone = fail.noop ? [] : list.filter((p) => objects.delete(p)).map((name) => ({ name }));
      return Promise.resolve({ data: gone, error: null });
    },
  };
  return { bucket, objects, calls };
}

const FAMILY = "0b9f6c2e-7d1a-4f3b-9a8e-2c5d4e6f7a8b";
const OTHER = "1c0a7d3f-8e2b-4a4c-8b9f-3d6e5f7a8b9c";

Deno.test("removeFolder: removes every file in the folder, page by page", async () => {
  const mine = Array.from({ length: 250 }, (_, i) => `${FAMILY}/${String(i).padStart(3, "0")}.jpg`);
  const { bucket, objects, calls } = fakeBucket([...mine, `${OTHER}/keep.jpg`]);
  assertEquals(await removeFolder(bucket, FAMILY), { removed: 250, error: null });
  assertEquals([...objects], [`${OTHER}/keep.jpg`]);
  assertEquals(calls.remove, 3);
});

Deno.test("removeFolder: an empty or missing folder is fine", async () => {
  const { bucket, calls } = fakeBucket([`${OTHER}/keep.jpg`]);
  assertEquals(await removeFolder(bucket, FAMILY), { removed: 0, error: null });
  assertEquals(calls.remove, 0);
});

Deno.test("removeFolder: sub-folders are left alone and don't loop", async () => {
  const { bucket, objects } = fakeBucket([`${FAMILY}/a.jpg`, `${FAMILY}/thumbs/a.jpg`]);
  assertEquals(await removeFolder(bucket, FAMILY), { removed: 1, error: null });
  assertEquals([...objects], [`${FAMILY}/thumbs/a.jpg`]);
});

Deno.test("removePaths: deletes the named files and ignores ones already gone", async () => {
  const { bucket, objects } = fakeBucket([`${FAMILY}/a.jpg`, `${FAMILY}/a-thumb.jpg`, `${OTHER}/keep.jpg`]);
  assertEquals(
    await removePaths(bucket, [`${FAMILY}/a.jpg`, `${FAMILY}/missing.jpg`, `${FAMILY}/a.jpg`, `${FAMILY}/a-thumb.jpg`]),
    { removed: 2, error: null },
  );
  assertEquals([...objects], [`${OTHER}/keep.jpg`]);
  assertEquals(await removePaths(bucket, []), { removed: 0, error: null });
  assertEquals(await removePaths(fakeBucket([], { remove: "denied" }).bucket, [`${FAMILY}/a.jpg`]),
    { removed: 0, error: "denied" });
});

Deno.test("removeFolder: errors stop it and are reported", async () => {
  assertEquals(await removeFolder(fakeBucket([`${FAMILY}/a.jpg`], { list: "boom" }).bucket, FAMILY),
    { removed: 0, error: "boom" });
  assertEquals(await removeFolder(fakeBucket([`${FAMILY}/a.jpg`], { remove: "denied" }).bucket, FAMILY),
    { removed: 0, error: "denied" });
  const stuck = fakeBucket([`${FAMILY}/a.jpg`], { noop: true });
  assertEquals(await removeFolder(stuck.bucket, FAMILY), { removed: 0, error: "the files couldn't be removed" });
  assertEquals(stuck.calls.list, 1);
});
