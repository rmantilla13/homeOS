import { assert, assertEquals } from "jsr:@std/assert@1";
import { buildFeed, escapeText, fold } from "./feed.ts";
import { parseIcs } from "./ics.ts";

Deno.test("escapeText and fold", () => {
  assertEquals(escapeText("Pizza, games; fun\\more\nnext"), "Pizza\\, games\\; fun\\\\more\\nnext");
  assertEquals(fold("SUMMARY:short"), "SUMMARY:short");
  const long = `SUMMARY:${"é".repeat(60)}`; // 8 + 120 octets
  const folded = fold(long);
  for (const line of folded.split("\r\n")) assert(new TextEncoder().encode(line).length <= 75, line);
  assertEquals(folded.split("\r\n").map((l, i) => (i ? l.slice(1) : l)).join(""), long);
});

const base = {
  familyName: "The Demo Family",
  timeZone: "America/Los_Angeles",
  memberNames: new Map([["m1", "Leo"], ["m2", "Mia"]]),
  now: Date.parse("2026-10-07T12:00:00Z"),
};

Deno.test("buildFeed: one-offs, repeats, all-day; imported events stay out", () => {
  const ics = buildFeed({
    ...base,
    occurrences: [
      { id: "e1", title: "Dentist, Leo", description: "Bring the form", location: "Main St", starts_at: "2026-10-20T22:00:00Z",
        ends_at: "2026-10-20T23:00:00Z", all_day: false, rrule: null, member_ids: ["m1"], source_id: null },
      { id: "e2", title: "Soccer", description: null, location: null, starts_at: "2026-10-21T23:30:00Z",
        ends_at: "2026-10-22T00:30:00Z", all_day: false, rrule: "FREQ=WEEKLY", member_ids: ["m1", "m2", "gone"], source_id: null },
      { id: "e3", title: "Fall break", description: null, location: null, starts_at: "2026-10-23T07:00:00Z",
        ends_at: "2026-10-25T06:59:59Z", all_day: true, rrule: null, member_ids: [], source_id: null },
      { id: "e4", title: "Mom's work thing", description: null, location: null, starts_at: "2026-10-23T16:00:00Z",
        ends_at: "2026-10-23T17:00:00Z", all_day: false, rrule: null, member_ids: [], source_id: "src" },
    ],
  });
  assert(ics.startsWith("BEGIN:VCALENDAR\r\nVERSION:2.0\r\n"));
  assert(ics.endsWith("END:VCALENDAR\r\n"));
  assert(ics.includes("X-WR-CALNAME:The Demo Family\r\n"));
  assert(ics.includes("UID:e1@ohanaos\r\nDTSTAMP:20261007T120000Z\r\nDTSTART:20261020T220000Z\r\nDTEND:20261020T230000Z\r\n"));
  assert(ics.includes("SUMMARY:Dentist\\, Leo\r\nLOCATION:Main St\r\nDESCRIPTION:Bring the form\\n\\nFor: Leo\r\n"));
  assert(ics.includes("UID:e2-20261021@ohanaos"));
  assert(ics.includes("DESCRIPTION:For: Leo\\, Mia\r\n"));
  assert(ics.includes("UID:e3@ohanaos\r\nDTSTAMP:20261007T120000Z\r\nDTSTART;VALUE=DATE:20261023\r\nDTEND;VALUE=DATE:20261025\r\n"));
  assert(!ics.includes("Mom's work thing"));

  // What we publish, our own parser reads back the same.
  const rows = parseIcs(ics, { timeZone: "America/Los_Angeles", from: Date.parse("2026-10-01T00:00:00Z"), to: Date.parse("2026-11-01T00:00:00Z") }).rows;
  assertEquals(rows.map((r) => [r.uid, r.title, r.starts_at, r.ends_at, r.all_day]), [
    ["e1@ohanaos", "Dentist, Leo", "2026-10-20T22:00:00.000Z", "2026-10-20T23:00:00.000Z", false],
    ["e2-20261021@ohanaos", "Soccer", "2026-10-21T23:30:00.000Z", "2026-10-22T00:30:00.000Z", false],
    ["e3@ohanaos", "Fall break", "2026-10-23T07:00:00.000Z", "2026-10-25T06:59:59.000Z", true],
  ]);
});

Deno.test("buildFeed: an all-day event stored to midnight ends the day before", () => {
  const ics = buildFeed({
    ...base,
    occurrences: [{ id: "e5", title: "Holiday", description: null, location: null, starts_at: "2026-12-25T08:00:00Z",
      ends_at: "2026-12-26T08:00:00Z", all_day: true, rrule: null, member_ids: null, source_id: null }],
  });
  assert(ics.includes("DTSTART;VALUE=DATE:20261225\r\nDTEND;VALUE=DATE:20261226\r\n"));
});
