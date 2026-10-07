// Request parsing for calendar-sync, kept free of I/O so it can be
// unit-tested (request.test.ts).

import { isUuid } from "../_shared/http.ts";

/** How a new calendar shows: its name, color, person, and whether only "Busy" shows. */
export interface CalendarLook {
  name: string | null; // null: the calendar's own name
  color: string | null; // #RRGGBB; null: the person's color
  memberId: string | null;
  busyOnly: boolean;
}

export type CalendarRequest =
  | ({ action: "add_link"; familyId: string; url: string } & CalendarLook)
  | ({ action: "add_google"; accountId: string; calendarId: string } & CalendarLook)
  | { action: "sync"; familyId: string | null; sourceId: string | null; force: boolean }
  | { action: "google_start"; familyId: string }
  | { action: "google_calendars" | "disconnect_google"; accountId: string }
  | { action: "sync_due" }
  | { action: "sync_source"; sourceId: string }; // internal: one calendar per request

function look(b: Record<string, unknown>): CalendarLook | { error: string } {
  if (b.name != null && (typeof b.name !== "string" || b.name.trim().length > 100)) {
    return { error: "name must be text of at most 100 characters" };
  }
  if (b.color != null && (typeof b.color !== "string" || !/^#[0-9a-f]{6}$/i.test(b.color))) {
    return { error: "color must look like #RRGGBB" };
  }
  if (b.member_id != null && !isUuid(b.member_id)) return { error: "member_id must be a uuid" };
  if (b.busy_only != null && typeof b.busy_only !== "boolean") return { error: "busy_only must be true or false" };
  return {
    name: (b.name as string | undefined)?.trim() || null,
    color: (b.color as string | undefined)?.toUpperCase() ?? null,
    memberId: (b.member_id as string | undefined)?.toLowerCase() ?? null,
    busyOnly: b.busy_only === true,
  };
}

export function parseCalendarRequest(body: unknown): CalendarRequest | { error: string } {
  if (typeof body !== "object" || body === null || Array.isArray(body)) return { error: "body must be a JSON object" };
  const b = body as Record<string, unknown>;

  switch (b.action) {
    case "add_link": {
      if (!isUuid(b.family_id)) return { error: "family_id must be a uuid" };
      if (typeof b.url !== "string" || !b.url.trim()) return { error: "url is required" };
      const l = look(b);
      if ("error" in l) return l;
      return { action: "add_link", familyId: b.family_id.toLowerCase(), url: b.url.trim(), ...l };
    }
    case "add_google": {
      if (!isUuid(b.account_id)) return { error: "account_id must be a uuid" };
      if (typeof b.calendar_id !== "string" || !b.calendar_id || b.calendar_id.length > 1024) {
        return { error: "calendar_id is required" };
      }
      const l = look(b);
      if ("error" in l) return l;
      return { action: "add_google", accountId: b.account_id.toLowerCase(), calendarId: b.calendar_id, ...l };
    }
    case "sync": {
      const familyId = b.family_id == null ? null : b.family_id;
      const sourceId = b.source_id == null ? null : b.source_id;
      if ((familyId === null) === (sourceId === null)) return { error: "give family_id or source_id" };
      if (familyId !== null && !isUuid(familyId)) return { error: "family_id must be a uuid" };
      if (sourceId !== null && !isUuid(sourceId)) return { error: "source_id must be a uuid" };
      if (b.force != null && typeof b.force !== "boolean") return { error: "force must be true or false" };
      return {
        action: "sync",
        familyId: (familyId as string | null)?.toLowerCase() ?? null,
        sourceId: (sourceId as string | null)?.toLowerCase() ?? null,
        force: b.force === true,
      };
    }
    case "google_start":
      if (!isUuid(b.family_id)) return { error: "family_id must be a uuid" };
      return { action: "google_start", familyId: b.family_id.toLowerCase() };
    case "google_calendars":
    case "disconnect_google":
      if (!isUuid(b.account_id)) return { error: "account_id must be a uuid" };
      return { action: b.action, accountId: b.account_id.toLowerCase() };
    case "sync_due":
      return { action: "sync_due" };
    case "sync_source":
      if (!isUuid(b.source_id)) return { error: "source_id must be a uuid" };
      return { action: "sync_source", sourceId: b.source_id.toLowerCase() };
    default:
      return { error: "unknown action" };
  }
}
