// Calendar links (ICS / webcal): the text of a calendar turned into one row
// per occurrence in the sync window. ical.js (Mozilla's parser, used by
// Thunderbird) reads the file and expands repeats, including EXDATE, RDATE,
// moved or cancelled repeats (RECURRENCE-ID) and the file's own VTIMEZONEs.
//
// Times: UTC and zones the file defines convert directly. A TZID the file
// doesn't define is read as an IANA zone when the runtime knows it; anything
// else, and floating times, are the family's zone. All-day events span local
// midnight to 23:59:59 in the family's zone, as the apps store them.
// Private and confidential events (CLASS) come in as "Busy". Cancelled
// events and repeats are left out.

import ICAL from "npm:ical.js@2.2.1";
import { allDaySpan, isoDate, isTimeZone, wallTimeToMs } from "./time.ts";
import { BUSY, CalendarError, clip, DAY_MS, overlaps, type SyncRow } from "./rows.ts";

export interface ParsedCalendar {
  name: string | null; // X-WR-CALNAME, a default name for a new calendar
  rows: SyncRow[];
}

export interface ParseOptions {
  timeZone: string; // the family's zone (valid)
  from: number; // window, ms since the epoch
  to: number;
}

// Work limits. Edge functions get about 2 s of CPU per request, so a
// calendar too big to read in BUDGET_MS fails with a message instead.
const MAX_STEPS_PER_SERIES = 20_000;
const MAX_ROWS_COLLECTED = 10_000;
const BUDGET_MS = 1200;
// A repeat moved into the window from a little past it still shows.
const MOVED_MARGIN_MS = 32 * DAY_MS;

type Time = InstanceType<typeof ICAL.Time>;
type Event = InstanceType<typeof ICAL.Event>;
type Component = InstanceType<typeof ICAL.Component>;

export function parseIcs(text: string, opts: ParseOptions): ParsedCalendar {
  if (!/BEGIN:VCALENDAR/i.test(text)) {
    throw new CalendarError("That link didn't return a calendar.");
  }
  let roots: Component[];
  try {
    const parsed = ICAL.parse(text);
    const list = (Array.isArray(parsed[0]) ? parsed : [parsed]) as unknown[];
    roots = list.map((j) => new ICAL.Component(j as unknown[]));
  } catch {
    throw new CalendarError("That calendar couldn't be read.");
  }
  roots = roots.filter((c) => c.name === "vcalendar");
  if (!roots.length) throw new CalendarError("That link didn't return a calendar.");

  // Zones are global in ical.js. Everything below is synchronous, so another
  // request can't register its zones in between.
  ICAL.TimezoneService.reset();
  for (const root of roots) {
    for (const vtz of root.getAllSubcomponents("vtimezone")) {
      try {
        const zone = new ICAL.Timezone(vtz);
        if (zone.tzid && !ICAL.TimezoneService.has(zone.tzid)) ICAL.TimezoneService.register(zone);
      } catch {
        // A broken VTIMEZONE: its times fall back to the IANA name or the family's zone.
      }
    }
  }
  try {
    return { name: calendarName(roots), rows: expand(roots, opts) };
  } finally {
    ICAL.TimezoneService.reset();
  }
}

function calendarName(roots: Component[]): string | null {
  for (const root of roots) {
    const name = clip(root.getFirstPropertyValue("x-wr-calname"), 100);
    if (name) return name;
  }
  return null;
}

function expand(roots: Component[], opts: ParseOptions): SyncRow[] {
  const masters = new Map<string, Event>();
  const singles: Event[] = [];
  const exceptions: Component[] = [];
  for (const root of roots) {
    for (const v of root.getAllSubcomponents("vevent")) {
      const uid = String(v.getFirstPropertyValue("uid") ?? "").trim();
      if (!uid || !v.hasProperty("dtstart")) continue;
      if (v.hasProperty("recurrence-id")) {
        exceptions.push(v);
        continue;
      }
      // `exceptions: []` stops ical.js from scanning every other event for
      // this one's exceptions (quadratic); they're related below.
      const event = new ICAL.Event(v, { exceptions: [] });
      if (event.isRecurring() && !masters.has(uid)) masters.set(uid, event);
      else singles.push(event);
    }
  }
  for (const v of exceptions) {
    const master = masters.get(String(v.getFirstPropertyValue("uid")).trim());
    if (master) master.relateException(v);
    else singles.push(new ICAL.Event(v, { exceptions: [] })); // a moved repeat whose series isn't in the file
  }

  const started = performance.now();
  const checkBudget = () => {
    if (performance.now() - started > BUDGET_MS) {
      throw new CalendarError("That calendar is too big to sync. Try a link to a smaller calendar.");
    }
  };
  const rows: SyncRow[] = [];
  const used = new Set<string>();
  const add = (row: SyncRow | null) => {
    if (!row || rows.length >= MAX_ROWS_COLLECTED) return;
    let uid = row.uid;
    if (used.has(uid)) uid = `${row.uid}/${compact(Date.parse(row.starts_at), row.all_day)}`;
    if (used.has(uid)) return;
    used.add(uid);
    rows.push({ ...row, uid });
  };

  for (const [i, event] of singles.entries()) {
    if (i % 256 === 0) checkBudget();
    if (cancelled(event.component)) continue;
    const key = event.isRecurrenceException()
      ? `${event.uid}/${recurrenceKey(event.recurrenceId, tzidOf(event.component, "recurrence-id"), opts.timeZone)}`
      : event.uid;
    add(occurrence(key, event, event.startDate, event.endDate, opts));
  }

  for (const [uid, master] of masters) {
    if (cancelled(master.component)) continue;
    fastForward(master, opts.from);
    const it = master.iterator();
    for (let step = 0; step < MAX_STEPS_PER_SERIES && rows.length < MAX_ROWS_COLLECTED; step++) {
      if (step % 256 === 0) checkBudget();
      const next: Time | null = it.next();
      if (!next) break;
      // toUnixTime reads a floating time as UTC: within a day of the truth.
      if (next.toUnixTime() * 1000 > opts.to + MOVED_MARGIN_MS) break;
      const details = master.getOccurrenceDetails(next);
      if (cancelled(details.item.component)) continue;
      const key = `${uid}/${recurrenceKey(details.recurrenceId, tzidOf(master.component, "dtstart"), opts.timeZone)}`;
      add(occurrence(key, details.item, details.startDate, details.endDate, opts));
    }
  }
  return rows;
}

/**
 * Moves an old series' start forward by whole periods to just before the
 * window, so expanding it doesn't walk every repeat since it began. Whole
 * weeks (DAILY, WEEKLY) or whole years (MONTHLY, YEARLY), times INTERVAL,
 * keep every BY rule, INTERVAL, UNTIL, EXDATE and moved repeat lining up
 * with the same days. The moved start itself may not fit the rule (a
 * series' start always counts), so it stays more than a month before the
 * window, where it's dropped anyway. Series with COUNT, several RRULEs,
 * more frequent than daily, or starting on Feb 29 are left alone.
 */
function fastForward(master: Event, from: number): void {
  const rules = master.component.getAllProperties("rrule");
  if (rules.length !== 1) return;
  const rule = rules[0].getFirstValue() as InstanceType<typeof ICAL.Recur>;
  if (rule.count) return;
  const start = master.startDate;
  const end = master.endDate;
  const length = Math.max(0, end.toUnixTime() - start.toUnixTime()) * 1000;
  const before = from - length - 40 * DAY_MS;
  const span = before - start.toUnixTime() * 1000; // a floating time read as UTC: within a day
  const interval = Math.max(1, rule.interval || 1);
  let k: number;
  let move: (t: Time) => void;
  if (rule.freq === "DAILY" || rule.freq === "WEEKLY") {
    k = Math.floor(span / (7 * interval * DAY_MS)) - 1;
    move = (t) => t.adjust(k * 7 * interval, 0, 0, 0);
  } else if (rule.freq === "MONTHLY" || rule.freq === "YEARLY") {
    if (start.month === 2 && start.day === 29) return;
    k = Math.floor(span / (366 * interval * DAY_MS)) - 1;
    move = (t) => void (t.year += k * interval);
  } else {
    return;
  }
  if (k < 1) return;
  for (const [prop, time] of [["dtstart", start], ["dtend", end]] as const) {
    const p = master.component.getFirstProperty(prop);
    if (!p) continue; // no DTEND: DURATION carries over
    const tzid = p.getParameter("tzid");
    const moved = time.clone();
    move(moved);
    p.setValue(moved);
    // Setting the value drops a TZID ical.js didn't know; toMs still needs it.
    if (typeof tzid === "string") p.setParameter("tzid", tzid);
  }
}

const cancelled = (c: Component) => String(c.getFirstPropertyValue("status") ?? "").toUpperCase() === "CANCELLED";

function tzidOf(c: Component, prop: string): string | null {
  const p = c.getFirstProperty(prop);
  const tzid = p?.getParameter("tzid");
  return typeof tzid === "string" ? tzid : null;
}

/** The instant of a date-time, by its zone, its TZID, or the family's zone. */
function toMs(t: Time, tzid: string | null, familyZone: string): number {
  const zone = t.zone?.tzid;
  if (zone && zone !== "floating") return t.toUnixTime() * 1000; // UTC or a zone the file defined
  const tz = tzid && isTimeZone(tzid) ? tzid : familyZone;
  return wallTimeToMs(tz, { year: t.year, month: t.month, day: t.day, hour: t.hour, minute: t.minute, second: t.second });
}

// An instant for uids: 20261026T233000Z, or 20261026 for a date.
function compact(ms: number, isDate: boolean): string {
  const iso = new Date(ms).toISOString().replace(/[-:]/g, "").slice(0, 15) + "Z";
  return isDate ? iso.slice(0, 8) : iso;
}

// Which repeat an occurrence is, for its uid: its original start in UTC, or
// its date for an all-day series.
const recurrenceKey = (t: Time, tzid: string | null, familyZone: string): string =>
  t.isDate ? isoDate(t.year, t.month, t.day).replaceAll("-", "") : compact(toMs(t, tzid, familyZone), false);

function occurrence(uid: string, item: Event, start: Time, end: Time | null, opts: ParseOptions): SyncRow | null {
  const c = item.component;
  const klass = String(c.getFirstPropertyValue("class") ?? "").toUpperCase();
  const busy = klass === "PRIVATE" || klass === "CONFIDENTIAL";
  const text = {
    title: busy ? BUSY : clip(item.summary, 500) ?? "Untitled event",
    description: busy ? null : clip(item.description, 4000),
    location: busy ? null : clip(item.location, 500),
  };

  if (start.isDate) {
    const first = isoDate(start.year, start.month, start.day);
    // DTEND of an all-day event is the day after the last one.
    let last = first;
    if (end) {
      const endDay = new Date(Date.UTC(end.year, end.month - 1, end.day) - DAY_MS);
      last = isoDate(endDay.getUTCFullYear(), endDay.getUTCMonth() + 1, endDay.getUTCDate());
      if (!end.isDate && (end.hour || end.minute || end.second)) last = isoDate(end.year, end.month, end.day);
    }
    const span = allDaySpan(opts.timeZone, first, last < first ? first : last);
    if (!overlaps(Date.parse(span.startsAt), Date.parse(span.endsAt), opts.from, opts.to)) return null;
    return { uid, ...text, starts_at: span.startsAt, ends_at: span.endsAt, all_day: true };
  }

  const startMs = toMs(start, tzidOf(c, "dtstart"), opts.timeZone);
  let endMs = end ? toMs(end, tzidOf(c, "dtend") ?? tzidOf(c, "dtstart"), opts.timeZone) : startMs;
  if (!Number.isFinite(startMs)) return null;
  if (!Number.isFinite(endMs) || endMs < startMs) endMs = startMs;
  if (!overlaps(startMs, endMs, opts.from, opts.to)) return null;
  return {
    uid,
    ...text,
    starts_at: new Date(startMs).toISOString(),
    ends_at: new Date(endMs).toISOString(),
    all_day: false,
  };
}
