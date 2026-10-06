// assistant: the family AI on the wall display, in the iOS app and in Siri.
//
// v2  POST { message, thread_id?, mode?: "chat" | "quick", stream?: boolean }
//       stream false -> { reply, actions: [{ type, summary }], thread_id, message_id }
//       stream true  -> text/event-stream: thread, delta…, action…, then done (or error)
// v1  POST { messages: [{ role: "user" | "assistant", text }, …] } -> { reply, actions }
//       Legacy body, kept for older clients. Nothing is stored.
//
// Each request is grounded in the family's live data (calendar, chores,
// points, rewards, meals, lists) plus the family memory. Family data, threads
// and messages are read and written with the caller's own JWT, so row-level
// security limits the assistant to the caller's family. The service role is
// used only to identify the caller (and the family of the thread they name),
// enforce the platform gates (family suspension, assistant switch, daily
// limit) and record usage.
//
// Claude can add events, list items, chores and meals, remember facts and,
// for parents, forget them. Points, approvals and rewards stay out of reach on
// purpose: a child at the screen shouldn't be able to award points.
//
// Secrets: ANTHROPIC_API_KEY (set with `supabase secrets set`).

import Anthropic from "npm:@anthropic-ai/sdk@^0.131.0";
import { createClient, type SupabaseClient, type User } from "jsr:@supabase/supabase-js@2";
import { bearerToken, corsHeaders, HttpError, json, preflight } from "../_shared/http.ts";
import {
  type Caller,
  echoContent,
  findMember,
  fmtLocal,
  fmtLocalDay,
  historyToMessages,
  isParent,
  isValidTimeZone,
  type LegacyMessage,
  localDate,
  localToUtc,
  matchMemories,
  type Mode,
  parseRequest,
  pickList,
  ReplyBuilder,
  runnableToolUses,
  sseEvent,
  threadTitle,
  type ToolCall,
  type UsageTotals,
  usageOf,
  utcDayStart,
  type V2Request,
  validateToolInput,
  whoIsAsking,
} from "./helpers.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;
const SERVICE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const MODEL = "claude-opus-5-5";
const MAX_TOOL_ROUNDS = 6;
const HISTORY: Record<Mode, number> = { chat: 20, quick: 6 };
const MAX_TOKENS: Record<Mode, number> = { chat: 16000, quick: 2000 };
const DEFAULT_DAILY_LIMIT = 200; // used only if platform_settings has no row
const MAX_FORGET = 5; // more matches than this and Claude must be more specific

const REPLY = {
  off: "The assistant is turned off right now.",
  limit: "We've hit today's assistant limit. Try again tomorrow.",
  refusal: "Sorry, I can't help with that one.",
  tooManySteps: "That took more steps than I can do at once. Could you break it into smaller requests?",
  truncated: "That ran longer than I can manage in one go. Could you ask for a bit less at once?",
  busy: "I'm a bit busy right now. Try again in a moment.",
  unavailable: "The assistant isn't available right now. Please try again in a bit.",
  failed: "Sorry, something went wrong. Please try again.",
  failedPartway: "Sorry, something went wrong before I could finish.",
};

const anthropic = new Anthropic(); // reads ANTHROPIC_API_KEY
const service = createClient(SUPABASE_URL, SERVICE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

// ───────────────────────────── Prompt ─────────────────────────────

// Stable instructions first so they can be cached; who's asking and the
// family snapshot (which change every request) go in a later system block.
const INSTRUCTIONS = `You are homeOS, the assistant built into a family's shared touchscreen and phone app.

Who you're talking to: the line "You're talking with …" below says who is asking. On the family screen in the kitchen it could be anyone in the family, a parent or a child, and on a phone it's that person. Keep answers friendly, short and easy to read from a few feet away: one to three sentences, or a short list. No markdown headings or tables.

What you know: the family snapshot below is live data from their calendar, chores, points, rewards, meal plan, lists and family memory. Answer from it. If something isn't in the snapshot, say you don't know rather than guessing. Times in the snapshot are already in the family's local time zone.

What you can do: add calendar events, add items to a list, add chores, set a planned meal, remember facts the family tells you, and forget saved facts when a parent asks. Before adding something that's ambiguous (which person, which day, what time), ask one short clarifying question. After you use a tool, confirm what you did in one sentence.

What you can't do: award or remove points, approve chores, or redeem rewards — those belong to parents in the iPhone app. If asked, say so kindly.

When someone shares a lasting fact about the family (allergies, routines, preferences, who carpools with whom), save it with the remember tool so you know it next time.

Keep it kid-safe.`;

const QUICK_MODE =
  "Answer in one or two short sentences meant to be spoken aloud. No lists, no markdown, no emoji. Say times and numbers naturally.";

// ───────────────────────────── Tools ─────────────────────────────

// strict: true keeps arguments schema-valid; inputs are still validated before
// anything runs (validateToolInput). Inputs are a few short strings, so eager
// input streaming would gain nothing and is left off.
const TOOLS: Anthropic.Beta.BetaTool[] = [
  {
    name: "add_event",
    description:
      "Add an event to the family calendar. Use when someone asks to add, schedule or put something on the calendar. Use local date/time in the family's time zone (YYYY-MM-DDTHH:MM). For all-day events, pass the date at 00:00 and all_day true.",
    strict: true,
    input_schema: {
      type: "object",
      properties: {
        title: { type: "string" },
        start: { type: "string", description: "Local start, YYYY-MM-DDTHH:MM" },
        end: { type: "string", description: "Local end, YYYY-MM-DDTHH:MM. Default to one hour after start if unknown." },
        all_day: { type: "boolean" },
        member_names: { type: "array", items: { type: "string" }, description: "Family members involved, by display name. Empty for the whole family." },
        location: { type: ["string", "null"] },
      },
      required: ["title", "start", "end", "all_day", "member_names", "location"],
      additionalProperties: false,
    },
  },
  {
    name: "add_list_item",
    description: "Add an item to one of the family's lists, for example the grocery list. Use when someone says to add, buy or pick up something.",
    strict: true,
    input_schema: {
      type: "object",
      properties: {
        list_name: { type: "string", description: "Name of an existing list, e.g. Groceries" },
        text: { type: "string" },
      },
      required: ["list_name", "text"],
      additionalProperties: false,
    },
  },
  {
    name: "add_chore",
    description: "Add a chore or to-do, optionally assigned to a family member, with reward points.",
    strict: true,
    input_schema: {
      type: "object",
      properties: {
        title: { type: "string" },
        assignee_name: { type: ["string", "null"] },
        points: { type: "integer", description: "Reward points, 0 for none" },
        repeats_daily: { type: "boolean" },
      },
      required: ["title", "assignee_name", "points", "repeats_daily"],
      additionalProperties: false,
    },
  },
  {
    name: "set_meal",
    description: "Set the planned meal for a day.",
    strict: true,
    input_schema: {
      type: "object",
      properties: {
        date: { type: "string", description: "YYYY-MM-DD" },
        meal: { type: "string", enum: ["breakfast", "lunch", "dinner", "snack"] },
        title: { type: "string" },
      },
      required: ["date", "meal", "title"],
      additionalProperties: false,
    },
  },
  {
    name: "remember",
    description: "Save a lasting fact about the family so you know it in future conversations.",
    strict: true,
    input_schema: {
      type: "object",
      properties: { fact: { type: "string" } },
      required: ["fact"],
      additionalProperties: false,
    },
  },
  {
    name: "forget",
    description:
      "Delete saved family memories that contain the given text. Use when someone asks you to forget something or says a saved fact is wrong. Only parents may do this; the tool says so if the person asking isn't a parent.",
    strict: true,
    input_schema: {
      type: "object",
      properties: {
        fact_contains: { type: "string", description: "A distinctive word or phrase from the memory to delete, e.g. peanuts" },
      },
      required: ["fact_contains"],
      additionalProperties: false,
    },
  },
];

// ───────────────────────────── Caller and family ─────────────────────────────

interface FamilyInfo {
  id: string;
  name: string;
  timezone: string;
  status: string;
  assistant_daily_limit: number | null;
}

const dbError = (what: string, error: { message: string }) => new Error(`${what}: ${error.message}`);

// Who is calling and which family they're asking about, read with the service
// role so a suspended family answers 403 instead of looking empty. Picks
// `familyHint` (a thread's family) when given, else the first active family.
async function identify(user: User, familyHint: string | null): Promise<{ caller: Caller; family: FamilyInfo }> {
  const isDevice = user.app_metadata?.kind === "device";
  const memberships: { family_id: string; id?: string; display_name?: string; role?: string }[] = [];
  if (isDevice) {
    const { data, error } = await service.from("devices").select("family_id").eq("user_id", user.id);
    if (error) throw dbError("device lookup", error);
    memberships.push(...(data ?? []));
  } else {
    const { data, error } = await service.from("members")
      .select("id, family_id, display_name, role").eq("user_id", user.id).order("created_at");
    if (error) throw dbError("member lookup", error);
    memberships.push(...(data ?? []));
  }
  if (!memberships.length) throw new HttpError(403, "no family for this account");

  const [families, profile] = await Promise.all([
    service.from("families").select("id, name, timezone, status, assistant_daily_limit")
      .in("id", memberships.map((m) => m.family_id)),
    isDevice ? null : service.from("profiles").select("display_name").eq("id", user.id).maybeSingle(),
  ]);
  if (families.error) throw dbError("family lookup", families.error);
  if (profile?.error) throw dbError("profile lookup", profile.error);
  const byId = new Map((families.data as FamilyInfo[]).map((f) => [f.id, f]));

  const membership = familyHint
    ? memberships.find((m) => m.family_id === familyHint)
    : memberships.find((m) => byId.get(m.family_id)?.status !== "suspended") ?? memberships[0];
  const family = membership && byId.get(membership.family_id);
  if (!membership || !family) throw new HttpError(403, "you're not a member of that family");
  if (family.status === "suspended") throw new HttpError(403, "this family's account is suspended");
  if (!isValidTimeZone(family.timezone)) family.timezone = "UTC";

  const caller: Caller = isDevice ? { kind: "device", userId: user.id } : {
    kind: "person",
    userId: user.id,
    memberId: membership.id!,
    name: profile?.data?.display_name?.trim() || membership.display_name?.trim() || "a family member",
    role: membership.role ?? "parent",
  };
  return { caller, family };
}

// The platform switch and the family's daily limit (UTC day). Returns the
// reply to give instead of calling Claude, or null to go ahead.
async function gate(family: FamilyInfo): Promise<string | null> {
  const [settings, usage] = await Promise.all([
    service.from("platform_settings").select("assistant_enabled, assistant_daily_limit").maybeSingle(),
    service.from("assistant_usage").select("id", { count: "exact", head: true })
      .eq("family_id", family.id).gte("created_at", utcDayStart(Date.now())),
  ]);
  if (settings.error) throw dbError("platform settings", settings.error);
  if (usage.error) throw dbError("usage count", usage.error);
  if (settings.data?.assistant_enabled === false) return REPLY.off;
  const limit = family.assistant_daily_limit ?? settings.data?.assistant_daily_limit ?? DEFAULT_DAILY_LIMIT;
  return (usage.count ?? 0) >= limit ? REPLY.limit : null;
}

// ───────────────────────────── Family snapshot ─────────────────────────────

type Row = Record<string, unknown>;
interface MemberRow {
  id: string;
  display_name: string;
  role: string;
}
interface ListRow {
  id: string;
  name: string;
  list_items: { text: string; done: boolean }[] | null;
}
interface Snapshot {
  members: MemberRow[];
  lists: ListRow[];
  text: string;
}

async function loadSnapshot(db: SupabaseClient, family: FamilyInfo): Promise<Snapshot> {
  const { id: fid, timezone: tz } = family;
  const now = Date.now();
  const today = localDate(now, tz);
  const in14 = new Date(now + 14 * 86_400_000).toISOString();
  const weekAhead = localDate(now + 7 * 86_400_000, tz);

  const results = await Promise.all([
    db.from("members").select("id, display_name, role").eq("family_id", fid).order("sort_order"),
    db.from("member_points").select("member_id, balance").eq("family_id", fid),
    db.from("events").select("title, starts_at, ends_at, all_day, location, event_members(member_id)").eq("family_id", fid)
      .gte("ends_at", new Date(now - 86_400_000).toISOString()).lt("starts_at", in14).order("starts_at").limit(80),
    db.from("tasks").select("id, title, assignee_id, points, rrule, requires_approval").eq("family_id", fid).eq("archived", false),
    db.from("task_completions").select("task_id, member_id, status").eq("family_id", fid).eq("for_date", today),
    db.from("rewards").select("title, cost").eq("family_id", fid).eq("active", true).order("cost"),
    db.from("meal_plans").select("date, meal, title").eq("family_id", fid).gte("date", today).lte("date", weekAhead).order("date"),
    db.from("lists").select("id, name, list_items(text, done)").eq("family_id", fid).order("sort_order"),
    db.from("family_memories").select("content").eq("family_id", fid).order("created_at").limit(100),
  ]);
  for (const r of results) if (r.error) console.error("snapshot query failed:", r.error.message);
  const [members, points, events, tasks, done, rewards, meals, lists, memories] = results.map((r) => (r.data ?? []) as Row[]);

  const memberRows = members as unknown as MemberRow[];
  const nameOf = (id: unknown) => memberRows.find((m) => m.id === id)?.display_name ?? "someone";
  const balance = new Map(points.map((p) => [p.member_id, p.balance]));
  const doneMap = new Map(done.map((c) => [`${c.task_id}|${c.member_id}`, c.status]));

  const lines: string[] = [];
  lines.push(`Family: ${family.name}. Time zone: ${tz}.`);
  lines.push(`Now: ${new Intl.DateTimeFormat("en-US", { timeZone: tz, dateStyle: "full", timeStyle: "short" }).format(new Date(now))} (today is ${today}).`);

  lines.push("\nMembers:");
  for (const m of memberRows) {
    const pts = m.role === "child" ? `, ${balance.get(m.id) ?? 0} points` : "";
    lines.push(`- ${m.display_name} (${m.role}${pts})`);
  }

  lines.push("\nCalendar (next 14 days):");
  for (const e of events) {
    const who = ((e.event_members as Row[]) ?? []).map((em) => nameOf(em.member_id)).join(", ") || "whole family";
    const when = e.all_day ? `${fmtLocalDay(String(e.starts_at), tz)} (all day)` : fmtLocal(String(e.starts_at), tz);
    lines.push(`- ${when}: ${e.title} — ${who}${e.location ? ` @ ${e.location}` : ""}`);
  }
  if (!events.length) lines.push("- nothing scheduled");

  lines.push("\nChores (today's status; recurrence in RRULE form):");
  for (const t of tasks) {
    const status = doneMap.get(`${t.id}|${t.assignee_id}`) ?? "not done";
    lines.push(`- ${t.title} — ${t.assignee_id ? nameOf(t.assignee_id) : "anyone"}, ${t.points} pts, ${t.rrule ?? "one-time"}: ${status}`);
  }

  lines.push("\nRewards: " + rewards.map((r) => `${r.title} (${r.cost} pts)`).join("; "));
  lines.push("\nMeals planned: " + (meals.map((m) => `${m.date} ${m.meal}: ${m.title}`).join("; ") || "none"));

  const listRows = lists as unknown as ListRow[];
  lines.push("\nLists:");
  for (const l of listRows) {
    const open = (l.list_items ?? []).filter((i) => !i.done).map((i) => i.text);
    lines.push(`- ${l.name}: ${open.length ? open.join(", ") : "(empty)"}`);
  }

  lines.push("\nFamily memory:");
  lines.push(memories.length ? memories.map((m) => `- ${m.content}`).join("\n") : "- (nothing saved yet)");

  return { members: memberRows, lists: listRows, text: lines.join("\n") };
}

// ───────────────────────────── Tool execution ─────────────────────────────

interface Action {
  type: string;
  summary: string;
}
interface ToolOutcome {
  content: string;
  isError?: boolean;
  action?: Action;
}
interface ToolContext {
  db: SupabaseClient;
  family: FamilyInfo;
  caller: Caller;
  snapshot: Snapshot;
}

async function runTool(ctx: ToolContext, call: ToolCall): Promise<ToolOutcome> {
  const { db, family, caller } = ctx;
  const tz = family.timezone;
  const memberId = caller.kind === "person" ? caller.memberId : null;
  const failed = (what: string, error: { message: string }): ToolOutcome => ({
    content: `Couldn't ${what}: ${error.message}`,
    isError: true,
  });

  switch (call.name) {
    case "add_event": {
      const found = call.member_names.map((n) => ({ n, m: findMember(ctx.snapshot.members, n) }));
      const unknown = found.filter((f) => !f.m).map((f) => f.n);
      if (unknown.length) {
        return {
          content: `No family member named ${unknown.join(", ")}. Members are: ${ctx.snapshot.members.map((m) => m.display_name).join(", ")}.`,
          isError: true,
        };
      }
      const startsAt = localToUtc(call.start, tz);
      const endsAt = localToUtc(call.end, tz);
      const { data, error } = await db.from("events").insert({
        family_id: family.id, title: call.title, starts_at: startsAt, ends_at: endsAt < startsAt ? startsAt : endsAt,
        all_day: call.all_day, location: call.location, created_by: memberId,
      }).select("id").single();
      if (error) return failed("add the event", error);
      if (found.length) {
        const { error: linkErr } = await db.from("event_members")
          .insert(found.map((f) => ({ event_id: data.id, member_id: f.m!.id })));
        if (linkErr) console.error("event_members insert failed:", linkErr.message);
      }
      const when = call.all_day ? `${fmtLocalDay(startsAt, tz)} (all day)` : fmtLocal(startsAt, tz);
      return { content: "Event added.", action: { type: "add_event", summary: `Added “${call.title}” on ${when}` } };
    }
    case "add_list_item": {
      const list = pickList(ctx.snapshot.lists, call.list_name);
      if (!list.ok) return { content: list.error, isError: true };
      const { error } = await db.from("list_items").insert({ list_id: list.value.id, text: call.text, added_by: memberId });
      if (error) return failed("add the item", error);
      return {
        content: `Added to ${list.value.name}.`,
        action: { type: "add_list_item", summary: `Added ${call.text} to ${list.value.name}` },
      };
    }
    case "add_chore": {
      const assignee = findMember(ctx.snapshot.members, call.assignee_name);
      if (call.assignee_name && !assignee) return { content: `No family member named ${call.assignee_name}.`, isError: true };
      const { error } = await db.from("tasks").insert({
        family_id: family.id, title: call.title, assignee_id: assignee?.id ?? null, points: call.points,
        rrule: call.repeats_daily ? "FREQ=DAILY" : null, created_by: memberId,
      });
      if (error) return failed("add the chore", error);
      return {
        content: "Chore added.",
        action: { type: "add_chore", summary: `Added chore “${call.title}”${assignee ? ` for ${assignee.display_name}` : ""}` },
      };
    }
    case "set_meal": {
      const { error } = await db.from("meal_plans").upsert(
        { family_id: family.id, date: call.date, meal: call.meal, title: call.title },
        { onConflict: "family_id,date,meal" },
      );
      if (error) return failed("set the meal", error);
      return { content: "Meal saved.", action: { type: "set_meal", summary: `${call.meal} on ${call.date}: ${call.title}` } };
    }
    case "remember": {
      const { error } = await db.from("family_memories").insert({ family_id: family.id, content: call.fact, source: "assistant" });
      if (error) return failed("save that", error);
      return { content: "Saved to family memory.", action: { type: "remember", summary: `Remembered: ${call.fact}` } };
    }
    case "forget": {
      if (!isParent(caller)) {
        return { content: "Only a parent can make me forget things. A parent can ask me, or remove it in the iPhone app." };
      }
      const { data, error } = await db.from("family_memories").select("id, content").eq("family_id", family.id).limit(1000);
      if (error) return failed("look up family memory", error);
      const matches = matchMemories((data ?? []) as { id: string; content: string }[], call.fact_contains);
      if (!matches.length) return { content: `Nothing in family memory mentions “${call.fact_contains}”.` };
      if (matches.length > MAX_FORGET) {
        return {
          content: `${matches.length} memories mention “${call.fact_contains}”. Ask which one to forget, or use a more specific phrase.`,
          isError: true,
        };
      }
      const { data: deleted, error: delErr } = await db.from("family_memories")
        .delete().in("id", matches.map((m) => m.id)).select("content");
      if (delErr) return failed("forget that", delErr);
      if (!deleted?.length) return { content: "Couldn't delete that memory.", isError: true };
      const facts = (deleted as { content: string }[]).map((d) => d.content);
      return {
        content: `Forgot: ${facts.join(" | ")}`,
        action: {
          type: "forget",
          summary: facts.length === 1 ? `Forgot: ${facts[0]}` : `Forgot ${facts.length} things about ${call.fact_contains}`,
        },
      };
    }
  }
}

// Validates a tool call, then runs it. Failures go back to Claude as error
// results so it can correct itself or tell the family.
async function executeTool(ctx: ToolContext, block: Anthropic.Beta.BetaToolUseBlock): Promise<ToolOutcome> {
  const input = validateToolInput(block.name, block.input);
  if (!input.ok) return { content: input.error, isError: true };
  try {
    return await runTool(ctx, input.value);
  } catch (err) {
    console.error(`tool ${block.name} failed:`, err);
    return { content: `Something went wrong running ${block.name}.`, isError: true };
  }
}

// ───────────────────────────── Conversation ─────────────────────────────

interface Stats {
  rounds: number;
  toolCalls: number;
  usage: UsageTotals;
  model: string;
}
const newStats = (): Stats => ({ rounds: 0, toolCalls: 0, usage: { input: 0, output: 0, cacheRead: 0 }, model: MODEL });

interface ConverseOptions {
  ctx: ToolContext;
  mode: Mode;
  messages: Anthropic.Beta.BetaMessageParam[];
  actions: Action[]; // filled as tools succeed
  stats: Stats; // filled as rounds complete, even if a later round fails
  onText?: (text: string) => void;
  onAction?: (action: Action) => void;
}

// Runs Claude with the family tools until it answers, streaming text as it
// arrives. Returns the reply; model API errors propagate to the caller.
async function converse({ ctx, mode, messages, actions, stats, onText, onAction }: ConverseOptions): Promise<string> {
  const system: Anthropic.Beta.BetaTextBlockParam[] = [
    { type: "text", text: INSTRUCTIONS, cache_control: { type: "ephemeral" } },
    { type: "text", text: `${whoIsAsking(ctx.caller)}\n\nFamily snapshot:\n${ctx.snapshot.text}` },
  ];
  if (mode === "quick") system.push({ type: "text", text: QUICK_MODE });

  const reply = new ReplyBuilder();
  const emit = (text: string) => {
    const out = reply.push(text);
    if (out) onText?.(out);
  };

  for (let round = 0; round < MAX_TOOL_ROUNDS; round++) {
    const stream = anthropic.beta.messages.stream({
      model: MODEL,
      max_tokens: MAX_TOKENS[mode],
      // Conversational and latency-sensitive: low effort keeps replies quick.
      // Thinking is left at the model's default (adaptive).
      output_config: { effort: "low" },
      // If a safety classifier declines a benign family request, the API re-runs
      // it on Anthropic's recommended fallback model instead of failing the turn.
      betas: ["server-side-fallback-2026-07-01"],
      fallbacks: "default",
      system,
      tools: TOOLS,
      messages,
    });
    for await (const event of stream) {
      if (event.type === "content_block_start" && event.content_block.type === "text") emit(event.content_block.text);
      else if (event.type === "content_block_delta" && event.delta.type === "text_delta") emit(event.delta.text);
    }
    const message = await stream.finalMessage();
    stats.rounds++;
    stats.model = message.model;
    const u = usageOf(message.usage);
    stats.usage.input += u.input;
    stats.usage.output += u.output;
    stats.usage.cacheRead += u.cacheRead;

    // The whole fallback chain declined. Any partial text is discarded; the
    // `done` reply replaces what was streamed.
    if (message.stop_reason === "refusal") return REPLY.refusal;

    if (message.stop_reason === "pause_turn") {
      messages.push({ role: "assistant", content: echoContent(message.content) });
      continue;
    }

    const toolUses = runnableToolUses(message.content);
    if (message.stop_reason === "tool_use" && toolUses.length) {
      messages.push({ role: "assistant", content: echoContent(message.content) });
      const results: Anthropic.Beta.BetaToolResultBlockParam[] = [];
      for (const block of toolUses) {
        stats.toolCalls++;
        const outcome = await executeTool(ctx, block);
        if (outcome.action) {
          actions.push(outcome.action);
          onAction?.(outcome.action);
        }
        results.push({
          type: "tool_result",
          tool_use_id: block.id,
          content: outcome.content,
          ...(outcome.isError ? { is_error: true } : {}),
        });
      }
      messages.push({ role: "user", content: results });
      reply.paragraph();
      continue;
    }

    // Cut off mid tool call: the input may be truncated, so it isn't run.
    if (message.stop_reason === "max_tokens" && toolUses.length) {
      reply.paragraph();
      emit(REPLY.truncated);
    }
    return reply.text || "Done!";
  }

  reply.paragraph();
  emit(REPLY.tooManySteps);
  return reply.text;
}

function modelErrorMessage(err: InstanceType<typeof Anthropic.APIError>): string {
  return err instanceof Anthropic.RateLimitError || err.status === 529 ? REPLY.busy : REPLY.unavailable;
}

// ───────────────────────────── Persistence ─────────────────────────────

// Usage is written with the service role (clients can't write it) and counts
// toward the family's daily limit. Only requests that reached the model count.
async function recordUsage(family: FamilyInfo, userId: string, threadId: string | null, mode: Mode, stats: Stats) {
  if (!stats.rounds) return;
  const { error } = await service.from("assistant_usage").insert({
    family_id: family.id,
    user_id: userId,
    thread_id: threadId,
    mode,
    model: stats.model,
    input_tokens: stats.usage.input,
    output_tokens: stats.usage.output,
    cache_read_tokens: stats.usage.cacheRead,
    tool_calls: stats.toolCalls,
  });
  if (error) console.error("usage insert failed:", error.message);
}

// Stores the assistant's reply as the caller and bumps the thread.
async function saveReply(
  db: SupabaseClient, threadId: string, familyId: string, mode: Mode, reply: string, actions: Action[],
): Promise<number> {
  const { data, error } = await db.from("assistant_messages")
    .insert({ thread_id: threadId, family_id: familyId, role: "assistant", content: reply, actions, mode })
    .select("id").single();
  if (error) throw dbError("saving reply", error);
  const { error: touchErr } = await db.from("assistant_threads")
    .update({ updated_at: new Date().toISOString() }).eq("id", threadId);
  if (touchErr) console.error("thread touch failed:", touchErr.message);
  return Number(data.id);
}

// ───────────────────────────── Streaming ─────────────────────────────

type Send = (event: string, data: unknown) => void;

// An SSE response fed by `run`. If the client goes away the work carries on,
// so the reply is still stored in the thread.
function sseResponse(run: (send: Send) => Promise<void>): Response {
  const encoder = new TextEncoder();
  let open = true;
  const body = new ReadableStream<Uint8Array>({
    start(controller) {
      const send: Send = (event, data) => {
        if (!open) return;
        try {
          controller.enqueue(encoder.encode(sseEvent(event, data)));
        } catch {
          open = false;
        }
      };
      const task = run(send)
        .catch((err) => {
          console.error("assistant stream failed:", err);
          send("error", { message: REPLY.failed });
        })
        .finally(() => {
          if (!open) return;
          open = false;
          controller.close();
        });
      // Keep the worker alive until the reply is stored, even after a disconnect.
      (globalThis as { EdgeRuntime?: { waitUntil(p: Promise<unknown>): void } }).EdgeRuntime?.waitUntil(task);
    },
    cancel() {
      open = false;
    },
  });
  return new Response(body, {
    headers: { ...corsHeaders, "Content-Type": "text/event-stream", "Cache-Control": "no-cache", "X-Accel-Buffering": "no" },
  });
}

// ───────────────────────────── Handlers ─────────────────────────────

async function handleV2(db: SupabaseClient, user: User, req: V2Request): Promise<Response> {
  // Look the thread up with the service role so a thread in a suspended
  // family answers 403 (from identify) rather than 404.
  let threadId: string | null = null;
  let threadFamily: string | null = null;
  if (req.threadId) {
    const { data, error } = await service.from("assistant_threads")
      .select("id, family_id, owner_id").eq("id", req.threadId).maybeSingle();
    if (error) throw dbError("thread lookup", error);
    if (!data || data.owner_id !== user.id) throw new HttpError(404, "thread not found");
    threadId = data.id as string;
    threadFamily = data.family_id as string;
  }
  const { caller, family } = await identify(user, threadFamily ?? req.familyId);
  // A gate reply (assistant off, daily limit) is stored like any other reply,
  // so clients always get a thread id and message id back.
  const refusal = await gate(family);

  // Threads and messages are read and written as the caller, under RLS.
  let history: Anthropic.Beta.BetaMessageParam[] = [];
  if (threadId) {
    const { data, error } = await db.from("assistant_messages").select("role, content")
      .eq("thread_id", threadId).order("id", { ascending: false }).limit(HISTORY[req.mode]);
    if (error) throw dbError("loading history", error);
    history = historyToMessages((data ?? []).reverse());
  } else {
    const { data, error } = await db.from("assistant_threads")
      .insert({ family_id: family.id, title: threadTitle(req.message) }).select("id").single();
    if (error) throw dbError("creating thread", error);
    threadId = data.id as string;
  }
  const { error: msgErr } = await db.from("assistant_messages")
    .insert({ thread_id: threadId, family_id: family.id, role: "user", content: req.message, mode: req.mode });
  if (msgErr) throw dbError("saving message", msgErr);

  const snapshot = refusal ? null : await loadSnapshot(db, family);
  const thread = threadId;

  // Produces and stores the reply. Model API errors propagate.
  const turn = async (onText?: (text: string) => void, onAction?: (a: Action) => void) => {
    const actions: Action[] = [];
    if (!snapshot) {
      onText?.(refusal!);
      return { reply: refusal!, actions, messageId: await saveReply(db, thread, family.id, req.mode, refusal!, actions) };
    }
    const stats = newStats();
    try {
      const reply = await converse({
        ctx: { db, family, caller, snapshot },
        mode: req.mode,
        messages: [...history, { role: "user", content: req.message }],
        actions,
        stats,
        onText,
        onAction,
      });
      return { reply, actions, messageId: await saveReply(db, thread, family.id, req.mode, reply, actions) };
    } catch (err) {
      // Keep a record of anything that was already done.
      if (actions.length) {
        await saveReply(db, thread, family.id, req.mode, REPLY.failedPartway, actions)
          .catch((e) => console.error("saving partial reply failed:", e));
      }
      throw err;
    } finally {
      await recordUsage(family, user.id, thread, req.mode, stats);
    }
  };

  if (!req.stream) {
    try {
      const { reply, actions, messageId } = await turn();
      return json({ reply, actions, thread_id: thread, message_id: messageId });
    } catch (err) {
      if (!(err instanceof Anthropic.APIError)) throw err;
      console.error(`Claude API error ${err.status}:`, err.message);
      return json({ error: modelErrorMessage(err) }, 502);
    }
  }

  return sseResponse(async (send) => {
    send("thread", { thread_id: thread });
    try {
      const { reply, actions, messageId } = await turn(
        (text) => send("delta", { text }),
        (action) => send("action", action),
      );
      send("done", { reply, actions, thread_id: thread, message_id: messageId });
    } catch (err) {
      if (!(err instanceof Anthropic.APIError)) throw err;
      console.error(`Claude API error ${err.status}:`, err.message);
      send("error", { message: modelErrorMessage(err) });
    }
  });
}

// The v1 body: the client sends the whole conversation and nothing is stored.
async function handleLegacy(db: SupabaseClient, user: User, history: LegacyMessage[]): Promise<Response> {
  const { caller, family } = await identify(user, null);
  const refusal = await gate(family);
  if (refusal) return json({ reply: refusal, actions: [] });
  const snapshot = await loadSnapshot(db, family);

  const actions: Action[] = [];
  const stats = newStats();
  try {
    const reply = await converse({
      ctx: { db, family, caller, snapshot },
      mode: "chat",
      messages: history.map((m) => ({ role: m.role, content: m.text })),
      actions,
      stats,
    });
    return json({ reply, actions });
  } catch (err) {
    if (err instanceof Anthropic.RateLimitError) return json({ reply: REPLY.busy, actions });
    if (!(err instanceof Anthropic.APIError)) throw err;
    console.error(`Claude API error ${err.status}:`, err.message);
    return json({ error: "assistant unavailable" }, 502);
  } finally {
    await recordUsage(family, user.id, null, "chat", stats);
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return preflight();
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const token = bearerToken(req);
  if (!token) return json({ error: "sign in required" }, 401);

  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid JSON" }, 400);
  }
  const parsed = parseRequest(body);
  if (parsed.kind === "invalid") return json({ error: parsed.error }, 400);

  // Queries run as the caller, so RLS scopes everything to their family.
  const db = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: `Bearer ${token}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: { user } } = await db.auth.getUser(token);
  if (!user) return json({ error: "sign in required" }, 401);

  try {
    return parsed.kind === "legacy" ? await handleLegacy(db, user, parsed.history) : await handleV2(db, user, parsed);
  } catch (err) {
    if (err instanceof HttpError) return json({ error: err.message }, err.status);
    console.error("assistant failed:", err);
    return json({ error: "something went wrong" }, 500);
  }
});
