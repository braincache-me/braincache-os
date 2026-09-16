import assert from "node:assert/strict";
import fs from "node:fs/promises";
import test from "node:test";
import { buildDataset } from "../server/activityParser.js";
import { getProviderConfig } from "../server/aiProvider.js";
import {
  NO_KEY_MESSAGE,
  analyzeActivityWithAgentStream,
  assistantTurn,
  buildGoals,
  buildToolDefinitions,
  chatWithAgentStream,
  historyMessages,
  parseGoalPlan,
  parseToolArguments,
  toolResultMessage
} from "../server/agentAnalyzer.js";

// --- helpers ----------------------------------------------------------------

// Replies are consumed in order; each entry is the `choices[0].message` body.
function mockChat(messages) {
  const requests = [];
  const original = globalThis.fetch;
  const queue = [...messages];
  globalThis.fetch = async (url, init = {}) => {
    const body = JSON.parse(init.body);
    requests.push({ url: String(url), body });
    const message = queue.shift() ?? { role: "assistant", content: "(no more scripted replies)" };
    return { ok: true, status: 200, json: async () => ({ model: body.model, choices: [{ message }] }) };
  };
  return { requests, restore: () => { globalThis.fetch = original; } };
}

function toolCall(id, name, args) {
  return { id, type: "function", function: { name, arguments: JSON.stringify(args) } };
}

const ANALYSIS_JSON = JSON.stringify({
  overview: "Searched for jobs and read API docs.",
  performance: { summary: "Fine", strengths: ["focused"], bottlenecks: [], recommendations: [] },
  goals: [{ id: "goal-1", title: "Find a new role", summary: "", taskIds: ["task-1"] }],
  tasks: [{
    id: "task-1",
    title: "Search LinkedIn job listings",
    summary: "Opened LinkedIn and searched for jobs.",
    goalId: "goal-1",
    confidence: 0.8,
    attempts: 1,
    outcome: "completed",
    eventIds: ["e4", "e5"],
    steps: [{ label: "Opened LinkedIn Jobs", evidenceEventId: "e4", appName: "Google Chrome", timestamp: "2026-06-04T11:52:00.000Z" }]
  }]
});

const GOAL_PLAN_JSON = JSON.stringify({
  goals: [{ id: "g-hire", title: "Land a new role", summary: "Job search across LinkedIn and docs.", taskIds: ["task-1"] }]
});

async function loadEvents() {
  const content = await fs.readFile(new URL("./fixtures/sample.jsonl", import.meta.url), "utf8");
  const dataset = buildDataset([{ name: "2026-06-04.jsonl", content }]);
  return dataset;
}

function collect() {
  const events = [];
  return { events, emit: async (event) => { events.push(event); } };
}

// --- the tool-call loop -----------------------------------------------------

test("answers every tool call with one tool message, then returns the final analysis", async () => {
  const { events, summary } = await loadEvents();
  const config = getProviderConfig({ NEBIUS_API_KEY: "nk-test" });
  const chat = mockChat([
    { role: "assistant", content: "", tool_calls: [toolCall("call_1", "list_events", { limit: 5 })] },
    { role: "assistant", content: "<think>compose</think>" + ANALYSIS_JSON },
    { role: "assistant", content: GOAL_PLAN_JSON }
  ]);
  const stream = collect();

  try {
    const analysis = await analyzeActivityWithAgentStream({ events, summary, activityRoot: null, config }, stream.emit);

    // Round 2 carries the assistant turn verbatim plus exactly one tool reply.
    const second = chat.requests[1].body.messages;
    const assistant = second.at(-2);
    const toolReply = second.at(-1);
    assert.equal(assistant.role, "assistant");
    assert.deepEqual(assistant.tool_calls, [toolCall("call_1", "list_events", { limit: 5 })]);
    assert.equal(toolReply.role, "tool");
    assert.equal(toolReply.tool_call_id, "call_1");
    assert.equal(JSON.parse(toolReply.content).total, events.length);
    assert.equal(second.filter((message) => message.role === "tool").length, 1);

    // Tools are the Chat Completions shape, not flat function schemas.
    assert.equal(chat.requests[0].body.tools[0].type, "function");
    assert.equal(chat.requests[0].body.tools[0].function.name, "list_events");
    assert.equal(chat.requests[0].body.tool_choice, "auto");

    // Analysis result: think tags stripped, reasoning grouping applied.
    assert.equal(analysis.source, "ai");
    assert.equal(analysis.tasks.length, 1);
    assert.equal(analysis.models.agent, config.models.agent);
    assert.equal(analysis.models.reasoning, config.models.reasoning);
    assert.equal(analysis.warning, undefined);
    assert.deepEqual(analysis.goals, [{ id: "g-hire", title: "Land a new role", summary: "Job search across LinkedIn and docs.", taskIds: ["task-1"] }]);

    // The goal pass runs on the reasoning model with no tools.
    const goalRequest = chat.requests[2].body;
    assert.equal(goalRequest.model, config.models.reasoning);
    assert.equal(goalRequest.tools, undefined);
    assert.match(JSON.stringify(goalRequest.messages), /task-1/);

    // Stream events the UI renders.
    const types = stream.events.map((event) => event.type);
    assert.ok(types.includes("tool_call"));
    assert.ok(types.includes("tool_output"));
    assert.ok(types.includes("output"));
    assert.equal(types.at(-1), "done");
    const call = stream.events.find((event) => event.type === "tool_call");
    assert.deepEqual([call.name, call.callId, call.arguments], ["list_events", "call_1", { limit: 5 }]);
  } finally {
    chat.restore();
  }
});

test("exhausted tool budget still answers every call and forces tool_choice none", async () => {
  const { events, summary } = await loadEvents();
  const config = getProviderConfig({ NEBIUS_API_KEY: "nk-test", AI_MAX_TOOL_CALLS: "1" });
  const chat = mockChat([
    {
      role: "assistant",
      content: "",
      tool_calls: [
        toolCall("call_1", "search_events", { query: "linkedin" }),
        toolCall("call_2", "search_events", { query: "docs" })
      ]
    },
    { role: "assistant", content: ANALYSIS_JSON },
    { role: "assistant", content: GOAL_PLAN_JSON }
  ]);
  const stream = collect();

  try {
    await analyzeActivityWithAgentStream({ events, summary, activityRoot: null, config }, stream.emit);

    const second = chat.requests[1].body;
    const toolReplies = second.messages.filter((message) => message.role === "tool");
    assert.deepEqual(toolReplies.map((message) => message.tool_call_id), ["call_1", "call_2"]);
    assert.match(JSON.parse(toolReplies[0].content).events[0].appName, /Chrome|Cursor/);
    assert.match(JSON.parse(toolReplies[1].content).error, /budget exhausted/i);
    assert.equal(second.tool_choice, "none");
  } finally {
    chat.restore();
  }
});

test("a model that keeps calling tools after tool_choice none is still answered, never left unmatched", async () => {
  const { events, summary } = await loadEvents();
  const config = getProviderConfig({ NEBIUS_API_KEY: "nk-test", AI_MAX_TOOL_ROUNDS: "1", AI_MAX_TOOL_CALLS: "9" });
  const chat = mockChat([
    { role: "assistant", content: "", tool_calls: [toolCall("call_1", "list_events", {})] },
    { role: "assistant", content: "", tool_calls: [toolCall("call_2", "list_events", {})] },
    { role: "assistant", content: ANALYSIS_JSON },
    { role: "assistant", content: GOAL_PLAN_JSON }
  ]);

  try {
    const analysis = await analyzeActivityWithAgentStream({ events, summary, activityRoot: null, config }, collect().emit);
    const third = chat.requests[2].body;
    assert.equal(third.tool_choice, "none");
    assert.deepEqual(
      third.messages.filter((message) => message.role === "tool").map((message) => message.tool_call_id),
      ["call_1", "call_2"]
    );
    assert.equal(analysis.source, "ai");
  } finally {
    chat.restore();
  }
});

// --- degraded paths ---------------------------------------------------------

test("without a key the heuristic analyzer runs and says which key is missing", async () => {
  const { events, summary } = await loadEvents();
  const stream = collect();
  const analysis = await analyzeActivityWithAgentStream(
    { events, summary, config: getProviderConfig({}) },
    stream.emit
  );

  assert.equal(analysis.source, "heuristic");
  assert.equal(analysis.models, null);
  assert.ok(analysis.tasks.length > 0);
  assert.ok(analysis.warning.startsWith(NO_KEY_MESSAGE));
  assert.match(analysis.performance.summary, /NEBIUS_API_KEY/);
  assert.equal(stream.events.at(-1).type, "done");
});

test("unparseable analysis JSON falls back to the built-in analyzer", async () => {
  const { events, summary } = await loadEvents();
  const config = getProviderConfig({ NEBIUS_API_KEY: "nk-test" });
  const chat = mockChat([{ role: "assistant", content: "I could not do it, sorry." }]);
  try {
    const analysis = await analyzeActivityWithAgentStream({ events, summary, config }, collect().emit);
    assert.equal(analysis.source, "heuristic");
    assert.match(analysis.warning, /not valid analysis JSON/);
  } finally {
    chat.restore();
  }
});

test("a failed reasoning pass keeps the agent's goals and warns", async () => {
  const { events, summary } = await loadEvents();
  const config = getProviderConfig({ NEBIUS_API_KEY: "nk-test" });
  const chat = mockChat([
    { role: "assistant", content: ANALYSIS_JSON },
    { role: "assistant", content: "sorry, no JSON here" }
  ]);
  try {
    const analysis = await analyzeActivityWithAgentStream({ events, summary, config }, collect().emit);
    assert.equal(analysis.goals[0].title, "Find a new role");
    assert.match(analysis.warning, /reasoning pass/);
  } finally {
    chat.restore();
  }
});

// --- chat -------------------------------------------------------------------

test("chat runs on the fast model, maps history to plain messages and strips think tags", async () => {
  const { events } = await loadEvents();
  const config = getProviderConfig({ NEBIUS_API_KEY: "nk-test" });
  const chat = mockChat([{ role: "assistant", content: "<think>looking</think>You searched LinkedIn." }]);
  try {
    const result = await chatWithAgentStream({
      events,
      activityRoot: null,
      history: [{ role: "user", content: "hi" }, { role: "assistant", content: "hello" }],
      message: "What did I do?",
      config
    }, collect().emit);

    assert.equal(result.answer, "You searched LinkedIn.");
    const body = chat.requests[0].body;
    assert.equal(body.model, config.models.fast);
    assert.deepEqual(body.messages.map((message) => message.role), ["system", "user", "assistant", "user"]);
    assert.equal(body.messages.at(-1).content, "What did I do?");
  } finally {
    chat.restore();
  }
});

test("chat without a key names the env var instead of pretending to answer", async () => {
  const result = await chatWithAgentStream({ events: [], message: "hi", config: getProviderConfig({}) }, collect().emit);
  assert.match(result.answer, /NEBIUS_API_KEY/);
});

// --- pure helpers -----------------------------------------------------------

test("tool definitions use the nested Chat Completions function shape", () => {
  const tools = buildToolDefinitions();
  const names = tools.map((tool) => tool.function.name);
  assert.deepEqual(names, [
    "list_events",
    "search_events",
    "get_event_detail",
    "inspect_screenshot",
    "read_transcript",
    "transcribe_recording"
  ]);
  assert.ok(tools.every((tool) => tool.type === "function" && tool.function.parameters.type === "object"));
});

test("parseToolArguments tolerates objects, blanks and broken JSON", () => {
  assert.deepEqual(parseToolArguments('{"a":1}'), { a: 1 });
  assert.deepEqual(parseToolArguments({ a: 1 }), { a: 1 });
  assert.deepEqual(parseToolArguments(""), {});
  assert.deepEqual(parseToolArguments("{oops"), {});
});

test("assistantTurn keeps tool_calls and normalizes a null content", () => {
  const turn = assistantTurn({ choices: [{ message: { role: "assistant", content: null, tool_calls: [{ id: "c1" }] } }] });
  assert.deepEqual(turn, { role: "assistant", content: "", tool_calls: [{ id: "c1" }] });
  assert.deepEqual(toolResultMessage({ id: "c1" }, { ok: true }), { role: "tool", tool_call_id: "c1", content: '{"ok":true}' });
});

test("parseGoalPlan accepts an object, a bare array and fenced JSON; rejects junk", () => {
  assert.deepEqual(parseGoalPlan('{"goals":[{"title":"Close the books","taskIds":["t1"]}]}'), [
    { id: "goal-1", title: "Close the books", summary: "", taskIds: ["t1"] }
  ]);
  assert.equal(parseGoalPlan('[{"id":"g2","title":"Hire","taskIds":[]}]')[0].id, "g2");
  assert.equal(parseGoalPlan('```json\n{"goals":[{"title":"A"}]}\n```')[0].title, "A");
  assert.equal(parseGoalPlan("no json at all"), null);
  assert.equal(parseGoalPlan('{"goals":[{"summary":"missing a title"}]}'), null);
});

test("buildGoals sweeps unreferenced tasks into Other activity", () => {
  const tasks = [{ id: "t1", title: "A" }, { id: "t2", title: "B" }];
  const goals = buildGoals([{ id: "g1", title: "Goal", taskIds: ["t1"] }], tasks);
  assert.deepEqual(goals.map((goal) => goal.id), ["g1", "goal-other"]);
  assert.equal(tasks[1].goalId, "goal-other");
});

test("historyMessages keeps only the last turns as plain role/content pairs", () => {
  const history = Array.from({ length: 25 }, (_, index) => ({ role: index % 2 ? "assistant" : "user", content: `m${index}`, toolTrace: [] }));
  const messages = historyMessages(history);
  assert.equal(messages.length, 20);
  assert.deepEqual(Object.keys(messages[0]), ["role", "content"]);
  assert.equal(messages.at(-1).content, "m24");
});
