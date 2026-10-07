// What a sync hands to calendar_apply_sync: one row per occurrence, in a
// window around today. Repeating events arrive already expanded (Google does
// it for us; ics.ts does it for links), so their exceptions, moved repeats
// and time zones are exactly what the other calendar shows.

export interface SyncRow {
  uid: string; // stable per occurrence: the same repeat keeps its row across syncs
  title: string;
  description: string | null;
  location: string | null;
  starts_at: string; // ISO 8601 instant
  ends_at: string;
  all_day: boolean;
}

export const DAY_MS = 24 * 3600 * 1000;
/** How far back and ahead a sync looks. The iOS app shows 45 days back and 120 ahead. */
export const WINDOW_PAST_DAYS = 60;
export const WINDOW_FUTURE_DAYS = 365;
/** calendar_apply_sync takes at most this many rows. */
export const MAX_ROWS = 5000;

export function syncWindow(now: number): { from: number; to: number } {
  return { from: now - WINDOW_PAST_DAYS * DAY_MS, to: now + WINDOW_FUTURE_DAYS * DAY_MS };
}

/** Whether [start, end] overlaps [from, to), counting a zero-length event that starts inside. */
export const overlaps = (start: number, end: number, from: number, to: number) =>
  start < to && (end > from || start >= from);

/** At most `max` rows, keeping those nearest to `now`, in start order. */
export function nearestRows(rows: SyncRow[], now: number, max = MAX_ROWS): SyncRow[] {
  let kept = rows;
  if (rows.length > max) {
    const distance = (r: SyncRow) => Math.abs(Date.parse(r.starts_at) - now);
    kept = [...rows].sort((a, b) => distance(a) - distance(b)).slice(0, max);
  }
  return [...kept].sort((a, b) => Date.parse(a.starts_at) - Date.parse(b.starts_at) || a.uid.localeCompare(b.uid));
}

/** Text clipped for a column, with blank meaning none. */
export function clip(text: unknown, max: number): string | null {
  if (typeof text !== "string") return null;
  const trimmed = text.trim();
  return trimmed ? trimmed.slice(0, max) : null;
}

/** Shown instead of a private event's details. */
export const BUSY = "Busy";

/** A sync problem a parent can act on; its message is shown in the app. */
export class CalendarError extends Error {}
