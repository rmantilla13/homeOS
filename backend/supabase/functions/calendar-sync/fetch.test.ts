// Fake fetch and database calls answer at once, so many are async without an await.
// deno-lint-ignore-file require-await
import { assertEquals, assertRejects } from "jsr:@std/assert@1";
import { fetchCalendarText, isPublicHost, MAX_CALENDAR_BYTES, normalizeCalendarUrl } from "./fetch.ts";
import { CalendarError } from "./rows.ts";

const noDns = async () => [] as string[];

const urlOf = (input: string) => {
  const r = normalizeCalendarUrl(input);
  return "url" in r ? r.url.toString() : r.error;
};

Deno.test("normalizeCalendarUrl: webcal becomes https; other schemes and private hosts are refused", () => {
  assertEquals(urlOf(" webcal://p52-caldav.icloud.com/published/2/abc "), "https://p52-caldav.icloud.com/published/2/abc");
  assertEquals(urlOf("WEBCALS://example.com/a.ics"), "https://example.com/a.ics");
  assertEquals(urlOf("https://calendar.google.com/calendar/ical/x%40gmail.com/private-abc/basic.ics#frag"),
    "https://calendar.google.com/calendar/ical/x%40gmail.com/private-abc/basic.ics");
  assertEquals(urlOf("http://school.example.org/cal.ics"), "http://school.example.org/cal.ics");
  assertEquals(urlOf("ftp://example.com/a.ics"), "That doesn't look like a calendar link. It should start with https:// or webcal://.");
  assertEquals(urlOf("calendar.google.com/x.ics"), "That doesn't look like a calendar link. It should start with https:// or webcal://.");
  assertEquals(urlOf("https://user:pw@example.com/a.ics"), "Links with a user name or password aren't supported.");
  assertEquals(urlOf("http://localhost:54321/functions/v1/x"), "That link points to a private network.");
  assertEquals(urlOf("http://169.254.169.254/latest/meta-data"), "That link points to a private network.");
  assertEquals(urlOf(`https://example.com/${"a".repeat(2100)}`), "That link is too long.");
  assertEquals(urlOf(42 as unknown as string), "That doesn't look like a calendar link. It should start with https:// or webcal://.");
});

Deno.test("isPublicHost", () => {
  for (const host of ["calendar.google.com", "p52-caldav.icloud.com", "8.8.8.8", "[2606:4700::1111]", "outlook.office365.com"]) {
    assertEquals(isPublicHost(host), true, host);
  }
  for (const host of ["localhost", "db.localhost", "printer.local", "kong", "10.0.0.5", "127.0.0.1", "172.16.0.1",
    "192.168.1.10", "100.64.0.1", "0.0.0.0", "[::1]", "[fd00::1]", "[fe80::1]", "[::ffff:127.0.0.1]", "2130706433",
    "0x7f000001", "metadata.google.internal", "[64:ff9b::a00:1]", "[2002:a00:1::]", "[ff02::1]"]) {
    assertEquals(isPublicHost(host), false, host);
  }
});

const respond = (status: number, body = "", headers: Record<string, string> = {}) => new Response(body, { status, headers });

Deno.test("fetchCalendarText: follows public redirects and returns the text", async () => {
  const seen: string[] = [];
  const fake = (async (input: URL | RequestInfo) => {
    const url = input.toString();
    seen.push(url);
    if (url.endsWith("/old.ics")) return respond(301, "", { Location: "/new.ics" });
    return respond(200, "BEGIN:VCALENDAR\r\nEND:VCALENDAR");
  }) as typeof fetch;
  assertEquals(await fetchCalendarText(fake, new URL("https://example.com/old.ics"), noDns), "BEGIN:VCALENDAR\r\nEND:VCALENDAR");
  assertEquals(seen, ["https://example.com/old.ics", "https://example.com/new.ics"]);
});

Deno.test("fetchCalendarText: refuses a redirect into a private network", async () => {
  const fake = (async () => respond(302, "", { Location: "http://10.0.0.1/admin" })) as typeof fetch;
  await assertRejects(() => fetchCalendarText(fake, new URL("https://example.com/a.ics"), noDns), CalendarError,
    "That link points to a private network.");
});

Deno.test("fetchCalendarText: errors a parent can act on", async () => {
  const cases: [Response, string][] = [
    [respond(404), "That calendar link doesn't exist anymore."],
    [respond(401), "The calendar link needs a sign-in. Use a public or secret link instead."],
    [respond(500), "The calendar link answered with an error (500)."],
    [respond(200, "x", { "Content-Length": String(MAX_CALENDAR_BYTES + 1) }), "That calendar is too big to sync (over 5 MB)."],
  ];
  for (const [res, message] of cases) {
    await assertRejects(() => fetchCalendarText((async () => res) as typeof fetch, new URL("https://example.com/a.ics"), noDns),
      CalendarError, message);
  }
  const bigStream = new ReadableStream<Uint8Array>({
    pull(c) {
      c.enqueue(new Uint8Array(1024 * 1024));
    },
  });
  await assertRejects(() => fetchCalendarText((async () => new Response(bigStream)) as typeof fetch, new URL("https://example.com/a.ics"), noDns),
    CalendarError, "That calendar is too big to sync (over 5 MB).");
  await assertRejects(() => fetchCalendarText((async () => { throw new TypeError("dns"); }) as typeof fetch, new URL("https://example.com/a.ics"), noDns),
    CalendarError, "The calendar link couldn't be reached.");
  let hops = 0;
  const loop = (async () => respond(302, "", { Location: `/a${++hops}.ics` })) as typeof fetch;
  await assertRejects(() => fetchCalendarText(loop, new URL("https://example.com/a.ics"), noDns), CalendarError,
    "The calendar link redirects too many times.");
});

Deno.test("fetchCalendarText: a name that resolves to a private address is refused, on every hop", async () => {
  const dns: Record<string, string[]> = {
    "10.0.0.5.nip.io": ["10.0.0.5"],
    "calendar.example.com": ["93.184.215.14", "2606:2800:21f:cb07:6820:80da:af6b:8b2c"],
    "sneaky.example.com": ["93.184.215.14", "::1"],
  };
  const resolve = async (host: string) => dns[host] ?? [];
  const ok = (async () => respond(200, "BEGIN:VCALENDAR")) as typeof fetch;
  await assertRejects(() => fetchCalendarText(ok, new URL("https://10.0.0.5.nip.io/a.ics"), resolve), CalendarError,
    "That link points to a private network.");
  await assertRejects(() => fetchCalendarText(ok, new URL("https://sneaky.example.com/a.ics"), resolve), CalendarError,
    "That link points to a private network.");
  assertEquals(await fetchCalendarText(ok, new URL("https://calendar.example.com/a.ics"), resolve), "BEGIN:VCALENDAR");
  const hop = (async (input: URL | RequestInfo) =>
    input.toString().includes("calendar.example.com")
      ? respond(302, "", { Location: "https://10.0.0.5.nip.io/admin" })
      : respond(200, "secret")) as typeof fetch;
  await assertRejects(() => fetchCalendarText(hop, new URL("https://calendar.example.com/a.ics"), resolve), CalendarError,
    "That link points to a private network.");
  // A lookup that fails (or a runtime without DNS) leaves the request to fail or succeed on its own.
  const broken = async () => { throw new Error("no dns"); };
  assertEquals(await fetchCalendarText(ok, new URL("https://calendar.example.com/a.ics"), broken), "BEGIN:VCALENDAR");
});
