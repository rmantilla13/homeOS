// Display formatting. Dates are shown in UTC (the server renders them, and
// admins in different time zones should read the same thing); relative times
// carry the exact timestamp in a tooltip.

const integer = new Intl.NumberFormat("en-US");
const compactFormat = new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 1 });
const dateFormat = new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" });
const shortDate = new Intl.DateTimeFormat("en-US", { month: "short", day: "numeric", timeZone: "UTC" });
const dateTimeFormat = new Intl.DateTimeFormat("en-US", {
  month: "short",
  day: "numeric",
  year: "numeric",
  hour: "numeric",
  minute: "2-digit",
  timeZone: "UTC",
  timeZoneName: "short",
});

export const formatNumber = (n: number) => integer.format(n);
export const formatCompact = (n: number) => (Math.abs(n) < 10_000 ? integer.format(n) : compactFormat.format(n));

// Timestamps come from family-writable rows, and Postgres also stores values
// JavaScript can't read ('infinity', years past 9999). Those are shown as
// they are instead of throwing, so one odd row can't take a page down.
function format(f: Intl.DateTimeFormat, iso: string): string {
  const t = Date.parse(iso);
  return Number.isFinite(t) ? f.format(t) : iso;
}

export function formatDate(iso: string | null | undefined): string {
  return iso ? format(dateFormat, iso) : "—";
}

export function formatShortDate(iso: string): string {
  return format(shortDate, iso.length === 10 ? `${iso}T00:00:00Z` : iso);
}

export function formatDateTime(iso: string | null | undefined): string {
  return iso ? format(dateTimeFormat, iso) : "—";
}

const UNITS: [Intl.RelativeTimeFormatUnit, number][] = [
  ["year", 365 * 86_400],
  ["month", 30 * 86_400],
  ["week", 7 * 86_400],
  ["day", 86_400],
  ["hour", 3_600],
  ["minute", 60],
];
const relative = new Intl.RelativeTimeFormat("en-US", { numeric: "auto", style: "short" });

export function formatRelative(iso: string | null | undefined, now = Date.now()): string {
  if (!iso) return "never";
  const t = Date.parse(iso);
  if (!Number.isFinite(t)) return iso;
  const seconds = Math.round((t - now) / 1000);
  if (Math.abs(seconds) < 60) return seconds <= 0 ? "just now" : "in a moment";
  for (const [unit, size] of UNITS) {
    if (Math.abs(seconds) >= size) return relative.format(Math.trunc(seconds / size), unit);
  }
  return relative.format(Math.trunc(seconds / 60), "minute");
}

export const plural = (n: number, one: string, many = `${one}s`) => `${formatNumber(n)} ${n === 1 ? one : many}`;

// A member color that is safe to put in a style attribute, or null. Colors are
// free text that family members set themselves; anything but a hex color
// ("red;position:fixed", "url(https://…)") would be CSS in the admin's page.
export function cssColor(value: unknown): string | null {
  const v = typeof value === "string" ? value.trim() : "";
  return /^#(?:[0-9a-f]{3,4}|[0-9a-f]{6}|[0-9a-f]{8})$/i.test(v) ? v : null;
}

// Audit action ids → words.
const ACTIONS: Record<string, string> = {
  create_platform_invite: "Created invite",
  revoke_platform_invite: "Revoked invite",
  invite_email: "Emailed invite",
  set_family_status: "Changed family status",
  delete_family: "Deleted family",
  delete_family_files: "Removed family files",
  update_settings: "Updated settings",
  set_admin: "Changed admin access",
  ban_user: "Banned user",
  unban_user: "Unbanned user",
  delete_user: "Deleted user",
};

export function describeAction(action: string, details: Record<string, unknown> = {}): string {
  if (action === "set_family_status") return details.status === "suspended" ? "Suspended family" : "Reactivated family";
  if (action === "set_admin") return details.make_admin ? "Made admin" : "Removed admin";
  return ACTIONS[action] ?? action.replaceAll("_", " ");
}
