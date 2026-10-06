// assistant: the family AI on the wall display and in the iOS app.
//
// POST { messages: [{ role: "user" | "assistant", text: string }, ...] }
//   -> { reply: string, actions: [{ type, summary }] }
//
// Each request is grounded in the family's live data (calendar, chores,
// points, rewards, meals, lists) plus the family memory. Data is read with
// the caller's own JWT, so row-level security limits the assistant to the
// caller's family. Claude can add events, list items, chores and meals and
// save memories through tools. Points, approvals and rewards stay out of
// reach on purpose: a child at the screen shouldn't be able to award points.
//
// Secrets: ANTHROPIC_API_KEY (set with `supabase secrets set`).

import Anthropic from "npm:@anthropic-ai/sdk@^0.131.0";
import { createClient, type SupabaseClient } from "jsr:@supabase/supabase-js@2";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

const MODEL = "claude-opus-5-5";
const MAX_TOOL_ROUNDS = 6;
const MAX_HISTORY = 20;

const anthropic = new Anthropic(); // reads ANTHROPIC_API_KEY

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json" } });

// ───────────────────────────── Prompt ─────────────────────────────

// Stable instructions first so they can be cached; the family snapshot
// (which changes every request) goes in a second system block after it.
const INSTRUCTIONS = `You are homeOS, the assistant built into a family's shared touchscreen and phone app.

Who you're talking to: usually whoever is standing at the family screen in the kitchen — a parent or a child — or a parent on their phone. You don't know which person it is unless they say so. Keep answers friendly, short and easy to read from a few feet away: one to three sentences, or a short list. No markdown headings or tables.

What you know: the family snapshot below is live data from their calendar, chores, points, rewards, meal plan, lists and family memory. Answer from it. If something isn't in the snapshot, say you don't know rather than guessing. Times in the snapshot are already in the family's local time zone.

What you can do: add calendar events, add items to a list, add chores, set a planned meal, and remember facts the family tells you. Before adding something that's ambiguous (which person, which day, what time), ask one short clarifying question. After you use a tool, confirm what you did in one sentence.

What you can't do: award or remove points, approve chores, or redeem rewards — those belong to parents in the iPhone app. If asked, say so kindly.

When someone shares a lasting fact about the family (allergies, routines, preferences, who carpools with whom), save it with the remember tool so you know it next time.

Keep it kid-safe.`;

// ───────────────────────────── Tools ─────────────────────────────

// strict: true keeps arguments schema-valid; schemas set additionalProperties: false.
const tools: Anthropic.Beta.BetaTool[] = [
  {
    name: "add_event",
    description:
      "Add an event to the family calendar. Use local date/time in the family's time zone (YYYY-MM-DDTHH:MM). For all-day events, pass the date at 00:00 and all_day true.",
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
    description: "Add an item to one of the family's lists (for example the grocery list).",
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
];

// ───────────────────────────── Family data ─────────────────────────────

type Row = Record<string, unknown>;

interface Family {
  id: string;
  name: string;
  timezone: string;
  members: Row[];
  lists: Row[];
}

// Local "YYYY-MM-DDTHH:MM" in `tz` → UTC ISO string.
function localToUtc(local: string, tz: string): string {
  const [date, time = "00:00"] = local.split("T");
  const [y, mo, d] = date.split("-").map(Number);
  const [h, mi] = time.split(":").map(Number);
  const guess = Date.UTC(y, mo - 1, d, h, mi);
  return new Date(guess - tzOffsetMs(guess, tz)).toISOString();
}

// Offset of `tz` from UTC at instant `utcMs`, in milliseconds.
function tzOffsetMs(utcMs: number, tz: string): number {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en-US", {
      timeZone: tz, hourCycle: "h23",
      year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", second: "2-digit",
    }).formatToParts(new Date(utcMs)).map((p) => [p.type, p.value]),
  );
  const asUtc = Date.UTC(+parts.year, +parts.month - 1, +parts.day, +parts.hour, +parts.minute, +parts.second);
  return asUtc - utcMs;
}

function fmtLocal(iso: string, tz: string): string {
  return new Intl.DateTimeFormat("en-US", {
    timeZone: tz, weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit",
  }).format(new Date(iso));
}

function localDate(ms: number, tz: string): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: tz }).format(new Date(ms)); // YYYY-MM-DD
}

async function loadFamily(db: SupabaseClient): Promise<{ family: Family; snapshot: string }> {
  const { data: fam, error } = await db.from("families").select("id, name, timezone").limit(1).single();
  if (error || !fam) throw new Error("no family for this account");
  const tz = fam.timezone || "UTC";
  const now = Date.now();
  const today = localDate(now, tz);
  const in14 = new Date(now + 14 * 86_400_000).toISOString();
  const weekAhead = localDate(now + 7 * 86_400_000, tz);

  const [members, points, events, tasks, done, rewards, meals, lists, memories] = await Promise.all([
    db.from("members").select("id, display_name, role").order("sort_order"),
    db.from("member_points").select("member_id, balance"),
    db.from("events").select("title, starts_at, ends_at, all_day, location, event_members(member_id)")
      .gte("ends_at", new Date(now - 86_400_000).toISOString()).lt("starts_at", in14).order("starts_at").limit(80),
    db.from("tasks").select("id, title, assignee_id, points, rrule, requires_approval").eq("archived", false),
    db.from("task_completions").select("task_id, member_id, status").eq("for_date", today),
    db.from("rewards").select("title, cost").eq("active", true).order("cost"),
    db.from("meal_plans").select("date, meal, title").gte("date", today).lte("date", weekAhead).order("date"),
    db.from("lists").select("id, name, list_items(text, done)").order("sort_order"),
    db.from("family_memories").select("content").order("created_at").limit(100),
  ]);

  const memberRows = (members.data ?? []) as Row[];
  const nameOf = (id: unknown) => memberRows.find((m) => m.id === id)?.display_name ?? "someone";
  const balance = new Map((points.data ?? []).map((p: Row) => [p.member_id, p.balance]));
  const doneMap = new Map((done.data ?? []).map((c: Row) => [`${c.task_id}|${c.member_id}`, c.status]));

  const lines: string[] = [];
  lines.push(`Family: ${fam.name}. Time zone: ${tz}.`);
  lines.push(`Now: ${new Intl.DateTimeFormat("en-US", { timeZone: tz, dateStyle: "full", timeStyle: "short" }).format(new Date(now))} (today is ${today}).`);

  lines.push("\nMembers:");
  for (const m of memberRows) {
    const pts = m.role === "child" ? `, ${balance.get(m.id) ?? 0} points` : "";
    lines.push(`- ${m.display_name} (${m.role}${pts})`);
  }

  lines.push("\nCalendar (next 14 days):");
  for (const e of (events.data ?? []) as Row[]) {
    const who = ((e.event_members as Row[]) ?? []).map((em) => nameOf(em.member_id)).join(", ") || "whole family";
    const when = e.all_day ? `${fmtLocal(String(e.starts_at), tz).split(",").slice(0, 2).join(",")} (all day)` : fmtLocal(String(e.starts_at), tz);
    lines.push(`- ${when}: ${e.title} — ${who}${e.location ? ` @ ${e.location}` : ""}`);
  }
  if (!events.data?.length) lines.push("- nothing scheduled");

  lines.push("\nChores (today's status; recurrence in RRULE form):");
  for (const t of (tasks.data ?? []) as Row[]) {
    const status = doneMap.get(`${t.id}|${t.assignee_id}`) ?? "not done";
    lines.push(`- ${t.title} — ${t.assignee_id ? nameOf(t.assignee_id) : "anyone"}, ${t.points} pts, ${t.rrule ?? "one-time"}: ${status}`);
  }

  lines.push("\nRewards: " + ((rewards.data ?? []) as Row[]).map((r) => `${r.title} (${r.cost} pts)`).join("; "));
  lines.push("\nMeals planned: " + (((meals.data ?? []) as Row[]).map((m) => `${m.date} ${m.meal}: ${m.title}`).join("; ") || "none"));

  lines.push("\nLists:");
  for (const l of (lists.data ?? []) as Row[]) {
    const open = ((l.list_items as Row[]) ?? []).filter((i) => !i.done).map((i) => i.text);
    lines.push(`- ${l.name}: ${open.length ? open.join(", ") : "(empty)"}`);
  }

  lines.push("\nFamily memory:");
  const mem = (memories.data ?? []) as Row[];
  lines.push(mem.length ? mem.map((m) => `- ${m.content}`).join("\n") : "- (nothing saved yet)");

  return {
    family: { id: fam.id, name: fam.name, timezone: tz, members: memberRows, lists: (lists.data ?? []) as Row[] },
    snapshot: lines.join("\n"),
  };
}

// ───────────────────────────── Tool execution ─────────────────────────────

interface Action { type: string; summary: string }

function findMember(family: Family, name: string | null): Row | undefined {
  if (!name) return undefined;
  const n = name.trim().toLowerCase();
  return family.members.find((m) => String(m.display_name).toLowerCase() === n);
}

async function runTool(
  db: SupabaseClient, family: Family, name: string, input: Record<string, unknown>, actions: Action[],
): Promise<string> {
  switch (name) {
    case "add_event": {
      const names = (input.member_names as string[]) ?? [];
      const ids = names.map((n) => findMember(family, n)?.id).filter(Boolean);
      if (ids.length !== names.length) {
        return `Unknown family member in ${JSON.stringify(names)}. Members are: ${family.members.map((m) => m.display_name).join(", ")}.`;
      }
      const startsAt = localToUtc(String(input.start), family.timezone);
      let endsAt = localToUtc(String(input.end), family.timezone);
      if (endsAt < startsAt) endsAt = startsAt;
      const { data, error } = await db.from("events").insert({
        family_id: family.id, title: input.title, starts_at: startsAt, ends_at: endsAt,
        all_day: input.all_day, location: input.location ?? null,
      }).select("id").single();
      if (error) return `Couldn't add the event: ${error.message}`;
      if (ids.length) {
        await db.from("event_members").insert(ids.map((id) => ({ event_id: data.id, member_id: id })));
      }
      actions.push({ type: "add_event", summary: `Added “${input.title}” on ${fmtLocal(startsAt, family.timezone)}` });
      return "Event added.";
    }
    case "add_list_item": {
      const wanted = String(input.list_name).toLowerCase();
      const list = family.lists.find((l) => String(l.name).toLowerCase() === wanted) ?? family.lists[0];
      if (!list) return "The family has no lists yet.";
      const { error } = await db.from("list_items").insert({ list_id: list.id, text: input.text });
      if (error) return `Couldn't add the item: ${error.message}`;
      actions.push({ type: "add_list_item", summary: `Added ${input.text} to ${list.name}` });
      return `Added to ${list.name}.`;
    }
    case "add_chore": {
      const assignee = findMember(family, input.assignee_name as string | null);
      if (input.assignee_name && !assignee) return `No family member named ${input.assignee_name}.`;
      const { error } = await db.from("tasks").insert({
        family_id: family.id, title: input.title, assignee_id: assignee?.id ?? null,
        points: Math.max(0, Number(input.points) || 0), rrule: input.repeats_daily ? "FREQ=DAILY" : null,
      });
      if (error) return `Couldn't add the chore: ${error.message}`;
      actions.push({ type: "add_chore", summary: `Added chore “${input.title}”${assignee ? ` for ${assignee.display_name}` : ""}` });
      return "Chore added.";
    }
    case "set_meal": {
      const { error } = await db.from("meal_plans").upsert(
        { family_id: family.id, date: input.date, meal: input.meal, title: input.title },
        { onConflict: "family_id,date,meal" },
      );
      if (error) return `Couldn't set the meal: ${error.message}`;
      actions.push({ type: "set_meal", summary: `${input.meal} on ${input.date}: ${input.title}` });
      return "Meal saved.";
    }
    case "remember": {
      const { error } = await db.from("family_memories").insert({ family_id: family.id, content: String(input.fact).slice(0, 500) });
      if (error) return `Couldn't save that: ${error.message}`;
      actions.push({ type: "remember", summary: `Remembered: ${input.fact}` });
      return "Saved to family memory.";
    }
    default:
      return `Unknown tool ${name}.`;
  }
}

// ───────────────────────────── Handler ─────────────────────────────

Deno.serve(async (req) => {
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  const auth = req.headers.get("Authorization");
  if (!auth) return json({ error: "sign in required" }, 401);
  // Queries run as the caller, so RLS scopes everything to their family.
  const db = createClient(SUPABASE_URL, ANON_KEY, {
    global: { headers: { Authorization: auth } },
    auth: { persistSession: false },
  });

  let body: { messages?: { role: string; text: string }[] };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid JSON" }, 400);
  }
  const history = (body.messages ?? [])
    .filter((m) => (m.role === "user" || m.role === "assistant") && typeof m.text === "string" && m.text.trim())
    .slice(-MAX_HISTORY);
  while (history.length && history[0].role !== "user") history.shift();
  if (!history.length || history[history.length - 1].role !== "user") {
    return json({ error: "messages must end with a user message" }, 400);
  }

  let family: Family, snapshot: string;
  try {
    ({ family, snapshot } = await loadFamily(db));
  } catch (e) {
    return json({ error: (e as Error).message }, 403);
  }

  const messages: Anthropic.Beta.BetaMessageParam[] = history.map((m) => ({
    role: m.role as "user" | "assistant",
    content: m.text,
  }));
  const actions: Action[] = [];

  try {
    for (let round = 0; round < MAX_TOOL_ROUNDS; round++) {
      const response = await anthropic.beta.messages.create({
        model: MODEL,
        max_tokens: 16000,
        // Conversational and latency-sensitive: low effort keeps replies quick.
        output_config: { effort: "low" },
        // Re-run on Anthropic's recommended model if a safety classifier
        // declines a benign family request, instead of failing the turn.
        betas: ["server-side-fallback-2026-07-01"],
        fallbacks: "default",
        system: [
          { type: "text", text: INSTRUCTIONS, cache_control: { type: "ephemeral" } },
          { type: "text", text: `Family snapshot:\n${snapshot}` },
        ],
        tools,
        messages,
      });

      if (response.stop_reason === "refusal") {
        return json({ reply: "Sorry, I can't help with that one.", actions });
      }

      if (response.stop_reason === "tool_use") {
        messages.push({ role: "assistant", content: response.content });
        const results: Anthropic.Beta.BetaToolResultBlockParam[] = [];
        for (const block of response.content) {
          if (block.type !== "tool_use") continue;
          const out = await runTool(db, family, block.name, block.input as Record<string, unknown>, actions);
          results.push({ type: "tool_result", tool_use_id: block.id, content: out });
        }
        messages.push({ role: "user", content: results });
        continue;
      }

      if (response.stop_reason === "pause_turn") {
        messages.push({ role: "assistant", content: response.content });
        continue;
      }

      const reply = response.content
        .filter((b): b is Anthropic.Beta.BetaTextBlock => b.type === "text")
        .map((b) => b.text)
        .join("\n")
        .trim();
      return json({ reply: reply || "Done!", actions });
    }
    return json({ reply: "That took more steps than I can do at once. Could you break it into smaller requests?", actions });
  } catch (error) {
    if (error instanceof Anthropic.RateLimitError) {
      return json({ reply: "I'm a bit busy right now. Try again in a moment.", actions }, 200);
    }
    if (error instanceof Anthropic.APIError) {
      console.error(`Claude API error ${error.status}:`, error.message);
      return json({ error: "assistant unavailable" }, 502);
    }
    throw error;
  }
});
