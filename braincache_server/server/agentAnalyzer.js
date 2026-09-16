// The analysis agent — reads recorded activity through tool calls and returns
// business-outcome tasks, a goal grouping, reusable skills, and chat answers.
//
// Transport is the OpenAI-compatible Chat Completions API (Nebius Token Factory
// by default, see aiProvider.js). Model routing:
//   agent     — the tool-calling analysis loop and skill authoring
//   reasoning — one extra non-tool pass that groups tasks into business goals
//   fast      — conversational follow-ups in the Chat tab
//   omni      — screenshot vision and meeting-recording transcription
//
// Without a key every path degrades to the deterministic built-in analyzer /
// skill template, so the console still works offline.

import fs from "node:fs/promises";
import path from "node:path";
import { resolveMediaPath } from "./activityParser.js";
import { eventLabel, inferTasks, computeTaskMetrics } from "./taskInference.js";
import { generateSkillMarkdown } from "./skillGenerator.js";
import {
  getProviderConfig,
  messageText,
  messageToolCalls,
  omniChatCompletion,
  roleChatCompletion,
  stripThinkTags
} from "./aiProvider.js";
import { transcribeRecording, transcriptExists, transcriptPathForRecording } from "./transcription.js";

export const NO_KEY_MESSAGE = "AI analysis needs a Nebius Token Factory key. Set NEBIUS_API_KEY on the server.";
const NO_KEY_CHAT_MESSAGE = "AI chat needs a Nebius Token Factory key. Set NEBIUS_API_KEY on the server to ask questions about your logs.";

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

export async function analyzeActivityWithAgent(input) {
  return analyzeActivityWithAgentStream(input, async () => {});
}

export async function analyzeActivityWithAgentStream(
  { events, summary, activityRoot, model, targetGoals = [], config = getProviderConfig() },
  emit
) {
  if (!config.enabled) {
    await emit({ type: "thinking", message: "No Nebius Token Factory key is set — using the built-in analyzer instead." });
    const fallback = heuristicAnalysis(events, summary, `${NO_KEY_MESSAGE} Used the built-in analyzer.`, targetGoals);
    await emit({ type: "done", analysis: fallback });
    return fallback;
  }

  const agentModel = model || config.models.agent;
  const compactSummary = buildCompactSummary(events, summary);
  const toolContext = { events, activityRoot, config, emit };

  await emit({
    type: "thinking",
    message: `Reading ${compactSummary.eventCount} recorded events` +
      `${compactSummary.screenshotCount ? `, ${compactSummary.screenshotCount} screenshots` : ""}` +
      `${compactSummary.transcriptCount ? `, ${compactSummary.transcriptCount} transcripts` : ""}` +
      ` with ${agentModel}.`
  });

  try {
    const finalText = await runAgentLoop({
      config,
      model: agentModel,
      toolContext,
      systemPrompt: analysisSystemPrompt(),
      messages: [{ role: "user", content: analysisUserPrompt({ compactSummary, events, targetGoals }) }],
      emit
    });

    await emit({ type: "output", text: finalText.slice(0, 12000) });
    const parsed = parseJsonObject(finalText);
    if (!parsed?.tasks) {
      await emit({ type: "thinking", message: "The agent's answer wasn't usable — falling back to the built-in analyzer." });
      const fallback = heuristicAnalysis(events, summary, "The model's response was not valid analysis JSON; used the built-in analyzer.", targetGoals);
      await emit({ type: "done", analysis: fallback });
      return fallback;
    }

    const tasks = normalizeAgentTasks(parsed, events);
    const grouping = await planGoals({ tasks, targetGoals, rawGoals: parsed.goals, config, emit });
    // The reasoning pass re-groups from scratch — drop the analysis model's own
    // goalIds so its ids can't pull tasks into a same-named reasoning goal.
    if (grouping.source === "reasoning") tasks.forEach((task) => { delete task.goalId; });

    const analysis = {
      source: "ai",
      provider: config.providerLabel,
      model: agentModel,
      models: { agent: agentModel, reasoning: config.models.reasoning },
      overview: parsed.overview || "",
      performance: parsed.performance || {},
      goals: buildGoals(grouping.rawGoals, tasks),
      tasks
    };
    if (grouping.warning) analysis.warning = grouping.warning;

    await emit({ type: "done", analysis });
    return analysis;
  } catch (error) {
    await emit({ type: "error", message: error.message });
    const fallback = heuristicAnalysis(events, summary, `AI analysis failed: ${error.message}; used the built-in analyzer.`, targetGoals);
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
export async function generateSkillWithAgentStream(
  { task, events, activityRoot, model, goal, config = getProviderConfig() },
  emit
) {
  const taskEvents = scopeEventsToTask(task, events);

  if (!config.enabled) {
    await emit({ type: "thinking", message: "No Nebius Token Factory key is set — generating a skill from the built-in template." });
    const markdown = generateSkillMarkdown(task);
    await emit({ type: "done", skill: { markdown, source: "template" } });
    return { markdown, source: "template" };
  }

  const agentModel = model || config.models.agent;
  await emit({ type: "thinking", message: `Generalizing “${task.title}” into a reusable skill from ${taskEvents.length} steps of evidence.` });

  try {
    const markdown = await runAgentLoop({
      config,
      model: agentModel,
      toolContext: { events: taskEvents, activityRoot, config, emit },
      systemPrompt: skillSystemPrompt(),
      messages: [{ role: "user", content: skillUserPrompt({ task, goal }) }],
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

    const skill = { markdown: trimmed, source: "ai", model: agentModel };
    await emit({ type: "done", skill });
    return skill;
  } catch (error) {
    await emit({ type: "error", message: error.message });
    const fallback = generateSkillMarkdown(task);
    await emit({ type: "done", skill: { markdown: fallback, source: "template" } });
    return { markdown: fallback, source: "template" };
  }
}

// Conversational follow-up: ask questions about the logs and the extracted
// tasks. Keeps prior turns as context so follow-ups work, and uses the same
// tools to look up real evidence before answering. Runs on the fast model.
export async function chatWithAgentStream(
  { events, activityRoot, model, history = [], message, analysis, config = getProviderConfig() },
  emit
) {
  if (!config.enabled) {
    await emit({ type: "done", answer: NO_KEY_CHAT_MESSAGE });
    return { answer: NO_KEY_CHAT_MESSAGE, toolTrace: [] };
  }

  try {
    const chatModel = model || config.models.fast;
    await emit({ type: "thinking", message: "Looking through the activity to answer…" });

    const answer = await runAgentLoop({
      config,
      model: chatModel,
      role: "fast",
      toolContext: { events, activityRoot, config, emit },
      systemPrompt: chatSystemPrompt(analysis),
      messages: [...historyMessages(history), { role: "user", content: String(message || "") }],
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

// Prior chat turns as plain Chat Completions messages.
export function historyMessages(history = [], limit = 20) {
  return history.slice(-limit).map((turn) => ({
    role: turn.role === "assistant" ? "assistant" : "user",
    content: String(turn.content || "")
  }));
}

// ---------------------------------------------------------------------------
// Agent driver — one place, used by analysis, skill authoring and chat.
//
// Correctness rule for Chat Completions tool use: when a response carries
// `tool_calls`, the assistant message must be appended verbatim and EVERY call
// must be answered by exactly one `{role:"tool", tool_call_id}` message —
// including calls skipped because the budget ran out. When the budget is
// reached the next request is sent with tool_choice:"none" so the model has to
// answer in text instead of calling again.
// ---------------------------------------------------------------------------

async function runAgentLoop({ config, model, role = "agent", toolContext, systemPrompt, messages: seed, emit, maxRounds, maxCalls }) {
  const tools = buildToolDefinitions();
  const rounds = maxRounds ?? config.limits.maxToolRounds;
  const callBudget = maxCalls ?? config.limits.maxToolCalls;
  const messages = [{ role: "system", content: systemPrompt }, ...seed];

  const ask = (toolChoice) => roleChatCompletion(role, {
    model,
    messages,
    tools,
    tool_choice: toolChoice,
    max_tokens: config.limits.maxOutputTokens
  }, { config });

  let response = await ask("auto");
  let totalCalls = 0;

  for (let round = 0; round < rounds; round += 1) {
    const calls = messageToolCalls(response);
    if (!calls.length) break;

    await emit({ type: "thinking", message: `Looking deeper (round ${round + 1}): ${calls.length} tool call(s).` });
    messages.push(assistantTurn(response));

    for (const call of calls) {
      const name = call.function?.name || call.name;
      const args = parseToolArguments(call.function?.arguments);
      await emit({ type: "tool_call", callId: call.id, name, arguments: args });

      let result;
      if (totalCalls >= callBudget) {
        result = { error: "Tool budget exhausted. Do not call more tools — return your final answer now." };
      } else {
        result = await executeToolCall(name, args, toolContext);
        totalCalls += 1;
      }

      await emit({ type: "tool_output", callId: call.id, name, output: summarizeToolOutput(result) });
      // Every call_id gets exactly one tool message, in order.
      messages.push(toolResultMessage(call, result));
    }

    const budgetReached = totalCalls >= callBudget;
    await emit({
      type: "thinking",
      message: budgetReached ? "Wrapping up — composing the final answer." : "Thinking through the evidence so far."
    });

    response = await ask(budgetReached ? "none" : "auto");
    if (budgetReached) break;
  }

  // Safety net: the round budget ran out (or the model ignored tool_choice) and
  // calls are still pending — answer them, never leave one unmatched, and force
  // a text reply.
  let guard = 0;
  while (messageToolCalls(response).length && guard < 2) {
    guard += 1;
    messages.push(assistantTurn(response));
    for (const call of messageToolCalls(response)) {
      messages.push(toolResultMessage(call, { error: "No more tools available — return your final answer as text now." }));
    }
    response = await ask("none");
  }

  return stripThinkTags(messageText(response));
}

// The assistant turn as the server returned it (tool_calls included), with a
// string `content` so servers that reject a null content still accept it.
export function assistantTurn(response) {
  const message = response?.choices?.[0]?.message || {};
  return { ...message, role: "assistant", content: typeof message.content === "string" ? message.content : "" };
}

export function toolResultMessage(call, result) {
  return { role: "tool", tool_call_id: call.id, content: JSON.stringify(result) };
}

// ---------------------------------------------------------------------------
// Goal planning — one extra reasoning pass over the extracted tasks
// ---------------------------------------------------------------------------

// Ask the reasoning model to group the flat task list into business goals. On
// any failure the agent model's own goals (or the heuristic grouping) are kept
// and a warning is surfaced in the UI.
async function planGoals({ tasks, targetGoals, rawGoals, config, emit }) {
  const model = config.models.reasoning;
  if (!tasks.length) return { rawGoals, warning: null, source: "agent" };

  await emit({ type: "thinking", message: `Grouping ${tasks.length} task(s) into business goals with ${model}…` });
  try {
    const response = await roleChatCompletion("reasoning", {
      model,
      messages: [
        { role: "system", content: goalSystemPrompt() },
        { role: "user", content: goalUserPrompt(tasks, targetGoals) }
      ],
      temperature: 0.2,
      max_tokens: Math.min(config.limits.maxOutputTokens, 6000)
    }, { config });

    const plan = parseGoalPlan(stripThinkTags(messageText(response)));
    if (plan?.length) return { rawGoals: plan, warning: null, source: "reasoning" };
    const warning = `The reasoning pass (${model}) returned no usable goal grouping, so the analysis model's goals were kept.`;
    await emit({ type: "thinking", message: warning });
    return { rawGoals, warning, source: "agent" };
  } catch (error) {
    const warning = `The reasoning pass (${model}) failed: ${error.message}. The analysis model's goals were kept.`;
    await emit({ type: "thinking", message: warning });
    return { rawGoals, warning, source: "agent" };
  }
}

// Accept `{ goals: [...] }` or a bare array; keep only entries that name a goal.
export function parseGoalPlan(text) {
  const parsed = parseJsonObject(text) || parseJsonArray(text);
  const list = Array.isArray(parsed) ? parsed : Array.isArray(parsed?.goals) ? parsed.goals : null;
  if (!list) return null;
  const goals = list
    .filter((goal) => goal && typeof goal === "object" && String(goal.title || "").trim())
    .map((goal, index) => ({
      id: String(goal.id || `goal-${index + 1}`),
      title: String(goal.title).trim(),
      summary: String(goal.summary || ""),
      taskIds: (Array.isArray(goal.taskIds) ? goal.taskIds : []).map(String)
    }));
  return goals.length ? goals : null;
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

function analysisUserPrompt({ compactSummary, events, targetGoals }) {
  return [
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
  ].join("\n");
}

function goalSystemPrompt() {
  return [
    "You group already-extracted workflow tasks into the BUSINESS GOALS they served.",
    "A goal is a real-world outcome (e.g. 'Book incoming invoices correctly', 'Prepare the investment review'), never an app, a surface, or a verb like 'Research & browsing'.",
    "Tasks that span different applications often serve ONE goal — group them together. Keep goals few (usually 2-6) and give each a plain-language title a non-technical manager would recognize.",
    "Every task id must appear in exactly one goal. Use the task ids exactly as given.",
    "Return JSON only, no prose and no markdown fences:",
    '{ "goals": [ { "id": "goal-1", "title": "...", "summary": "...", "taskIds": ["task-1"] } ] }'
  ].join("\n");
}

function goalUserPrompt(tasks, targetGoals = []) {
  const lines = [];
  if (targetGoals.length) {
    lines.push(
      "The user DEFINED the goals they care about. Use these as the goal titles (refine wording only slightly) and assign each task to the one it advanced:",
      ...targetGoals.map((goal, index) => `  ${index + 1}. ${goal}`),
      "Tasks that fit none of them go under a final goal titled 'Other activity'.",
      ""
    );
  } else {
    lines.push("Infer the goals from the tasks themselves.", "");
  }
  lines.push(
    "Tasks to group:",
    JSON.stringify(tasks.map((task) => ({
      id: task.id,
      title: task.title,
      summary: task.summary,
      apps: (task.apps || []).map((app) => app.name),
      startTimestamp: task.startTimestamp,
      endTimestamp: task.endTimestamp,
      steps: (task.steps || []).slice(0, 8).map((step) => step.label).filter(Boolean)
    })))
  );
  return lines.join("\n");
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

function skillUserPrompt({ task, goal }) {
  return [
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
  ].filter(Boolean).join("\n");
}

// ---------------------------------------------------------------------------
// Tools — Chat Completions function schemas
// ---------------------------------------------------------------------------

export function buildToolDefinitions() {
  return [
    {
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
      name: "inspect_screenshot",
      description: "Inspect a screenshot attached to an event. Returns a visual summary produced by the omni vision model when the file is available.",
      parameters: {
        type: "object",
        properties: { eventId: { type: "string" } },
        required: ["eventId"],
        additionalProperties: false
      }
    },
    {
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
    },
    {
      name: "transcribe_recording",
      description: "Transcribe a meeting or voice recording with the omni audio model and return its text. Give the ID of an event that has a recording, or a recording path relative to the recordings folder. Already-transcribed recordings are returned from disk. Slow — use it only when the recording matters to the answer.",
      parameters: {
        type: "object",
        properties: {
          eventId: { type: "string" },
          recordingPath: { type: "string" },
          maxChars: { type: "integer", minimum: 500, maximum: 12000 }
        },
        additionalProperties: false
      }
    }
  ].map((tool) => ({ type: "function", function: tool }));
}

async function executeToolCall(name, args, context) {
  switch (name) {
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
    case "transcribe_recording":
      return transcribeRecordingTool(context, args);
    default:
      return { error: `Unknown tool: ${name}` };
  }
}

export function parseToolArguments(raw) {
  if (raw && typeof raw === "object") return raw;
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
      event.transcriptPath,
      event.audioPath
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

// Vision goes to the omni model as an image_url data URI part.
async function inspectScreenshot({ events, activityRoot, config }, eventId) {
  const event = events.find((item) => item.id === eventId);
  if (!event) return { error: "Event not found." };
  if (!event.screenshotPath) return { error: "This event has no screenshot." };
  const filePath = resolveMediaPath(activityRoot, "screenshots", event.screenshotPath);
  if (!filePath) return { error: "Invalid screenshot path." };

  try {
    const data = await fs.readFile(filePath);
    const ext = path.extname(filePath).toLowerCase();
    const mime = ext === ".png" ? "image/png" : "image/jpeg";
    const response = await omniChatCompletion({
      messages: [
        {
          role: "user",
          content: [
            {
              type: "text",
              text: [
                "Describe this screenshot of recorded computer activity in plain language.",
                "Cover the visible app/window, important on-screen text, the likely action, and anything useful for automation.",
                `Event context: ${JSON.stringify(compactEvent(event))}`
              ].join("\n")
            },
            { type: "image_url", image_url: { url: `data:${mime};base64,${data.toString("base64")}` } }
          ]
        }
      ],
      temperature: 0.2,
      max_tokens: 1000
    }, { config });
    return { eventId, screenshotPath: event.screenshotPath, summary: stripThinkTags(messageText(response)) };
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
    return { eventId, transcriptPath: event.transcriptPath, length: text.length, text: text.slice(0, clampChars(maxChars)) };
  } catch (error) {
    return { error: error.message, eventId, transcriptPath: event.transcriptPath };
  }
}

// On-demand transcription of a recording referenced by an event (or named
// directly). Cached transcripts are read from disk instead of re-billed.
async function transcribeRecordingTool({ events, activityRoot, config = getProviderConfig(), emit = async () => {} }, args = {}) {
  let relativePath = String(args.recordingPath || "").trim() || null;
  if (!relativePath && args.eventId) {
    const event = events.find((item) => item.id === args.eventId);
    if (!event) return { error: "Event not found." };
    if (!event.audioPath) return { error: "This event has no recording." };
    relativePath = event.audioPath;
  }
  if (!relativePath) return { error: "Provide an eventId whose event has a recording, or a recordingPath." };
  if (!activityRoot) return { error: "No activity root is configured for this project." };

  const filePath = resolveMediaPath(activityRoot, "recordings", relativePath);
  if (!filePath) return { error: "Invalid recording path." };

  const transcriptPath = transcriptPathForRecording(relativePath);
  try {
    if (await transcriptExists(activityRoot, relativePath)) {
      const text = await fs.readFile(resolveMediaPath(activityRoot, "transcripts", transcriptPath), "utf8");
      return { recordingPath: relativePath, transcriptPath, cached: true, length: text.length, text: text.slice(0, clampChars(args.maxChars)) };
    }
    const result = await transcribeRecording(filePath, { emit, activityRoot, relativePath, config });
    return {
      recordingPath: relativePath,
      transcriptPath: result.transcriptPath,
      cached: false,
      model: result.model,
      seconds: result.seconds,
      length: result.text.length,
      text: result.text.slice(0, clampChars(args.maxChars))
    };
  } catch (error) {
    return { error: error.message, recordingPath: relativePath };
  }
}

function clampChars(value, fallback = 6000) {
  return Math.max(500, Math.min(12000, Number(value) || fallback));
}

// ---------------------------------------------------------------------------
// Response parsing (pure)
// ---------------------------------------------------------------------------

function parseJsonObject(text) {
  const raw = stripJsonFences(String(text || "")).trim();
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : null;
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

function parseJsonArray(text) {
  const raw = stripJsonFences(String(text || "")).trim();
  const match = raw.match(/\[[\s\S]*\]/);
  if (!match) return null;
  try {
    const parsed = JSON.parse(match[0]);
    return Array.isArray(parsed) ? parsed : null;
  } catch {
    return null;
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

function normalizeAgentTasks(analysis, events) {
  const byId = new Map(events.map((event) => [event.id, event]));
  return (analysis.tasks || []).map((task, index) => {
    const taskEvents = (task.eventIds || []).map((id) => byId.get(id)).filter(Boolean);
    const fallbackEvents = taskEvents.length ? taskEvents : events.slice(0, 1);
    const metrics = computeTaskMetrics(fallbackEvents);
    const attempts = Number.isFinite(Number(task.attempts)) ? Number(task.attempts) : metrics.attempts;
    const outcome = task.outcome || metrics.outcome;
    return {
      id: task.id || `task-${index + 1}`,
      title: task.title || `Task ${index + 1}`,
      summary: task.summary || "",
      goalId: task.goalId,
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
}

// Build the goal grouping over the flat task list. Prefers the supplied goals
// (matching by taskIds or each task's goalId), sweeps any leftover tasks into an
// "Other activity" goal, and falls back to a heuristic grouping if none exist.
// Mutates each task with its resolved `goalId`.
export function buildGoals(rawGoals, tasks) {
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

// Heuristic grouping when no usable goals exist (or for the offline analyzer):
// cluster tasks by their dominant inferred verb, then app.
export function deriveGoalsFromTasks(tasks) {
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
    models: null,
    warning,
    overview: `Recorded ${summary?.eventCount ?? events.length} events across ${summary?.dayCount ?? "an unknown number of"} day(s).`,
    performance: {
      summary: "The built-in analyzer groups activity by time gaps and app/window continuity. Set NEBIUS_API_KEY for richer, Nemotron-driven task analysis.",
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
    audioPath: event.audioPath || undefined,
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
