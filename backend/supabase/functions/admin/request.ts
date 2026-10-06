// Request parsing for the admin function, kept free of I/O so it can be
// unit-tested (request.test.ts).

import { isUuid } from "../_shared/http.ts";

export type AdminRequest =
  | { action: "invite_email"; email: string; note: string | null; redirectTo: string | null }
  | { action: "ban_user" | "unban_user" | "delete_user"; userId: string }
  | { action: "delete_family"; familyId: string }
  | { action: "sign_media"; familyId: string; mediaIds: string[] }
  | { action: "delete_media"; mediaId: string }
  | { action: "revoke_device"; deviceId: string };

const EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

export function parseAdminRequest(body: unknown): AdminRequest | { error: string } {
  if (typeof body !== "object" || body === null || Array.isArray(body)) return { error: "body must be a JSON object" };
  const b = body as Record<string, unknown>;

  switch (b.action) {
    case "invite_email": {
      const email = typeof b.email === "string" ? b.email.trim() : "";
      if (!EMAIL.test(email) || email.length > 320) return { error: "email must be a valid email address" };
      if (b.note != null && (typeof b.note !== "string" || b.note.length > 500)) {
        return { error: "note must be text of at most 500 characters" };
      }
      if (b.redirect_to != null && (typeof b.redirect_to !== "string" || !URL.canParse(b.redirect_to))) {
        return { error: "redirect_to must be a URL" };
      }
      return {
        action: "invite_email",
        email,
        note: (b.note as string | undefined)?.trim() || null,
        redirectTo: (b.redirect_to as string | undefined) ?? null,
      };
    }
    case "ban_user":
    case "unban_user":
    case "delete_user":
      if (!isUuid(b.user_id)) return { error: "user_id must be a uuid" };
      return { action: b.action, userId: b.user_id.toLowerCase() };
    case "delete_family":
      if (!isUuid(b.family_id)) return { error: "family_id must be a uuid" };
      return { action: "delete_family", familyId: b.family_id.toLowerCase() };
    case "sign_media": {
      if (!isUuid(b.family_id)) return { error: "family_id must be a uuid" };
      if (!Array.isArray(b.media_ids) || b.media_ids.length < 1 || b.media_ids.length > 60) {
        return { error: "media_ids must be 1 to 60 uuids" };
      }
      const mediaIds: string[] = [];
      for (const id of b.media_ids) {
        if (!isUuid(id)) return { error: "media_ids must be 1 to 60 uuids" };
        const lower = id.toLowerCase();
        if (!mediaIds.includes(lower)) mediaIds.push(lower);
      }
      return { action: "sign_media", familyId: b.family_id.toLowerCase(), mediaIds };
    }
    case "delete_media":
      if (!isUuid(b.media_id)) return { error: "media_id must be a uuid" };
      return { action: "delete_media", mediaId: b.media_id.toLowerCase() };
    case "revoke_device":
      if (!isUuid(b.device_id)) return { error: "device_id must be a uuid" };
      return { action: "revoke_device", deviceId: b.device_id.toLowerCase() };
    default:
      return {
        error: "action must be invite_email, ban_user, unban_user, delete_user, delete_family, sign_media, delete_media or revoke_device",
      };
  }
}
