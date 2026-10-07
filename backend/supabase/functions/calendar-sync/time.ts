// Wall-clock times in a named time zone, with only the runtime's Intl data.
// Imported calendars give times as "16:30 in America/Los_Angeles", floating
// ("16:30", meaning the family's zone) or as dates (all-day events); these
// turn them into instants the database stores.

const formatters = new Map<string, Intl.DateTimeFormat>();

function formatter(timeZone: string): Intl.DateTimeFormat {
  let f = formatters.get(timeZone);
  if (!f) {
    f = new Intl.DateTimeFormat("en-US", {
      timeZone,
      hourCycle: "h23",
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
    });
    formatters.set(timeZone, f);
  }
  return f;
}

/** Whether the runtime knows this IANA zone name. */
export function isTimeZone(timeZone: unknown): timeZone is string {
  if (typeof timeZone !== "string" || timeZone === "") return false;
  try {
    formatter(timeZone);
    return true;
  } catch {
    return false;
  }
}

/** The family's zone, or UTC when it isn't one the runtime knows (as event_occurrences does). */
export const zoneOrUtc = (timeZone: unknown): string => (isTimeZone(timeZone) ? timeZone : "UTC");

export interface WallTime {
  year: number;
  month: number; // 1-12
  day: number;
  hour: number;
  minute: number;
  second: number;
}

/** The wall-clock time in `timeZone` at the instant `ms`. */
export function wallTimeAt(timeZone: string, ms: number): WallTime {
  const parts: Record<string, number> = {};
  for (const p of formatter(timeZone).formatToParts(new Date(ms))) {
    if (p.type !== "literal") parts[p.type] = Number(p.value);
  }
  return { year: parts.year, month: parts.month, day: parts.day, hour: parts.hour, minute: parts.minute, second: parts.second };
}

const asUtc = (t: WallTime) => Date.UTC(t.year, t.month - 1, t.day, t.hour, t.minute, t.second);

// How far `timeZone` is ahead of UTC at the instant `ms`, in milliseconds.
const offsetAt = (timeZone: string, ms: number) => asUtc(wallTimeAt(timeZone, ms)) - Math.floor(ms / 1000) * 1000;

/**
 * The instant a wall-clock time in `timeZone` names. As in RFC 5545, a time
 * that happens twice (the hour the clocks go back) is the first one, and a
 * time the clocks skip uses the offset from before the jump (02:30 on the
 * spring-forward day is 03:30).
 */
export function wallTimeToMs(timeZone: string, t: WallTime): number {
  const local = asUtc(t);
  const day = 12 * 3600 * 1000;
  const before = offsetAt(timeZone, local - day);
  const after = offsetAt(timeZone, local + day);
  const matches = [...new Set([local - before, local - after])]
    .filter((ms) => asUtc(wallTimeAt(timeZone, ms)) === local)
    .sort((a, b) => a - b);
  return matches.length ? matches[0] : local - before;
}

/** "YYYY-MM-DD" of a date. */
export const isoDate = (year: number, month: number, day: number): string =>
  `${String(year).padStart(4, "0")}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;

/** `date` ("YYYY-MM-DD") moved by `days`. */
export function addDays(date: string, days: number): string {
  const [y, m, d] = date.split("-").map(Number);
  const t = new Date(Date.UTC(y, m - 1, d + days));
  return isoDate(t.getUTCFullYear(), t.getUTCMonth() + 1, t.getUTCDate());
}

/** The local date ("YYYY-MM-DD") in `timeZone` at the instant `ms`. */
export function localDate(timeZone: string, ms: number): string {
  const t = wallTimeAt(timeZone, ms);
  return isoDate(t.year, t.month, t.day);
}

/**
 * An all-day span as the apps store it: from local midnight of `first` to
 * 23:59:59 of `last` (both "YYYY-MM-DD", inclusive) in `timeZone`.
 */
export function allDaySpan(timeZone: string, first: string, last: string): { startsAt: string; endsAt: string } {
  const [y1, m1, d1] = first.split("-").map(Number);
  const end = last < first ? first : last;
  const [y2, m2, d2] = end.split("-").map(Number);
  return {
    startsAt: new Date(wallTimeToMs(timeZone, { year: y1, month: m1, day: d1, hour: 0, minute: 0, second: 0 })).toISOString(),
    endsAt: new Date(wallTimeToMs(timeZone, { year: y2, month: m2, day: d2, hour: 23, minute: 59, second: 59 })).toISOString(),
  };
}
