// Fake fetch and database calls answer at once, so many are async without an await.
// deno-lint-ignore-file require-await
import { assert, assertEquals, assertRejects } from "jsr:@std/assert@1";
import {
  authUrl,
  CALENDAR_SCOPE,
  exchangeCode,
  googleConfig,
  GoogleReconnect,
  googleRows,
  idTokenEmail,
  listCalendars,
  listEvents,
  refreshAccess,
  signState,
  verifyState,
} from "./google.ts";

const config = { clientId: "client-1", clientSecret: "shh", redirectUri: "https://p.supabase.co/functions/v1/calendar-sync/google/callback" };
const NOW = Date.parse("2026-10-07T12:00:00Z");

Deno.test("googleConfig: needs both secrets; the callback defaults to this function", () => {
  const env = (vars: Record<string, string>) => (k: string) => vars[k];
  assertEquals(googleConfig(env({}), "https://p.supabase.co"), null);
  assertEquals(googleConfig(env({ GOOGLE_CLIENT_ID: "a" }), "https://p.supabase.co"), null);
  assertEquals(googleConfig(env({ GOOGLE_CLIENT_ID: "a", GOOGLE_CLIENT_SECRET: "b" }), "https://p.supabase.co/"), {
    clientId: "a",
    clientSecret: "b",
    redirectUri: "https://p.supabase.co/functions/v1/calendar-sync/google/callback",
  });
  assertEquals(googleConfig(env({ GOOGLE_CLIENT_ID: "a", GOOGLE_CLIENT_SECRET: "b", GOOGLE_REDIRECT_URI: "https://x.example/cb" }), "")
    ?.redirectUri, "https://x.example/cb");
});

Deno.test("authUrl: read-only calendar access, offline, consent every time", () => {
  const url = new URL(authUrl(config, "STATE"));
  assertEquals(url.origin + url.pathname, "https://accounts.google.com/o/oauth2/v2/auth");
  assertEquals(url.searchParams.get("scope"), `openid email ${CALENDAR_SCOPE}`);
  assertEquals(url.searchParams.get("access_type"), "offline");
  assertEquals(url.searchParams.get("prompt"), "consent");
  assertEquals(url.searchParams.get("redirect_uri"), config.redirectUri);
  assertEquals(url.searchParams.get("state"), "STATE");
});

Deno.test("state: signed, bound to the family and person, and short-lived", async () => {
  const s = await signState("secret", { familyId: "fam", userId: "mom" }, NOW);
  assertEquals(await verifyState("secret", s, NOW + 60_000), { familyId: "fam", userId: "mom", expires: NOW + 15 * 60_000 });
  assertEquals(await verifyState("secret", s, NOW + 16 * 60_000), null, "expired");
  assertEquals(await verifyState("other secret", s, NOW), null, "another key");
  const [payload, sig] = s.split(".");
  const forged = btoa(JSON.stringify({ f: "fam2", u: "mom", e: NOW + 1e9, n: "x" })).replace(/=+$/, "");
  assertEquals(await verifyState("secret", `${forged}.${sig}`, NOW), null, "a changed payload");
  assertEquals(await verifyState("secret", `${payload}.${sig}.x`, NOW), null);
  assertEquals(await verifyState("secret", "garbage", NOW), null);
  assertEquals(await verifyState("secret", null, NOW), null);
});

const jwt = (claims: Record<string, unknown>) => `h.${btoa(JSON.stringify(claims)).replace(/=+$/, "")}.s`;

Deno.test("idTokenEmail", () => {
  assertEquals(idTokenEmail(jwt({ email: "Mom@Gmail.com" })), "mom@gmail.com");
  assertEquals(idTokenEmail(jwt({ sub: "1" })), null);
  assertEquals(idTokenEmail("nope"), null);
  assertEquals(idTokenEmail(undefined), null);
});

const jsonResponse = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

Deno.test("exchangeCode: posts the code and reads the grant", async () => {
  let sent: URLSearchParams | null = null;
  const fake = (async (_url: URL | RequestInfo, init?: RequestInit) => {
    sent = init?.body as URLSearchParams;
    return jsonResponse({
      access_token: "at",
      expires_in: 3599,
      refresh_token: "rt",
      scope: `openid ${CALENDAR_SCOPE} https://www.googleapis.com/auth/userinfo.email`,
      id_token: jwt({ email: "mom@gmail.com" }),
    });
  }) as typeof fetch;
  const grant = await exchangeCode(fake, config, "the-code", NOW);
  assertEquals(grant, {
    accessToken: "at",
    expiresAt: NOW + 3599_000,
    refreshToken: "rt",
    scopes: ["openid", CALENDAR_SCOPE, "https://www.googleapis.com/auth/userinfo.email"],
    email: "mom@gmail.com",
  });
  assertEquals(sent!.get("grant_type"), "authorization_code");
  assertEquals(sent!.get("code"), "the-code");
  assertEquals(sent!.get("client_secret"), "shh");
  assertEquals(sent!.get("redirect_uri"), config.redirectUri);
});

Deno.test("refreshAccess: a revoked grant means connecting again", async () => {
  const revoked = (async () => jsonResponse({ error: "invalid_grant" }, 400)) as typeof fetch;
  await assertRejects(() => refreshAccess(revoked, config, "rt", NOW), GoogleReconnect);
  const down = (async () => jsonResponse({ error: "server_error" }, 503)) as typeof fetch;
  const err = await assertRejects(() => refreshAccess(down, config, "rt", NOW));
  assert(!(err instanceof GoogleReconnect));
});

Deno.test("listCalendars: readable calendars, primary first, hidden ones left out", async () => {
  let path = "";
  const fake = (async (url: URL | RequestInfo, init?: RequestInit) => {
    path = url.toString();
    assertEquals((init?.headers as Record<string, string>).Authorization, "Bearer at");
    return jsonResponse({
      items: [
        { id: "family@group.calendar.google.com", summary: "Family", backgroundColor: "#9fe1e7" },
        { id: "mom@gmail.com", summary: "mom@gmail.com", summaryOverride: "Mom", primary: true, backgroundColor: "#16a765" },
        { id: "hidden", summary: "Hidden", hidden: true },
        { id: "holidays", summary: "Holidays", backgroundColor: "blue" },
      ],
    });
  }) as typeof fetch;
  assertEquals(await listCalendars(fake, "at"), [
    { id: "mom@gmail.com", name: "Mom", color: "#16A765", primary: true },
    { id: "family@group.calendar.google.com", name: "Family", color: "#9FE1E7", primary: false },
    { id: "holidays", name: "Holidays", color: null, primary: false },
  ]);
  assert(path.includes("minAccessRole=reader"));
});

Deno.test("listEvents: pages, expanded repeats, the window", async () => {
  const urls: URL[] = [];
  const fake = (async (url: URL | RequestInfo) => {
    const u = new URL(url.toString());
    urls.push(u);
    return u.searchParams.get("pageToken")
      ? jsonResponse({ items: [{ id: "b" }] })
      : jsonResponse({ items: [{ id: "a" }], nextPageToken: "p2" });
  }) as typeof fetch;
  const window = { from: NOW, to: NOW + 86_400_000 };
  assertEquals((await listEvents(fake, "at", "family@group.calendar.google.com", window)).map((e) => e.id), ["a", "b"]);
  assertEquals(urls[0].pathname, "/calendar/v3/calendars/family%40group.calendar.google.com/events");
  assertEquals(urls[0].searchParams.get("singleEvents"), "true");
  assertEquals(urls[0].searchParams.get("timeMin"), "2026-10-07T12:00:00.000Z");
  assertEquals(urls[1].searchParams.get("pageToken"), "p2");
});

Deno.test("listEvents: Google's answers become messages a parent can act on", async () => {
  const fail = (status: number, reason?: string) =>
    (async () => jsonResponse({ error: { errors: reason ? [{ reason }] : [] } }, status)) as typeof fetch;
  const window = { from: NOW, to: NOW + 1 };
  await assertRejects(() => listEvents(fail(401), "at", "c", window), GoogleReconnect);
  await assertRejects(() => listEvents(fail(403, "insufficientPermissions"), "at", "c", window), GoogleReconnect);
  await assertRejects(() => listEvents(fail(404), "at", "c", window), Error, "That Google calendar isn't shared with this account anymore.");
  await assertRejects(() => listEvents(fail(500), "at", "c", window), Error, "Google Calendar didn't answer. Ohana will try again soon.");
});

Deno.test("googleRows: timed, all-day, private, cancelled and working-location events", () => {
  const window = { from: Date.parse("2026-10-01T00:00:00Z"), to: Date.parse("2026-12-01T00:00:00Z") };
  const rows = googleRows([
    { id: "a_20261026T233000Z", summary: "Soccer", location: "Field 3", start: { dateTime: "2026-10-26T16:30:00-07:00" }, end: { dateTime: "2026-10-26T17:30:00-07:00" } },
    { id: "trip", summary: "Trip", start: { date: "2026-11-23" }, end: { date: "2026-11-26" } },
    { id: "doc", summary: "Doctor", description: "Results", visibility: "private", start: { dateTime: "2026-10-27T09:00:00Z" }, end: { dateTime: "2026-10-27T10:00:00Z" } },
    { id: "gone", status: "cancelled", start: { dateTime: "2026-10-28T09:00:00Z" } },
    { id: "wfh", eventType: "workingLocation", summary: "Home", start: { date: "2026-10-28" }, end: { date: "2026-10-29" } },
    { id: "old", summary: "Old", start: { dateTime: "2026-09-01T09:00:00Z" }, end: { dateTime: "2026-09-01T10:00:00Z" } },
    { summary: "No id", start: { dateTime: "2026-10-28T09:00:00Z" } },
    { id: "odd", start: { dateTime: "2026-10-29T09:00:00Z" }, end: { dateTime: "2026-10-29T08:00:00Z" } },
  ], "America/Los_Angeles", window);
  assertEquals(rows, [
    { uid: "a_20261026T233000Z", title: "Soccer", description: null, location: "Field 3", starts_at: "2026-10-26T23:30:00.000Z", ends_at: "2026-10-27T00:30:00.000Z", all_day: false },
    { uid: "trip", title: "Trip", description: null, location: null, starts_at: "2026-11-23T08:00:00.000Z", ends_at: "2026-11-26T07:59:59.000Z", all_day: true },
    { uid: "doc", title: "Busy", description: null, location: null, starts_at: "2026-10-27T09:00:00.000Z", ends_at: "2026-10-27T10:00:00.000Z", all_day: false },
    { uid: "odd", title: "Untitled event", description: null, location: null, starts_at: "2026-10-29T09:00:00.000Z", ends_at: "2026-10-29T09:00:00.000Z", all_day: false },
  ]);
});
