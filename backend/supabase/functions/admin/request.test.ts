// Unit tests for the admin function's request parsing: `deno test admin/`.

import { assertEquals } from "jsr:@std/assert@1";
import { parseAdminRequest } from "./request.ts";

const USER = "6F1C2B9A-0D4E-4B8A-9C3F-5E7D1A2B3C4D";

Deno.test("invite_email: valid bodies", () => {
  assertEquals(parseAdminRequest({ action: "invite_email", email: " ana@example.com " }), {
    action: "invite_email", email: "ana@example.com", note: null, redirectTo: null,
  });
  assertEquals(
    parseAdminRequest({ action: "invite_email", email: "ana@example.com", note: " Grandma ", redirect_to: "homeos://welcome" }),
    { action: "invite_email", email: "ana@example.com", note: "Grandma", redirectTo: "homeos://welcome" },
  );
  assertEquals(parseAdminRequest({ action: "invite_email", email: "ana@example.com", note: "  " }), {
    action: "invite_email", email: "ana@example.com", note: null, redirectTo: null,
  });
});

Deno.test("invite_email: invalid bodies", () => {
  for (const body of [
    { action: "invite_email" },
    { action: "invite_email", email: "not-an-email" },
    { action: "invite_email", email: "a b@example.com" },
    { action: "invite_email", email: "ana@example.com", note: 5 },
    { action: "invite_email", email: "ana@example.com", note: "x".repeat(501) },
    { action: "invite_email", email: "ana@example.com", redirect_to: "not a url" },
  ]) {
    assertEquals("error" in parseAdminRequest(body), true, JSON.stringify(body));
  }
});

Deno.test("user actions need a uuid", () => {
  for (const action of ["ban_user", "unban_user", "delete_user"] as const) {
    assertEquals(parseAdminRequest({ action, user_id: USER }), { action, userId: USER.toLowerCase() });
    assertEquals(parseAdminRequest({ action, user_id: "123" }), { error: "user_id must be a uuid" });
    assertEquals(parseAdminRequest({ action }), { error: "user_id must be a uuid" });
  }
});

Deno.test("delete_family needs a uuid", () => {
  assertEquals(parseAdminRequest({ action: "delete_family", family_id: USER }), {
    action: "delete_family", familyId: USER.toLowerCase(),
  });
  assertEquals(parseAdminRequest({ action: "delete_family", family_id: "../x" }), { error: "family_id must be a uuid" });
  assertEquals(parseAdminRequest({ action: "delete_family", user_id: USER }), { error: "family_id must be a uuid" });
});

Deno.test("sign_media needs a family and 1 to 60 uuids", () => {
  const other = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
  assertEquals(parseAdminRequest({ action: "sign_media", family_id: USER, media_ids: [USER, USER, other] }), {
    action: "sign_media", familyId: USER.toLowerCase(), mediaIds: [USER.toLowerCase(), other],
  });
  assertEquals(parseAdminRequest({ action: "sign_media", family_id: "nope", media_ids: [USER] }), {
    error: "family_id must be a uuid",
  });
  assertEquals(parseAdminRequest({ action: "sign_media", family_id: USER, media_ids: [] }), {
    error: "media_ids must be 1 to 60 uuids",
  });
  assertEquals(parseAdminRequest({ action: "sign_media", family_id: USER, media_ids: ["nope"] }), {
    error: "media_ids must be 1 to 60 uuids",
  });
  assertEquals(parseAdminRequest({ action: "sign_media", family_id: USER, media_ids: Array(61).fill(USER) }), {
    error: "media_ids must be 1 to 60 uuids",
  });
});

Deno.test("delete_media and revoke_device need a uuid", () => {
  assertEquals(parseAdminRequest({ action: "delete_media", media_id: USER }), {
    action: "delete_media", mediaId: USER.toLowerCase(),
  });
  assertEquals(parseAdminRequest({ action: "delete_media", media_id: "../x" }), { error: "media_id must be a uuid" });
  assertEquals(parseAdminRequest({ action: "revoke_device", device_id: USER }), {
    action: "revoke_device", deviceId: USER.toLowerCase(),
  });
  assertEquals(parseAdminRequest({ action: "revoke_device" }), { error: "device_id must be a uuid" });
});

Deno.test("unknown actions and non-object bodies", () => {
  const err = {
    error: "action must be invite_email, ban_user, unban_user, delete_user, delete_family, sign_media, delete_media or revoke_device",
  };
  assertEquals(parseAdminRequest({ action: "make_admin", user_id: USER }), err);
  assertEquals(parseAdminRequest({}), err);
  for (const body of [null, [], "invite_email", 1]) {
    assertEquals(parseAdminRequest(body), { error: "body must be a JSON object" });
  }
});
