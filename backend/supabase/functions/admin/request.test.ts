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

Deno.test("unknown actions and non-object bodies", () => {
  const err = { error: "action must be invite_email, ban_user, unban_user, delete_user or delete_family" };
  assertEquals(parseAdminRequest({ action: "make_admin", user_id: USER }), err);
  assertEquals(parseAdminRequest({}), err);
  for (const body of [null, [], "invite_email", 1]) {
    assertEquals(parseAdminRequest(body), { error: "body must be a JSON object" });
  }
});
