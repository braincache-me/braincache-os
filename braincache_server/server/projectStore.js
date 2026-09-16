import { DatabaseSync } from "node:sqlite";
import { mkdirSync } from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";
import { buildDataset } from "./activityParser.js";

// Projects are persisted in a single SQLite database (Node's built-in
// `node:sqlite` — no external dependency). Schema:
//   projects  — one row per project; analysis + lastRun kept as JSON columns
//   sources   — one row per uploaded log file (raw JSONL stored as TEXT)
//   skills    — one row per (project, task) generated skill
//   messages  — chat conversation, ordered by rowid
//
// All exported functions are async (returning sync results) so the rest of the
// app can keep awaiting them unchanged.

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const DATA_ROOT = process.env.BRAINCACHE_DATA_ROOT || path.resolve(__dirname, "..", "data");
const DB_PATH = process.env.BRAINCACHE_DB_PATH || path.join(DATA_ROOT, "braincache.db");

let db = null;

function getDb() {
  if (db) return db;
  mkdirSync(path.dirname(DB_PATH), { recursive: true });
  db = new DatabaseSync(DB_PATH);
  db.exec("PRAGMA foreign_keys = ON;");
  db.exec("PRAGMA journal_mode = WAL;");
  db.exec(`
    CREATE TABLE IF NOT EXISTS projects (
      id TEXT PRIMARY KEY,
      name TEXT NOT NULL,
      status TEXT NOT NULL,
      activity_root TEXT,
      gap_minutes INTEGER,
      created_at TEXT NOT NULL,
      updated_at TEXT NOT NULL,
      analysis_json TEXT,
      last_run_json TEXT
    );
    CREATE TABLE IF NOT EXISTS sources (
      id TEXT PRIMARY KEY,
      project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      name TEXT NOT NULL,
      added_at TEXT NOT NULL,
      size INTEGER,
      event_count INTEGER,
      error_count INTEGER,
      content TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS skills (
      project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      task_id TEXT NOT NULL,
      markdown TEXT,
      source TEXT,
      model TEXT,
      generated_at TEXT,
      PRIMARY KEY (project_id, task_id)
    );
    CREATE TABLE IF NOT EXISTS messages (
      id TEXT PRIMARY KEY,
      project_id TEXT NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
      role TEXT NOT NULL,
      content TEXT NOT NULL,
      tool_trace_json TEXT,
      created_at TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_sources_project ON sources(project_id);
    CREATE INDEX IF NOT EXISTS idx_messages_project ON messages(project_id);
  `);
  // Migration: user-defined target goals (added later; ALTER preserves existing data).
  const columns = db.prepare("PRAGMA table_info(projects)").all().map((c) => c.name);
  if (!columns.includes("target_goals_json")) {
    db.exec("ALTER TABLE projects ADD COLUMN target_goals_json TEXT");
  }
  // Migration: manual skill edits (added later).
  const skillColumns = db.prepare("PRAGMA table_info(skills)").all().map((c) => c.name);
  if (!skillColumns.includes("edited_at")) {
    db.exec("ALTER TABLE skills ADD COLUMN edited_at TEXT");
  }
  return db;
}

function parseTargetGoals(value) {
  if (!Array.isArray(value)) {
    value = String(value || "").split("\n");
  }
  return value.map((g) => String(g).trim()).filter(Boolean).slice(0, 20);
}

function newId(prefix) {
  return `${prefix}_${crypto.randomUUID().slice(0, 8)}`;
}

function now() {
  return new Date().toISOString();
}

function touch(id) {
  getDb().prepare("UPDATE projects SET updated_at = ? WHERE id = ?").run(now(), id);
}

function getRow(id) {
  return getDb().prepare("SELECT * FROM projects WHERE id = ?").get(id);
}

// Reconstruct the in-memory project shape the rest of the app expects
// (source file metadata only — never the raw content).
function hydrate(row) {
  if (!row) return null;
  const database = getDb();
  const files = database
    .prepare("SELECT id, name, added_at, size, event_count, error_count FROM sources WHERE project_id = ? ORDER BY rowid")
    .all(row.id)
    .map((r) => ({ id: r.id, name: r.name, addedAt: r.added_at, size: r.size, eventCount: r.event_count, errorCount: r.error_count }));

  const skills = {};
  for (const s of database.prepare("SELECT task_id, markdown, source, model, generated_at, edited_at FROM skills WHERE project_id = ?").all(row.id)) {
    skills[s.task_id] = { markdown: s.markdown, source: s.source, model: s.model || undefined, generatedAt: s.generated_at, editedAt: s.edited_at || undefined };
  }

  const conversation = database
    .prepare("SELECT id, role, content, tool_trace_json, created_at FROM messages WHERE project_id = ? ORDER BY rowid")
    .all(row.id)
    .map((m) => ({
      id: m.id,
      role: m.role,
      content: m.content,
      toolTrace: m.tool_trace_json ? JSON.parse(m.tool_trace_json) : undefined,
      createdAt: m.created_at
    }));

  return {
    id: row.id,
    name: row.name,
    status: row.status,
    activityRoot: row.activity_root,
    gapMinutes: row.gap_minutes,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
    files,
    targetGoals: row.target_goals_json ? JSON.parse(row.target_goals_json) : [],
    analysis: row.analysis_json ? JSON.parse(row.analysis_json) : null,
    skills,
    conversation,
    lastRun: row.last_run_json ? JSON.parse(row.last_run_json) : null
  };
}

function requireProject(id) {
  const row = getRow(id);
  if (!row) throw new Error("Project not found.");
  return row;
}

// ---------------------------------------------------------------------------
// Public API (mirrors the previous file-based store)
// ---------------------------------------------------------------------------

export async function listProjects() {
  const rows = getDb().prepare(`
    SELECT p.*,
      (SELECT COUNT(*) FROM sources s WHERE s.project_id = p.id) AS file_count,
      (SELECT COALESCE(SUM(event_count), 0) FROM sources s WHERE s.project_id = p.id) AS event_count
    FROM projects p
    ORDER BY p.updated_at DESC
  `).all();

  return rows.map((row) => {
    const analysis = row.analysis_json ? JSON.parse(row.analysis_json) : null;
    return {
      id: row.id,
      name: row.name,
      status: row.status,
      activityRoot: row.activity_root,
      gapMinutes: row.gap_minutes,
      createdAt: row.created_at,
      updatedAt: row.updated_at,
      fileCount: row.file_count,
      eventCount: row.event_count,
      taskCount: analysis?.tasks?.length || 0,
      analyzedAt: analysis?.generatedAt || null,
      analysisSource: analysis?.source || null
    };
  });
}

export async function createProject({ name, activityRoot, gapMinutes, targetGoals } = {}) {
  const id = newId("proj");
  const ts = now();
  getDb().prepare(`
    INSERT INTO projects (id, name, status, activity_root, gap_minutes, created_at, updated_at, target_goals_json)
    VALUES (?, ?, 'draft', ?, ?, ?, ?, ?)
  `).run(
    id,
    String(name || "Untitled project").trim() || "Untitled project",
    activityRoot || process.env.BRAINCACHE_ACTIVITY_ROOT || "",
    Number(gapMinutes) || 10,
    ts,
    ts,
    JSON.stringify(parseTargetGoals(targetGoals))
  );
  return hydrate(getRow(id));
}

export async function getProject(id) {
  return hydrate(requireProject(id));
}

export async function updateProject(id, patch = {}) {
  const row = requireProject(id);
  getDb().prepare("UPDATE projects SET name = ?, activity_root = ?, gap_minutes = ?, target_goals_json = ?, updated_at = ? WHERE id = ?").run(
    patch.name !== undefined ? (String(patch.name).trim() || row.name) : row.name,
    patch.activityRoot !== undefined ? patch.activityRoot : row.activity_root,
    patch.gapMinutes !== undefined ? (Number(patch.gapMinutes) || row.gap_minutes) : row.gap_minutes,
    patch.targetGoals !== undefined ? JSON.stringify(parseTargetGoals(patch.targetGoals)) : row.target_goals_json,
    now(),
    id
  );
  return hydrate(getRow(id));
}

export async function deleteProject(id) {
  getDb().prepare("DELETE FROM projects WHERE id = ?").run(id);
  return { ok: true };
}

export async function addSource(id, { name, content }) {
  const row = requireProject(id);
  const sourceId = newId("src");
  const safeName = String(name || `${sourceId}.jsonl`);
  const text = String(content ?? "");
  const dataset = buildDataset([{ name: safeName, content: text }]);

  getDb().prepare(`
    INSERT INTO sources (id, project_id, name, added_at, size, event_count, error_count, content)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
  `).run(sourceId, id, safeName, now(), Buffer.byteLength(text), dataset.summary.eventCount, dataset.errors.length, text);

  // Adding new data invalidates a prior analysis.
  if (row.status === "initialized") {
    getDb().prepare("UPDATE projects SET status = 'ready' WHERE id = ?").run(id);
  }
  touch(id);
  return hydrate(getRow(id));
}

export async function removeSource(id, sourceId) {
  const row = requireProject(id);
  getDb().prepare("DELETE FROM sources WHERE id = ? AND project_id = ?").run(sourceId, id);
  if (row.status === "initialized") {
    getDb().prepare("UPDATE projects SET status = 'ready' WHERE id = ?").run(id);
  }
  touch(id);
  return hydrate(getRow(id));
}

// Load and merge every source file into one dataset for analysis.
export async function loadProjectDataset(id) {
  const project = hydrate(requireProject(id));
  const rows = getDb().prepare("SELECT name, content FROM sources WHERE project_id = ? ORDER BY rowid").all(id);
  const dataset = buildDataset(rows.map((r) => ({ name: r.name, content: r.content })));
  return { project, dataset };
}

export async function saveAnalysis(id, analysis) {
  requireProject(id);
  const stored = { ...analysis, generatedAt: now() };
  getDb().prepare("UPDATE projects SET analysis_json = ?, status = 'initialized', updated_at = ? WHERE id = ?")
    .run(JSON.stringify(stored), now(), id);
  return hydrate(getRow(id));
}

export async function saveSkill(id, taskId, skill) {
  requireProject(id);
  // A regenerate replaces any manual edits, so the edited marker is cleared.
  getDb().prepare(`
    INSERT INTO skills (project_id, task_id, markdown, source, model, generated_at, edited_at)
    VALUES (?, ?, ?, ?, ?, ?, NULL)
    ON CONFLICT(project_id, task_id) DO UPDATE SET
      markdown = excluded.markdown, source = excluded.source, model = excluded.model,
      generated_at = excluded.generated_at, edited_at = NULL
  `).run(id, taskId, skill.markdown, skill.source || null, skill.model || null, now());
  touch(id);
  return hydrate(getRow(id));
}

// Manual edit of a generated skill's markdown.
export async function updateSkill(id, taskId, patch = {}) {
  requireProject(id);
  const markdown = String(patch.markdown ?? "");
  if (!markdown.trim()) throw new Error("Skill markdown cannot be empty.");
  const result = getDb().prepare("UPDATE skills SET markdown = ?, edited_at = ? WHERE project_id = ? AND task_id = ?")
    .run(markdown, now(), id, taskId);
  if (!result.changes) throw new Error("Skill not found. Generate it first.");
  touch(id);
  return hydrate(getRow(id));
}

// Append one chat message ({ role, content, toolTrace? }) to the conversation.
export async function appendMessage(id, message) {
  requireProject(id);
  const stored = { id: newId("msg"), createdAt: now(), ...message };
  getDb().prepare("INSERT INTO messages (id, project_id, role, content, tool_trace_json, created_at) VALUES (?, ?, ?, ?, ?, ?)")
    .run(stored.id, id, stored.role, stored.content, message.toolTrace ? JSON.stringify(message.toolTrace) : null, stored.createdAt);
  touch(id);
  return { project: hydrate(getRow(id)), message: stored };
}

// Persist the trace of the most recent agent run so the Agent tab survives reload.
export async function saveRun(id, run) {
  requireProject(id);
  getDb().prepare("UPDATE projects SET last_run_json = ?, updated_at = ? WHERE id = ?")
    .run(JSON.stringify({ ...run, at: now() }), now(), id);
  return hydrate(getRow(id));
}

// Edit an extracted task (process): title, summary, and/or steps.
export async function updateTask(id, taskId, patch = {}) {
  const row = requireProject(id);
  const analysis = row.analysis_json ? JSON.parse(row.analysis_json) : null;
  if (!analysis?.tasks?.length) throw new Error("This project has no analysis yet.");
  let found = false;
  analysis.tasks = analysis.tasks.map((task) => {
    if (task.id !== taskId) return task;
    found = true;
    const next = { ...task };
    if (patch.title !== undefined) next.title = String(patch.title);
    if (patch.summary !== undefined) next.summary = String(patch.summary);
    if (Array.isArray(patch.steps)) next.steps = patch.steps;
    next.edited = true;
    return next;
  });
  if (!found) throw new Error("Task not found.");
  getDb().prepare("UPDATE projects SET analysis_json = ?, updated_at = ? WHERE id = ?")
    .run(JSON.stringify(analysis), now(), id);
  return hydrate(getRow(id));
}

export async function setStatus(id, status) {
  requireProject(id);
  getDb().prepare("UPDATE projects SET status = ?, updated_at = ? WHERE id = ?").run(status, now(), id);
  return hydrate(getRow(id));
}
