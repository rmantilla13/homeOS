"use server";

import { refresh } from "next/cache";
import { redirect } from "next/navigation";
import type { ActionResult } from "@/lib/action-result";
import * as data from "@/lib/data";
import { DataError } from "@/lib/errors";
import { GIB, MIB } from "@/lib/format";

// Mutations behind the console's forms. Each one re-checks that the caller is
// a platform admin (server actions are public endpoints), validates its input,
// then goes through lib/data, where the RPC or edge function checks again and
// writes the audit log.

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

const text = (fd: FormData, name: string, max = 500) => {
  const v = fd.get(name);
  return typeof v === "string" ? v.trim().slice(0, max) : "";
};
const uuid = (fd: FormData, name: string) => {
  const v = text(fd, name, 64);
  if (!UUID.test(v)) throw new DataError("That link is out of date. Reload the page and try again.");
  return v.toLowerCase();
};
const int = (fd: FormData, name: string, min: number, max: number, label: string) => {
  const raw = text(fd, name, 12);
  const n = Number(raw);
  if (raw === "" || !Number.isInteger(n) || n < min || n > max) {
    throw new DataError(`${label} must be a whole number from ${min} to ${max}.`);
  }
  return n;
};
const decimal = (fd: FormData, name: string, min: number, max: number, label: string) => {
  const raw = text(fd, name, 16);
  const n = Number(raw);
  if (raw === "" || !Number.isFinite(n) || n < min || n > max) {
    throw new DataError(`${label} must be a number from ${min} to ${max}.`);
  }
  return n;
};

// Runs a mutation and turns failures into a message for the form. The admin
// check sits outside the try: its redirect must not be swallowed.
async function mutate(fn: () => Promise<ActionResult | void>, { rerender = true } = {}): Promise<ActionResult> {
  await data.requireAdmin();
  try {
    const result = await fn();
    if (rerender) refresh();
    return result ?? { ok: true };
  } catch (err) {
    if (err instanceof DataError) return { ok: false, error: sentence(err.message), code: err.inviteCode };
    console.error("admin action failed:", err);
    return { ok: false, error: "Something went wrong. Try again." };
  }
}

const sentence = (s: string) => {
  const t = s.trim();
  return t ? t[0].toUpperCase() + t.slice(1) + (/[.!?]$/.test(t) ? "" : ".") : "Something went wrong.";
};

// ───────────────────────────── Families ─────────────────────────────

export async function setFamilyStatusAction(_prev: ActionResult, fd: FormData): Promise<ActionResult> {
  return mutate(async () => {
    const id = uuid(fd, "family_id");
    const status = text(fd, "status");
    if (status !== "active" && status !== "suspended") throw new DataError("Unknown status.");
    const reason = text(fd, "reason") || null;
    if (status === "suspended" && !reason) throw new DataError("Give a reason for the suspension.");
    await data.setFamilyStatus(id, status, reason);
    return { ok: true, message: status === "suspended" ? "Family suspended." : "Family reactivated." };
  });
}

export async function deleteFamilyAction(_prev: ActionResult, fd: FormData): Promise<ActionResult> {
  let deleted = false;
  const result = await mutate(async () => {
    const id = uuid(fd, "family_id");
    const family = await data.getFamilyDetail(id);
    if (!family) throw new DataError("That family no longer exists.");
    // Names have no length limit, so the typed text may be as long as the name.
    const name = family.family.name.trim();
    if (text(fd, "confirm", name.length + 1) !== name) {
      throw new DataError(`Type the family name, ${family.family.name}, exactly to confirm.`);
    }
    await data.deleteFamily(id);
    deleted = true;
  }, { rerender: false });
  // No name in the URL: the families page would show whatever a link put there.
  if (result?.ok && deleted) redirect("/families?deleted=1");
  return result;
}

// ───────────────────────────── Invites ─────────────────────────────

export async function createInviteAction(_prev: ActionResult, fd: FormData): Promise<ActionResult> {
  return mutate(async () => {
    const email = text(fd, "email", 320).toLowerCase() || null;
    if (email && !EMAIL.test(email)) throw new DataError("That email address doesn't look right.");
    const note = text(fd, "note") || null;

    if (fd.get("send_email") === "on") {
      if (!email) throw new DataError("Add an email address to send the invite to.");
      const { code } = await data.emailPlatformInvite(email, note);
      return { ok: true, code, message: `Invite emailed to ${email}.` };
    }
    const maxUses = int(fd, "max_uses", 1, 10_000, "Max uses");
    const expiresInDays = int(fd, "expires_in_days", 1, 365, "Expiry");
    const invite = await data.createPlatformInvite({ email, note, maxUses, expiresInDays });
    return { ok: true, code: invite.code, expiresAt: invite.expires_at, message: "Invite created." };
  });
}

export async function revokeInviteAction(_prev: ActionResult, fd: FormData): Promise<ActionResult> {
  return mutate(async () => {
    await data.revokePlatformInvite(uuid(fd, "invite_id"));
    return { ok: true, message: "Invite revoked." };
  });
}

// ───────────────────────────── Settings ─────────────────────────────

export async function updateSettingsAction(_prev: ActionResult, fd: FormData): Promise<ActionResult> {
  return mutate(async () => {
    const storageBytes = Math.round(decimal(fd, "storage_gib", 0, 1024, "Storage per family") * GIB);
    const maxBytes = Math.round(decimal(fd, "media_max_mib", 1, 5120, "Largest file") * MIB);
    const next = {
      invite_only: fd.get("invite_only") === "on",
      assistant_enabled: fd.get("assistant_enabled") === "on",
      assistant_daily_limit: int(fd, "assistant_daily_limit", 0, 1_000_000, "The daily limit"),
      storage_limit_bytes: storageBytes,
      media_max_bytes: maxBytes,
      media_item_limit: int(fd, "media_item_limit", 0, 1_000_000, "Items per family"),
    };
    // Send only what this admin changed (the form carries the values it was
    // opened with), so saving a form opened before another admin's change
    // can't quietly undo it, e.g. turn the assistant back on. Null leaves a
    // setting as it is (admin_update_settings).
    const patch: Parameters<typeof data.updateSettings>[0] = {};
    for (const key of [
      "invite_only", "assistant_enabled", "assistant_daily_limit",
      "storage_limit_bytes", "media_max_bytes", "media_item_limit",
    ] as const) {
      if (String(next[key]) !== text(fd, `was_${key}`, 20)) Object.assign(patch, { [key]: next[key] });
    }
    if (Object.keys(patch).length === 0) return { ok: true, message: "Nothing changed." };
    await data.updateSettings(patch);
    return { ok: true, message: "Settings saved." };
  });
}

export async function setFamilyLimitsAction(_prev: ActionResult, fd: FormData): Promise<ActionResult> {
  return mutate(async () => {
    const id = uuid(fd, "family_id");
    const patch: Parameters<typeof data.setFamilyLimits>[1] = {};
    const assistant = limitValue(fd, "use_platform_assistant", "was_assistant", () =>
      int(fd, "assistant_daily_limit", 0, 1_000_000, "The daily limit"));
    const storage = limitValue(fd, "use_platform_storage", "was_storage", () =>
      Math.round(decimal(fd, "storage_gib", 0, 1024, "Storage") * GIB));
    const items = limitValue(fd, "use_platform_items", "was_items", () =>
      int(fd, "media_item_limit", 0, 1_000_000, "The item cap"));
    if (assistant !== undefined) patch.assistant_daily_limit = assistant;
    if (storage !== undefined) patch.storage_limit_bytes = storage;
    if (items !== undefined) patch.media_item_limit = items;
    if (Object.keys(patch).length === 0) return { ok: true, message: "Nothing changed." };
    await data.setFamilyLimits(id, patch);
    return { ok: true, message: "Limits saved." };
  });
}

// Null clears the override. Undefined means this field didn't change, so the
// number input isn't even read (a disabled field can be empty).
function limitValue(fd: FormData, useName: string, wasName: string, read: () => number): number | null | undefined {
  const was = text(fd, wasName, 20);
  if (fd.get(useName) === "on") return was === "" ? undefined : null;
  const next = read();
  return String(next) === was ? undefined : next;
}

export async function deleteMediaAction(_prev: ActionResult, fd: FormData): Promise<ActionResult> {
  return mutate(async () => {
    await data.deleteMedia(uuid(fd, "media_id"));
    return { ok: true, message: "Removed from the family." };
  });
}

export async function revokeDeviceAction(_prev: ActionResult, fd: FormData): Promise<ActionResult> {
  return mutate(async () => {
    await data.revokeDevice(uuid(fd, "device_id"));
    return { ok: true, message: "Display revoked. It will need to be paired again." };
  });
}

// ───────────────────────────── Users ─────────────────────────────

export async function setAdminAction(_prev: ActionResult, fd: FormData): Promise<ActionResult> {
  return mutate(async () => {
    const makeAdmin = text(fd, "make_admin") === "1";
    await data.setAdmin(uuid(fd, "user_id"), makeAdmin);
    return { ok: true, message: makeAdmin ? "Admin access granted." : "Admin access removed." };
  });
}

export async function accountAction(_prev: ActionResult, fd: FormData): Promise<ActionResult> {
  return mutate(async () => {
    const action = text(fd, "action");
    if (action !== "ban_user" && action !== "unban_user" && action !== "delete_user") {
      throw new DataError("Unknown action.");
    }
    const userId = uuid(fd, "user_id");
    if (action === "delete_user") {
      const expected = text(fd, "expected", 320);
      if (!expected || text(fd, "confirm", 320).toLowerCase() !== expected.toLowerCase()) {
        throw new DataError(`Type ${expected || "the email address"} exactly to confirm.`);
      }
    }
    await data.accountAction(action, userId);
    return {
      ok: true,
      message: action === "ban_user" ? "User banned." : action === "unban_user" ? "User unbanned." : "User deleted.",
    };
  });
}

// ───────────────────────────── Session ─────────────────────────────

export async function signOutAction(): Promise<void> {
  try {
    await data.signOut();
  } catch (err) {
    if (!(err instanceof DataError)) throw err; // not configured: nobody is signed in
  }
  redirect("/login?signed_out=1");
}
