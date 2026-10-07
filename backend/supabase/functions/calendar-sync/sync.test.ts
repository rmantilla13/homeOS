// Fake fetch and database calls answer at once, so many are async without an await.
// deno-lint-ignore-file require-await
import { assertEquals } from "jsr:@std/assert@1";
import { GENERIC_FAILURE, type Source, type SyncDeps, syncAll, syncSource } from "./sync.ts";
import type { SyncRow } from "./rows.ts";

const NOW = Date.parse("2026-10-07T12:00:00Z");
const link: Source = { id: "s1", family_id: "f1", provider: "ics", account_id: null, google_calendar_id: null };
const google: Source = { id: "s2", family_id: "f1", provider: "google", account_id: "a1", google_calendar_id: "family@group" };

const ICS = [
  "BEGIN:VCALENDAR",
  "VERSION:2.0",
  "BEGIN:VEVENT",
  "UID:fair",
  "DTSTART:20261020T150000Z",
  "DTEND:20261020T170000Z",
  "SUMMARY:Science fair",
  "END:VEVENT",
  "END:VCALENDAR",
].join("\r\n");

function fakeDeps(overrides: Partial<SyncDeps> & { responses?: Record<string, () => Response> } = {}) {
  const log: string[] = [];
  const applied: Record<string, SyncRow[]> = {};
  const failures: Record<string, string> = {};
  const responses = overrides.responses ?? {};
  const deps: SyncDeps = {
    now: () => NOW,
    resolve: async () => [],
    fetch: (async (input: URL | RequestInfo) => {
      const url = input.toString();
      log.push(`fetch ${url.split("?")[0]}`);
      const key = Object.keys(responses).find((k) => url.startsWith(k));
      return key ? responses[key]() : new Response("no route", { status: 500 });
    }) as typeof fetch,
    google: { clientId: "c", clientSecret: "s", redirectUri: "https://x/cb" },
    familyZone: async () => "America/Los_Angeles",
    link: async () => "webcal://school.example.org/cal.ics",
    token: async () => ({ refreshToken: "rt", accessToken: "old", expiresAt: NOW + 30_000 }),
    saveToken: async (id, token) => void log.push(`save ${id} ${token}`),
    markReconnect: async (id) => void log.push(`reconnect ${id}`),
    apply: async (id, rows) => {
      applied[id] = rows;
      return { added: rows.length, updated: 0, removed: 0, event_count: rows.length };
    },
    fail: async (id, message) => void (failures[id] = message),
    ...overrides,
  };
  return { deps, log, applied, failures };
}

const json = (body: unknown, status = 200) => () => new Response(JSON.stringify(body), { status });

Deno.test("syncSource: a link is fetched over https, parsed and applied", async () => {
  const { deps, log, applied } = fakeDeps({ responses: { "https://school.example.org/cal.ics": () => new Response(ICS) } });
  assertEquals(await syncSource(deps, link), { source_id: "s1", ok: true, added: 1, updated: 0, removed: 0, event_count: 1 });
  assertEquals(log, ["fetch https://school.example.org/cal.ics"]);
  assertEquals(applied.s1.map((r) => [r.uid, r.title, r.starts_at]), [["fair", "Science fair", "2026-10-20T15:00:00.000Z"]]);
});

Deno.test("syncSource: rows already fetched (a new link) aren't fetched again", async () => {
  const { deps, log, applied } = fakeDeps();
  const rows: SyncRow[] = [{ uid: "x", title: "X", description: null, location: null, starts_at: "2026-10-20T15:00:00.000Z", ends_at: "2026-10-20T16:00:00.000Z", all_day: false }];
  assertEquals((await syncSource(deps, link, rows)).ok, true);
  assertEquals(log, []);
  assertEquals(applied.s1, rows);
});

Deno.test("syncSource: Google refreshes an expiring token, saves it, then reads the calendar", async () => {
  const { deps, log, applied } = fakeDeps({
    responses: {
      "https://oauth2.googleapis.com/token": json({ access_token: "fresh", expires_in: 3600 }),
      "https://www.googleapis.com/calendar/v3/calendars/family%40group/events": json({
        items: [{ id: "e1", summary: "Dinner", start: { dateTime: "2026-10-08T01:00:00Z" }, end: { dateTime: "2026-10-08T02:00:00Z" } }],
      }),
    },
  });
  const outcome = await syncSource(deps, google);
  assertEquals(outcome.ok, true);
  assertEquals(log, [
    "fetch https://oauth2.googleapis.com/token",
    "save a1 fresh",
    "fetch https://www.googleapis.com/calendar/v3/calendars/family%40group/events",
  ]);
  assertEquals(applied.s2.map((r) => r.uid), ["e1"]);
});

Deno.test("syncSource: a token with time left is used as is", async () => {
  const { deps, log } = fakeDeps({
    token: async () => ({ refreshToken: "rt", accessToken: "good", expiresAt: NOW + 3_000_000 }),
    responses: { "https://www.googleapis.com/calendar/v3/": json({ items: [] }) },
  });
  assertEquals((await syncSource(deps, google)).ok, true);
  assertEquals(log, ["fetch https://www.googleapis.com/calendar/v3/calendars/family%40group/events"]);
});

Deno.test("syncSource: a revoked Google grant asks for a reconnect and records why", async () => {
  const { deps, log, failures } = fakeDeps({ responses: { "https://oauth2.googleapis.com/token": json({ error: "invalid_grant" }, 400) } });
  assertEquals(await syncSource(deps, google), { source_id: "s2", ok: false, error: "Google needs you to connect this account again." });
  assertEquals(log.at(-1), "reconnect a1");
  assertEquals(failures.s2, "Google needs you to connect this account again.");
});

Deno.test("syncSource: a broken link records a message a parent can act on; surprises stay generic", async () => {
  const gone = fakeDeps({ responses: { "https://school.example.org/": () => new Response("", { status: 404 }) } });
  assertEquals(await syncSource(gone.deps, link), { source_id: "s1", ok: false, error: "That calendar link doesn't exist anymore." });
  assertEquals(gone.failures.s1, "That calendar link doesn't exist anymore.");

  const html = fakeDeps({ responses: { "https://school.example.org/": () => new Response("<html>login</html>") } });
  assertEquals((await syncSource(html.deps, link)).ok, false);
  assertEquals(html.failures.s1, "That link didn't return a calendar.");

  const db = fakeDeps({
    responses: { "https://school.example.org/": () => new Response(ICS) },
    apply: async () => { throw new Error("connection reset"); },
  });
  assertEquals(await syncSource(db.deps, link), { source_id: "s1", ok: false, error: GENERIC_FAILURE });

  const noLink = fakeDeps({ link: async () => null });
  assertEquals((await syncSource(noLink.deps, link)).ok, false);
  assertEquals(noLink.failures.s1, "This calendar's link is missing. Remove it and add it again.");

  const noGoogle = fakeDeps({ google: null });
  await syncSource(noGoogle.deps, google);
  assertEquals(noGoogle.failures.s2, "Google Calendar isn't set up on this server yet.");
});

Deno.test("syncAll: everything, a few at a time, nothing new past the deadline", async () => {
  const { deps } = fakeDeps({ responses: { "https://school.example.org/": () => new Response(ICS) } });
  const many = Array.from({ length: 5 }, (_, i) => ({ ...link, id: `s${i}` }));
  assertEquals((await syncAll(deps, many, 2)).map((o) => o.source_id).sort(), ["s0", "s1", "s2", "s3", "s4"]);
  assertEquals(await syncAll(deps, many, 2, NOW), []);
});
