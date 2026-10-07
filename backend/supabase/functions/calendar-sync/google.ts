// Google Calendar: OAuth (web server flow, offline access, read-only scope)
// and the Calendar API calls a sync needs. The refresh token stays in
// calendar_account_tokens; phones and displays never see it.
//
// Google expands repeats for us (singleEvents=true), so moved and cancelled
// repeats come out exactly as Google Calendar shows them. Events marked
// private or confidential come in as "Busy", as on a shared screen they
// should. Working-location and focus-time blocks are left out.

import { allDaySpan, addDays } from "./time.ts";
import { BUSY, CalendarError, clip, MAX_ROWS, overlaps, type SyncRow } from "./rows.ts";
import type { Fetch } from "./fetch.ts";

export const CALENDAR_SCOPE = "https://www.googleapis.com/auth/calendar.readonly";
const AUTH_URL = "https://accounts.google.com/o/oauth2/v2/auth";
const TOKEN_URL = "https://oauth2.googleapis.com/token";
const REVOKE_URL = "https://oauth2.googleapis.com/revoke";
const API = "https://www.googleapis.com/calendar/v3";
const STATE_TTL_MS = 15 * 60 * 1000;
const MAX_PAGES = 10;

export interface GoogleConfig {
  clientId: string;
  clientSecret: string;
  redirectUri: string; // must be listed on the OAuth client in Google Cloud
}

/** The OAuth client from the function's secrets, or null when Google isn't set up. */
export function googleConfig(env: (name: string) => string | undefined, supabaseUrl: string): GoogleConfig | null {
  const clientId = env("GOOGLE_CLIENT_ID")?.trim();
  const clientSecret = env("GOOGLE_CLIENT_SECRET")?.trim();
  if (!clientId || !clientSecret) return null;
  const redirectUri = env("GOOGLE_REDIRECT_URI")?.trim() ||
    `${supabaseUrl.replace(/\/+$/, "")}/functions/v1/calendar-sync/google/callback`;
  return { clientId, clientSecret, redirectUri };
}

/** Google refused the account's token: a parent has to connect it again. */
export class GoogleReconnect extends CalendarError {
  constructor() {
    super("Google needs you to connect this account again.");
  }
}

// ───────────────────────────── OAuth ─────────────────────────────

export function authUrl(config: GoogleConfig, state: string): string {
  const q = new URLSearchParams({
    client_id: config.clientId,
    redirect_uri: config.redirectUri,
    response_type: "code",
    scope: ["openid", "email", CALENDAR_SCOPE].join(" "),
    access_type: "offline", // a refresh token, so syncs run without the parent
    prompt: "consent", // and one every time, even for an account connected before
    include_granted_scopes: "true",
    state,
  });
  return `${AUTH_URL}?${q}`;
}

export interface OAuthState {
  familyId: string;
  userId: string;
  expires: number;
}

const b64url = (bytes: Uint8Array) =>
  btoa(String.fromCharCode(...bytes)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const fromB64url = (text: string) =>
  Uint8Array.from(atob(text.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));

async function stateKey(secret: string): Promise<CryptoKey> {
  return await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(`calendar-sync oauth state\n${secret}`),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
}

/**
 * The OAuth `state`: who started connecting an account to which family,
 * signed so the callback (a plain browser redirect, no Supabase session)
 * can trust it. It expires after 15 minutes.
 */
export async function signState(secret: string, s: { familyId: string; userId: string }, now: number): Promise<string> {
  const payload = b64url(new TextEncoder().encode(JSON.stringify({
    f: s.familyId,
    u: s.userId,
    e: now + STATE_TTL_MS,
    n: b64url(crypto.getRandomValues(new Uint8Array(9))),
  })));
  const sig = new Uint8Array(await crypto.subtle.sign("HMAC", await stateKey(secret), new TextEncoder().encode(payload)));
  return `${payload}.${b64url(sig)}`;
}

export async function verifyState(secret: string, state: unknown, now: number): Promise<OAuthState | null> {
  if (typeof state !== "string" || state.length > 1000) return null;
  const [payload, sig, extra] = state.split(".");
  if (!payload || !sig || extra !== undefined) return null;
  try {
    const ok = await crypto.subtle.verify("HMAC", await stateKey(secret), fromB64url(sig), new TextEncoder().encode(payload));
    if (!ok) return null;
    const v = JSON.parse(new TextDecoder().decode(fromB64url(payload)));
    if (typeof v.f !== "string" || typeof v.u !== "string" || typeof v.e !== "number" || v.e < now) return null;
    return { familyId: v.f, userId: v.u, expires: v.e };
  } catch {
    return null;
  }
}

export interface TokenGrant {
  accessToken: string;
  expiresAt: number;
  refreshToken: string | null;
  scopes: string[];
  email: string | null;
}

async function tokenRequest(doFetch: Fetch, body: Record<string, string>): Promise<Record<string, unknown>> {
  let res: Response;
  try {
    res = await doFetch(TOKEN_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams(body),
      signal: AbortSignal.timeout(15_000),
    });
  } catch {
    throw new CalendarError("Google didn't answer. Try again in a moment.");
  }
  const data = await res.json().catch(() => ({})) as Record<string, unknown>;
  if (!res.ok) {
    if (data.error === "invalid_grant") throw new GoogleReconnect();
    console.error("google token request failed:", res.status, data.error);
    throw new CalendarError("Google didn't accept the sign-in. Try again in a moment.");
  }
  return data;
}

// The email in an ID token that came straight from Google's token endpoint
// over TLS, which OpenID Connect says needs no signature check.
export function idTokenEmail(idToken: unknown): string | null {
  if (typeof idToken !== "string") return null;
  try {
    const claims = JSON.parse(new TextDecoder().decode(fromB64url(idToken.split(".")[1] ?? "")));
    return typeof claims.email === "string" ? claims.email.toLowerCase() : null;
  } catch {
    return null;
  }
}

function grantFrom(data: Record<string, unknown>, now: number): TokenGrant {
  if (typeof data.access_token !== "string") throw new CalendarError("Google didn't accept the sign-in. Try again in a moment.");
  return {
    accessToken: data.access_token,
    expiresAt: now + (typeof data.expires_in === "number" ? data.expires_in : 3600) * 1000,
    refreshToken: typeof data.refresh_token === "string" ? data.refresh_token : null,
    scopes: typeof data.scope === "string" ? data.scope.split(" ") : [],
    email: idTokenEmail(data.id_token),
  };
}

export async function exchangeCode(doFetch: Fetch, config: GoogleConfig, code: string, now: number): Promise<TokenGrant> {
  return grantFrom(await tokenRequest(doFetch, {
    grant_type: "authorization_code",
    code,
    client_id: config.clientId,
    client_secret: config.clientSecret,
    redirect_uri: config.redirectUri,
  }), now);
}

export async function refreshAccess(doFetch: Fetch, config: GoogleConfig, refreshToken: string, now: number): Promise<TokenGrant> {
  return grantFrom(await tokenRequest(doFetch, {
    grant_type: "refresh_token",
    refresh_token: refreshToken,
    client_id: config.clientId,
    client_secret: config.clientSecret,
  }), now);
}

/** Tells Google to forget the grant. Best effort: the account goes either way. */
export async function revokeToken(doFetch: Fetch, token: string): Promise<boolean> {
  try {
    const res = await doFetch(REVOKE_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ token }),
      signal: AbortSignal.timeout(10_000),
    });
    await res.body?.cancel();
    return res.ok;
  } catch {
    return false;
  }
}

// ───────────────────────────── Calendar API ─────────────────────────────

async function api(doFetch: Fetch, accessToken: string, path: string, query: URLSearchParams): Promise<Record<string, unknown>> {
  let res: Response;
  try {
    res = await doFetch(`${API}${path}?${query}`, {
      headers: { Authorization: `Bearer ${accessToken}`, Accept: "application/json" },
      signal: AbortSignal.timeout(20_000),
    });
  } catch {
    throw new CalendarError("Google Calendar didn't answer. Ohana will try again soon.");
  }
  if (res.ok) return await res.json() as Record<string, unknown>;
  const body = await res.json().catch(() => ({})) as { error?: { errors?: { reason?: string }[] } };
  const reason = body.error?.errors?.[0]?.reason;
  if (res.status === 401 || (res.status === 403 && reason === "insufficientPermissions")) throw new GoogleReconnect();
  if (res.status === 404) throw new CalendarError("That Google calendar isn't shared with this account anymore.");
  console.error("google calendar api failed:", res.status, reason);
  throw new CalendarError("Google Calendar didn't answer. Ohana will try again soon.");
}

export interface GoogleCalendar {
  id: string;
  name: string;
  color: string | null; // #RRGGBB
  primary: boolean;
}

const hexColor = (value: unknown) =>
  typeof value === "string" && /^#[0-9a-f]{6}$/i.test(value) ? value.toUpperCase() : null;

/** The calendars the account can read, primary first, then by name. */
export async function listCalendars(doFetch: Fetch, accessToken: string): Promise<GoogleCalendar[]> {
  const data = await api(doFetch, accessToken, "/users/me/calendarList", new URLSearchParams({
    minAccessRole: "reader",
    maxResults: "250",
    fields: "items(id,summary,summaryOverride,backgroundColor,primary,hidden)",
  }));
  const items = Array.isArray(data.items) ? data.items as Record<string, unknown>[] : [];
  return items
    .filter((c) => typeof c.id === "string" && c.hidden !== true)
    .map((c) => ({
      id: c.id as string,
      name: clip(c.summaryOverride, 100) ?? clip(c.summary, 100) ?? (c.id as string).slice(0, 100),
      color: hexColor(c.backgroundColor),
      primary: c.primary === true,
    }))
    .sort((a, b) => Number(b.primary) - Number(a.primary) || a.name.localeCompare(b.name));
}

export interface GoogleEvent {
  id?: string;
  status?: string;
  summary?: string;
  description?: string;
  location?: string;
  visibility?: string;
  eventType?: string;
  start?: { date?: string; dateTime?: string };
  end?: { date?: string; dateTime?: string };
}

/** Every occurrence in [from, to), up to MAX_ROWS, repeats expanded by Google. */
export async function listEvents(doFetch: Fetch, accessToken: string, calendarId: string,
  window: { from: number; to: number }): Promise<GoogleEvent[]> {
  const items: GoogleEvent[] = [];
  let pageToken: string | undefined;
  for (let page = 0; page < MAX_PAGES && items.length < MAX_ROWS; page++) {
    const q = new URLSearchParams({
      singleEvents: "true",
      orderBy: "startTime",
      showDeleted: "false",
      maxResults: "2500",
      timeMin: new Date(window.from).toISOString(),
      timeMax: new Date(window.to).toISOString(),
      fields: "items(id,status,summary,description,location,visibility,eventType,start,end),nextPageToken",
    });
    if (pageToken) q.set("pageToken", pageToken);
    const data = await api(doFetch, accessToken, `/calendars/${encodeURIComponent(calendarId)}/events`, q);
    if (Array.isArray(data.items)) items.push(...data.items as GoogleEvent[]);
    pageToken = typeof data.nextPageToken === "string" ? data.nextPageToken : undefined;
    if (!pageToken) break;
  }
  return items;
}

const SKIPPED_TYPES = new Set(["workingLocation", "focusTime"]);

/** Google events as sync rows. All-day events use the family's zone. */
export function googleRows(items: GoogleEvent[], timeZone: string, window: { from: number; to: number }): SyncRow[] {
  const rows: SyncRow[] = [];
  for (const e of items) {
    if (!e.id || e.status === "cancelled" || SKIPPED_TYPES.has(e.eventType ?? "")) continue;
    const busy = e.visibility === "private" || e.visibility === "confidential";
    const text = {
      title: busy ? BUSY : clip(e.summary, 500) ?? "Untitled event",
      description: busy ? null : clip(e.description, 4000),
      location: busy ? null : clip(e.location, 500),
    };
    let startsAt: string, endsAt: string, allDay: boolean;
    if (e.start?.date && /^\d{4}-\d{2}-\d{2}$/.test(e.start.date)) {
      const last = e.end?.date && /^\d{4}-\d{2}-\d{2}$/.test(e.end.date) ? addDays(e.end.date, -1) : e.start.date;
      ({ startsAt, endsAt } = allDaySpan(timeZone, e.start.date, last));
      allDay = true;
    } else {
      const start = Date.parse(e.start?.dateTime ?? "");
      let end = Date.parse(e.end?.dateTime ?? "");
      if (!Number.isFinite(start)) continue;
      if (!Number.isFinite(end) || end < start) end = start;
      startsAt = new Date(start).toISOString();
      endsAt = new Date(end).toISOString();
      allDay = false;
    }
    if (!overlaps(Date.parse(startsAt), Date.parse(endsAt), window.from, window.to)) continue;
    rows.push({ uid: e.id, ...text, starts_at: startsAt, ends_at: endsAt, all_day: allDay });
  }
  return rows;
}
