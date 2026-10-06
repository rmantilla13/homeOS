// Run with `npm test` (Node 22 strips the TypeScript types itself).
import assert from "node:assert/strict";
import { test } from "node:test";
import { cssColor, formatDate, formatDateTime, formatRelative, formatShortDate } from "../lib/format.ts";

test("cssColor passes hex colors through", () => {
  for (const c of ["#4F7CF7", "#abc", "#abcd", "#11223344", " #8E9CE6 "]) assert.equal(cssColor(c), c.trim());
});

test("cssColor refuses anything that would be more CSS", () => {
  const payloads = [
    "red;position:fixed;inset:0",
    "url(https://tracker.example/x.png)",
    "#fff;background-image:url(//x)",
    "expression(alert(1))",
    "var(--accent)",
    "red",
    "#12345",
    "",
    null,
    undefined,
    7,
  ];
  for (const p of payloads) assert.equal(cssColor(p), null, String(p));
});

test("formatRelative reads past and future times", () => {
  const now = Date.parse("2026-10-06T12:00:00Z");
  assert.equal(formatRelative("2026-10-06T11:59:30Z", now), "just now");
  assert.equal(formatRelative("2026-10-06T09:00:00Z", now), "3 hr. ago");
  assert.equal(formatRelative("2026-10-09T12:00:00Z", now), "in 3 days");
  assert.equal(formatRelative(null, now), "never");
});

test("dates Postgres can hold but JavaScript can't read don't throw", () => {
  for (const odd of ["infinity", "-infinity", "12345-01-01T00:00:00+00:00", "garbage"]) {
    assert.equal(formatRelative(odd), odd);
    assert.equal(formatDate(odd), odd);
    assert.equal(formatDateTime(odd), odd);
    assert.equal(formatShortDate(odd), odd);
  }
  assert.equal(formatDate("2026-10-06T23:30:00-02:00"), "Oct 7, 2026");
  assert.equal(formatShortDate("2026-10-06"), "Oct 6");
  assert.equal(formatDate(null), "—");
});
