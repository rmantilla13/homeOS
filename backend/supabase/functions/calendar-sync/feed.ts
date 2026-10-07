// The family's own calendar as an ICS feed, for Google Calendar, Apple
// Calendar or Outlook to subscribe to. Repeats come expanded from
// event_occurrences, in UTC, so there are no time-zone tables to get wrong;
// all-day events are dates. Events imported from connected calendars are
// left out: they already live in those calendars.

import { addDays, localDate } from "./time.ts";

export interface FeedOccurrence {
  id: string;
  title: string;
  description: string | null;
  location: string | null;
  starts_at: string;
  ends_at: string;
  all_day: boolean;
  rrule: string | null;
  member_ids: string[] | null;
  source_id: string | null;
}

export interface FeedOptions {
  familyName: string;
  timeZone: string;
  occurrences: FeedOccurrence[];
  memberNames: Map<string, string>;
  now: number;
}

/** RFC 5545 TEXT: backslash, semicolon, comma and line breaks escaped. */
export const escapeText = (text: string): string =>
  text.replace(/\\/g, "\\\\").replace(/;/g, "\\;").replace(/,/g, "\\,").replace(/\r\n|\r|\n/g, "\\n");

/** A content line folded at 75 octets, never inside a UTF-8 character. */
export function fold(line: string): string {
  const encoder = new TextEncoder();
  if (encoder.encode(line).length <= 75) return line;
  const parts: string[] = [];
  let current = "";
  let size = 0;
  for (const ch of line) {
    const n = encoder.encode(ch).length;
    const limit = parts.length ? 74 : 75; // continuation lines start with a space
    if (size + n > limit) {
      parts.push(current);
      current = "";
      size = 0;
    }
    current += ch;
    size += n;
  }
  parts.push(current);
  return parts.join("\r\n ");
}

const utcStamp = (ms: number) => new Date(ms).toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
const dateValue = (date: string) => date.replaceAll("-", "");

export function buildFeed(opts: FeedOptions): string {
  const lines = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//OhanaOS//Ohana Display//EN",
    "CALSCALE:GREGORIAN",
    "METHOD:PUBLISH",
    `X-WR-CALNAME:${escapeText(opts.familyName || "Family")}`,
    `X-WR-TIMEZONE:${opts.timeZone}`,
    "REFRESH-INTERVAL;VALUE=DURATION:PT1H",
    "X-PUBLISHED-TTL:PT1H",
  ];
  const stamp = utcStamp(opts.now);
  for (const o of opts.occurrences) {
    if (o.source_id) continue;
    const start = Date.parse(o.starts_at);
    const end = Math.max(Date.parse(o.ends_at), start);
    if (!Number.isFinite(start) || !Number.isFinite(end)) continue;
    const repeats = !!o.rrule?.trim();
    // A one-off event keeps its UID when it moves; each repeat is its own.
    const uid = repeats ? `${o.id}-${dateValue(localDate(opts.timeZone, start))}@ohanaos` : `${o.id}@ohanaos`;
    lines.push("BEGIN:VEVENT", `UID:${uid}`, `DTSTAMP:${stamp}`);
    if (o.all_day) {
      const first = localDate(opts.timeZone, start);
      // Stored to 23:59:59 of the last day; one that ends at midnight ends the day before.
      const last = localDate(opts.timeZone, Math.max(end - 1000, start));
      lines.push(`DTSTART;VALUE=DATE:${dateValue(first)}`, `DTEND;VALUE=DATE:${dateValue(addDays(last < first ? first : last, 1))}`);
    } else {
      lines.push(`DTSTART:${utcStamp(start)}`, `DTEND:${utcStamp(end)}`);
    }
    lines.push(`SUMMARY:${escapeText(o.title)}`);
    if (o.location) lines.push(`LOCATION:${escapeText(o.location)}`);
    const who = (o.member_ids ?? []).map((id) => opts.memberNames.get(id)).filter((n): n is string => !!n);
    const description = [o.description?.trim(), who.length ? `For: ${who.join(", ")}` : ""].filter(Boolean).join("\n\n");
    if (description) lines.push(`DESCRIPTION:${escapeText(description)}`);
    lines.push("END:VEVENT");
  }
  lines.push("END:VCALENDAR");
  return lines.map(fold).join("\r\n") + "\r\n";
}
