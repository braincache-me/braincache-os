import fs from "node:fs/promises";
import path from "node:path";
import { resolveMediaPath } from "./activityParser.js";
import { eventLabel, inferTasks, computeTaskMetrics } from "./taskInference.js";
import { generateSkillMarkdown } from "./skillGenerator.js";

const OPENAI_RESPONSES_URL = "https://api.openai.com/v1/responses";
const DEFAULT_MODEL = process.env.OPENAI_MODEL || "gpt-5.5";
// A real agentic loop needs room to look around. These are generous but bounded.
const MAX_TOOL_ROUNDS = Number(process.env.OPENAI_MAX_TOOL_ROUNDS || 8);
const MAX_TOOL_CALLS = Number(process.env.OPENAI_MAX_TOOL_CALLS || 14);
// Reasoning models with tool use + vision routinely take longer than a few
// seconds. The old 12s default aborted screenshot inspection mid-flight.
const REQUEST_TIMEOUT_MS = Number(process.env.OPENAI_TIMEOUT_MS || 240000);
// Final analysis JSON for a busy day can be large. 8000 truncated it and the
// unparseable JSON silently fell back to the app-centric heuristic analyzer.
const MAX_OUTPUT_TOKENS = Number(process.env.OPENAI_MAX_OUTPUT_TOKENS || 24000);

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

export async function analyzeActivityWithAgent(input) {
  return analyzeActivityWithAgentStream(input, async () => {});
}

export async function analyzeActivityWithAgentStream({ events, summary, activityRoot, model = DEFAULT_MODEL, targetGoals = [] }, emit) {
  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) {
    await emit({ type: "thinking", message: "No OpenAI key is set — using the built-in analyzer instead." });
    const fallback = heuristicAnalysis(events, summary, "OpenAI key is not set; used the built-in analyzer.", targetGoals);
    await emit({ type: "done", analysis: fallback });
    return fallback;
  }

  const compactSummary = buildCompactSummary(events, summary);
  const toolContext = { events, activityRoot, apiKey, model };

  await emit({
    type: "thinking",
    message: `Reading ${compactSummary.eventCount} recorded events` +
      `${compactSummary.screenshotCount ? `, ${compactSummary.screenshotCount} screenshots` : ""}` +
      `${compactSummary.transcriptCount ? `, ${compactSummary.transcriptCount} transcripts` : ""}.`
  });

  try {
    const userContent = [
      {
        type: "input_text",
        text: [
          "Analyze these recorded computer-activity logs and figure out the BUSINESS PROBLEMS the person was solving — not which apps they used.",
          "Use the tools to read across the WHOLE event set, search for evidence, inspect screenshots, and read transcripts where helpful. Don't judge from the first events alone — survey the timeline.",
          "Method: (1) read the events; (2) for each action ask WHY it happened — which business process drove it (e.g. a meeting attended because of the monthly accounting close, or because of product work) — the 'why' is the goal, not the surface; (3) CONNECT events that belong together — even when they jump between different apps and are separated by time — because they serve one real-world outcome; (4) build the CHRONOLOGY of connected events that achieved each outcome; (5) GROUP by the business target/outcome; (6) only then produce the analysis.",
          "Apps (SAP, a web browser, Excel, email, Slack, a terminal…) are just TOOLS, never the goal. Do NOT create goals like 'Google Chrome', 'SAP GUI', 'Research & browsing', or 'Writing & communication'. Those describe the tool or the verb, not the business problem — name the outcome instead.",
          "Example: actions in SAP, then a browser, then Excel, then email might all be ONE goal: 'Book incoming invoices correctly' — the apps are incidental. Group them together. Likewise reading Bloomberg + checking email + a calendar might all serve 'Prepare for the investment review meeting'.",
          targetGoals.length
            ? [
                "The user has DEFINED the business goals they care about. Organize the activity into THESE goals, using them as the goal titles (refine wording only slightly):",
                ...targetGoals.map((goal, index) => `  ${index + 1}. ${goal}`),
                "For each defined goal, find the connected events across apps and build the chronology that advanced it. Put activity that fits no defined goal under a final goal titled 'Other activity'. If a defined goal has no supporting activity, omit it and say so in the overview."
              ].join("\n")
            : "Infer the goals yourself from the evidence.",
          "Three levels: GOAL = the business problem/outcome (cross-app); TASK = an end-to-end workflow that advances the goal (may span several apps); STEP = the concrete actions in chronological order.",
          "Write everything for a non-technical reader: plain language, no CSS selectors, no raw event-type names.",
          "Return final output as JSON only, with this exact top-level shape:",
          "{ overview: string, performance: { summary: string, strengths: string[], bottlenecks: string[], recommendations: string[] }, goals: Goal[], tasks: Task[] }.",
          "Each Goal: { id, title (the business outcome in plain language, e.g. 'Book incoming invoices correctly'), summary (the problem being solved and the apps it spanned), taskIds: string[] }.",
          "Each Task: { id, title, summary, goalId, startTimestamp, endTimestamp, confidence (0-1), attempts (integer), outcome ('completed'|'incomplete'|'partial'), eventIds: string[] (a REPRESENTATIVE subset — the key evidence, not every event), steps: Step[] (milestones, not every click; cap ~12), performance: { timeSpent: string, friction: string[], automatable: boolean } }.",
          "Each Step: { label (plain-language, e.g. 'Entered the invoice in SAP'), evidenceEventId, appName, timestamp, notes }.",
          "Every task belongs to exactly one goal. Keep goals few and outcome-based (usually 2-6). Be concise so the JSON is complete and valid.",
          "",
          `Dataset summary: ${JSON.stringify(compactSummary)}.`,
          `First events preview: ${JSON.stringify(events.slice(0, 18).map(compactEvent))}.`
        ].join("\n")
      }
    ];

    const finalText = await runAgentLoop({
      apiKey,
      model,
      toolContext,
      systemPrompt: analysisSystemPrompt(),
      userContent,
      emit
    });

    await emit({ type: "output", text: finalText.slice(0, 12000) });
    const parsed = parseJsonObject(finalText);
    if (!parsed?.tasks) {
      await emit({ type: "thinking", message: "The agent's answer wasn't usable — falling back to the built-in analyzer." });
      const fallback = heuristicAnalysis(events, summary, "OpenAI response was not valid analysis JSON; used the built-in analyzer.", targetGoals);
      await emit({ type: "done", analysis: fallback });
      return fallback;
    }

    const analysis = normalizeAgentAnalysis(parsed, events, model);
    await emit({ type: "done", analysis });
    return analysis;
  } catch (error) {
    await emit({ type: "error", message: error.message });
    const fallback = heuristicAnalysis(events, summary, `OpenAI analysis failed: ${error.message}; used the built-in analyzer.`, targetGoals);
    await emit({ type: "done", analysis: fallback });
    return fallback;
  }
}

export async function generateSkillWithAgent(input) {
  return generateSkillWithAgentStream(input, async () => {});
}

// Agentic skill authoring: the model inspects the task's evidence through the
// same tools and writes a ready-to-use SKILL.md. Falls back to the deterministic
// template when no key is set or the model misbehaves.
export async function generateSkillWithAgentStream({ task, events, activityRoot, model = DEFAULT_MODEL, goal }, emit) {
  const apiKey = process.env.OPENAI_API_KEY;
  const taskEvents = scopeEventsToTask(task, events);

  if (!apiKey) {
    await emit({ type: "thinking", message: "No OpenAI key is set — generating a skill from the built-in template." });
    const markdown = generateSkillMarkdown(task);
    await emit({ type: "done", skill: { markdown, source: "template" } });
    return { markdown, source: "template" };
  }

  await emit({ type: "thinking", message: `Generalizing “${task.title}” into a reusable skill from ${taskEvents.length} steps of evidence.` });

  try {
    const userContent = [
      {
        type: "input_text",
        text: [
          "Write a reusable agent SKILL.md that GENERALIZES this observed workflow so an AI agent can complete SIMILAR cases in the future — not replay this one exact instance.",
          `Observed task: "${task.title}".`,
          `Task summary: ${task.summary || "(none)"}.`,
          goal?.title ? `Business goal this serves: "${goal.title}"${goal.summary ? ` — ${goal.summary}` : ""}.` : "",
          "Inspect the evidence with the tools (events, screenshots, transcripts) before writing, so the procedure is accurate.",
          "",
          "ABSTRACTION RULES (critical):",
          "- Generalize to the CLASS of task. The skill title and steps should fit any similar case, e.g. 'Book a supplier invoice in SAP', NOT 'Book Acme invoice INV-2026-4471'.",
          "- Replace every case-specific value (invoice numbers, vendor names, amounts, PO numbers, dates, person names, file names) with a NAMED PLACEHOLDER like {invoice_number}, {vendor}, {po_number}.",
          "- For EVERY placeholder, say WHERE to find it: which app, screen, document, or field to read it from (e.g. '{po_number} — on the invoice PDF header, or matched in SAP ME23N').",
          "- Capture decision points and branches you saw (e.g. 'if approval is rejected for wrong coding, correct the account assignment and repost') as general conditional steps.",
          "- Mention the specific observed case ONLY as a short example, clearly labelled.",
          "",
          "The skill must be practical for an AI agent that can drive a Mac (browser + native apps). Use stable anchors (visible text, menu paths, transaction codes, URLs, accessibility labels, file paths) — never raw click coordinates. Never include secure or private values.",
          "Return ONLY GitHub-flavored Markdown (no JSON, no code fences around the whole document) with these sections:",
          "# <Generalized title — the class of task>",
          "## Purpose — when to use this skill and which business goal it accomplishes (generalized).",
          "## Inputs — for each variable the agent needs, a line: `{placeholder}` — what it is, and **where to find it** (app/screen/document/field).",
          "## Required Access — apps, sites, systems, permissions.",
          "## Procedure — numbered general steps with the app and the anchor to act on; include the conditional branches observed.",
          "## Where to find details — a checklist mapping each piece of needed information to the source/system and how to locate it.",
          "## Verification — how the agent confirms the goal was achieved.",
          "## Notes & Risks — privacy, approval gates, edge cases. Reference the observed case only as an illustrative example.",
          "",
          `Observed steps (evidence to generalize, not to copy verbatim): ${JSON.stringify((task.steps || []).slice(0, 24))}.`,
          `Apps involved: ${(task.apps || []).map((app) => app.name).join(", ") || "unknown"}.`
        ].filter(Boolean).join("\n")
      }
    ];

    const markdown = await runAgentLoop({
      apiKey,
      model,
      toolContext: { events: taskEvents, activityRoot, apiKey, model },
      systemPrompt: skillSystemPrompt(),
      userContent,
      emit,
      maxRounds: 5,
      maxCalls: 8
    });

    const trimmed = stripJsonFences(markdown).trim();
    if (!trimmed || !/^#\s/m.test(trimmed)) {
      await emit({ type: "thinking", message: "The agent's draft wasn't valid Markdown — using the built-in template." });
      const fallback = generateSkillMarkdown(task);
      await emit({ type: "done", skill: { markdown: fallback, source: "template" } });
      return { markdown: fallback, source: "template" };
    }

    await emit({ type: "done", skill: { markdown: trimmed, source: "openai", model } });
    return { markdown: trimmed, source: "openai", model };
  } catch (error) {
    await emit({ type: "error", message: error.message });
    const fallback = generateSkillMarkdown(task);
    await emit({ type: "done", skill: { markdown: fallback, source: "template" } });
    return { markdown: fallback, source: "template" };
  }
}

// Conversational follow-up: ask questions about the logs and the extracted
// tasks. Keeps prior turns as context so follow-ups work, and uses the same
// tools to look up real evidence before answering.
export async function chatWithAgentStream({ events, activityRoot, model = DEFAULT_MODEL, history = [], message, analysis }, emit) {
  const apiKey = process.env.OPENAI_API_KEY;
  if (!apiKey) {
    const answer = "AI chat needs an OpenAI key. Set OPENAI_API_KEY on the server to ask questions about your logs.";
    await emit({ type: "done", answer });
    return { answer, toolTrace: [] };
  }

  try {
    const input = [];
    for (const turn of history.slice(-20)) {
      const role = turn.role === "assistant" ? "assistant" : "user";
      input.push({ role, content: [{ type: role === "assistant" ? "output_text" : "input_text", text: String(turn.content || "") }] });
    }
    input.push({ role: "user", content: [{ type: "input_text", text: String(message || "") }] });

    await emit({ type: "thinking", message: "Looking through the activity to answer…" });

    const answer = await runAgentLoop({
      apiKey,
      model,
      toolContext: { events, activityRoot, apiKey, model },
      systemPrompt: chatSystemPrompt(analysis),
      inputMessages: input,
      emit,
      maxRounds: 6,
      maxCalls: 10
    });

    await emit({ type: "done", answer });
    return { answer };
  } catch (error) {
    await emit({ type: "error", message: error.message });
    const answer = `Sorry — I couldn't answer that: ${error.message}`;
    await emit({ type: "done", answer });
    return { answer };
  }
}

// ---------------------------------------------------------------------------
// Agent driver — one place, used by analysis and skill authoring.
//
// Correctness rule for the Responses API: when a response contains
// `function_call` items and we continue the turn with `previous_response_id`,
// EVERY function_call must get a matching `function_call_output`. The previous
// version dropped over-budget calls and, when out of tool budget, sent a bare
// user message — both leave function calls unanswered, which is exactly the
// "No tool output found for function call …" error. This driver always answers
// every call, and forces the final answer with tool_choice:"none" instead of an
// unmatched user message.
// ---------------------------------------------------------------------------

async function runAgentLoop({ apiKey, model, toolContext, systemPrompt, userContent, inputMessages, emit, maxRounds = MAX_TOOL_ROUNDS, maxCalls = MAX_TOOL_CALLS }) {
  const tools = buildTools();

  let response = await callResponses(apiKey, {
    model,
    reasoning: { effort: "medium" },
    max_output_tokens: MAX_OUTPUT_TOKENS,
    instructions: systemPrompt,
    input: inputMessages || [{ role: "user", content: userContent }],
    tools
  });

  let totalCalls = 0;
  for (let round = 0; round < maxRounds; round += 1) {
    const calls = getFunctionCalls(response);
    if (!calls.length) break;

    await emit({ type: "thinking", message: `Looking deeper (round ${round + 1}): ${calls.length} tool call(s).` });

    const outputs = [];
    for (const call of calls) {
      const args = parseToolArguments(call.arguments);
      await emit({ type: "tool_call", callId: call.call_id, name: call.name, arguments: args });

      let result;
      if (totalCalls >= maxCalls) {
        result = { error: "Tool budget reached. Do not call more tools — return your final answer now." };
      } else {
        result = await executeToolCall(call, toolContext);
        totalCalls += 1;
      }

      await emit({ type: "tool_output", callId: call.call_id, name: call.name, output: summarizeToolOutput(result) });
      // Always answer every call_id, in order.
      outputs.push({ type: "function_call_output", call_id: call.call_id, output: JSON.stringify(result) });
    }

    const budgetReached = totalCalls >= maxCalls;
    await emit({
      type: "thinking",
      message: budgetReached ? "Wrapping up — composing the final answer." : "Thinking through the evidence so far."
    });

    response = await callResponses(apiKey, {
      model,
      previous_response_id: response.id,
      reasoning: { effort: budgetReached ? "low" : "medium" },
      max_output_tokens: MAX_OUTPUT_TOKENS,
      input: outputs,
      tools,
      tool_choice: budgetReached ? "none" : "auto"
    });

    if (budgetReached) break;
  }

  // Safety net: if the model somehow still emitted tool calls, answer them
  // (never leave them unmatched) and force a text reply.
  let guard = 0;
  while (getFunctionCalls(response).length && guard < 2) {
    guard += 1;
    const outputs = getFunctionCalls(response).map((call) => ({
      type: "function_call_output",
      call_id: call.call_id,
      output: JSON.stringify({ error: "No more tools available — return your final answer as text now." })
    }));
    response = await callResponses(apiKey, {
      model,
      previous_response_id: response.id,
      reasoning: { effort: "low" },
      max_output_tokens: MAX_OUTPUT_TOKENS,
      input: outputs,
      tools,
      tool_choice: "none"
    });
  }

  return extractResponseText(response);
}

// ---------------------------------------------------------------------------
// Prompts
// ---------------------------------------------------------------------------

function analysisSystemPrompt() {
  return [
    "You analyze recorded computer activity to understand the BUSINESS PROBLEMS a person was solving — the outcomes they were working toward, not the apps they happened to use.",
    "Look at the whole event set. Connect events that belong together even when they span different applications and are separated by time gaps, then group them by the real-world outcome.",
    "Apps (SAP, a browser, Excel, email, Slack, a terminal…) are just tools. NEVER make an app or a surface the goal — name the business objective. Many actions across SAP, a browser, and Excel might all serve one goal like 'Book incoming invoices correctly'.",
    "For each goal, describe the end-to-end tasks (workflows, which may cross apps) that advanced it, then the key milestone steps.",
    "Estimate how many attempts each task took and whether it was finished. Identify where time went, repeated work, context switching, waiting, and automation opportunities.",
    "Treat the captured data as evidence, not perfect truth. Use screenshots and transcripts when relevant. Write for a non-technical reader. Never invent secure-field contents or private values.",
    "Be concise so the JSON stays complete: representative eventIds (not every event) and milestone steps (not every click).",
    "Return JSON only — no markdown fences, no prose outside the JSON."
  ].join("\n");
}

function chatSystemPrompt(analysis) {
  const lines = [
    "You are a helpful analyst answering questions about a person's recorded computer activity and the tasks (processes) extracted from it.",
    "Use the tools to look up real evidence before answering — don't guess.",
    "Be concise and conversational, and write for a non-technical reader.",
    "Never reveal secure-field contents, passwords, or invented data.",
    "Answer in GitHub-flavored Markdown."
  ];
  const goals = analysis?.goals || [];
  const tasks = analysis?.tasks || [];
  if (goals.length) {
    const taskById = new Map(tasks.map((task) => [task.id, task]));
    lines.push("", "Goals and the tasks under them, already extracted from these logs:");
    goals.forEach((goal) => {
      lines.push(`• Goal: ${goal.title}`);
      (goal.taskIds || []).forEach((id) => {
        const task = taskById.get(id);
        if (task) lines.push(`    - ${task.title}`);
      });
    });
  } else if (tasks.length) {
    lines.push("", "Tasks already extracted from these logs:");
    tasks.forEach((task, index) => lines.push(`${index + 1}. ${task.title}${task.summary ? ` — ${task.summary}` : ""}`));
  }
  return lines.join("\n");
}

function skillSystemPrompt() {
  return [
    "You are an expert at turning ONE recorded workflow into a GENERALIZED, reusable agent skill.",
    "Your job is abstraction: capture the repeatable procedure for the whole class of task, not a replay of the single observed instance.",
    "Replace case-specific values with named placeholders, and for each one state where to find it (which app/screen/document/field).",
    "Inspect the evidence first, then write clear, executable, decision-aware steps.",
    "Prefer stable anchors (visible text, menu paths, transaction codes, URLs, accessibility labels, file paths) over coordinates.",
    "Never include secure or private values.",
    "Return GitHub-flavored Markdown only."
  ].join("\n");
}

// ---------------------------------------------------------------------------
// Tools
// ---------------------------------------------------------------------------

function buildTools() {
  return [
    {
      type: "function",
      name: "list_events",
      description: "List a compact slice of recorded activity events in time order.",
      parameters: {
        type: "object",
        properties: {
          offset: { type: "integer", minimum: 0 },
          limit: { type: "integer", minimum: 1, maximum: 80 }
        },
        additionalProperties: false
      }
    },
    {
      type: "function",
      name: "search_events",
      description: "Search recorded events by text, app name, event type, URL, window title, control text, AI prompt, or AI response.",
      parameters: {
        type: "object",
        properties: {
          query: { type: "string" },
          appName: { type: "string" },
          eventType: { type: "string" },
          limit: { type: "integer", minimum: 1, maximum: 80 }
        },
        additionalProperties: false
      }
    },
    {
      type: "function",
      name: "get_event_detail",
      description: "Fetch full details for one event by event ID.",
      parameters: {
        type: "object",
        properties: { eventId: { type: "string" } },
        required: ["eventId"],
        additionalProperties: false
      }
    },
    {
      type: "function",
      name: "inspect_screenshot",
      description: "Inspect a screenshot attached to an event. Returns a visual summary generated with image input when the file is available.",
      parameters: {
        type: "object",
        properties: { eventId: { type: "string" } },
        required: ["eventId"],
        additionalProperties: false
      }
    },
    {
      type: "function",
      name: "read_transcript",
      description: "Read a transcript file attached to an event.",
      parameters: {
        type: "object",
        properties: {
          eventId: { type: "string" },
          maxChars: { type: "integer", minimum: 500, maximum: 12000 }
        },
        required: ["eventId"],
        additionalProperties: false
      }
    }
  ];
}

async function executeToolCall(call, context) {
  const args = parseToolArguments(call.arguments);
  switch (call.name) {
    case "list_events":
      return listEvents(context.events, args);
    case "search_events":
      return searchEvents(context.events, args);
    case "get_event_detail":
      return getEventDetail(context.events, args.eventId);
    case "inspect_screenshot":
      return inspectScreenshot(context, args.eventId);
    case "read_transcript":
      return readTranscript(context, args.eventId, args.maxChars);
    default:
      return { error: `Unknown tool: ${call.name}` };
  }
}

function parseToolArguments(raw) {
  try {
    return raw ? JSON.parse(raw) : {};
  } catch {
    return {};
  }
}

function summarizeToolOutput(result) {
  if (!result || typeof result !== "object") return result;
  if (Array.isArray(result.events)) {
    return {
      ...result,
      events: result.events.slice(0, 12),
      truncatedEvents: Math.max(0, result.events.length - 12)
    };
  }
  if (result.event) return result;
  if (result.summary) return result;
  if (result.text) {
    return {
      ...result,
      text: result.text.slice(0, 3000),
      truncatedChars: Math.max(0, result.text.length - 3000)
    };
  }
  return result;
}

function listEvents(events, { offset = 0, limit = 40 }) {
  const safeOffset = Math.max(0, Number(offset) || 0);
  const safeLimit = Math.max(1, Math.min(80, Number(limit) || 40));
  return {
    offset: safeOffset,
    limit: safeLimit,
    total: events.length,
    events: events.slice(safeOffset, safeOffset + safeLimit).map(compactEvent)
  };
}

function searchEvents(events, { query = "", appName = "", eventType = "", limit = 40 }) {
  const needle = String(query || "").toLowerCase();
  const appNeedle = String(appName || "").toLowerCase();
  const typeNeedle = String(eventType || "").toLowerCase();
  const safeLimit = Math.max(1, Math.min(80, Number(limit) || 40));
  const matches = events.filter((event) => {
    if (appNeedle && !event.appName.toLowerCase().includes(appNeedle)) return false;
    if (typeNeedle && event.eventType.toLowerCase() !== typeNeedle) return false;
    if (!needle) return true;
    return [
      event.appName,
      event.windowTitle,
      event.eventType,
      event.controlName,
      event.controlValue,
      event.nearbyText,
      event.url,
      event.triggerMetadata,
      event.aiPrompt,
      event.aiResponse,
      event.screenshotPath,
      event.transcriptPath
    ].filter(Boolean).join("\n").toLowerCase().includes(needle);
  });
  return {
    totalMatches: matches.length,
    events: matches.slice(0, safeLimit).map(compactEvent)
  };
}

function getEventDetail(events, eventId) {
  const event = events.find((item) => item.id === eventId);
  if (!event) return { error: "Event not found." };
  return {
    event: {
      ...event.raw,
      computedLabel: eventLabel(event),
      sourceName: event.sourceName,
      lineNumber: event.lineNumber
    }
  };
}

async function inspectScreenshot({ events, activityRoot, apiKey, model }, eventId) {
  const event = events.find((item) => item.id === eventId);
  if (!event) return { error: "Event not found." };
  if (!event.screenshotPath) return { error: "This event has no screenshot." };
  const filePath = resolveMediaPath(activityRoot, "screenshots", event.screenshotPath);
  if (!filePath) return { error: "Invalid screenshot path." };

  try {
    const data = await fs.readFile(filePath);
    const ext = path.extname(filePath).toLowerCase();
    const mime = ext === ".png" ? "image/png" : "image/jpeg";
    const dataUrl = `data:${mime};base64,${data.toString("base64")}`;
    const response = await callResponses(apiKey, {
      model,
      max_output_tokens: 1000,
      input: [
        {
          role: "user",
          content: [
            {
              type: "input_text",
              text: [
                "Describe this screenshot of recorded computer activity in plain language.",
                "Cover the visible app/window, important on-screen text, the likely action, and anything useful for automation.",
                `Event context: ${JSON.stringify(compactEvent(event))}`
              ].join("\n")
            },
            { type: "input_image", image_url: dataUrl }
          ]
        }
      ]
    });
    return { eventId, screenshotPath: event.screenshotPath, summary: extractResponseText(response) };
  } catch (error) {
    return { error: error.message, eventId, screenshotPath: event.screenshotPath };
  }
}

async function readTranscript({ events, activityRoot }, eventId, maxChars = 6000) {
  const event = events.find((item) => item.id === eventId);
  if (!event) return { error: "Event not found." };
  if (!event.transcriptPath) return { error: "This event has no transcript." };
  const filePath = resolveMediaPath(activityRoot, "transcripts", event.transcriptPath);
  if (!filePath) return { error: "Invalid transcript path." };
  try {
    const text = await fs.readFile(filePath, "utf8");
    const safeMax = Math.max(500, Math.min(12000, Number(maxChars) || 6000));
    return { eventId, transcriptPath: event.transcriptPath, length: text.length, text: text.slice(0, safeMax) };
  } catch (error) {
    return { error: error.message, eventId, transcriptPath: event.transcriptPath };
  }
}

// ---------------------------------------------------------------------------
// OpenAI transport
// ---------------------------------------------------------------------------

async function callResponses(apiKey, body) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
  let response;
  try {
    response = await fetch(OPENAI_RESPONSES_URL, {
      method: "POST",
      signal: controller.signal,
      headers: {
        authorization: `Bearer ${apiKey}`,
        "content-type": "application/json"
      },
      body: JSON.stringify(body)
    });
  } catch (error) {
    clearTimeout(timeout);
    if (error.name === "AbortError") {
      throw new Error(`OpenAI request timed out after ${Math.round(REQUEST_TIMEOUT_MS / 1000)}s.`);
    }
    throw error;
  }
  clearTimeout(timeout);
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(payload.error?.message || `OpenAI request failed (${response.status}).`);
  }
  return payload;
}

function getFunctionCalls(response) {
  return (response.output || []).filter((item) => item.type === "function_call");
}

function extractResponseText(response) {
  if (response.output_text) return response.output_text;
  const chunks = [];
  for (const item of response.output || []) {
    if (item.type === "message") {
      for (const part of item.content || []) {
        if (part.type === "output_text" || part.type === "text") chunks.push(part.text);
      }
    }
  }
  return chunks.join("\n").trim();
}

function parseJsonObject(text) {
  const raw = stripJsonFences(String(text || "")).trim();
  if (!raw) return null;
  try {
    return JSON.parse(raw);
  } catch {
    const match = raw.match(/\{[\s\S]*\}/);
    if (!match) return null;
    try {
      return JSON.parse(match[0]);
    } catch {
      return null;
    }
  }
}

function stripJsonFences(text) {
  return String(text || "")
    .replace(/^\s*```(?:json|markdown|md)?\s*/i, "")
    .replace(/\s*```\s*$/i, "");
}

// ---------------------------------------------------------------------------
// Normalization
// ---------------------------------------------------------------------------

function buildCompactSummary(events, summary) {
  return {
    eventCount: summary?.eventCount ?? events.length,
    dayCount: summary?.dayCount,
    days: summary?.days,
    firstTimestamp: summary?.firstTimestamp,
    lastTimestamp: summary?.lastTimestamp,
    durationMinutes: summary?.durationMinutes,
    screenshotCount: summary?.screenshotCount,
    transcriptCount: summary?.transcriptCount,
    apps: summary?.apps,
    eventTypes: summary?.eventTypes
  };
}

function normalizeAgentAnalysis(analysis, events, model) {
  const byId = new Map(events.map((event) => [event.id, event]));
  const tasks = (analysis.tasks || []).map((task, index) => {
    const taskEvents = (task.eventIds || []).map((id) => byId.get(id)).filter(Boolean);
    const fallbackEvents = taskEvents.length ? taskEvents : events.slice(0, 1);
    const metrics = computeTaskMetrics(fallbackEvents);
    const attempts = Number.isFinite(Number(task.attempts)) ? Number(task.attempts) : metrics.attempts;
    const outcome = task.outcome || metrics.outcome;
    return {
      id: task.id || `task-${index + 1}`,
      title: task.title || `Task ${index + 1}`,
      summary: task.summary || "",
      confidence: clampNumber(task.confidence, 0, 1, 0.7),
      startTimestamp: task.startTimestamp || fallbackEvents[0]?.timestamp || null,
      endTimestamp: task.endTimestamp || fallbackEvents[fallbackEvents.length - 1]?.timestamp || null,
      durationMinutes: estimateDurationMinutes(task, fallbackEvents),
      eventCount: task.eventIds?.length || fallbackEvents.length,
      actionCount: metrics.actions,
      screenshotCount: fallbackEvents.filter((event) => event.screenshotPath).length,
      transcriptCount: fallbackEvents.filter((event) => event.transcriptPath || event.eventType?.includes("transcript")).length,
      apps: topApps(fallbackEvents),
      eventTypes: topTypes(fallbackEvents),
      windows: [...new Set(fallbackEvents.map((event) => event.windowTitle).filter(Boolean))].slice(0, 5),
      verbs: [],
      steps: task.steps || [],
      metrics,
      attempts,
      outcome,
      evidence: fallbackEvents.slice(0, 16).map((event) => ({
        id: event.id,
        timestamp: event.timestamp,
        eventType: event.eventType,
        appName: event.appName,
        windowTitle: event.windowTitle,
        label: eventLabel(event),
        screenshotPath: event.screenshotPath,
        transcriptPath: event.transcriptPath
      })),
      performance: task.performance || {},
      eventIds: task.eventIds || fallbackEvents.map((event) => event.id),
      events: fallbackEvents
    };
  });

  const goals = buildGoals(analysis.goals, tasks);

  return {
    source: "openai",
    model,
    overview: analysis.overview || "",
    performance: analysis.performance || {},
    goals,
    tasks
  };
}

// Build the goal grouping over the flat task list. Prefers the model's goals
// (matching by taskIds or each task's goalId), sweeps any leftover tasks into an
// "Other activity" goal, and falls back to a heuristic grouping if none exist.
// Mutates each task with its resolved `goalId`.
function buildGoals(rawGoals, tasks) {
  const taskById = new Map(tasks.map((task) => [task.id, task]));
  const assigned = new Set();
  const goals = [];

  (rawGoals || []).forEach((goal, index) => {
    const id = goal.id || `goal-${index + 1}`;
    const referenced = tasks.filter((task) => task.goalId === id).map((task) => task.id);
    const ids = [...new Set([...(Array.isArray(goal.taskIds) ? goal.taskIds : []), ...referenced])]
      .filter((taskId) => taskById.has(taskId) && !assigned.has(taskId));
    if (!ids.length) return;
    ids.forEach((taskId) => { assigned.add(taskId); taskById.get(taskId).goalId = id; });
    goals.push({ id, title: goal.title || `Goal ${index + 1}`, summary: goal.summary || "", taskIds: ids });
  });

  const orphans = tasks.filter((task) => !assigned.has(task.id));
  if (orphans.length) {
    if (!goals.length) return deriveGoalsFromTasks(tasks);
    orphans.forEach((task) => { task.goalId = "goal-other"; });
    goals.push({ id: "goal-other", title: "Other activity", summary: "", taskIds: orphans.map((task) => task.id) });
  }
  return goals.length ? goals : deriveGoalsFromTasks(tasks);
}

// Heuristic grouping when the model gives no goals (or for the offline analyzer):
// cluster tasks by their dominant inferred verb, then app.
function deriveGoalsFromTasks(tasks) {
  const titleForKey = {
    Code: "Coding & development",
    Research: "Research & browsing",
    Write: "Writing & communication",
    Analyze: "Data & analysis",
    Meet: "Meetings & calls",
    Configure: "Setup & configuration",
    Operate: "Hands-on operation",
    Navigate: "Navigating & browsing"
  };
  const groups = new Map();
  for (const task of tasks) {
    const key = (task.verbs && task.verbs[0]) || task.apps?.[0]?.name || "Other activity";
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(task);
  }
  let index = 0;
  const goals = [];
  for (const [key, groupTasks] of groups) {
    index += 1;
    const id = `goal-${index}`;
    groupTasks.forEach((task) => { task.goalId = id; });
    goals.push({ id, title: titleForKey[key] || key, summary: "", taskIds: groupTasks.map((task) => task.id) });
  }
  return goals;
}

const STOPWORDS = new Set(["the", "a", "an", "and", "or", "to", "of", "in", "on", "for", "with", "into", "from", "by", "at", "as", "is", "are", "be", "use", "using", "via", "my", "our", "their", "this", "that", "all", "correctly", "properly", "work", "working"]);

function tokenize(text) {
  return new Set(
    String(text || "")
      .toLowerCase()
      .split(/[^a-z0-9]+/)
      .filter((token) => token.length > 2 && !STOPWORDS.has(token))
  );
}

// Bucket heuristic tasks under user-defined goals by keyword overlap. Every
// defined goal is kept (even with no tasks) so the user always sees their input;
// unmatched tasks fall into "Other activity".
function groupTasksByTargetGoals(tasks, targetGoals) {
  const goals = targetGoals.map((title, i) => ({ id: `goal-${i + 1}`, title, summary: "", taskIds: [], tokens: tokenize(title) }));
  const other = { id: "goal-other", title: "Other activity", summary: "", taskIds: [] };

  for (const task of tasks) {
    const text = [task.title, task.summary, ...(task.apps || []).map((a) => a.name), ...(task.steps || []).map((s) => s.label)].join(" ");
    const taskTokens = tokenize(text);
    let best = -1;
    let bestScore = 0;
    goals.forEach((goal, i) => {
      let score = 0;
      for (const token of goal.tokens) if (taskTokens.has(token)) score += 1;
      if (score > bestScore) { bestScore = score; best = i; }
    });
    if (best >= 0 && bestScore > 0) {
      goals[best].taskIds.push(task.id);
      task.goalId = goals[best].id;
    } else {
      other.taskIds.push(task.id);
      task.goalId = other.id;
    }
  }

  const result = goals.map(({ tokens, ...goal }) => goal);
  if (other.taskIds.length) result.push(other);
  return result;
}

function heuristicAnalysis(events, summary, warning, targetGoals = []) {
  const tasks = inferTasks(events, { gapMinutes: 10 });
  // If the user defined goals, ALWAYS honor them — bucket tasks into those goals
  // (by keyword overlap) even on the offline/fallback path, so the goals the user
  // typed always appear.
  const goals = targetGoals.length
    ? groupTasksByTargetGoals(tasks, targetGoals)
    : deriveGoalsFromTasks(tasks);
  return {
    source: "heuristic",
    model: null,
    warning,
    overview: `Recorded ${summary?.eventCount ?? events.length} events across ${summary?.dayCount ?? "an unknown number of"} day(s).`,
    performance: {
      summary: "The built-in analyzer groups activity by time gaps and app/window continuity. Add an OpenAI key for richer, AI-driven task analysis.",
      strengths: [],
      bottlenecks: [],
      recommendations: []
    },
    goals,
    tasks
  };
}

function compactEvent(event) {
  return {
    id: event.id,
    timestamp: event.timestamp,
    appName: event.appName,
    eventType: event.eventType,
    windowTitle: event.windowTitle || undefined,
    label: eventLabel(event),
    controlName: event.controlName || undefined,
    controlValue: event.controlValue || undefined,
    nearbyText: event.nearbyText || undefined,
    url: event.url || undefined,
    screenshotPath: event.screenshotPath || undefined,
    transcriptPath: event.transcriptPath || undefined,
    aiPrompt: event.aiPrompt || undefined,
    aiResponse: event.aiResponse || undefined
  };
}

function scopeEventsToTask(task, allEvents) {
  if (Array.isArray(task?.events) && task.events.length) return task.events;
  const ids = new Set(task?.eventIds || []);
  if (ids.size && Array.isArray(allEvents)) {
    const scoped = allEvents.filter((event) => ids.has(event.id));
    if (scoped.length) return scoped;
  }
  return Array.isArray(allEvents) ? allEvents : [];
}

function estimateDurationMinutes(task, events) {
  if (Number.isFinite(Number(task.durationMinutes))) return Number(task.durationMinutes);
  const first = events[0]?.timeMs;
  const last = events[events.length - 1]?.timeMs;
  if (!first || !last) return 0;
  return Math.max(1, Math.round((last - first) / 60000));
}

function clampNumber(value, min, max, fallback) {
  const number = Number(value);
  if (!Number.isFinite(number)) return fallback;
  return Math.max(min, Math.min(max, number));
}

function topApps(events) {
  return topCounts(events, (event) => event.appName);
}

function topTypes(events) {
  return topCounts(events, (event) => event.eventType);
}

function topCounts(events, getKey) {
  const counts = new Map();
  for (const event of events) {
    const key = getKey(event);
    if (!key) continue;
    counts.set(key, (counts.get(key) || 0) + 1);
  }
  return [...counts.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, 6)
    .map(([name, count]) => ({ name, count }));
}
