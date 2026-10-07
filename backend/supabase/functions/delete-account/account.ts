// What delete-account does after the caller is known, kept free of I/O setup
// so it can be unit-tested with fakes (account.test.ts).
//
// 1. delete_my_account() with the caller's own JWT decides and removes the
//    rows (see its migration, 20261010000001_account_deletion.sql).
// 2. Files: the profile photo (avatars/<user_id>/) and the Storage folder of
//    each family that went with the account (family-media/<family_id>/).
//    These go before the account, because a retry after a failed step 3
//    finds no families left to name.
// 3. When SQL wasn't allowed to delete auth users: the deleted families'
//    display accounts, then the caller's own. Supabase Auth deleting it also
//    ends its sessions.
// A file or display cleanup failure is logged and reported but doesn't stop
// the deletion. Only the caller's own account failing to go is an error,
// and asking again finishes it.

import { type Bucket, removeFolder } from "../_shared/files.ts";

type Failure = { message: string; code?: string; status?: number };

export interface Deps {
  /** db.rpc("delete_my_account") as the caller. */
  deleteRows(): PromiseLike<{ data: unknown; error: Failure | null }>;
  avatars: Bucket;
  familyMedia: Bucket;
  /** service.auth.admin.deleteUser */
  deleteUser(id: string): PromiseLike<{ error: Failure | null }>;
  log?(message: string): void;
}

export type Outcome = {
  status: number;
  body: { ok: true; families_deleted: string[]; files_error?: string } | { error: string; families_deleted?: string[] };
};

type Deletion = { familiesDeleted: string[]; deviceUsers: string[]; authUserRemoved: boolean };

const ids = (value: unknown): string[] | null =>
  Array.isArray(value) && value.every((v) => typeof v === "string") ? value : null;

export function parseDeletion(data: unknown): Deletion | null {
  if (!data || typeof data !== "object") return null;
  const row = data as Record<string, unknown>;
  const familiesDeleted = ids(row.families_deleted);
  const deviceUsers = ids(row.device_users);
  if (!familiesDeleted || !deviceUsers || typeof row.auth_user_removed !== "boolean") return null;
  return { familiesDeleted, deviceUsers, authUserRemoved: row.auth_user_removed };
}

export async function deleteAccount(deps: Deps, userId: string): Promise<Outcome> {
  const log = deps.log ?? console.error;
  const { data, error } = await deps.deleteRows();
  if (error) {
    // The function's own refusals (raise exception) are written for people.
    if (error.code === "P0001") return { status: 400, body: { error: error.message } };
    log(`delete_my_account failed: ${error.message}`);
    return { status: 500, body: { error: "couldn't delete your account; try again in a moment" } };
  }
  const deletion = parseDeletion(data);
  if (!deletion) {
    log(`delete_my_account answered something unexpected: ${JSON.stringify(data)}`);
    return { status: 500, body: { error: "couldn't delete your account; try again in a moment" } };
  }
  const families = deletion.familiesDeleted;

  const fileErrors: string[] = [];
  for (const [bucket, folder] of [
    [deps.avatars, userId.toLowerCase()],
    ...families.map((f) => [deps.familyMedia, f.toLowerCase()] as const),
  ] as const) {
    const files = await removeFolder(bucket, folder);
    if (files.error) {
      log(`file cleanup for ${folder} failed: ${files.error}`);
      fileErrors.push(files.error);
    }
  }

  if (!deletion.authUserRemoved) {
    for (const device of deletion.deviceUsers) {
      const { error: deviceErr } = await deps.deleteUser(device);
      if (deviceErr && deviceErr.status !== 404) log(`display account ${device} wasn't removed: ${deviceErr.message}`);
    }
    const { error: authErr } = await deps.deleteUser(userId);
    if (authErr && authErr.status !== 404) {
      log(`auth user ${userId} wasn't removed: ${authErr.message}`);
      return {
        status: 502,
        body: {
          error: "your data is deleted, but your login couldn't be removed yet; try again in a moment",
          families_deleted: families,
        },
      };
    }
  }

  return {
    status: 200,
    body: { ok: true, families_deleted: families, ...(fileErrors.length ? { files_error: fileErrors.join("; ") } : {}) },
  };
}
