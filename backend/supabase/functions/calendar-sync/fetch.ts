// Fetching a calendar link a parent pasted. The function runs on the
// server, so a link must not reach the server's own network: only http(s)
// on public hosts, redirects checked the same way, a time limit and a size
// cap. webcal:// (what "Subscribe" buttons hand out) is https.

import { CalendarError } from "./rows.ts";

export type Fetch = typeof fetch;

export const MAX_CALENDAR_BYTES = 5 * 1024 * 1024;
const TIMEOUT_MS = 20_000;
const MAX_REDIRECTS = 5;

/** The https URL for a pasted link, or why it can't be used. */
export function normalizeCalendarUrl(input: unknown): { url: URL } | { error: string } {
  const bad = { error: "That doesn't look like a calendar link. It should start with https:// or webcal://." };
  if (typeof input !== "string") return bad;
  let text = input.trim();
  if (text.length > 2048) return { error: "That link is too long." };
  text = text.replace(/^webcals?:\/\//i, "https://");
  if (!/^https?:\/\//i.test(text)) return bad;
  let url: URL;
  try {
    url = new URL(text);
  } catch {
    return bad;
  }
  if (url.username || url.password) return { error: "Links with a user name or password aren't supported." };
  if (!isPublicHost(url.hostname)) return { error: "That link points to a private network." };
  url.hash = "";
  return { url };
}

/** False for localhost, private, link-local and other non-public addresses. */
export function isPublicHost(hostname: string): boolean {
  const host = hostname.toLowerCase().replace(/^\[|\]$/g, "").replace(/\.$/, "");
  if (!host || host === "localhost" || /\.(localhost|local|internal|lan|home|arpa)$/.test(host)) return false;
  if (!host.includes(".") && !host.includes(":")) return false; // a bare name only resolves inside a network
  const v4 = host.match(/^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/);
  if (v4) {
    const [a, b] = [Number(v4[1]), Number(v4[2])];
    return !(a === 0 || a === 10 || a === 127 || a >= 224 ||
      (a === 100 && b >= 64 && b <= 127) || (a === 169 && b === 254) ||
      (a === 172 && b >= 16 && b <= 31) || (a === 192 && b === 168) ||
      (a === 192 && b === 0) || (a === 198 && (b === 18 || b === 19)));
  }
  if (/^\d+$/.test(host) || /^0x/i.test(host)) return false; // 2130706433, 0x7f000001
  if (host.includes(":")) {
    // IPv6: loopback, unspecified, unique local, link-local, and IPv4-mapped ones.
    return !(host === "::1" || host === "::" || /^f[cd]/.test(host) || /^fe[89ab]/.test(host) || host.startsWith("::ffff:"));
  }
  return true;
}

/**
 * The text of the calendar at `url`. Throws CalendarError with a message a
 * parent can act on.
 */
export async function fetchCalendarText(doFetch: Fetch, start: URL): Promise<string> {
  let url = start;
  for (let hop = 0; ; hop++) {
    let res: Response;
    try {
      res = await doFetch(url, {
        redirect: "manual",
        signal: AbortSignal.timeout(TIMEOUT_MS),
        headers: { Accept: "text/calendar, text/plain;q=0.9, */*;q=0.5", "User-Agent": "OhanaOS-CalendarSync/1.0" },
      });
    } catch (err) {
      if (err instanceof DOMException && (err.name === "TimeoutError" || err.name === "AbortError")) {
        throw new CalendarError("The calendar took too long to answer.");
      }
      throw new CalendarError("The calendar link couldn't be reached.");
    }
    if (res.status >= 300 && res.status < 400 && res.headers.get("Location")) {
      await res.body?.cancel();
      if (hop >= MAX_REDIRECTS) throw new CalendarError("The calendar link redirects too many times.");
      const next = normalizeCalendarUrl(new URL(res.headers.get("Location")!, url).toString());
      if ("error" in next) throw new CalendarError(next.error);
      url = next.url;
      continue;
    }
    if (res.status === 401 || res.status === 403) {
      await res.body?.cancel();
      throw new CalendarError("The calendar link needs a sign-in. Use a public or secret link instead.");
    }
    if (res.status === 404 || res.status === 410) {
      await res.body?.cancel();
      throw new CalendarError("That calendar link doesn't exist anymore.");
    }
    if (!res.ok) {
      await res.body?.cancel();
      throw new CalendarError(`The calendar link answered with an error (${res.status}).`);
    }
    return await readCapped(res);
  }
}

async function readCapped(res: Response): Promise<string> {
  const tooBig = () => new CalendarError("That calendar is too big to sync (over 5 MB).");
  if (Number(res.headers.get("Content-Length")) > MAX_CALENDAR_BYTES) {
    await res.body?.cancel();
    throw tooBig();
  }
  if (!res.body) return "";
  const reader = res.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  try {
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > MAX_CALENDAR_BYTES) {
        await reader.cancel().catch(() => {});
        throw tooBig();
      }
      chunks.push(value);
    }
  } catch (err) {
    if (err instanceof CalendarError) throw err;
    throw new CalendarError("The calendar stopped answering halfway through.");
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const c of chunks) {
    bytes.set(c, offset);
    offset += c.byteLength;
  }
  return new TextDecoder().decode(bytes);
}
