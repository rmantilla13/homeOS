// Pure helpers for the assistant function: request parsing, SSE encoding,
// time-zone math, tool input validation, thread titles, reply assembly and
// usage accounting. Nothing here does I/O, so it's all covered by
// helpers.test.ts.

import type Anthropic from "npm:@anthropic-ai/sdk@^0.131.0";
import { isUuid } from "../_shared/http.ts";

export type Mode = "chat" | "quick";

const isObject = (v: unknown): v is Record<string, unknown> =>
  typeof v === "object" && v !== null && !Array.isArray(v);

// ───────────────────────────── Request body ─────────────────────────────

export const MAX_MESSAGE_CHARS = 4000;
const LEGACY_HISTORY = 20;

// `text` cut to at most `max` UTF-16 units, ending in "…" when it was cut.
// Never splits a surrogate pair.
export function clip(text: string, max: number): string {
  if (text.length <= max) return text;
  let cut = text.slice(0, max - 1);
  if (/[\uD800-\uDBFF]$/.test(cut)) cut = cut.slice(0, -1);
  return cut + "…";
}

// Family-typed text for the system prompt, on one line and clipped, so a
// list item or memory can't add prompt lines of its own or blow up its size.
export function oneLine(value: unknown, max: number): string {
  return clip(String(value ?? "").replace(/\s+/g, " ").trim(), max);
}

export interface V2Request {
  kind: "v2";
  message: string;
  threadId: string | null;
  mode: Mode;
  stream: boolean;
  familyId: string | null; // optional: which family a new thread belongs to
}
export interface LegacyMessage {
  role: "user" | "assistant";
  text: string;
}
export interface LegacyRequest {
  kind: "legacy";
  history: LegacyMessage[];
}
export type ParsedRequest = V2Request | LegacyRequest | { kind: "invalid"; error: string };

// `message` selects v2. Without it, a `messages` array is the v1 body: the
// last 20 turns, starting and ending with the user.
export function parseRequest(body: unknown): ParsedRequest {
  const invalid = (error: string): ParsedRequest => ({ kind: "invalid", error });
  if (!isObject(body)) return invalid("body must be a JSON object");

  if (body.message == null) {
    if (!Array.isArray(body.messages)) return invalid("message is required");
    const history = body.messages
      .filter((m): m is LegacyMessage =>
        isObject(m) && (m.role === "user" || m.role === "assistant") &&
        typeof m.text === "string" && m.text.trim() !== ""
      )
      .slice(-LEGACY_HISTORY)
      // Old clients send the whole conversation; cap each turn as v2 caps its message.
      .map((m) => ({ role: m.role, text: clip(m.text, MAX_MESSAGE_CHARS) }));
    while (history.length && history[0].role !== "user") history.shift();
    if (!history.length || history[history.length - 1].role !== "user") {
      return invalid("messages must end with a user message");
    }
    return { kind: "legacy", history };
  }

  if (typeof body.message !== "string" || !body.message.trim()) return invalid("message must be a non-empty string");
  const message = body.message.trim();
  if (message.length > MAX_MESSAGE_CHARS) return invalid(`message must be at most ${MAX_MESSAGE_CHARS} characters`);
  if (body.thread_id != null && !isUuid(body.thread_id)) return invalid("thread_id must be a uuid");
  if (body.family_id != null && !isUuid(body.family_id)) return invalid("family_id must be a uuid");
  if (body.mode != null && body.mode !== "chat" && body.mode !== "quick") return invalid('mode must be "chat" or "quick"');
  if (body.stream != null && typeof body.stream !== "boolean") return invalid("stream must be true or false");

  // Ids are compared as strings later, and Postgres returns them lowercase.
  return {
    kind: "v2",
    message,
    threadId: (body.thread_id as string | undefined)?.toLowerCase() ?? null,
    mode: (body.mode as Mode | undefined) ?? "chat",
    stream: body.stream === true,
    familyId: (body.family_id as string | undefined)?.toLowerCase() ?? null,
  };
}

// Stored thread messages (oldest first) → Claude messages. Empty rows are
// skipped and the history must open with a user turn. Owners can insert rows
// straight through PostgREST, so each one is clipped like a new message.
export function historyToMessages(rows: { role: unknown; content: unknown }[]): Anthropic.Beta.BetaMessageParam[] {
  const out: Anthropic.Beta.BetaMessageParam[] = [];
  for (const r of rows) {
    if ((r.role !== "user" && r.role !== "assistant") || typeof r.content !== "string" || !r.content.trim()) continue;
    if (!out.length && r.role !== "user") continue;
    out.push({ role: r.role, content: clip(r.content, MAX_MESSAGE_CHARS) });
  }
  return out;
}

// ───────────────────────────── Server-sent events ─────────────────────────────

// One SSE frame. JSON.stringify escapes newlines, so `data` is a single line.
export const sseEvent = (event: string, data: unknown): string =>
  `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;

// ───────────────────────────── Threads ─────────────────────────────

// A thread title from the first ~48 characters of its first message, cut at a
// word boundary when one is close.
export function threadTitle(message: string, max = 48): string {
  const text = message.replace(/\s+/g, " ").trim();
  const chars = Array.from(text); // code points, so emoji aren't split
  if (!chars.length) return "New chat";
  if (chars.length <= max) return text;
  let cut = chars.slice(0, max).join("");
  const space = cut.lastIndexOf(" ");
  if (space >= max * 0.6) cut = cut.slice(0, space);
  return cut.replace(/[\s.,;:!?-]+$/, "") + "…";
}

// ───────────────────────────── Who's asking ─────────────────────────────

export type Caller =
  | { kind: "device"; userId: string }
  | { kind: "person"; userId: string; memberId: string; name: string; role: string };

export function whoIsAsking(caller: Caller): string {
  return caller.kind === "device"
    ? "You're talking with the family screen in the kitchen; could be anyone in the family."
    : `You're talking with ${oneLine(caller.name, 60)} (${caller.role}).`; // the name is user-set
}

export const isParent = (caller: Caller): boolean => caller.kind === "person" && caller.role === "parent";

// ───────────────────────────── Time zones ─────────────────────────────

export function isValidTimeZone(tz: string): boolean {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: tz });
    return true;
  } catch {
    return false;
  }
}

function zonedParts(utcMs: number, tz: string): Record<string, number> {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: tz, hourCycle: "h23",
    year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit",
  }).formatToParts(new Date(utcMs));
  return Object.fromEntries(parts.filter((p) => p.type !== "literal").map((p) => [p.type, Number(p.value)]));
}

// Offset of `tz` from UTC at instant `utcMs`, in milliseconds.
export function tzOffsetMs(utcMs: number, tz: string): number {
  const p = zonedParts(utcMs, tz);
  return Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute, p.second) - (utcMs - (utcMs % 1000));
}

const LOCAL_DATE_TIME = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}))?)?$/;

// "YYYY-MM-DD", "YYYY-MM-DDTHH:MM" or "YYYY-MM-DDTHH:MM:SS" → its parts, or
// null when it isn't a real calendar date and time.
export function parseLocalDateTime(s: string): { y: number; mo: number; d: number; h: number; mi: number } | null {
  const m = LOCAL_DATE_TIME.exec(s.trim());
  if (!m) return null;
  const [y, mo, d, h, mi, sec] = [m[1], m[2], m[3], m[4] ?? "0", m[5] ?? "0", m[6] ?? "0"].map(Number);
  if (mo < 1 || mo > 12 || d < 1 || h > 23 || mi > 59 || sec > 59) return null;
  if (new Date(Date.UTC(y, mo - 1, d)).getUTCDate() !== d) return null; // e.g. Feb 30
  return { y, mo, d, h, mi };
}

const pad = (n: number, width = 2) => String(n).padStart(width, "0");

// Local wall time in `tz` → UTC ISO string. The second pass corrects the
// offset when the wall time is on the other side of a DST change from the
// first guess.
export function localToUtc(local: string, tz: string): string {
  const p = parseLocalDateTime(local);
  if (!p) throw new RangeError(`not a local date-time: ${local}`);
  const wall = Date.UTC(p.y, p.mo - 1, p.d, p.h, p.mi);
  let utc = wall - tzOffsetMs(wall, tz);
  utc = wall - tzOffsetMs(utc, tz);
  return new Date(utc).toISOString();
}

// The calendar date (YYYY-MM-DD) in `tz` at instant `ms`.
export function localDate(ms: number, tz: string): string {
  const p = zonedParts(ms, tz);
  return `${pad(p.year, 4)}-${pad(p.month)}-${pad(p.day)}`;
}

// Start of the UTC day containing `ms`, as an ISO string (the daily limit's day).
export function utcDayStart(ms: number): string {
  const d = new Date(ms);
  return new Date(Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate())).toISOString();
}

export function fmtLocal(iso: string, tz: string): string {
  return new Intl.DateTimeFormat("en-US", {
    timeZone: tz, weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit",
  }).format(new Date(iso));
}

export function fmtLocalDay(iso: string, tz: string): string {
  return new Intl.DateTimeFormat("en-US", { timeZone: tz, weekday: "short", month: "short", day: "numeric" })
    .format(new Date(iso));
}

// ───────────────────────────── Tool input validation ─────────────────────────────

export const MEALS = ["breakfast", "lunch", "dinner", "snack"] as const;
export type Meal = (typeof MEALS)[number];

export type ToolCall =
  | {
    name: "add_event";
    title: string;
    start: string; // normalized local YYYY-MM-DDTHH:MM
    end: string;
    all_day: boolean;
    member_names: string[];
    location: string | null;
  }
  | { name: "add_list_item"; list_name: string; text: string }
  | { name: "add_chore"; title: string; assignee_name: string | null; points: number; repeats_daily: boolean }
  | { name: "set_meal"; date: string; meal: Meal; title: string }
  | { name: "remember"; fact: string }
  | { name: "forget"; fact_contains: string };

export type Validation<T> = { ok: true; value: T } | { ok: false; error: string };

// Checks a tool's input against what its handler needs before anything runs.
// Strict tool schemas make bad input rare; this is the guarantee.
export function validateToolInput(name: string, input: unknown): Validation<ToolCall> {
  const errors: string[] = [];
  const obj = isObject(input) ? input : {};
  if (!isObject(input)) errors.push("input must be an object");

  const allow = (...keys: string[]) => {
    for (const k of Object.keys(obj)) if (!keys.includes(k)) errors.push(`unexpected field ${k}`);
  };
  const text = (key: string, max: number): string => {
    const v = obj[key];
    if (typeof v !== "string" || !v.trim()) {
      errors.push(`${key} must be a non-empty string`);
      return "";
    }
    if (v.trim().length > max) errors.push(`${key} must be at most ${max} characters`);
    return v.trim();
  };
  const optionalText = (key: string, max: number): string | null =>
    obj[key] == null || (typeof obj[key] === "string" && !(obj[key] as string).trim()) ? null : text(key, max);
  const bool = (key: string): boolean => {
    if (typeof obj[key] !== "boolean") errors.push(`${key} must be true or false`);
    return obj[key] === true;
  };
  const int = (key: string, min: number, max: number): number => {
    const v = obj[key];
    if (typeof v !== "number" || !Number.isInteger(v) || v < min || v > max) {
      errors.push(`${key} must be a whole number from ${min} to ${max}`);
      return min;
    }
    return v;
  };
  const dateTime = (key: string): string => {
    const v = obj[key];
    const p = typeof v === "string" ? parseLocalDateTime(v) : null;
    if (!p) {
      errors.push(`${key} must be a local date and time, YYYY-MM-DDTHH:MM`);
      return "";
    }
    return `${pad(p.y, 4)}-${pad(p.mo)}-${pad(p.d)}T${pad(p.h)}:${pad(p.mi)}`;
  };
  const date = (key: string): string => {
    const v = obj[key];
    if (typeof v !== "string" || !/^\d{4}-\d{2}-\d{2}$/.test(v) || !parseLocalDateTime(v)) {
      errors.push(`${key} must be a date, YYYY-MM-DD`);
      return "";
    }
    return v;
  };
  const names = (key: string): string[] => {
    const v = obj[key];
    if (v == null) return [];
    if (!Array.isArray(v) || v.length > 20 || v.some((n) => typeof n !== "string" || !n.trim() || n.length > 100)) {
      errors.push(`${key} must be a list of up to 20 names`);
      return [];
    }
    const seen = new Set<string>();
    return (v as string[]).map((n) => n.trim()).filter((n) => !seen.has(n.toLowerCase()) && seen.add(n.toLowerCase()));
  };
  const done = (value: ToolCall): Validation<ToolCall> =>
    errors.length ? { ok: false, error: `Invalid ${name} input: ${errors.join("; ")}.` } : { ok: true, value };

  switch (name) {
    case "add_event": {
      allow("title", "start", "end", "all_day", "member_names", "location");
      const start = dateTime("start");
      const end = dateTime("end");
      return done({
        name, title: text("title", 200), start, end: end < start ? start : end, all_day: bool("all_day"),
        member_names: names("member_names"), location: optionalText("location", 200),
      });
    }
    case "add_list_item":
      allow("list_name", "text");
      return done({ name, list_name: text("list_name", 100), text: text("text", 200) });
    case "add_chore":
      allow("title", "assignee_name", "points", "repeats_daily");
      return done({
        name, title: text("title", 200), assignee_name: optionalText("assignee_name", 100),
        points: int("points", 0, 10_000), repeats_daily: bool("repeats_daily"),
      });
    case "set_meal": {
      allow("date", "meal", "title");
      const meal = obj.meal;
      if (!MEALS.includes(meal as Meal)) errors.push(`meal must be one of ${MEALS.join(", ")}`);
      return done({ name, date: date("date"), meal: meal as Meal, title: text("title", 200) });
    }
    case "remember":
      allow("fact");
      return done({ name, fact: text("fact", 500) });
    case "forget": {
      allow("fact_contains");
      const needle = text("fact_contains", 200);
      if (needle && needle.length < 3) errors.push("fact_contains must be at least 3 characters");
      return done({ name, fact_contains: needle });
    }
    default:
      return { ok: false, error: `Unknown tool ${name}.` };
  }
}

// ───────────────────────────── Tool lookups ─────────────────────────────

export function findMember<M extends { display_name: string }>(members: M[], name: string | null): M | undefined {
  if (!name) return undefined;
  const n = name.trim().toLowerCase();
  return members.find((m) => m.display_name.trim().toLowerCase() === n);
}

// The list a tool call means: an exact name match, the only partial match, or
// the family's only list. Otherwise an error naming the lists so Claude can ask.
export function pickList<L extends { name: string }>(lists: L[], wanted: string): Validation<L> {
  if (!lists.length) return { ok: false, error: "The family has no lists yet." };
  const w = wanted.trim().toLowerCase();
  const exact = lists.find((l) => l.name.toLowerCase() === w);
  if (exact) return { ok: true, value: exact };
  const partial = lists.filter((l) => l.name.toLowerCase().includes(w) || w.includes(l.name.toLowerCase()));
  if (partial.length === 1) return { ok: true, value: partial[0] };
  if (lists.length === 1) return { ok: true, value: lists[0] };
  return { ok: false, error: `No list called ${wanted}. The lists are: ${lists.map((l) => l.name).join(", ")}.` };
}

// Memories whose text contains `needle`, ignoring case and spacing.
export function matchMemories<R extends { content: string }>(rows: R[], needle: string): R[] {
  const norm = (s: string) => s.toLowerCase().replace(/\s+/g, " ").trim();
  const n = norm(needle);
  return n ? rows.filter((r) => norm(r.content).includes(n)) : [];
}

// ───────────────────────────── Replies ─────────────────────────────

// Builds the reply from streamed text so the `done` reply matches what was
// streamed. Text from a later tool round starts a new paragraph.
export class ReplyBuilder {
  #text = "";
  #paragraph = false;

  // The next text starts a new paragraph (call between tool rounds).
  paragraph(): void {
    if (this.#text) this.#paragraph = true;
  }

  // Adds a piece of text and returns exactly what to forward to the client.
  push(delta: string): string {
    if (!delta) return "";
    let out = delta;
    if (this.#paragraph) {
      this.#paragraph = false;
      if (!/\s$/.test(this.#text) && !/^\s/.test(delta)) out = "\n\n" + delta;
    }
    this.#text += out;
    return out;
  }

  get text(): string {
    return this.#text.trim();
  }
}

// ───────────────────────────── Model content ─────────────────────────────

type Block = Anthropic.Beta.BetaContentBlock;

const lastFallback = (content: Block[]) => content.findLastIndex((b) => b.type === "fallback");

// The assistant content to send back on the next tool round. After a
// mid-output fallback, only the text the declining model produced before the
// final `fallback` block is echoed; its thinking and tool calls are dropped.
export function echoContent(content: Block[]): Block[] {
  const boundary = lastFallback(content);
  return boundary < 0 ? content : content.filter((b, i) => i >= boundary || b.type === "text");
}

// Tool calls to run: only those made by the model that finished the turn.
export function runnableToolUses(content: Block[]): Anthropic.Beta.BetaToolUseBlock[] {
  const boundary = lastFallback(content);
  return content.filter((b, i): b is Anthropic.Beta.BetaToolUseBlock => i > boundary && b.type === "tool_use");
}

// ───────────────────────────── Usage ─────────────────────────────

export interface UsageTotals {
  input: number; // uncached input plus cache writes
  output: number;
  cacheRead: number;
}

// Tokens for one response. With a server-side fallback, the top-level usage
// covers only the serving model, so the per-attempt iterations are summed.
export function usageOf(usage: Anthropic.Beta.BetaUsage): UsageTotals {
  const attempts = (usage.iterations ?? []).filter((i) => i.type === "message" || i.type === "fallback_message");
  const rows = attempts.length ? attempts : [usage];
  return rows.reduce<UsageTotals>((t, u) => ({
    input: t.input + u.input_tokens + (u.cache_creation_input_tokens ?? 0),
    output: t.output + u.output_tokens,
    cacheRead: t.cacheRead + (u.cache_read_input_tokens ?? 0),
  }), { input: 0, output: 0, cacheRead: 0 });
}
