// Unit tests for deleting your own account: `deno test delete-account/`.

import { assertEquals } from "jsr:@std/assert@1";
import type { Bucket } from "../_shared/files.ts";
import { deleteAccount, type Deps, parseDeletion } from "./account.ts";

const USER = "6f1c2b9a-0d4e-4b8a-9c3f-5e7d1a2b3c4d";
const FAMILY = "0b9f6c2e-7d1a-4f3b-9a8e-2c5d4e6f7a8b";
const DEVICE = "d0000000-0000-4000-8000-000000000001";

// Storage's list/remove for a flat '<folder>/<file>' layout.
function bucket(paths: string[], failList?: string): { bucket: Bucket; objects: Set<string> } {
  const objects = new Set(paths);
  return {
    objects,
    bucket: {
      list(folder, { limit }) {
        if (failList) return Promise.resolve({ data: null, error: { message: failList } });
        const data = [...objects].filter((p) => p.startsWith(`${folder}/`)).slice(0, limit)
          .map((p) => ({ name: p.slice(folder.length + 1), id: "x" }));
        return Promise.resolve({ data, error: null });
      },
      remove(list) {
        return Promise.resolve({ data: list.filter((p) => objects.delete(p)).map((name) => ({ name })), error: null });
      },
    },
  };
}

type Setup = {
  rows?: { data: unknown; error: { message: string; code?: string } | null };
  authErrors?: Record<string, { message: string; status?: number }>;
  failList?: string;
};

function world(setup: Setup = {}) {
  const avatars = bucket([`${USER}/avatar.jpg`, "someone-else/avatar.jpg", `${FAMILY}/kid-1.jpg`], setup.failList);
  const media = bucket([`${FAMILY}/a.jpg`, `${FAMILY}/b.mp4`, "other-family/c.jpg"]);
  const deleted: string[] = [];
  const logs: string[] = [];
  const deps: Deps = {
    deleteRows: () =>
      Promise.resolve(setup.rows ?? {
        data: { families_deleted: [], device_users: [], auth_user_removed: true },
        error: null,
      }),
    avatars: avatars.bucket,
    familyMedia: media.bucket,
    deleteUser: (id) => {
      deleted.push(id);
      return Promise.resolve({ error: setup.authErrors?.[id] ?? null });
    },
    log: (m) => logs.push(m),
  };
  return { deps, avatars: avatars.objects, media: media.objects, deleted, logs };
}

Deno.test("SQL removed the account: the photo goes, Auth isn't called", async () => {
  const w = world();
  assertEquals(await deleteAccount(w.deps, USER), { status: 200, body: { ok: true, families_deleted: [] } });
  assertEquals([...w.avatars], ["someone-else/avatar.jpg", `${FAMILY}/kid-1.jpg`]);
  assertEquals(w.media.size, 3);
  assertEquals(w.deleted, []);
});

Deno.test("a family that went with the account loses its files, and Auth removes displays before the person", async () => {
  const w = world({
    rows: { data: { families_deleted: [FAMILY], device_users: [DEVICE], auth_user_removed: false }, error: null },
  });
  assertEquals(await deleteAccount(w.deps, USER), { status: 200, body: { ok: true, families_deleted: [FAMILY] } });
  assertEquals([...w.media], ["other-family/c.jpg"]);
  assertEquals([...w.avatars], ["someone-else/avatar.jpg"]);
  assertEquals(w.deleted, [DEVICE, USER]);
});

Deno.test("an account Auth already lost (404) counts as removed", async () => {
  const w = world({
    rows: { data: { families_deleted: [], device_users: [DEVICE], auth_user_removed: false }, error: null },
    authErrors: { [DEVICE]: { message: "User not found", status: 404 }, [USER]: { message: "User not found", status: 404 } },
  });
  assertEquals((await deleteAccount(w.deps, USER)).status, 200);
  assertEquals(w.logs, []);
});

Deno.test("Auth failing on the person is a 502 that still names the deleted families", async () => {
  const w = world({
    rows: { data: { families_deleted: [FAMILY], device_users: [DEVICE], auth_user_removed: false }, error: null },
    authErrors: { [DEVICE]: { message: "boom", status: 500 }, [USER]: { message: "boom", status: 500 } },
  });
  const outcome = await deleteAccount(w.deps, USER);
  assertEquals(outcome.status, 502);
  assertEquals(outcome.body, {
    error: "your data is deleted, but your login couldn't be removed yet; try again in a moment",
    families_deleted: [FAMILY],
  });
  // Files went first, so a retry (which names no families) leaves nothing behind.
  assertEquals([...w.media], ["other-family/c.jpg"]);
  assertEquals(w.logs.length, 2);
});

Deno.test("a file cleanup failure is reported but doesn't stop the deletion", async () => {
  const w = world({
    rows: { data: { families_deleted: [], device_users: [], auth_user_removed: false }, error: null },
    failList: "storage down",
  });
  assertEquals(await deleteAccount(w.deps, USER), {
    status: 200,
    body: { ok: true, families_deleted: [], files_error: "storage down" },
  });
  assertEquals(w.deleted, [USER]);
});

Deno.test("the database's refusals pass through as 400s; anything else is a 500", async () => {
  const refused = world({
    rows: { data: null, error: { message: "you're the only parent with a login in Home", code: "P0001" } },
  });
  assertEquals(await deleteAccount(refused.deps, USER), {
    status: 400,
    body: { error: "you're the only parent with a login in Home" },
  });
  assertEquals(refused.deleted, []);
  assertEquals(refused.avatars.size, 3, "nothing is touched after a refusal");

  const broken = world({ rows: { data: null, error: { message: "connection reset", code: "08006" } } });
  assertEquals((await deleteAccount(broken.deps, USER)).status, 500);
  assertEquals(broken.avatars.size, 3);
});

Deno.test("parseDeletion: only the shape delete_my_account returns", () => {
  assertEquals(parseDeletion({ families_deleted: [FAMILY], device_users: [], auth_user_removed: true }), {
    familiesDeleted: [FAMILY], deviceUsers: [], authUserRemoved: true,
  });
  for (const bad of [null, "x", {}, { families_deleted: [1], device_users: [], auth_user_removed: true },
    { families_deleted: [], device_users: [], auth_user_removed: "yes" }]) {
    assertEquals(parseDeletion(bad), null, JSON.stringify(bad));
  }
});
