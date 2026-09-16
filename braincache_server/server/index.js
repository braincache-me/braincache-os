import fs from "node:fs/promises";
import { createReadStream } from "node:fs";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { buildDataset, resolveMediaPath } from "./activityParser.js";
import { inferTasks } from "./taskInference.js";
import { generateSkillMarkdown } from "./skillGenerator.js";
import {
  analyzeActivityWithAgentStream,
  generateSkillWithAgentStream,
  chatWithAgentStream
} from "./agentAnalyzer.js";
import * as projects from "./projectStore.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, "..");
const PUBLIC = path.join(ROOT, "public");
const PORT = Number(process.env.PORT || 8787);

// Load the repo-root .env so OPENAI_API_KEY is picked up without extra flags.
for (const candidate of [path.join(ROOT, ".env"), path.resolve(ROOT, "..", ".env")]) {
  try {
    process.loadEnvFile?.(candidate);
  } catch {
    // No .env at this location — fine.
  }
}

const DEFAULT_ACTIVITY_ROOT = process.env.BRAINCACHE_ACTIVITY_ROOT || "/Users/bespaloff/Documents/LogsActivity";

const server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url, `http://${req.headers.host}`);

    if (req.method === "GET" && url.pathname === "/api/health") {
      return sendJson(res, {
        ok: true,
        defaultActivityRoot: DEFAULT_ACTIVITY_ROOT,
        aiEnabled: Boolean(process.env.OPENAI_API_KEY),
        model: process.env.OPENAI_MODEL || "gpt-5.5"
      });
    }

    // ---- Projects -------------------------------------------------------
    if (url.pathname === "/api/projects" && req.method === "GET") {
      return sendJson(res, { projects: await projects.listProjects() });
    }

    if (url.pathname === "/api/projects" && req.method === "POST") {
      const body = await readJson(req);
      const project = await projects.createProject({
        name: body.name,
        activityRoot: body.activityRoot || DEFAULT_ACTIVITY_ROOT,
        gapMinutes: body.gapMinutes,
        targetGoals: body.targetGoals
      });
      return sendJson(res, { project }, 201);
    }

    const projectMatch = url.pathname.match(/^\/api\/projects\/([^/]+)(\/.*)?$/);
    if (projectMatch) {
      const projectId = decodeURIComponent(projectMatch[1]);
      const sub = projectMatch[2] || "";

      if (sub === "" && req.method === "GET") {
        return sendJson(res, { project: await projects.getProject(projectId) });
      }
      if (sub === "" && req.method === "PATCH") {
        const body = await readJson(req);
        return sendJson(res, { project: await projects.updateProject(projectId, body) });
      }
      if (sub === "" && req.method === "DELETE") {
        return sendJson(res, await projects.deleteProject(projectId));
      }

      if (sub === "/files" && req.method === "POST") {
        const body = await readJson(req);
        const files = Array.isArray(body.files) ? body.files : [];
        let project = await projects.getProject(projectId);
        for (const file of files) {
          project = await projects.addSource(projectId, { name: file.name, content: file.content });
        }
        return sendJson(res, { project });
      }

      if (sub === "/load-paths" && req.method === "POST") {
        const body = await readJson(req);
        const paths = Array.isArray(body.paths) ? body.paths : [];
        let project = await projects.getProject(projectId);
        for (const filePath of paths) {
          const resolved = path.resolve(String(filePath));
          const content = await fs.readFile(resolved, "utf8");
          project = await projects.addSource(projectId, { name: resolved, content });
        }
        return sendJson(res, { project });
      }

      if (sub === "/load-directory" && req.method === "POST") {
        const body = await readJson(req);
        const directory = path.resolve(String(body.directory || path.join(DEFAULT_ACTIVITY_ROOT, "logs")));
        const names = await fs.readdir(directory);
        const jsonlNames = names.filter((name) => /^\d{4}-\d{2}-\d{2}\.jsonl$/.test(name)).sort();
        const selected = jsonlNames.slice(-(Number(body.limitDays) || 31));
        let project = await projects.getProject(projectId);
        for (const name of selected) {
          const content = await fs.readFile(path.join(directory, name), "utf8");
          project = await projects.addSource(projectId, { name, content });
        }
        return sendJson(res, { project });
      }

      const fileMatch = sub.match(/^\/files\/([^/]+)$/);
      if (fileMatch && req.method === "DELETE") {
        const project = await projects.removeSource(projectId, decodeURIComponent(fileMatch[1]));
        return sendJson(res, { project });
      }

      // Initialize the project: run the agent over all its logs and infer tasks.
      if (sub === "/initialize" && req.method === "POST") {
        const body = await readJson(req).catch(() => ({}));
        const { project, dataset } = await projects.loadProjectDataset(projectId);
        if (!dataset.events.length) {
          return sendJson(res, { error: "This project has no events yet. Add log files first." }, 400);
        }
        const trace = [];
        const emit = traceEmit(openEventStream(res), trace);
        try {
          await emit({ type: "thinking", message: `Initializing “${project.name}” from ${project.files.length} file(s)…` });
          const analysis = await analyzeActivityWithAgentStream(
            {
              events: dataset.events,
              summary: dataset.summary,
              activityRoot: project.activityRoot || DEFAULT_ACTIVITY_ROOT,
              model: body.model || process.env.OPENAI_MODEL,
              targetGoals: project.targetGoals || []
            },
            emit
          );
          await projects.saveAnalysis(projectId, analysis);
          const saved = await projects.saveRun(projectId, { kind: "initialize", trace });
          await emit({ type: "saved", project: saved });
        } catch (error) {
          await emit({ type: "error", message: error.message });
        } finally {
          res.end();
        }
        return;
      }

      // Chat / follow-up: ask questions about the logs and extracted tasks.
      if (sub === "/chat" && req.method === "POST") {
        const body = await readJson(req);
        const message = String(body.message || "").trim();
        if (!message) return sendJson(res, { error: "Empty message." }, 400);
        const { project, dataset } = await projects.loadProjectDataset(projectId);
        const history = project.conversation || [];
        await projects.appendMessage(projectId, { role: "user", content: message });
        const trace = [];
        const emit = traceEmit(openEventStream(res), trace);
        try {
          const result = await chatWithAgentStream(
            {
              events: dataset.events,
              activityRoot: project.activityRoot || DEFAULT_ACTIVITY_ROOT,
              model: body.model || process.env.OPENAI_MODEL,
              history,
              message,
              analysis: project.analysis
            },
            emit
          );
          const { project: saved } = await projects.appendMessage(projectId, {
            role: "assistant",
            content: result.answer,
            toolTrace: trace
          });
          await emit({ type: "saved", project: saved });
        } catch (error) {
          await emit({ type: "error", message: error.message });
        } finally {
          res.end();
        }
        return;
      }

      // Manually edit a generated goal-level skill's markdown.
      const goalSkillMatch = sub.match(/^\/goals\/([^/]+)\/skill$/);
      if (goalSkillMatch && req.method === "PATCH") {
        const goalId = decodeURIComponent(goalSkillMatch[1]);
        const body = await readJson(req);
        const saved = await projects.updateSkill(projectId, goalId, { markdown: body.markdown });
        return sendJson(res, { project: saved });
      }

      // Generate a reusable skill for a whole business goal, across all grouped tasks.
      if (goalSkillMatch && req.method === "POST") {
        const goalId = decodeURIComponent(goalSkillMatch[1]);
        const body = await readJson(req).catch(() => ({}));
        const { project, dataset } = await projects.loadProjectDataset(projectId);
        const goal = project.analysis?.goals?.find((item) => item.id === goalId);
        if (!goal) return sendJson(res, { error: "Goal not found. Initialize the project first." }, 404);
        const tasks = project.analysis?.tasks || [];
        const goalTasks = (goal.taskIds || []).map((id) => tasks.find((task) => task.id === id)).filter(Boolean);
        if (!goalTasks.length) return sendJson(res, { error: "This goal has no grouped tasks to generalize." }, 400);
        const task = buildGoalSkillTask(goal, goalTasks);
        const emit = openEventStream(res);
        try {
          const result = await generateSkillWithAgentStream(
            {
              task,
              goal: { title: goal.title, summary: goal.summary },
              events: dataset.events,
              activityRoot: project.activityRoot || DEFAULT_ACTIVITY_ROOT,
              model: body.model || process.env.OPENAI_MODEL
            },
            emit
          );
          const saved = await projects.saveSkill(projectId, goalId, result);
          await emit({ type: "saved", project: saved });
        } catch (error) {
          await emit({ type: "error", message: error.message });
        } finally {
          res.end();
        }
        return;
      }

      // Edit an extracted task (process).
      const taskEditMatch = sub.match(/^\/tasks\/([^/]+)$/);
      if (taskEditMatch && req.method === "PATCH") {
        const taskId = decodeURIComponent(taskEditMatch[1]);
        const body = await readJson(req);
        const saved = await projects.updateTask(projectId, taskId, {
          title: body.title,
          summary: body.summary,
          steps: body.steps
        });
        return sendJson(res, { project: saved });
      }

      // Manually edit a generated skill's markdown.
      const skillMatch = sub.match(/^\/tasks\/([^/]+)\/skill$/);
      if (skillMatch && req.method === "PATCH") {
        const taskId = decodeURIComponent(skillMatch[1]);
        const body = await readJson(req);
        const saved = await projects.updateSkill(projectId, taskId, { markdown: body.markdown });
        return sendJson(res, { project: saved });
      }

      // Generate a reusable skill for one inferred task (agentic).
      if (skillMatch && req.method === "POST") {
        const taskId = decodeURIComponent(skillMatch[1]);
        const body = await readJson(req).catch(() => ({}));
        const { project, dataset } = await projects.loadProjectDataset(projectId);
        const task = project.analysis?.tasks?.find((item) => item.id === taskId);
        if (!task) return sendJson(res, { error: "Task not found. Initialize the project first." }, 404);
        const goal = project.analysis?.goals?.find((g) => g.id === task.goalId || (g.taskIds || []).includes(taskId));
        const emit = openEventStream(res);
        try {
          const result = await generateSkillWithAgentStream(
            {
              task,
              goal: goal ? { title: goal.title, summary: goal.summary } : null,
              events: dataset.events,
              activityRoot: project.activityRoot || DEFAULT_ACTIVITY_ROOT,
              model: body.model || process.env.OPENAI_MODEL
            },
            emit
          );
          const saved = await projects.saveSkill(projectId, taskId, result);
          await emit({ type: "saved", project: saved });
        } catch (error) {
          await emit({ type: "error", message: error.message });
        } finally {
          res.end();
        }
        return;
      }
    }

    if (req.method === "POST" && url.pathname === "/api/analyze") {
      const body = await readJson(req);
      const files = Array.isArray(body.files) ? body.files : [];
      const dataset = buildDataset(files);
      const tasks = inferTasks(dataset.events, { gapMinutes: body.gapMinutes });
      return sendJson(res, { ...dataset, tasks });
    }

    if (req.method === "POST" && url.pathname === "/api/load-paths") {
      const body = await readJson(req);
      const paths = Array.isArray(body.paths) ? body.paths : [];
      const files = await Promise.all(paths.map(async (filePath) => {
        const resolved = path.resolve(String(filePath));
        return {
          name: resolved,
          content: await fs.readFile(resolved, "utf8")
        };
      }));
      const dataset = buildDataset(files);
      const tasks = inferTasks(dataset.events, { gapMinutes: body.gapMinutes });
      return sendJson(res, { ...dataset, tasks });
    }

    if (req.method === "POST" && url.pathname === "/api/load-directory") {
      const body = await readJson(req);
      const directory = path.resolve(String(body.directory || path.join(DEFAULT_ACTIVITY_ROOT, "logs")));
      const names = await fs.readdir(directory);
      const jsonlNames = names.filter((name) => /^\d{4}-\d{2}-\d{2}\.jsonl$/.test(name)).sort();
      const selected = jsonlNames.slice(-(Number(body.limitDays) || 31));
      const files = await Promise.all(selected.map(async (name) => {
        const filePath = path.join(directory, name);
        return { name: filePath, content: await fs.readFile(filePath, "utf8") };
      }));
      const dataset = buildDataset(files);
      const tasks = inferTasks(dataset.events, { gapMinutes: body.gapMinutes });
      return sendJson(res, { ...dataset, tasks, loadedFiles: selected.map((name) => path.join(directory, name)) });
    }

    if (req.method === "POST" && url.pathname === "/api/skill") {
      const body = await readJson(req);
      return sendText(res, generateSkillMarkdown(body.task, body.options), "text/markdown; charset=utf-8");
    }

    if (req.method === "POST" && url.pathname === "/api/agent-analyze-stream") {
      const body = await readJson(req);
      const events = Array.isArray(body.events) ? body.events : [];
      const summary = body.summary || {};
      const activityRoot = body.activityRoot || DEFAULT_ACTIVITY_ROOT;
      const model = body.model || process.env.OPENAI_MODEL || "gpt-5.5";
      const emit = openEventStream(res);
      try {
        await analyzeActivityWithAgentStream({ events, summary, activityRoot, model }, emit);
      } catch (error) {
        await emit({ type: "error", message: error.message });
      } finally {
        res.end();
      }
      return;
    }

    if (req.method === "GET" && url.pathname === "/api/transcript") {
      const activityRoot = url.searchParams.get("root") || DEFAULT_ACTIVITY_ROOT;
      const relativePath = url.searchParams.get("path");
      const filePath = resolveMediaPath(activityRoot, "transcripts", relativePath);
      if (!filePath) return sendJson(res, { error: "Invalid transcript path." }, 400);
      return sendText(res, await fs.readFile(filePath, "utf8"), "text/plain; charset=utf-8");
    }

    if (req.method === "GET" && url.pathname === "/media") {
      const activityRoot = url.searchParams.get("root") || DEFAULT_ACTIVITY_ROOT;
      const kind = url.searchParams.get("kind") || "screenshots";
      const relativePath = url.searchParams.get("path");
      const filePath = resolveMediaPath(activityRoot, kind, relativePath);
      if (!filePath) return sendJson(res, { error: "Invalid media path." }, 400);
      return streamFile(res, filePath);
    }

    if (req.method === "GET") {
      return serveStatic(res, url.pathname);
    }

    sendJson(res, { error: "Not found." }, 404);
  } catch (error) {
    sendJson(res, { error: error.message }, 500);
  }
});

server.listen(PORT, () => {
  console.log(`BrainCache Server running at http://127.0.0.1:${PORT}`);
});

async function readJson(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(chunk);
  const raw = Buffer.concat(chunks).toString("utf8");
  return raw ? JSON.parse(raw) : {};
}

function sendJson(res, payload, status = 200) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body)
  });
  res.end(body);
}

// Open a Server-Sent Events stream and return an `emit(event)` function that
// writes one timestamped JSON event per SSE frame.
function openEventStream(res) {
  res.writeHead(200, {
    "content-type": "text/event-stream; charset=utf-8",
    "cache-control": "no-cache, no-transform",
    connection: "keep-alive",
    "x-accel-buffering": "no"
  });
  return async (event) => {
    res.write(`data: ${JSON.stringify({ timestamp: new Date().toISOString(), ...event })}\n\n`);
  };
}

// Wrap an emit() so progress events are also collected into `trace` (a compact
// form, dropping bulky tool payloads) for persistence as run/chat history.
function traceEmit(emit, trace) {
  return async (event) => {
    if (["thinking", "tool_call", "tool_output", "error"].includes(event.type)) {
      trace.push({ type: event.type, message: event.message, name: event.name, arguments: event.arguments });
    }
    return emit(event);
  };
}

function sendText(res, body, contentType, status = 200) {
  res.writeHead(status, {
    "content-type": contentType,
    "content-length": Buffer.byteLength(body)
  });
  res.end(body);
}

function buildGoalSkillTask(goal, tasks) {
  const appCounts = new Map();
  const eventTypeCounts = new Map();
  const eventIds = new Set();
  const events = [];
  const steps = [];
  let screenshotCount = 0;
  let transcriptCount = 0;
  let actionCount = 0;

  for (const task of tasks) {
    screenshotCount += Number(task.screenshotCount || 0);
    transcriptCount += Number(task.transcriptCount || 0);
    actionCount += Number(task.actionCount || task.metrics?.actions || 0);

    for (const app of task.apps || []) {
      const name = app.name || app;
      if (!name) continue;
      appCounts.set(name, (appCounts.get(name) || 0) + Number(app.count || 1));
    }
    for (const eventType of task.eventTypes || []) {
      const name = eventType.name || eventType;
      if (!name) continue;
      eventTypeCounts.set(name, (eventTypeCounts.get(name) || 0) + Number(eventType.count || 1));
    }
    for (const event of task.events || []) {
      events.push(event);
      if (event.id) eventIds.add(event.id);
    }
    for (const step of task.steps || []) {
      steps.push({
        ...step,
        label: step.label || `Work step from ${task.title}`,
        notes: [step.notes, `Observed in example task: ${task.title}`].filter(Boolean).join(" ")
      });
      if (step.evidenceEventId) eventIds.add(step.evidenceEventId);
    }
  }

  return {
    id: goal.id,
    title: goal.title,
    summary: goal.summary || `Generalized from ${tasks.length} observed task runs.`,
    apps: [...appCounts.entries()].map(([name, count]) => ({ name, count })).sort((a, b) => b.count - a.count),
    eventTypes: [...eventTypeCounts.entries()].map(([name, count]) => ({ name, count })).sort((a, b) => b.count - a.count),
    events,
    eventIds: [...eventIds],
    steps,
    screenshotCount,
    transcriptCount,
    actionCount,
    attempts: tasks.reduce((sum, task) => sum + Number(task.attempts || 1), 0),
    metrics: {
      actions: actionCount,
      corrections: tasks.reduce((sum, task) => sum + Number(task.metrics?.corrections || 0), 0),
      appSwitches: tasks.reduce((sum, task) => sum + Number(task.metrics?.appSwitches || 0), 0)
    }
  };
}

async function serveStatic(res, pathname) {
  const cleanPath = pathname === "/" ? "/index.html" : pathname;
  const filePath = path.resolve(PUBLIC, `.${decodeURIComponent(cleanPath)}`);
  if (!filePath.startsWith(PUBLIC + path.sep) && filePath !== PUBLIC) {
    return sendJson(res, { error: "Forbidden." }, 403);
  }
  try {
    return await streamFile(res, filePath);
  } catch {
    return await streamFile(res, path.join(PUBLIC, "index.html"));
  }
}

async function streamFile(res, filePath) {
  const stat = await fs.stat(filePath);
  const contentType = contentTypeFor(filePath);
  res.writeHead(200, {
    "content-type": contentType,
    "content-length": stat.size
  });
  createReadStream(filePath).pipe(res);
}

function contentTypeFor(filePath) {
  const ext = path.extname(filePath).toLowerCase();
  return {
    ".html": "text/html; charset=utf-8",
    ".js": "text/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".json": "application/json; charset=utf-8",
    ".svg": "image/svg+xml",
    ".png": "image/png",
    ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg",
    ".txt": "text/plain; charset=utf-8",
    ".md": "text/markdown; charset=utf-8"
  }[ext] || "application/octet-stream";
}
