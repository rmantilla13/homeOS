// calendar-sync: connected calendars. See docs/PLATFORM_SPEC.md §2.5.
//
// In: events from a Google account or any calendar link (ICS / webcal) are
// copied into `events` as read-only rows, one per occurrence, refreshed every
// 15 minutes (pg_cron calls sync_due), when someone opens the app, and every
// 15 minutes from a paired display. Out: the family's own events as a
// subscribable ICS link.
//
//   POST with a person's or display's JWT:
//     { action: "add_link", family_id, url, name?, color?, member_id?, busy_only? }
//                                       parent -> { source_id, name, event_count, sync_error? }
//     { action: "google_start", family_id }            parent -> { url }  (open it in a browser sheet)
//     { action: "google_finish", code, state }         the parent who started it -> { account_id, email }
//     { action: "google_calendars", account_id }       the parent who connected it -> { email, calendars: [...] }
//     { action: "add_google", account_id, calendar_id, name?, color?, member_id?, busy_only? }
//                                       the parent who connected it -> { source_id, name, event_count, sync_error? }
//     { action: "disconnect_google", account_id }      parent -> { ok, revoked }
//     { action: "sync", source_id | family_id, force? } anyone in the family -> { results: [{ source_id, ok, ... }] }
//   POST with `Authorization: Bearer <CALENDAR_CRON_SECRET>`:
//     { action: "sync_due" } -> { synced, failed }
//   POST with the service role key (this function calling itself):
//     { action: "sync_source", source_id } -> { source_id, ok, ... }
//     Edge functions get about 2 s of CPU per request, so a run that syncs
//     several calendars hands each one to its own request.
//   GET  .../calendar-sync/google/callback?code&state   Google's redirect after consent; answers with a
//        redirect to CALENDAR_APP_REDIRECT (ohanaos://google-calendar) carrying code and state, or error.
//        The app then sends google_finish with its own JWT, so only the parent who started the sign-in
//        can finish it: a consent link sent to someone else can't attach their account to another family.
//   GET  .../calendar-sync/feed/<token>.ics             the family's own events (the token is the secret)
//
// Errors are { error } with 400 (bad body, or a link or Google problem the
// message explains), 401, 403 (not a parent / not in the family), 404, 409
// (already connected; or { reconnect: true } when Google needs the account
// connected again), 503 (Google isn't set up, or Auth is unreachable).
//
// Who may do what is checked with the caller's own JWT (RLS and
// is_family_parent); secrets and writes go through the service role.

import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2";
import { authenticate, bearerToken, HttpError, json, preflight, readJson } from "../_shared/http.ts";
import { buildFeed, type FeedOccurrence } from "./feed.ts";
import { fetchCalendarText, normalizeCalendarUrl } from "./fetch.ts";
import {
  authUrl,
  CALENDAR_SCOPE,
  exchangeCode,
  googleConfig,
  GoogleReconnect,
  listCalendars,
  revokeToken,
  signState,
  verifyState,
} from "./google.ts";
import { parseIcs } from "./ics.ts";
import { type CalendarRequest, parseCalendarRequest } from "./request.ts";
import { CalendarError, clip, nearestRows, syncWindow } from "./rows.ts";
import {
  accessTokenFor,
  type ApplyResult,
  GENERIC_FAILURE,
  type Source,
  type SyncDeps,
  syncAll,
  type SyncOutcome,
  syncSource,
} from "./sync.ts";
import { zoneOrUtc } from "./time.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const CRON_SECRET = Deno.env.get("CALENDAR_CRON_SECRET") ?? "";
const APP_REDIRECT = Deno.env.get("CALENDAR_APP_REDIRECT") || "ohanaos://google-calendar";
const GOOGLE = googleConfig((name) => Deno.env.get(name), SUPABASE_URL);

const SOURCE_COLUMNS = "id, family_id, provider, account_id, google_calendar_id";
const FEED_TOKEN = /^[A-Za-z0-9_-]{32}$/;

const service = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

// ───────────────────────────── Sync plumbing ─────────────────────────────

function must<T>(result: { data: T; error: { message: string } | null }, what: string): T {
  if (result.error) throw new Error(`${what}: ${result.error.message}`);
  return result.data;
}

function syncDeps(): SyncDeps {
  const zones = new Map<string, Promise<string>>();
  return {
    now: Date.now,
    fetch,
    google: GOOGLE,
    familyZone(familyId) {
      if (!zones.has(familyId)) {
        zones.set(familyId, (async () => {
          const row = must(await service.from("families").select("timezone").eq("id", familyId).maybeSingle(), "family zone");
          return zoneOrUtc(row?.timezone);
        })());
      }
      return zones.get(familyId)!;
    },
    async link(sourceId) {
      const row = must(await service.from("calendar_source_links").select("url").eq("source_id", sourceId).maybeSingle(), "link");
      return row?.url ?? null;
    },
    async token(accountId) {
      const row = must(
        await service.from("calendar_account_tokens")
          .select("refresh_token, access_token, access_token_expires_at").eq("account_id", accountId).maybeSingle(),
        "token",
      );
      if (!row) return null;
      return {
        refreshToken: row.refresh_token,
        accessToken: row.access_token,
        expiresAt: row.access_token_expires_at ? Date.parse(row.access_token_expires_at) : null,
      };
    },
    async saveToken(accountId, accessToken, expiresAt) {
      must(await service.from("calendar_account_tokens").update({
        access_token: accessToken,
        access_token_expires_at: new Date(expiresAt).toISOString(),
        updated_at: new Date().toISOString(),
      }).eq("account_id", accountId), "save token");
    },
    async markReconnect(accountId) {
      must(await service.from("calendar_accounts").update({ needs_reconnect: true }).eq("id", accountId), "mark reconnect");
    },
    async apply(sourceId, rows) {
      const { data, error } = await service.rpc("calendar_apply_sync", { source: sourceId, rows });
      if (error) {
        if (error.message === "this family is suspended") throw new CalendarError("This family's account is suspended.");
        throw new Error(`calendar_apply_sync: ${error.message}`);
      }
      return data as ApplyResult;
    },
    async fail(sourceId, message) {
      must(await service.from("calendar_sources").update({ last_error: message, last_attempt_at: new Date().toISOString() })
        .eq("id", sourceId), "record failure");
    },
  };
}

async function claim(lim: number, minAgeSeconds: number, familyId: string | null, sourceId: string | null): Promise<Source[]> {
  return must(
    await service.rpc("calendar_claim_due", { lim, min_age_seconds: minAgeSeconds, only_family: familyId, only_source: sourceId })
      .select(SOURCE_COLUMNS),
    "claim",
  ) as Source[];
}

// ───────────────────────────── Checks ─────────────────────────────

async function requireMember(db: SupabaseClient, familyId: string): Promise<void> {
  const { data, error } = await db.rpc("is_family_member", { fid: familyId });
  if (error) throw new Error(`is_family_member: ${error.message}`);
  if (data !== true) throw new HttpError(403, "you're not in that family");
}

async function requireParent(db: SupabaseClient, familyId: string): Promise<void> {
  await requireMember(db, familyId);
  const { data, error } = await db.rpc("is_family_parent", { fid: familyId });
  if (error) throw new Error(`is_family_parent: ${error.message}`);
  if (data !== true) throw new HttpError(403, "only a parent can connect calendars");
}

async function requireMemberRow(db: SupabaseClient, familyId: string, memberId: string | null): Promise<void> {
  if (!memberId) return;
  const row = must(await db.from("members").select("id").eq("id", memberId).eq("family_id", familyId).maybeSingle(), "member");
  if (!row) throw new HttpError(400, "that person isn't in this family");
}

interface Account {
  id: string;
  family_id: string;
  email: string;
  created_by: string;
}

/**
 * A Google account the caller may manage (RLS: parents of its family). With
 * `ownerOnly`, only the parent who connected it: their calendars are theirs
 * to show or not.
 */
async function accountFor(db: SupabaseClient, userId: string, accountId: string, ownerOnly: boolean): Promise<Account> {
  const row = must(
    await db.from("calendar_accounts").select("id, family_id, email, created_by").eq("id", accountId).maybeSingle(),
    "account",
  ) as Account | null;
  if (!row) throw new HttpError(404, "account not found");
  await requireParent(db, row.family_id);
  if (ownerOnly && row.created_by !== userId) {
    throw new HttpError(403, "Only the person who connected this Google account can choose its calendars.");
  }
  return row;
}

/** Runs a Google call for an account, flagging it to reconnect when Google refuses it. */
async function withAccount<T>(accountId: string, work: () => Promise<T>): Promise<T> {
  try {
    return await work();
  } catch (err) {
    if (err instanceof GoogleReconnect) {
      await service.from("calendar_accounts").update({ needs_reconnect: true }).eq("id", accountId);
    }
    throw err;
  }
}

/**
 * Whether another family has the same Google account connected. Google's
 * revoke withdraws Ohana's whole grant for the account, so it's skipped then.
 */
async function connectedElsewhere(email: string, exceptAccountId: string | null): Promise<boolean> {
  let q = service.from("calendar_accounts").select("id").eq("provider", "google").eq("email", email).limit(1);
  if (exceptAccountId) q = q.neq("id", exceptAccountId);
  return (must(await q, "other connections") as unknown[]).length > 0;
}

// ───────────────────────────── Actions ─────────────────────────────

type Look = Extract<CalendarRequest, { action: "add_link" }>;

async function addLink(db: SupabaseClient, userId: string, r: Look): Promise<Response> {
  await requireParent(db, r.familyId);
  await requireMemberRow(db, r.familyId, r.memberId);
  const normalized = normalizeCalendarUrl(r.url);
  if ("error" in normalized) return json({ error: normalized.error }, 400);
  const url = normalized.url.toString();

  const familySources = must(
    await service.from("calendar_sources").select("id").eq("family_id", r.familyId).eq("provider", "ics"),
    "family links",
  ) as { id: string }[];
  if (familySources.length) {
    const same = must(
      await service.from("calendar_source_links").select("source_id").eq("url", url)
        .in("source_id", familySources.map((s) => s.id)).limit(1),
      "same link",
    ) as unknown[];
    if (same.length) return json({ error: "That calendar is already connected." }, 409);
  }

  // Fetch and read it first, so a bad link is an answer, not a broken calendar.
  const deps = syncDeps();
  const zone = await deps.familyZone(r.familyId);
  const parsed = parseIcs(await fetchCalendarText(fetch, normalized.url), { timeZone: zone, ...syncWindow(Date.now()) });

  const name = r.name ?? parsed.name ?? clip(normalized.url.hostname, 100)!;
  const source = must(
    await service.from("calendar_sources").insert({
      family_id: r.familyId,
      provider: "ics",
      url_host: normalized.url.hostname,
      name,
      color: r.color,
      member_id: r.memberId,
      busy_only: r.busyOnly,
      created_by: userId,
    }).select(SOURCE_COLUMNS).single(),
    "insert link source",
  ) as Source;
  const { error: linkErr } = await service.from("calendar_source_links").insert({ source_id: source.id, url });
  if (linkErr) {
    await service.from("calendar_sources").delete().eq("id", source.id);
    throw new Error(`insert link: ${linkErr.message}`);
  }
  const outcome = await syncSource(deps, source, nearestRows(parsed.rows, Date.now()));
  return json(outcomeBody(source.id, name, outcome));
}

function outcomeBody(sourceId: string, name: string, outcome: Awaited<ReturnType<typeof syncSource>>) {
  return outcome.ok
    ? { source_id: sourceId, name, event_count: outcome.event_count }
    : { source_id: sourceId, name, event_count: 0, sync_error: outcome.error };
}

async function googleStart(db: SupabaseClient, userId: string, familyId: string): Promise<Response> {
  await requireParent(db, familyId);
  if (!GOOGLE) return json({ error: "Google Calendar isn't set up on this server yet." }, 503);
  const state = await signState(SERVICE_KEY, { familyId, userId }, Date.now());
  return json({ url: authUrl(GOOGLE, state) });
}

async function googleCalendars(db: SupabaseClient, userId: string, accountId: string): Promise<Response> {
  const account = await accountFor(db, userId, accountId, true);
  const calendars = await withAccount(account.id, async () => listCalendars(fetch, await accessTokenFor(syncDeps(), account.id)));
  const added = new Set(
    (must(await service.from("calendar_sources").select("google_calendar_id").eq("account_id", account.id), "added") as
      { google_calendar_id: string }[]).map((s) => s.google_calendar_id),
  );
  return json({ email: account.email, calendars: calendars.map((c) => ({ ...c, added: added.has(c.id) })) });
}

async function addGoogle(db: SupabaseClient, userId: string,
  r: Extract<CalendarRequest, { action: "add_google" }>): Promise<Response> {
  const account = await accountFor(db, userId, r.accountId, true);
  await requireMemberRow(db, account.family_id, r.memberId);
  const deps = syncDeps();
  const calendar = (await withAccount(account.id, async () => listCalendars(fetch, await accessTokenFor(deps, account.id))))
    .find((c) => c.id === r.calendarId);
  if (!calendar) return json({ error: "That calendar isn't in this Google account." }, 404);

  const name = r.name ?? calendar.name;
  const { data, error } = await service.from("calendar_sources").insert({
    family_id: account.family_id,
    provider: "google",
    account_id: account.id,
    google_calendar_id: calendar.id,
    name,
    // No color picked: the person's color when there is one, else Google's.
    color: r.color ?? (r.memberId ? null : calendar.color),
    member_id: r.memberId,
    busy_only: r.busyOnly,
    created_by: userId,
  }).select(SOURCE_COLUMNS).single();
  if (error?.code === "23505") return json({ error: "That calendar is already connected." }, 409);
  const source = must({ data, error }, "insert google source") as Source;
  return json(outcomeBody(source.id, name, await syncSource(deps, source)));
}

async function disconnectGoogle(db: SupabaseClient, userId: string, accountId: string): Promise<Response> {
  // Any parent may take an account off the family calendar.
  const account = await accountFor(db, userId, accountId, false);
  const token = must(
    await service.from("calendar_account_tokens").select("refresh_token").eq("account_id", account.id).maybeSingle(),
    "token",
  );
  const revoked = token && !(await connectedElsewhere(account.email, account.id))
    ? await revokeToken(fetch, token.refresh_token)
    : false;
  // Its calendars and their events go with it (on delete cascade).
  must(await service.from("calendar_accounts").delete().eq("id", account.id), "delete account");
  return json({ ok: true, revoked });
}

/** Syncs each calendar in its own request (its own CPU budget), a few at a time. */
async function fanOut(sources: Source[], concurrency: number, deadline: number): Promise<SyncOutcome[]> {
  const outcomes: SyncOutcome[] = [];
  let next = 0;
  const worker = async () => {
    while (next < sources.length && Date.now() < deadline) {
      const source = sources[next++];
      try {
        const res = await fetch(`${SUPABASE_URL}/functions/v1/calendar-sync`, {
          method: "POST",
          headers: { Authorization: `Bearer ${SERVICE_KEY}`, apikey: ANON_KEY, "Content-Type": "application/json" },
          body: JSON.stringify({ action: "sync_source", source_id: source.id }),
          signal: AbortSignal.timeout(Math.max(deadline - Date.now(), 1000) + 30_000),
        });
        const body = await res.json().catch(() => null);
        if (!res.ok || typeof body?.ok !== "boolean") throw new Error(`status ${res.status}`);
        outcomes.push(body as SyncOutcome);
      } catch (err) {
        console.error(`calendar ${source.id}: sync request failed:`, err);
        outcomes.push({ source_id: source.id, ok: false, error: GENERIC_FAILURE });
      }
    }
  };
  await Promise.all(Array.from({ length: Math.min(concurrency, sources.length) }, worker));
  return outcomes;
}

/** One calendar, already claimed by the request that asked for it. */
async function syncOne(sourceId: string): Promise<Response> {
  const source = must(await service.from("calendar_sources").select(SOURCE_COLUMNS).eq("id", sourceId).maybeSingle(), "source");
  if (!source) return json({ error: "calendar not found" }, 404);
  return json(await syncSource(syncDeps(), source as Source));
}

async function syncNow(db: SupabaseClient, r: Extract<CalendarRequest, { action: "sync" }>): Promise<Response> {
  let familyId = r.familyId;
  if (r.sourceId) {
    const row = must(await db.from("calendar_sources").select("family_id").eq("id", r.sourceId).maybeSingle(), "source");
    if (!row) return json({ error: "calendar not found" }, 404);
    familyId = row.family_id;
  }
  await requireMember(db, familyId!);
  // "Sync now" may repeat after 30 seconds; opening the app or a display's
  // timer refreshes calendars older than 10 minutes.
  const sources = await claim(20, r.force ? 30 : 600, r.sourceId ? null : familyId, r.sourceId);
  const deadline = Date.now() + 50_000;
  const results = sources.length > 1
    ? await fanOut(sources, 3, deadline)
    : await syncAll(syncDeps(), sources, 1, deadline);
  return json({ results });
}

async function syncDue(): Promise<Response> {
  const sources = await claim(50, 15 * 60 - 60, null, null);
  const results = await fanOut(sources, 5, Date.now() + 100_000);
  const synced = results.filter((o) => o.ok).length;
  return json({ synced, failed: results.length - synced });
}

// ───────────────────────────── Browser and calendar-app routes ─────────────────────────────

function backToApp(params: Record<string, string>): Response {
  const target = `${APP_REDIRECT}?${new URLSearchParams(params)}`;
  const html = `<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width">` +
    `<title>Ohana</title><p style="font:17px -apple-system,sans-serif;margin:40px">` +
    `<a href="${target.replace(/&/g, "&amp;").replace(/"/g, "&quot;")}">Return to Ohana Display</a></p>`;
  return new Response(html, {
    status: 302,
    headers: { Location: target, "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store" },
  });
}

async function googleCallback(url: URL): Promise<Response> {
  const fail = (error: string) => backToApp({ error });
  if (!GOOGLE) return fail("Google Calendar isn't set up on this server yet.");
  const stateText = url.searchParams.get("state") ?? "";
  if (!await verifyState(SERVICE_KEY, stateText, Date.now())) return fail("That sign-in took too long. Try connecting again.");
  const denied = url.searchParams.get("error");
  if (denied) return fail(denied === "access_denied" ? "Google sign-in was cancelled." : "Google couldn't sign you in. Try again.");
  const code = url.searchParams.get("code");
  if (!code) return fail("Google couldn't sign you in. Try again.");
  // The app finishes with google_finish, which proves who it is.
  return backToApp({ code, state: stateText });
}

/** Finishes a Google sign-in for the parent who started it. */
async function googleFinish(db: SupabaseClient, userId: string,
  r: Extract<CalendarRequest, { action: "google_finish" }>): Promise<Response> {
  if (!GOOGLE) return json({ error: "Google Calendar isn't set up on this server yet." }, 503);
  const state = await verifyState(SERVICE_KEY, r.state, Date.now());
  if (!state) return json({ error: "That sign-in took too long. Try connecting again." }, 400);
  if (state.userId !== userId) return json({ error: "That Google sign-in was started by someone else." }, 403);
  await requireParent(db, state.familyId);

  const grant = await exchangeCode(fetch, GOOGLE, r.code, Date.now());
  if (!grant.scopes.includes(CALENDAR_SCOPE)) {
    if (!grant.email || !(await connectedElsewhere(grant.email, null))) {
      await revokeToken(fetch, grant.refreshToken ?? grant.accessToken);
    }
    return json({ error: "Ohana needs permission to see your calendars. Try again and allow it." }, 400);
  }
  if (!grant.email) return json({ error: "Google didn't share the account's email. Try again." }, 400);

  const existing = must(
    await service.from("calendar_accounts").select("id, calendar_account_tokens(refresh_token)")
      .eq("family_id", state.familyId).eq("provider", "google").eq("email", grant.email).maybeSingle(),
    "existing account",
  ) as { id: string; calendar_account_tokens: { refresh_token: string } | { refresh_token: string }[] | null } | null;
  const stored = existing?.calendar_account_tokens;
  const refreshToken = grant.refreshToken ?? (Array.isArray(stored) ? stored[0] : stored)?.refresh_token;
  if (!refreshToken) return json({ error: "Google didn't give Ohana lasting access. Try connecting again." }, 400);

  const account = must(
    await service.from("calendar_accounts").upsert({
      family_id: state.familyId,
      provider: "google",
      email: grant.email,
      created_by: userId,
      needs_reconnect: false,
    }, { onConflict: "family_id,provider,email" }).select("id").single(),
    "save account",
  ) as { id: string };
  must(await service.from("calendar_account_tokens").upsert({
    account_id: account.id,
    refresh_token: refreshToken,
    access_token: grant.accessToken,
    access_token_expires_at: new Date(grant.expiresAt).toISOString(),
    updated_at: new Date().toISOString(),
  }), "save token");
  // A reconnected account's calendars catch up now rather than in 15 minutes.
  must(await service.from("calendar_sources").update({ last_attempt_at: null }).eq("account_id", account.id), "reset");
  return json({ account_id: account.id, email: grant.email });
}

async function serveFeed(token: string, head: boolean): Promise<Response> {
  const notFound = () => new Response("Not found", { status: 404, headers: { "Content-Type": "text/plain" } });
  if (!FEED_TOKEN.test(token)) return notFound();
  const feed = must(await service.from("calendar_feeds").select("family_id").eq("token", token).maybeSingle(), "feed");
  if (!feed) return notFound();
  const family = must(
    await service.from("families").select("name, timezone, status").eq("id", feed.family_id).maybeSingle(),
    "family",
  );
  if (!family || family.status !== "active") return notFound();

  const now = Date.now();
  const timeZone = zoneOrUtc(family.timezone);
  const occurrences: FeedOccurrence[] = [];
  const window = { range_start: new Date(now - 30 * 86_400_000).toISOString(), range_end: new Date(now + 365 * 86_400_000).toISOString() };
  for (let offset = 0; offset < 20_000; offset += 1000) {
    const page = must(
      await service.rpc("event_occurrences", { fid: feed.family_id, ...window }).is("source_id", null)
        .range(offset, offset + 999),
      "occurrences",
    ) as FeedOccurrence[];
    occurrences.push(...page);
    if (page.length < 1000) break;
  }
  const members = must(await service.from("members").select("id, display_name").eq("family_id", feed.family_id), "members") as
    { id: string; display_name: string }[];
  const body = buildFeed({
    familyName: family.name,
    timeZone,
    occurrences,
    memberNames: new Map(members.map((m) => [m.id, m.display_name])),
    now,
  });
  return new Response(head ? null : body, {
    headers: {
      "Content-Type": "text/calendar; charset=utf-8",
      "Content-Disposition": 'inline; filename="ohana.ics"',
      "Cache-Control": "private, max-age=300",
    },
  });
}

// ───────────────────────────── Entry ─────────────────────────────

/** Constant-time comparison for the cron secret. */
function sameSecret(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a);
  const y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}

async function handle(req: Request): Promise<Response> {
  const url = new URL(req.url);
  const feed = url.pathname.match(/\/feed\/([^/]+?)(?:\.ics)?$/);
  if (feed) {
    if (req.method !== "GET" && req.method !== "HEAD") return new Response("GET only", { status: 405 });
    return await serveFeed(feed[1], req.method === "HEAD");
  }
  if (/\/google\/callback$/.test(url.pathname)) {
    if (req.method !== "GET") return new Response("GET only", { status: 405 });
    return await googleCallback(url);
  }
  if (req.method === "OPTIONS") return preflight();
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const token = bearerToken(req);
  if (!token) return json({ error: "sign in required" }, 401);
  const read = await readJson(req);
  if ("error" in read) return read.error;
  const request = parseCalendarRequest(read.body);
  if ("error" in request) return json({ error: request.error }, 400);

  if (CRON_SECRET.length >= 16 && sameSecret(token, CRON_SECRET)) {
    if (request.action !== "sync_due") return json({ error: "the cron secret only runs sync_due" }, 403);
    return await syncDue();
  }
  if (sameSecret(token, SERVICE_KEY)) {
    if (request.action !== "sync_source") return json({ error: "the service key only runs sync_source" }, 403);
    return await syncOne(request.sourceId);
  }
  if (request.action === "sync_due") return json({ error: "sync_due needs the cron secret" }, 403);
  if (request.action === "sync_source") return json({ error: "sync_source is internal" }, 403);

  const db = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const auth = await authenticate(db, token);
  if ("error" in auth) return auth.error;
  const userId = auth.user.id;

  switch (request.action) {
    case "add_link":
      return await addLink(db, userId, request);
    case "google_start":
      return await googleStart(db, userId, request.familyId);
    case "google_finish":
      return await googleFinish(db, userId, request);
    case "google_calendars":
      return await googleCalendars(db, userId, request.accountId);
    case "add_google":
      return await addGoogle(db, userId, request);
    case "disconnect_google":
      return await disconnectGoogle(db, userId, request.accountId);
    case "sync":
      return await syncNow(db, request);
  }
}

Deno.serve(async (req) => {
  try {
    return await handle(req);
  } catch (err) {
    if (err instanceof HttpError) return json({ error: err.message }, err.status);
    if (err instanceof GoogleReconnect) return json({ error: err.message, reconnect: true }, 409);
    if (err instanceof CalendarError) return json({ error: err.message }, 400);
    console.error("calendar-sync failed:", err);
    return json({ error: "something went wrong" }, 500);
  }
});
