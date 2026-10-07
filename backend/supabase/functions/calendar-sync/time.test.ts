import { assertEquals } from "jsr:@std/assert@1";
import { addDays, allDaySpan, isTimeZone, localDate, wallTimeToMs, zoneOrUtc } from "./time.ts";

const wall = (y: number, mo: number, d: number, h = 0, mi = 0, s = 0) =>
  ({ year: y, month: mo, day: d, hour: h, minute: mi, second: s });
const iso = (ms: number) => new Date(ms).toISOString();

Deno.test("isTimeZone / zoneOrUtc: IANA names only", () => {
  assertEquals(isTimeZone("America/Los_Angeles"), true);
  assertEquals(isTimeZone("UTC"), true);
  assertEquals(isTimeZone("Not/AZone"), false);
  assertEquals(isTimeZone(""), false);
  assertEquals(isTimeZone(null), false);
  assertEquals(zoneOrUtc("Not/AZone"), "UTC");
  assertEquals(zoneOrUtc("Europe/Berlin"), "Europe/Berlin");
});

Deno.test("wallTimeToMs: ordinary times on both sides of DST", () => {
  assertEquals(iso(wallTimeToMs("America/Los_Angeles", wall(2026, 10, 26, 16, 30))), "2026-10-26T23:30:00.000Z");
  assertEquals(iso(wallTimeToMs("America/Los_Angeles", wall(2026, 11, 2, 16, 30))), "2026-11-03T00:30:00.000Z");
  assertEquals(iso(wallTimeToMs("Asia/Kolkata", wall(2026, 1, 1, 9, 0))), "2026-01-01T03:30:00.000Z");
  assertEquals(iso(wallTimeToMs("UTC", wall(2026, 1, 1, 9, 0))), "2026-01-01T09:00:00.000Z");
});

Deno.test("wallTimeToMs: a repeated hour is the first, a skipped one moves forward (RFC 5545)", () => {
  // 2026-11-01 01:30 happens twice in Los Angeles: PDT (08:30Z) first.
  assertEquals(iso(wallTimeToMs("America/Los_Angeles", wall(2026, 11, 1, 1, 30))), "2026-11-01T08:30:00.000Z");
  // 2026-03-08 02:30 doesn't exist: it's read with the offset before the jump (PST), 03:30 PDT.
  assertEquals(iso(wallTimeToMs("America/Los_Angeles", wall(2026, 3, 8, 2, 30))), "2026-03-08T10:30:00.000Z");
});

Deno.test("dates: addDays, localDate", () => {
  assertEquals(addDays("2026-12-31", 1), "2027-01-01");
  assertEquals(addDays("2028-03-01", -1), "2028-02-29");
  assertEquals(localDate("America/Los_Angeles", Date.parse("2026-10-27T03:00:00Z")), "2026-10-26");
  assertEquals(localDate("Asia/Tokyo", Date.parse("2026-10-26T20:00:00Z")), "2026-10-27");
});

Deno.test("allDaySpan: local midnight to 23:59:59, also across DST", () => {
  assertEquals(allDaySpan("America/New_York", "2026-10-31", "2026-11-01"), {
    startsAt: "2026-10-31T04:00:00.000Z",
    endsAt: "2026-11-02T04:59:59.000Z",
  });
  // A last day before the first is the first day alone.
  assertEquals(allDaySpan("UTC", "2026-10-07", "2026-10-06"), {
    startsAt: "2026-10-07T00:00:00.000Z",
    endsAt: "2026-10-07T23:59:59.000Z",
  });
});
