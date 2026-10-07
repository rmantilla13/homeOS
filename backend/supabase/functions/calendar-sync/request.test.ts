import { assertEquals } from "jsr:@std/assert@1";
import { parseCalendarRequest } from "./request.ts";

const FAM = "00000000-0000-0000-0000-00000000F001";
const ACC = "ac000000-0000-0000-0000-000000000001";
const MEM = "00000000-0000-0000-0000-00000000A004";

Deno.test("add_link: a link and how it shows", () => {
  assertEquals(parseCalendarRequest({ action: "add_link", family_id: FAM, url: " webcal://x.example/a.ics ", name: " School ",
    color: "#22aa55", member_id: MEM, busy_only: true }), {
    action: "add_link",
    familyId: FAM.toLowerCase(),
    url: "webcal://x.example/a.ics",
    name: "School",
    color: "#22AA55",
    memberId: MEM.toLowerCase(),
    busyOnly: true,
  });
  assertEquals(parseCalendarRequest({ action: "add_link", family_id: FAM, url: "https://x.example/a.ics" }), {
    action: "add_link", familyId: FAM.toLowerCase(), url: "https://x.example/a.ics",
    name: null, color: null, memberId: null, busyOnly: false,
  });
  assertEquals(parseCalendarRequest({ action: "add_link", family_id: FAM, url: "  " }), { error: "url is required" });
  assertEquals(parseCalendarRequest({ action: "add_link", family_id: "nope", url: "https://x" }), { error: "family_id must be a uuid" });
  assertEquals(parseCalendarRequest({ action: "add_link", family_id: FAM, url: "https://x", color: "red" }), { error: "color must look like #RRGGBB" });
  assertEquals(parseCalendarRequest({ action: "add_link", family_id: FAM, url: "https://x", name: "n".repeat(101) }),
    { error: "name must be text of at most 100 characters" });
  assertEquals(parseCalendarRequest({ action: "add_link", family_id: FAM, url: "https://x", busy_only: "yes" }),
    { error: "busy_only must be true or false" });
  assertEquals(parseCalendarRequest({ action: "add_link", family_id: FAM, url: "https://x", member_id: "leo" }),
    { error: "member_id must be a uuid" });
});

Deno.test("add_google", () => {
  assertEquals(parseCalendarRequest({ action: "add_google", account_id: ACC, calendar_id: "family@group.calendar.google.com" }), {
    action: "add_google", accountId: ACC, calendarId: "family@group.calendar.google.com",
    name: null, color: null, memberId: null, busyOnly: false,
  });
  assertEquals(parseCalendarRequest({ action: "add_google", account_id: ACC }), { error: "calendar_id is required" });
});

Deno.test("sync: a family or one calendar", () => {
  assertEquals(parseCalendarRequest({ action: "sync", family_id: FAM }),
    { action: "sync", familyId: FAM.toLowerCase(), sourceId: null, force: false });
  assertEquals(parseCalendarRequest({ action: "sync", source_id: ACC, force: true }),
    { action: "sync", familyId: null, sourceId: ACC, force: true });
  assertEquals(parseCalendarRequest({ action: "sync" }), { error: "give family_id or source_id" });
  assertEquals(parseCalendarRequest({ action: "sync", family_id: FAM, source_id: ACC }), { error: "give family_id or source_id" });
  assertEquals(parseCalendarRequest({ action: "sync", source_id: "x" }), { error: "source_id must be a uuid" });
});

Deno.test("the rest", () => {
  assertEquals(parseCalendarRequest({ action: "google_start", family_id: FAM }), { action: "google_start", familyId: FAM.toLowerCase() });
  assertEquals(parseCalendarRequest({ action: "google_finish", code: "4/abc", state: "p.s" }),
    { action: "google_finish", code: "4/abc", state: "p.s" });
  assertEquals(parseCalendarRequest({ action: "google_finish", state: "p.s" }), { error: "code is required" });
  assertEquals(parseCalendarRequest({ action: "google_finish", code: "4/abc" }), { error: "state is required" });
  assertEquals(parseCalendarRequest({ action: "google_calendars", account_id: ACC }), { action: "google_calendars", accountId: ACC });
  assertEquals(parseCalendarRequest({ action: "disconnect_google", account_id: ACC }), { action: "disconnect_google", accountId: ACC });
  assertEquals(parseCalendarRequest({ action: "disconnect_google" }), { error: "account_id must be a uuid" });
  assertEquals(parseCalendarRequest({ action: "sync_due" }), { action: "sync_due" });
  assertEquals(parseCalendarRequest({ action: "sync_source", source_id: ACC }), { action: "sync_source", sourceId: ACC });
  assertEquals(parseCalendarRequest({ action: "sync_source" }), { error: "source_id must be a uuid" });
  assertEquals(parseCalendarRequest({ action: "drop_tables" }), { error: "unknown action" });
  assertEquals(parseCalendarRequest([]), { error: "body must be a JSON object" });
  assertEquals(parseCalendarRequest(null), { error: "body must be a JSON object" });
});
