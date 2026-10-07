// Syncing one connected calendar: fetch it (a link or Google), turn it into
// rows for the window around today, and hand them to calendar_apply_sync.
// I/O comes in through SyncDeps so the order of things can be unit-tested
// (sync.test.ts). A failure is written to the calendar's last_error, which
// the app shows; it never throws.

import { fetchCalendarText, type Fetch, normalizeCalendarUrl } from "./fetch.ts";
import { type GoogleConfig, GoogleReconnect, googleRows, listEvents, refreshAccess } from "./google.ts";
import { parseIcs } from "./ics.ts";
import { CalendarError, nearestRows, type SyncRow, syncWindow } from "./rows.ts";

export interface Source {
  id: string;
  family_id: string;
  provider: "ics" | "google";
  account_id: string | null;
  google_calendar_id: string | null;
}

export interface ApplyResult {
  added: number;
  updated: number;
  removed: number;
  event_count: number;
}

export type SyncOutcome =
  | ({ source_id: string; ok: true } & ApplyResult)
  | { source_id: string; ok: false; error: string };

export interface StoredToken {
  refreshToken: string;
  accessToken: string | null;
  expiresAt: number | null;
}

export interface SyncDeps {
  now(): number;
  fetch: Fetch;
  google: GoogleConfig | null;
  familyZone(familyId: string): Promise<string>;
  link(sourceId: string): Promise<string | null>;
  token(accountId: string): Promise<StoredToken | null>;
  saveToken(accountId: string, accessToken: string, expiresAt: number): Promise<void>;
  markReconnect(accountId: string): Promise<void>;
  apply(sourceId: string, rows: SyncRow[]): Promise<ApplyResult>;
  fail(sourceId: string, message: string): Promise<void>;
}

export const GENERIC_FAILURE = "Something went wrong syncing this calendar. Ohana will try again soon.";

/** A usable Google access token for the account, refreshed when it's about to expire. */
export async function accessTokenFor(deps: SyncDeps, accountId: string): Promise<string> {
  if (!deps.google) throw new CalendarError("Google Calendar isn't set up on this server yet.");
  const stored = await deps.token(accountId);
  if (!stored) throw new GoogleReconnect();
  if (stored.accessToken && (stored.expiresAt ?? 0) > deps.now() + 60_000) return stored.accessToken;
  const grant = await refreshAccess(deps.fetch, deps.google, stored.refreshToken, deps.now());
  await deps.saveToken(accountId, grant.accessToken, grant.expiresAt);
  return grant.accessToken;
}

/** The calendar's occurrences in the window around now, at most MAX_ROWS. */
export async function sourceRows(deps: SyncDeps, source: Source, zone: string): Promise<SyncRow[]> {
  const window = syncWindow(deps.now());
  let rows: SyncRow[];
  if (source.provider === "ics") {
    const link = await deps.link(source.id);
    if (!link) throw new CalendarError("This calendar's link is missing. Remove it and add it again.");
    const url = normalizeCalendarUrl(link);
    if ("error" in url) throw new CalendarError(url.error);
    rows = parseIcs(await fetchCalendarText(deps.fetch, url.url), { timeZone: zone, ...window }).rows;
  } else {
    if (!source.account_id || !source.google_calendar_id) throw new CalendarError(GENERIC_FAILURE);
    const token = await accessTokenFor(deps, source.account_id);
    rows = googleRows(await listEvents(deps.fetch, token, source.google_calendar_id, window), zone, window);
  }
  return nearestRows(rows, deps.now());
}

/** Writes `rows` (already fetched, e.g. while checking a new link) or fetches them first. */
export async function syncSource(deps: SyncDeps, source: Source, rows?: SyncRow[]): Promise<SyncOutcome> {
  try {
    const zone = await deps.familyZone(source.family_id);
    const result = await deps.apply(source.id, rows ?? await sourceRows(deps, source, zone));
    return { source_id: source.id, ok: true, ...result };
  } catch (err) {
    const known = err instanceof CalendarError;
    if (!known) console.error(`calendar ${source.id} sync failed:`, err);
    const message = known ? err.message : GENERIC_FAILURE;
    if (err instanceof GoogleReconnect && source.account_id) {
      await deps.markReconnect(source.account_id).catch((e) => console.error("markReconnect failed:", e));
    }
    await deps.fail(source.id, message).catch((e) => console.error("recording a sync failure failed:", e));
    return { source_id: source.id, ok: false, error: message };
  }
}

/** Syncs `sources`, a few at a time, starting no new one after `deadline`. */
export async function syncAll(deps: SyncDeps, sources: Source[], concurrency = 3, deadline = Infinity): Promise<SyncOutcome[]> {
  const outcomes: SyncOutcome[] = [];
  let next = 0;
  const worker = async () => {
    while (next < sources.length && deps.now() < deadline) {
      const source = sources[next++];
      outcomes.push(await syncSource(deps, source));
    }
  };
  await Promise.all(Array.from({ length: Math.min(concurrency, sources.length) }, worker));
  return outcomes;
}
