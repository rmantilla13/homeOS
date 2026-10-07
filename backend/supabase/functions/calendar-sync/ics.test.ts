import { assertEquals, assertThrows } from "jsr:@std/assert@1";
import { parseIcs } from "./ics.ts";
import { CalendarError } from "./rows.ts";

const LA = `BEGIN:VTIMEZONE
TZID:America/Los_Angeles
BEGIN:DAYLIGHT
TZOFFSETFROM:-0800
TZOFFSETTO:-0700
TZNAME:PDT
DTSTART:19700308T020000
RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU
END:DAYLIGHT
BEGIN:STANDARD
TZOFFSETFROM:-0700
TZOFFSETTO:-0800
TZNAME:PST
DTSTART:19701101T020000
RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU
END:STANDARD
END:VTIMEZONE`;

const cal = (...parts: string[]) =>
  ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Test//EN", "X-WR-CALNAME:Lincoln Elementary", ...parts, "END:VCALENDAR"]
    .join("\r\n");

const opts = {
  timeZone: "America/Los_Angeles",
  from: Date.parse("2026-09-01T00:00:00Z"),
  to: Date.parse("2027-09-01T00:00:00Z"),
};
const brief = (text: string, o = opts) =>
  parseIcs(text, o).rows.map((r) => `${r.uid} | ${r.title} | ${r.starts_at} | ${r.ends_at}${r.all_day ? " | all day" : ""}`);

Deno.test("parseIcs: a weekly series across DST, with a skipped, a moved and a cancelled repeat", () => {
  const text = cal(
    LA,
    "BEGIN:VEVENT",
    "UID:soccer@test",
    "DTSTART;TZID=America/Los_Angeles:20261019T163000",
    "DTEND;TZID=America/Los_Angeles:20261019T173000",
    "RRULE:FREQ=WEEKLY;COUNT=5",
    "EXDATE;TZID=America/Los_Angeles:20261026T163000",
    "SUMMARY:Soccer practice",
    "LOCATION:Field 3",
    "END:VEVENT",
    "BEGIN:VEVENT",
    "UID:soccer@test",
    "RECURRENCE-ID;TZID=America/Los_Angeles:20261102T163000",
    "DTSTART;TZID=America/Los_Angeles:20261102T180000",
    "DTEND;TZID=America/Los_Angeles:20261102T190000",
    "SUMMARY:Soccer practice (late)",
    "END:VEVENT",
    "BEGIN:VEVENT",
    "UID:soccer@test",
    "RECURRENCE-ID;TZID=America/Los_Angeles:20261109T163000",
    "DTSTART;TZID=America/Los_Angeles:20261109T163000",
    "STATUS:CANCELLED",
    "SUMMARY:Soccer practice",
    "END:VEVENT",
  );
  assertEquals(brief(text), [
    "soccer@test/20261019T233000Z | Soccer practice | 2026-10-19T23:30:00.000Z | 2026-10-20T00:30:00.000Z",
    // Moved: keeps the uid of the slot it came from, so the row is updated, not replaced.
    "soccer@test/20261103T003000Z | Soccer practice (late) | 2026-11-03T02:00:00.000Z | 2026-11-03T03:00:00.000Z",
    // After DST ends it's still 4:30pm local.
    "soccer@test/20261117T003000Z | Soccer practice | 2026-11-17T00:30:00.000Z | 2026-11-17T01:30:00.000Z",
  ]);
  const first = parseIcs(text, opts).rows[0];
  assertEquals([first.location, first.description, first.all_day], ["Field 3", null, false]);
});

Deno.test("parseIcs: all-day events span local days; DTEND is exclusive", () => {
  const text = cal(
    "BEGIN:VEVENT",
    "UID:break",
    "DTSTART;VALUE=DATE:20261123",
    "DTEND;VALUE=DATE:20261126",
    "SUMMARY:Thanksgiving break",
    "END:VEVENT",
    "BEGIN:VEVENT",
    "UID:pictures",
    "DTSTART;VALUE=DATE:20261015",
    "SUMMARY:Picture day",
    "END:VEVENT",
  );
  assertEquals(brief(text), [
    // Three days, Monday to Wednesday.
    "break | Thanksgiving break | 2026-11-23T08:00:00.000Z | 2026-11-26T07:59:59.000Z | all day",
    // No DTEND: one day.
    "pictures | Picture day | 2026-10-15T07:00:00.000Z | 2026-10-16T06:59:59.000Z | all day",
  ]);
});

Deno.test("parseIcs: a yearly all-day series (birthdays)", () => {
  const text = cal("BEGIN:VEVENT", "UID:b2", "DTSTART;VALUE=DATE:19800310", "RRULE:FREQ=YEARLY", "SUMMARY:Mom", "END:VEVENT");
  assertEquals(brief(text), ["b2/20270310 | Mom | 2027-03-10T08:00:00.000Z | 2027-03-11T07:59:59.000Z | all day"]);
  // East of UTC, the repeat is still keyed by its date.
  assertEquals(brief(text, { ...opts, timeZone: "Asia/Tokyo" }),
    ["b2/20270310 | Mom | 2027-03-09T15:00:00.000Z | 2027-03-10T14:59:59.000Z | all day"]);
});

Deno.test("parseIcs: an undefined TZID is read as an IANA zone; floating times use the family's", () => {
  const text = cal(
    "BEGIN:VEVENT",
    "UID:berlin",
    "DTSTART;TZID=Europe/Berlin:20261026T163000",
    "DTEND;TZID=Europe/Berlin:20261026T173000",
    "SUMMARY:Call with Oma",
    "END:VEVENT",
    "BEGIN:VEVENT",
    "UID:floating",
    "DTSTART:20261026T163000",
    "DURATION:PT45M",
    "SUMMARY:Piano",
    "END:VEVENT",
    "BEGIN:VEVENT",
    "UID:utc",
    "DTSTART:20261027T120000Z",
    "DTEND:20261027T130000Z",
    "SUMMARY:Webinar",
    "END:VEVENT",
    "BEGIN:VEVENT",
    "UID:nowhere",
    "DTSTART;TZID=Pacific Standard Time:20261028T090000",
    "SUMMARY:Unknown zone name",
    "END:VEVENT",
  );
  assertEquals(brief(text), [
    "berlin | Call with Oma | 2026-10-26T15:30:00.000Z | 2026-10-26T16:30:00.000Z",
    "floating | Piano | 2026-10-26T23:30:00.000Z | 2026-10-27T00:15:00.000Z",
    "utc | Webinar | 2026-10-27T12:00:00.000Z | 2026-10-27T13:00:00.000Z",
    // Not a zone the runtime knows and not defined in the file: the family's zone. No end: zero length.
    "nowhere | Unknown zone name | 2026-10-28T16:00:00.000Z | 2026-10-28T16:00:00.000Z",
  ]);
});

Deno.test("parseIcs: Outlook-style zones defined in the file", () => {
  const text = cal(
    "BEGIN:VTIMEZONE",
    "TZID:W. Europe Standard Time",
    "BEGIN:STANDARD",
    "DTSTART:16010101T030000",
    "TZOFFSETFROM:+0200",
    "TZOFFSETTO:+0100",
    "RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=-1SU;BYMONTH=10",
    "END:STANDARD",
    "BEGIN:DAYLIGHT",
    "DTSTART:16010101T020000",
    "TZOFFSETFROM:+0100",
    "TZOFFSETTO:+0200",
    "RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=-1SU;BYMONTH=3",
    "END:DAYLIGHT",
    "END:VTIMEZONE",
    "BEGIN:VEVENT",
    "UID:outlook",
    "DTSTART;TZID=W. Europe Standard Time:20261020T100000",
    "DTEND;TZID=W. Europe Standard Time:20261020T110000",
    "SUMMARY:Board meeting",
    "END:VEVENT",
  );
  assertEquals(brief(text), ["outlook | Board meeting | 2026-10-20T08:00:00.000Z | 2026-10-20T09:00:00.000Z"]);
});

Deno.test("parseIcs: private events are Busy; cancelled ones and the past are left out", () => {
  const text = cal(
    "BEGIN:VEVENT",
    "UID:secret",
    "CLASS:PRIVATE",
    "DTSTART:20261021T170000Z",
    "DTEND:20261021T180000Z",
    "SUMMARY:Doctor",
    "DESCRIPTION:Results",
    "LOCATION:Clinic",
    "END:VEVENT",
    "BEGIN:VEVENT",
    "UID:called-off",
    "STATUS:CANCELLED",
    "DTSTART:20261022T170000Z",
    "SUMMARY:Called off",
    "END:VEVENT",
    "BEGIN:VEVENT",
    "UID:old",
    "DTSTART:20250101T170000Z",
    "DTEND:20250101T180000Z",
    "SUMMARY:Last year",
    "END:VEVENT",
    "BEGIN:VEVENT",
    "UID:far",
    "DTSTART:20290101T170000Z",
    "SUMMARY:Too far ahead",
    "END:VEVENT",
    "BEGIN:VEVENT",
    "UID:untitled",
    "DTSTART:20261023T170000Z",
    "END:VEVENT",
  );
  const rows = parseIcs(text, opts).rows;
  assertEquals(rows.map((r) => [r.uid, r.title, r.description, r.location]), [
    ["secret", "Busy", null, null],
    ["untitled", "Untitled event", null, null],
  ]);
});

Deno.test("parseIcs: a long-running series only yields repeats in the window", () => {
  const text = cal(
    "BEGIN:VEVENT",
    "UID:standup",
    "DTSTART:20100104T160000Z",
    "DTEND:20100104T161500Z",
    "RRULE:FREQ=DAILY;BYDAY=MO,TU,WE,TH,FR",
    "SUMMARY:Standup",
    "END:VEVENT",
  );
  const narrow = { ...opts, from: Date.parse("2026-10-05T00:00:00Z"), to: Date.parse("2026-10-12T00:00:00Z") };
  assertEquals(parseIcs(text, narrow).rows.map((r) => r.starts_at), [
    "2026-10-05T16:00:00.000Z",
    "2026-10-06T16:00:00.000Z",
    "2026-10-07T16:00:00.000Z",
    "2026-10-08T16:00:00.000Z",
    "2026-10-09T16:00:00.000Z",
  ]);
});

Deno.test("parseIcs: old series skip ahead without moving a single repeat", () => {
  const october = { ...opts, from: Date.parse("2026-10-01T07:00:00Z"), to: Date.parse("2026-11-01T07:00:00Z") };
  // Every other week on Monday and Wednesday since January 2015, one repeat
  // skipped and one moved. Expected days worked out separately.
  const biweekly = cal(
    LA,
    "BEGIN:VEVENT",
    "UID:swim",
    "DTSTART;TZID=America/Los_Angeles:20150105T070000",
    "DTEND;TZID=America/Los_Angeles:20150105T080000",
    "RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE",
    "EXDATE;TZID=America/Los_Angeles:20261014T070000",
    "SUMMARY:Swim",
    "END:VEVENT",
    "BEGIN:VEVENT",
    "UID:swim",
    "RECURRENCE-ID;TZID=America/Los_Angeles:20261026T070000",
    "DTSTART;TZID=America/Los_Angeles:20261026T090000",
    "DTEND;TZID=America/Los_Angeles:20261026T100000",
    "SUMMARY:Swim (late start)",
    "END:VEVENT",
  );
  assertEquals(brief(biweekly, october), [
    "swim/20261012T140000Z | Swim | 2026-10-12T14:00:00.000Z | 2026-10-12T15:00:00.000Z",
    "swim/20261026T140000Z | Swim (late start) | 2026-10-26T16:00:00.000Z | 2026-10-26T17:00:00.000Z",
    "swim/20261028T140000Z | Swim | 2026-10-28T14:00:00.000Z | 2026-10-28T15:00:00.000Z",
  ]);

  // The second Tuesday of every month since 2010, until the end of November.
  const monthly = cal(
    "BEGIN:VEVENT",
    "UID:pta",
    "DTSTART:20100112T030000Z",
    "DURATION:PT1H",
    "RRULE:FREQ=MONTHLY;BYDAY=2TU;UNTIL=20261130T000000Z",
    "SUMMARY:PTA",
    "END:VEVENT",
  );
  assertEquals(parseIcs(monthly, { ...opts, from: Date.parse("2026-10-01T00:00:00Z") }).rows.map((r) => r.starts_at), [
    "2026-10-13T03:00:00.000Z",
    "2026-11-10T03:00:00.000Z",
  ]);
});

Deno.test("parseIcs: a calendar too big to read in time fails with a message", () => {
  // COUNT series can't skip ahead: each walks 5000 days, all long before the window.
  const many = Array.from({ length: 300 }, (_, i) =>
    `BEGIN:VEVENT\r\nUID:s${i}\r\nDTSTART:20050105T090000Z\r\nRRULE:FREQ=DAILY;COUNT=5000\r\nSUMMARY:x\r\nEND:VEVENT`);
  assertThrows(() => parseIcs(cal(...many), opts), CalendarError, "That calendar is too big to sync.");
});

Deno.test("parseIcs: duplicate uids get distinct keys; the calendar's name comes along", () => {
  const text = cal(
    "BEGIN:VEVENT",
    "UID:dup",
    "DTSTART:20261021T170000Z",
    "SUMMARY:One",
    "END:VEVENT",
    "BEGIN:VEVENT",
    "UID:dup",
    "DTSTART:20261022T170000Z",
    "SUMMARY:Two",
    "END:VEVENT",
  );
  const parsed = parseIcs(text, opts);
  assertEquals(parsed.name, "Lincoln Elementary");
  assertEquals(parsed.rows.map((r) => r.uid), ["dup", "dup/20261022T170000Z"]);
});

Deno.test("parseIcs: not a calendar", () => {
  assertThrows(() => parseIcs("<html>Sign in</html>", opts), CalendarError, "That link didn't return a calendar.");
  assertThrows(() => parseIcs("BEGIN:VCALENDAR\r\nthis is :: not ical", opts), CalendarError);
});
