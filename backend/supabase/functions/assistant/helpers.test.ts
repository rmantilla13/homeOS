// Unit tests for the assistant's pure helpers: `deno test assistant/`.

import { assert, assertEquals, assertMatch, assertThrows } from "jsr:@std/assert@1";
import type Anthropic from "npm:@anthropic-ai/sdk@^0.131.0";
import {
  echoContent,
  findMember,
  historyToMessages,
  isParent,
  localDate,
  localToUtc,
  matchMemories,
  MAX_MESSAGE_CHARS,
  parseLocalDateTime,
  parseRequest,
  pickList,
  ReplyBuilder,
  runnableToolUses,
  sseEvent,
  threadTitle,
  tzOffsetMs,
  usageOf,
  utcDayStart,
  validateToolInput,
  whoIsAsking,
} from "./helpers.ts";

const THREAD = "0b6f3a52-1c1e-4d7e-9b1a-2f0c8e9d7a61";

// ───────────── parseRequest ─────────────

Deno.test("parseRequest: v2 with defaults", () => {
  assertEquals(parseRequest({ message: "  What's for dinner?  " }), {
    kind: "v2", message: "What's for dinner?", threadId: null, mode: "chat", stream: false, familyId: null,
  });
});

Deno.test("parseRequest: v2 with every field", () => {
  assertEquals(parseRequest({ message: "hi", thread_id: THREAD, mode: "quick", stream: true, family_id: THREAD }), {
    kind: "v2", message: "hi", threadId: THREAD, mode: "quick", stream: true, familyId: THREAD,
  });
  // null means "not given"
  assertEquals(parseRequest({ message: "hi", thread_id: null, mode: null, stream: null }), {
    kind: "v2", message: "hi", threadId: null, mode: "chat", stream: false, familyId: null,
  });
});

Deno.test("parseRequest: v2 rejects bad fields", () => {
  const bad = [
    {},
    { message: "" },
    { message: "   " },
    { message: 42 },
    { message: "x".repeat(MAX_MESSAGE_CHARS + 1) },
    { message: "hi", thread_id: "nope" },
    { message: "hi", mode: "loud" },
    { message: "hi", stream: "yes" },
    { message: "hi", family_id: 7 },
  ];
  for (const body of bad) assertEquals(parseRequest(body).kind, "invalid", JSON.stringify(body).slice(0, 80));
  for (const body of [null, "hi", [1, 2], 3]) assertEquals(parseRequest(body).kind, "invalid");
});

Deno.test("parseRequest: message wins over legacy messages", () => {
  const r = parseRequest({ message: "new", messages: [{ role: "user", text: "old" }] });
  assertEquals(r.kind, "v2");
});

Deno.test("parseRequest: legacy body behaves like v1", () => {
  const r = parseRequest({
    messages: [
      { role: "assistant", text: "Hi! How can I help?" },
      { role: "user", text: "What's on today?" },
      { role: "assistant", text: "Soccer at 4." },
      { role: "system", text: "ignored" },
      { role: "user", text: "  " },
      { role: "user", text: "And tomorrow?" },
    ],
  });
  assertEquals(r, {
    kind: "legacy",
    history: [
      { role: "user", text: "What's on today?" },
      { role: "assistant", text: "Soccer at 4." },
      { role: "user", text: "And tomorrow?" },
    ],
  });
});

Deno.test("parseRequest: legacy keeps the last 20 turns", () => {
  const messages = Array.from({ length: 30 }, (_, i) => ({ role: i % 2 ? "assistant" : "user", text: `m${i}` }));
  messages.push({ role: "user", text: "last" });
  const r = parseRequest({ messages });
  assert(r.kind === "legacy");
  // The last 20 start with an assistant turn, which is dropped (as in v1).
  assertEquals(r.history.length, 19);
  assertEquals(r.history[0], { role: "user", text: "m12" });
  assertEquals(r.history.at(-1)?.text, "last");
});

Deno.test("parseRequest: legacy must end with a user message", () => {
  assertEquals(parseRequest({ messages: [{ role: "user", text: "a" }, { role: "assistant", text: "b" }] }), {
    kind: "invalid", error: "messages must end with a user message",
  });
  assertEquals(parseRequest({ messages: [] }).kind, "invalid");
  assertEquals(parseRequest({ messages: "hi" }).kind, "invalid");
});

// ───────────── historyToMessages ─────────────

Deno.test("historyToMessages: starts with a user turn and skips empty rows", () => {
  assertEquals(
    historyToMessages([
      { role: "assistant", content: "orphan reply" },
      { role: "user", content: "a" },
      { role: "assistant", content: "" },
      { role: "user", content: "b" },
      { role: "assistant", content: "c" },
      { role: "tool", content: "x" },
    ]),
    [{ role: "user", content: "a" }, { role: "user", content: "b" }, { role: "assistant", content: "c" }],
  );
  assertEquals(historyToMessages([]), []);
});

// ───────────── SSE ─────────────

Deno.test("sseEvent: one event, one data line", () => {
  assertEquals(sseEvent("delta", { text: "Hi\nthere" }), 'event: delta\ndata: {"text":"Hi\\nthere"}\n\n');
  const frame = sseEvent("done", { reply: "a\r\nb", actions: [], thread_id: THREAD, message_id: 7 });
  assertEquals(frame.split("\n").length, 4); // event, data, blank, ""
  assertEquals(JSON.parse(frame.split("\n")[1].slice("data: ".length)).message_id, 7);
});

// ───────────── threadTitle ─────────────

Deno.test("threadTitle: short messages are kept, whitespace collapsed", () => {
  assertEquals(threadTitle("  What's   for\ndinner? "), "What's for dinner?");
  assertEquals(threadTitle(""), "New chat");
  assertEquals(threadTitle("x".repeat(48)), "x".repeat(48));
});

Deno.test("threadTitle: long messages are cut near 48 characters at a word", () => {
  const t = threadTitle("Can you add soccer practice for Leo every Tuesday at four thirty please");
  assertEquals(t, "Can you add soccer practice for Leo every…");
  assert(Array.from(t).length <= 49);
  const word = threadTitle("Supercalifragilisticexpialidocious".repeat(3));
  assertEquals(Array.from(word).length, 49); // no space to cut at: 48 chars + ellipsis
});

Deno.test("threadTitle: never splits an emoji", () => {
  const t = threadTitle("🍕".repeat(60));
  assertEquals(t, "🍕".repeat(48) + "…");
});

// ───────────── Who's asking ─────────────

Deno.test("whoIsAsking: person and device", () => {
  assertEquals(
    whoIsAsking({ kind: "person", userId: "u", memberId: "m", name: "Sam", role: "parent" }),
    "You're talking with Sam (parent).",
  );
  assertEquals(
    whoIsAsking({ kind: "device", userId: "d" }),
    "You're talking with the family screen in the kitchen; could be anyone in the family.",
  );
  assert(isParent({ kind: "person", userId: "u", memberId: "m", name: "Sam", role: "parent" }));
  assert(!isParent({ kind: "person", userId: "u", memberId: "m", name: "Leo", role: "child" }));
  assert(!isParent({ kind: "device", userId: "d" }));
});

// ───────────── Time zones ─────────────

Deno.test("localToUtc: fixed and fractional offsets", () => {
  assertEquals(localToUtc("2026-10-07T18:30", "UTC"), "2026-10-07T18:30:00.000Z");
  assertEquals(localToUtc("2026-01-15T09:30", "Asia/Kolkata"), "2026-01-15T04:00:00.000Z");
  assertEquals(localToUtc("2026-07-01T09:00", "Europe/London"), "2026-07-01T08:00:00.000Z");
  assertEquals(localToUtc("2026-01-15T09:00", "Australia/Sydney"), "2026-01-14T22:00:00.000Z");
});

Deno.test("localToUtc: DST transitions in New York", () => {
  // Spring forward on 2026-03-08 at 02:00 EST.
  assertEquals(localToUtc("2026-03-08T01:30", "America/New_York"), "2026-03-08T06:30:00.000Z");
  assertEquals(localToUtc("2026-03-08T03:30", "America/New_York"), "2026-03-08T07:30:00.000Z");
  assertEquals(localToUtc("2026-03-08T12:00", "America/New_York"), "2026-03-08T16:00:00.000Z");
  // Fall back on 2026-11-01.
  assertEquals(localToUtc("2026-11-01T12:00", "America/New_York"), "2026-11-01T17:00:00.000Z");
  assertEquals(localToUtc("2026-10-31T23:00", "America/New_York"), "2026-11-01T03:00:00.000Z");
});

Deno.test("localToUtc: date-only and seconds forms; rejects junk", () => {
  assertEquals(localToUtc("2026-10-07", "UTC"), "2026-10-07T00:00:00.000Z");
  assertEquals(localToUtc("2026-10-07T08:15:59", "UTC"), "2026-10-07T08:15:00.000Z");
  assertThrows(() => localToUtc("tomorrow at 5", "UTC"), RangeError);
});

Deno.test("tzOffsetMs and localDate", () => {
  const t = Date.UTC(2026, 6, 1, 12, 0, 0, 500);
  assertEquals(tzOffsetMs(t, "America/Los_Angeles"), -7 * 3_600_000);
  assertEquals(tzOffsetMs(t, "UTC"), 0);
  // 02:00 UTC on Oct 7 is still Oct 6 in Los Angeles.
  assertEquals(localDate(Date.UTC(2026, 9, 7, 2, 0), "America/Los_Angeles"), "2026-10-06");
  assertEquals(localDate(Date.UTC(2026, 9, 7, 2, 0), "Asia/Tokyo"), "2026-10-07");
});

Deno.test("utcDayStart", () => {
  assertEquals(utcDayStart(Date.UTC(2026, 9, 6, 23, 59, 59)), "2026-10-06T00:00:00.000Z");
  assertEquals(utcDayStart(Date.UTC(2026, 9, 7, 0, 0, 0)), "2026-10-07T00:00:00.000Z");
});

Deno.test("parseLocalDateTime: calendar validity", () => {
  assertEquals(parseLocalDateTime("2028-02-29T10:05"), { y: 2028, mo: 2, d: 29, h: 10, mi: 5 });
  for (const s of ["2026-02-29", "2026-13-01", "2026-04-31T10:00", "2026-01-01T24:00", "2026-01-01T10:60", "26-01-01"]) {
    assertEquals(parseLocalDateTime(s), null, s);
  }
});

// ───────────── Tool input validation ─────────────

const validEvent = {
  title: " Soccer ", start: "2026-10-08T16:30", end: "2026-10-08T17:30", all_day: false,
  member_names: ["Leo", "leo", "Mia"], location: null,
};

Deno.test("validateToolInput: add_event normalizes", () => {
  const r = validateToolInput("add_event", validEvent);
  assert(r.ok);
  assertEquals(r.value, {
    name: "add_event", title: "Soccer", start: "2026-10-08T16:30", end: "2026-10-08T17:30", all_day: false,
    member_names: ["Leo", "Mia"], location: null,
  });
  const clamped = validateToolInput("add_event", { ...validEvent, start: "2026-10-08T16:30:00", end: "2026-10-08T15:00" });
  assert(clamped.ok && clamped.value.name === "add_event");
  if (clamped.ok && clamped.value.name === "add_event") assertEquals(clamped.value.end, "2026-10-08T16:30");
});

Deno.test("validateToolInput: add_event rejects bad input", () => {
  const cases: Record<string, unknown>[] = [
    { ...validEvent, title: "" },
    { ...validEvent, start: "tomorrow" },
    { ...validEvent, end: "2026-02-30T10:00" },
    { ...validEvent, all_day: "no" },
    { ...validEvent, member_names: "Leo" },
    { ...validEvent, member_names: [""] },
    { ...validEvent, location: 5 },
    { ...validEvent, title: "x".repeat(201) },
    { ...validEvent, extra: 1 },
  ];
  for (const c of cases) {
    const r = validateToolInput("add_event", c);
    assert(!r.ok, JSON.stringify(c));
    assertMatch(r.error, /^Invalid add_event input: /);
  }
  assertEquals(validateToolInput("add_event", "nope").ok, false);
  assertEquals(validateToolInput("add_event", null).ok, false);
});

Deno.test("validateToolInput: the other v1 tools", () => {
  assertEquals(validateToolInput("add_list_item", { list_name: "Groceries", text: " milk " }), {
    ok: true, value: { name: "add_list_item", list_name: "Groceries", text: "milk" },
  });
  assertEquals(validateToolInput("add_list_item", { list_name: "Groceries" }).ok, false);

  assertEquals(validateToolInput("add_chore", { title: "Feed cat", assignee_name: null, points: 5, repeats_daily: true }), {
    ok: true, value: { name: "add_chore", title: "Feed cat", assignee_name: null, points: 5, repeats_daily: true },
  });
  for (const points of [-1, 2.5, "5", 10_001]) {
    assertEquals(validateToolInput("add_chore", { title: "x", assignee_name: null, points, repeats_daily: false }).ok, false);
  }

  assertEquals(validateToolInput("set_meal", { date: "2026-10-08", meal: "dinner", title: "Tacos" }), {
    ok: true, value: { name: "set_meal", date: "2026-10-08", meal: "dinner", title: "Tacos" },
  });
  assertEquals(validateToolInput("set_meal", { date: "2026-10-08", meal: "brunch", title: "Eggs" }).ok, false);
  assertEquals(validateToolInput("set_meal", { date: "2026-10-08T10:00", meal: "lunch", title: "Eggs" }).ok, false);

  assertEquals(validateToolInput("remember", { fact: "Leo is allergic to peanuts" }), {
    ok: true, value: { name: "remember", fact: "Leo is allergic to peanuts" },
  });
  assertEquals(validateToolInput("remember", { fact: "x".repeat(501) }).ok, false);
});

Deno.test("validateToolInput: forget and unknown tools", () => {
  assertEquals(validateToolInput("forget", { fact_contains: " peanuts " }), {
    ok: true, value: { name: "forget", fact_contains: "peanuts" },
  });
  const short = validateToolInput("forget", { fact_contains: "a" });
  assert(!short.ok);
  assertMatch(short.error, /at least 3 characters/);
  assertEquals(validateToolInput("award_points", { points: 100 }), { ok: false, error: "Unknown tool award_points." });
});

// ───────────── Lookups ─────────────

Deno.test("findMember and pickList", () => {
  const members = [{ id: "1", display_name: "Leo" }, { id: "2", display_name: "Mia Rose" }];
  assertEquals(findMember(members, " mia rose ")?.id, "2");
  assertEquals(findMember(members, "Mia"), undefined);
  assertEquals(findMember(members, null), undefined);

  const lists = [{ id: "a", name: "Groceries" }, { id: "b", name: "Packing" }, { id: "c", name: "Hardware store" }];
  assertEquals(pickList(lists, "groceries"), { ok: true, value: lists[0] });
  assertEquals(pickList(lists, "grocery list").ok, false);
  assertEquals(pickList(lists, "hardware"), { ok: true, value: lists[2] });
  const missing = pickList(lists, "Costco");
  assert(!missing.ok);
  assertMatch(missing.error, /Groceries, Packing, Hardware store/);
  assertEquals(pickList([lists[1]], "Groceries"), { ok: true, value: lists[1] }); // the only list
  assertEquals(pickList([], "Groceries"), { ok: false, error: "The family has no lists yet." });
});

Deno.test("matchMemories: case and spacing insensitive", () => {
  const rows = [
    { id: "1", content: "Leo is allergic to  PEANUTS" },
    { id: "2", content: "Soccer carpool is with the Parks" },
  ];
  assertEquals(matchMemories(rows, "allergic to peanuts").map((r) => r.id), ["1"]);
  assertEquals(matchMemories(rows, "carpool").map((r) => r.id), ["2"]);
  assertEquals(matchMemories(rows, "  "), []);
  assertEquals(matchMemories(rows, "swim"), []);
});

// ───────────── ReplyBuilder ─────────────

Deno.test("ReplyBuilder: forwards deltas and separates tool rounds", () => {
  const r = new ReplyBuilder();
  const out: string[] = [];
  const push = (s: string) => out.push(r.push(s));
  r.paragraph(); // nothing yet: no separator
  push("Adding ");
  push("it now.");
  r.paragraph();
  push("Done");
  push(" — milk is on the list.");
  assertEquals(out, ["Adding ", "it now.", "\n\nDone", " — milk is on the list."]);
  assertEquals(r.text, "Adding it now.\n\nDone — milk is on the list.");
  assertEquals(r.text, out.join(""));
  assertEquals(r.push(""), "");
});

Deno.test("ReplyBuilder: no extra separator when whitespace is already there", () => {
  const r = new ReplyBuilder();
  r.push("One.\n");
  r.paragraph();
  assertEquals(r.push("Two."), "Two.");
  assertEquals(r.text, "One.\nTwo.");
});

// ───────────── Model content (fallbacks) ─────────────

type Block = Anthropic.Beta.BetaContentBlock;
const text = (t: string) => ({ type: "text", text: t, citations: null }) as Block;
const thinking = () => ({ type: "thinking", thinking: "", signature: "sig" }) as Block;
const toolUse = (id: string) => ({ type: "tool_use", id, name: "add_list_item", input: {}, caller: { type: "direct" } }) as unknown as Block;
const fallback = () =>
  ({ type: "fallback", from: { model: "claude-opus-5-5" }, to: { model: "claude-opus-5" }, trigger: { type: "refusal", category: null } }) as unknown as Block;

Deno.test("echoContent / runnableToolUses: no fallback passes everything", () => {
  const content = [thinking(), text("Adding."), toolUse("t1"), toolUse("t2")];
  assertEquals(echoContent(content), content);
  assertEquals(runnableToolUses(content).map((b) => b.id), ["t1", "t2"]);
});

Deno.test("echoContent / runnableToolUses: mid-output fallback", () => {
  const content = [thinking(), text("Partial "), toolUse("declined"), fallback(), thinking(), text("rest."), toolUse("t2")];
  const echoed = echoContent(content);
  assertEquals(echoed.map((b) => b.type), ["text", "fallback", "thinking", "text", "tool_use"]);
  assertEquals(runnableToolUses(content).map((b) => b.id), ["t2"]);
});

// ───────────── Usage ─────────────

const baseUsage = {
  cache_creation: null, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, fallback_credit: null,
  inference_geo: null, input_tokens: 0, iterations: null, output_tokens: 0, output_tokens_details: null,
  server_tool_use: null, service_tier: null, speed: null,
} satisfies Anthropic.Beta.BetaUsage;

Deno.test("usageOf: top-level usage without iterations", () => {
  assertEquals(
    usageOf({ ...baseUsage, input_tokens: 120, cache_creation_input_tokens: 30, cache_read_input_tokens: 900, output_tokens: 40 }),
    { input: 150, output: 40, cacheRead: 900 },
  );
});

Deno.test("usageOf: sums every attempt after a fallback", () => {
  const it = (type: string, input: number, output: number, cacheRead = 0) => ({
    type, input_tokens: input, output_tokens: output, cache_read_input_tokens: cacheRead,
    cache_creation_input_tokens: 0, cache_creation: null, model: "claude-opus-5-5",
  });
  const usage = {
    ...baseUsage,
    input_tokens: 500, output_tokens: 60, // the serving attempt only
    iterations: [it("message", 400, 25, 100), it("compaction", 9999, 9999), it("fallback_message", 500, 60)],
  } as unknown as Anthropic.Beta.BetaUsage;
  assertEquals(usageOf(usage), { input: 900, output: 85, cacheRead: 100 });
});
