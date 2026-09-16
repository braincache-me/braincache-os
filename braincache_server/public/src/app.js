import React, { useEffect, useMemo, useRef, useState } from "react";
import { createRoot } from "react-dom/client";
import { appMeta, friendlyEventLabel, friendlyEventType, outcomeMeta } from "./labels.js";

const h = React.createElement;

// ===========================================================================
// API helpers
// ===========================================================================

async function api(path, { method = "GET", body } = {}) {
  const response = await fetch(path, {
    method,
    headers: body ? { "content-type": "application/json" } : undefined,
    body: body ? JSON.stringify(body) : undefined
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(data.error || `Request failed (${response.status}).`);
  return data;
}

async function streamPost(path, body, onEvent) {
  const response = await fetch(path, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body || {})
  });
  if (!response.ok || !response.body) throw new Error("The agent stream could not start.");
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  while (true) {
    const { value, done } = await reader.read();
    if (done) break;
    buffer += decoder.decode(value, { stream: true });
    const parts = buffer.split("\n\n");
    buffer = parts.pop() || "";
    for (const part of parts) emitPart(part, onEvent);
  }
  if (buffer.trim()) emitPart(buffer, onEvent);
}

function emitPart(part, onEvent) {
  const dataLines = part.split("\n").filter((line) => line.startsWith("data: ")).map((line) => line.slice(6));
  if (!dataLines.length) return;
  try {
    onEvent(JSON.parse(dataLines.join("\n")));
  } catch {
    onEvent({ type: "error", message: "Could not read a stream event." });
  }
}

// ===========================================================================
// Root
// ===========================================================================

function App() {
  const [health, setHealth] = useState({ aiEnabled: false, model: "gpt-5.5", defaultActivityRoot: "" });
  const [projects, setProjects] = useState([]);
  const [project, setProject] = useState(null);
  const [loadingProject, setLoadingProject] = useState(false);

  useEffect(() => {
    api("/api/health").then(setHealth).catch(() => {});
    refreshProjects();
  }, []);

  async function refreshProjects() {
    try {
      const data = await api("/api/projects");
      setProjects(data.projects || []);
    } catch {
      setProjects([]);
    }
  }

  async function openProject(id) {
    setLoadingProject(true);
    try {
      const data = await api(`/api/projects/${id}`);
      setProject(data.project);
    } finally {
      setLoadingProject(false);
    }
  }

  async function createProject(name) {
    const data = await api("/api/projects", {
      method: "POST",
      body: { name, activityRoot: health.defaultActivityRoot }
    });
    await refreshProjects();
    setProject(data.project);
  }

  async function deleteProject(id) {
    await api(`/api/projects/${id}`, { method: "DELETE" });
    if (project?.id === id) setProject(null);
    await refreshProjects();
  }

  return h("div", { className: "app" },
    h(Sidebar, {
      health,
      projects,
      activeId: project?.id,
      onSelect: openProject,
      onCreate: createProject,
      onDelete: deleteProject
    }),
    h("main", { className: "main" },
      loadingProject
        ? h(CenteredNote, { title: "Opening project…" })
        : project
          ? h(ProjectView, { project, setProject, onChanged: refreshProjects, health })
          : h(Welcome, { onCreate: createProject, hasProjects: projects.length > 0 })
    )
  );
}

// ===========================================================================
// Sidebar
// ===========================================================================

function Sidebar({ health, projects, activeId, onSelect, onCreate, onDelete }) {
  const [creating, setCreating] = useState(false);
  const [name, setName] = useState("");

  function submit(event) {
    event.preventDefault();
    const trimmed = name.trim();
    if (!trimmed) return;
    onCreate(trimmed);
    setName("");
    setCreating(false);
  }

  return h("aside", { className: "sidebar" },
    h("div", { className: "brand" },
      h("div", { className: "brand-mark" }, "B"),
      h("div", null,
        h("div", { className: "brand-name" }, "BrainCache"),
        h("div", { className: "brand-sub" }, "Workflow Studio")
      )
    ),
    h("div", { className: "sidebar-section-title" },
      h("span", null, "Projects"),
      h("button", { className: "icon-btn", title: "New project", onClick: () => setCreating((value) => !value) }, "+")
    ),
    creating
      ? h("form", { className: "new-project", onSubmit: submit },
          h("input", {
            autoFocus: true,
            value: name,
            placeholder: "Project name",
            onChange: (event) => setName(event.target.value),
            onKeyDown: (event) => event.key === "Escape" && setCreating(false)
          }),
          h("button", { className: "btn primary sm", type: "submit" }, "Create")
        )
      : null,
    h("div", { className: "project-list" },
      projects.length
        ? projects.map((item) => h(ProjectRow, {
            key: item.id,
            project: item,
            active: item.id === activeId,
            onSelect: () => onSelect(item.id),
            onDelete: () => onDelete(item.id)
          }))
        : h("div", { className: "sidebar-empty" }, "No projects yet. Create one to begin.")
    ),
    h("div", { className: "sidebar-footer" },
      h("span", { className: `dot ${health.aiEnabled ? "ok" : "off"}` }),
      health.aiEnabled ? `AI ready · ${health.model}` : "AI key not set"
    )
  );
}

function ProjectRow({ project, active, onSelect, onDelete }) {
  return h("div", { className: `project-row ${active ? "active" : ""}`, onClick: onSelect },
    h("div", { className: "project-row-main" },
      h("div", { className: "project-row-name" }, project.name),
      h("div", { className: "project-row-meta" },
        h(StatusBadge, { status: project.status }),
        h("span", null, `${project.fileCount} file${project.fileCount === 1 ? "" : "s"}`),
        project.taskCount ? h("span", null, `${project.taskCount} task${project.taskCount === 1 ? "" : "s"}`) : null
      )
    ),
    h("button", {
      className: "row-delete",
      title: "Delete project",
      onClick: (event) => { event.stopPropagation(); if (confirm(`Delete “${project.name}”?`)) onDelete(); }
    }, "×")
  );
}

function StatusBadge({ status }) {
  const meta = {
    draft: { label: "Draft", cls: "muted" },
    ready: { label: "Ready to analyze", cls: "amber" },
    initialized: { label: "Analyzed", cls: "green" },
    error: { label: "Error", cls: "red" }
  }[status] || { label: status, cls: "muted" };
  return h("span", { className: `badge ${meta.cls}` }, meta.label);
}

// ===========================================================================
// Welcome / empty states
// ===========================================================================

function Welcome({ onCreate, hasProjects }) {
  const [name, setName] = useState("");
  return h("div", { className: "welcome" },
    h("div", { className: "welcome-card" },
      h("h1", null, "Turn recorded work into reusable skills"),
      h("p", null, "Create a project, add Activity Capture log files, and let the agent map what you were doing — then turn any task into an automation-ready skill."),
      h("form", { className: "welcome-form", onSubmit: (event) => { event.preventDefault(); if (name.trim()) onCreate(name.trim()); } },
        h("input", { value: name, placeholder: "Name your first project", onChange: (event) => setName(event.target.value) }),
        h("button", { className: "btn primary", type: "submit", disabled: !name.trim() }, "Create project")
      ),
      h("ol", { className: "welcome-steps" },
        h("li", null, h("strong", null, "Add logs"), " — drop in one or more JSONL files."),
        h("li", null, h("strong", null, "Initialize"), " — the agent reads them and finds your tasks."),
        h("li", null, h("strong", null, "Review & build"), " — inspect each task and generate a skill.")
      )
    )
  );
}

function CenteredNote({ title, children }) {
  return h("div", { className: "welcome" }, h("div", { className: "welcome-card" }, h("h1", null, title), children || null));
}

// ===========================================================================
// Project view
// ===========================================================================

function ProjectView({ project, setProject, onChanged, health }) {
  const [stream, setStream] = useState([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [selectedTaskId, setSelectedTaskId] = useState(project.analysis?.tasks?.[0]?.id || null);
  const [activeTab, setActiveTab] = useState(project.analysis ? "results" : "logs");

  useEffect(() => {
    setSelectedTaskId(project.analysis?.tasks?.[0]?.id || null);
    setActiveTab(project.analysis ? "results" : "logs");
    setStream([]);
  }, [project.id]);

  const tasks = project.analysis?.tasks || [];
  const selectedTask = useMemo(
    () => tasks.find((task) => task.id === selectedTaskId) || tasks[0] || null,
    [tasks, selectedTaskId]
  );

  async function addFiles(fileList) {
    setError("");
    setBusy(true);
    try {
      const files = await Promise.all([...fileList].map(async (file) => ({ name: file.name, content: await file.text() })));
      const data = await api(`/api/projects/${project.id}/files`, { method: "POST", body: { files } });
      setProject(data.project);
      onChanged();
    } catch (err) {
      setError(err.message);
    } finally {
      setBusy(false);
    }
  }

  async function addByPaths(text) {
    const paths = text.split(/\n|,/).map((line) => line.trim()).filter(Boolean);
    if (!paths.length) return;
    setError(""); setBusy(true);
    try {
      const data = await api(`/api/projects/${project.id}/load-paths`, { method: "POST", body: { paths } });
      setProject(data.project); onChanged();
    } catch (err) { setError(err.message); } finally { setBusy(false); }
  }

  async function addDirectory(directory) {
    setError(""); setBusy(true);
    try {
      const data = await api(`/api/projects/${project.id}/load-directory`, { method: "POST", body: { directory, limitDays: 31 } });
      setProject(data.project); onChanged();
    } catch (err) { setError(err.message); } finally { setBusy(false); }
  }

  async function removeFile(fileId) {
    const data = await api(`/api/projects/${project.id}/files/${fileId}`, { method: "DELETE" });
    setProject(data.project); onChanged();
  }

  async function saveGoals(targetGoals) {
    const data = await api(`/api/projects/${project.id}`, { method: "PATCH", body: { targetGoals } });
    setProject(data.project); onChanged();
  }

  async function initialize() {
    setError("");
    setStream([]);
    setBusy(true);
    setActiveTab("agent");
    try {
      await streamPost(`/api/projects/${project.id}/initialize`, { model: health.model }, (event) => {
        setStream((current) => [...current, event]);
        if (event.type === "saved" && event.project) {
          setProject(event.project);
          setSelectedTaskId(event.project.analysis?.tasks?.[0]?.id || null);
          setActiveTab("results");
          onChanged();
        }
      });
    } catch (err) {
      setError(err.message);
    } finally {
      setBusy(false);
    }
  }

  const chatCount = (project.conversation || []).filter((message) => message.role === "user").length;
  const tabs = [
    { key: "logs", label: "Logs", badge: project.files.length || null },
    { key: "agent", label: "Agent", live: busy },
    { key: "summary", label: "Summary" },
    { key: "results", label: "Results", badge: tasks.length || null },
    { key: "chat", label: "Chat", badge: chatCount || null }
  ];

  return h("div", { className: `project ${activeTab === "results" ? "results-mode" : ""}` },
    h(ProjectHeader, { project, setProject, onChanged }),
    error ? h("div", { className: "banner error" }, error) : null,
    h("div", { className: "project-tabs" },
      tabs.map((tab) => h("button", {
        key: tab.key,
        className: `ptab ${activeTab === tab.key ? "active" : ""}`,
        onClick: () => setActiveTab(tab.key)
      },
        tab.live ? h("span", { className: "ptab-dot" }) : null,
        tab.label,
        tab.badge ? h("span", { className: "ptab-badge" }, tab.badge) : null
      ))
    ),
    h("div", { className: "project-body" },
      activeTab === "logs"
        ? h(SourcesPanel, { project, busy, onAddFiles: addFiles, onAddPaths: addByPaths, onAddDirectory: addDirectory, onRemove: removeFile, onInitialize: initialize, onSaveGoals: saveGoals, aiEnabled: health.aiEnabled })
        : null,
      activeTab === "agent"
        ? ((stream.length || project.lastRun?.trace?.length)
            ? h(AgentStream, { events: stream.length ? stream : project.lastRun.trace, title: busy ? "Initializing project" : "Last agent run" })
            : h("section", { className: "card" }, h("div", { className: "card-body" }, h("div", { className: "hint big" }, "No agent run yet. Add logs, then press “Initialize project”."))))
        : null,
      activeTab === "summary"
        ? (project.analysis
            ? h(Overview, { analysis: project.analysis, performance: project.analysis.performance || {}, goals: project.analysis.goals || [], tasks })
            : h(EmptyResults, { hasFiles: project.files.length > 0, busy }))
        : null,
      activeTab === "results"
        ? (tasks.length
            ? h(Results, { project, tasks, selectedTask, onSelectTask: setSelectedTaskId, setProject, onChanged, health })
            : h(EmptyResults, { hasFiles: project.files.length > 0, busy }))
        : null,
      activeTab === "chat"
        ? h(ChatPanel, { project, setProject, onChanged, health })
        : null
    )
  );
}

function ProjectHeader({ project, setProject, onChanged }) {
  const [editing, setEditing] = useState(false);
  const [name, setName] = useState(project.name);
  useEffect(() => setName(project.name), [project.name]);

  async function save() {
    setEditing(false);
    if (name.trim() && name !== project.name) {
      const data = await api(`/api/projects/${project.id}`, { method: "PATCH", body: { name: name.trim() } });
      setProject(data.project);
      onChanged();
    }
  }

  return h("header", { className: "project-header" },
    h("div", { className: "project-title" },
      editing
        ? h("input", { className: "title-input", autoFocus: true, value: name, onChange: (event) => setName(event.target.value), onBlur: save, onKeyDown: (event) => event.key === "Enter" && save() })
        : h("h1", { onClick: () => setEditing(true), title: "Click to rename" }, project.name),
      h(StatusBadge, { status: project.status })
    ),
    h("div", { className: "project-stats" },
      h("span", null, `${project.files.length} file${project.files.length === 1 ? "" : "s"}`),
      h("span", null, `${project.files.reduce((sum, file) => sum + (file.eventCount || 0), 0)} events`),
      project.analysis?.goals?.length ? h("span", null, `${project.analysis.goals.length} goals`) : null,
      project.analysis ? h("span", null, `${project.analysis.tasks?.length || 0} tasks`) : null,
      project.analysis?.source === "heuristic" ? h("span", { className: "warn-text" }, "built-in analyzer") : null
    )
  );
}

// ===========================================================================
// Sources panel
// ===========================================================================

function SourcesPanel({ project, busy, onAddFiles, onAddPaths, onAddDirectory, onRemove, onInitialize, onSaveGoals, aiEnabled }) {
  const [advanced, setAdvanced] = useState(false);
  const [pathText, setPathText] = useState("");
  const [dirText, setDirText] = useState(`${project.activityRoot || ""}/logs`.replace(/^\//, "/"));
  const [dragOver, setDragOver] = useState(false);
  const [goalsText, setGoalsText] = useState((project.targetGoals || []).join("\n"));
  const inputRef = useRef(null);

  useEffect(() => { setGoalsText((project.targetGoals || []).join("\n")); }, [project.id]);

  const analyzed = project.status === "initialized";

  function saveGoals() {
    const goals = goalsText.split("\n").map((g) => g.trim()).filter(Boolean);
    const current = project.targetGoals || [];
    if (JSON.stringify(goals) !== JSON.stringify(current)) return onSaveGoals(goals);
    return Promise.resolve();
  }

  function onDrop(event) {
    event.preventDefault();
    setDragOver(false);
    if (event.dataTransfer.files?.length) onAddFiles(event.dataTransfer.files);
  }

  return h("section", { className: "card sources" },
    h("div", { className: "card-head" },
      h("h2", null, "Activity logs"),
      h("button", { className: "link-btn", onClick: () => setAdvanced((value) => !value) }, advanced ? "Hide local loaders" : "Load from disk")
    ),
    h("div", { className: "card-body" },
      h("label", {
        className: `dropzone ${dragOver ? "over" : ""}`,
        onDragOver: (event) => { event.preventDefault(); setDragOver(true); },
        onDragLeave: () => setDragOver(false),
        onDrop
      },
        h("input", { ref: inputRef, type: "file", accept: ".json,.jsonl,application/json", multiple: true, hidden: true, onChange: (event) => onAddFiles(event.target.files) }),
        h("div", { className: "dropzone-icon" }, "⤓"),
        h("strong", null, "Drop JSONL files here"),
        h("span", { className: "muted" }, "or click to choose. One day, many days, or a full export.")
      ),
      advanced ? h("div", { className: "loaders" },
        h("label", { className: "field" }, "Local file path(s)",
          h("textarea", { rows: 2, value: pathText, placeholder: "/path/to/2026-06-04.jsonl", onChange: (event) => setPathText(event.target.value) })
        ),
        h("button", { className: "btn sm", disabled: busy, onClick: () => onAddPaths(pathText) }, "Add path(s)"),
        h("label", { className: "field" }, "Logs directory (latest 31 days)",
          h("input", { value: dirText, onChange: (event) => setDirText(event.target.value) })
        ),
        h("button", { className: "btn sm", disabled: busy, onClick: () => onAddDirectory(dirText) }, "Add directory")
      ) : null,
      project.files.length
        ? h("ul", { className: "file-list" },
            project.files.map((file) => h("li", { key: file.id, className: "file-row" },
              h("div", { className: "file-info" },
                h("span", { className: "file-name" }, basename(file.name)),
                h("span", { className: "file-meta" }, `${file.eventCount} events · ${formatBytes(file.size)}${file.errorCount ? ` · ${file.errorCount} skipped` : ""}`)
              ),
              h("button", { className: "row-delete", title: "Remove", disabled: busy, onClick: () => onRemove(file.id) }, "×")
            ))
          )
        : h("div", { className: "hint" }, "No files added yet."),
      h("div", { className: "goals-define" },
        h("label", { className: "field" }, "Goals to look for (optional — one business outcome per line)",
          h("textarea", {
            rows: 3,
            value: goalsText,
            placeholder: "Book incoming invoices correctly\nRespond to recruiters\nPrepare the investment review",
            onChange: (event) => setGoalsText(event.target.value),
            onBlur: saveGoals
          })
        ),
        h("span", { className: "hint" }, "The agent organizes events into these business goals and builds the chronology for each. Leave blank to let it infer the goals.")
      ),
      h("div", { className: "sources-actions" },
        h("button", {
          className: "btn primary",
          disabled: busy || !project.files.length,
          onClick: async () => { await saveGoals(); onInitialize(); }
        }, busy ? "Working…" : analyzed ? "Re-analyze project" : "Initialize project →"),
        !aiEnabled ? h("span", { className: "hint" }, "Set OPENAI_API_KEY for AI analysis (built-in analyzer used otherwise).") : null
      )
    )
  );
}

// ===========================================================================
// Results — overview, task list, task detail
// ===========================================================================

function EmptyResults({ hasFiles, busy }) {
  return h("section", { className: "card" },
    h("div", { className: "card-body" },
      h("div", { className: "hint big" }, busy
        ? "Analyzing… watch progress in the Agent tab."
        : hasFiles
          ? "Press “Initialize project” in the Logs tab to let the agent find your tasks."
          : "Add at least one log file in the Logs tab to get started.")
    )
  );
}

function Results({ project, tasks, selectedTask, onSelectTask, setProject, onChanged, health }) {
  const analysis = project.analysis || {};
  const goals = analysis.goals || [];

  // Selection can be a task or a goal (goal = combined timeline view).
  const [sel, setSel] = useState({ kind: "task", id: selectedTask?.id });
  const [sortDir, setSortDir] = useState("asc"); // chronological by default
  useEffect(() => { setSel({ kind: "task", id: tasks[0]?.id }); }, [project.id, analysis.generatedAt]);

  function selectTask(id) { setSel({ kind: "task", id }); onSelectTask?.(id); }
  function selectGoal(id) { setSel({ kind: "goal", id }); }

  const headLabel = goals.length
    ? `${goals.length} goal${goals.length === 1 ? "" : "s"} · ${tasks.length} task${tasks.length === 1 ? "" : "s"}`
    : `Tasks (${tasks.length})`;

  const selectedGoal = sel.kind === "goal" ? goals.find((g) => g.id === sel.id) : null;
  const panelTask = tasks.find((t) => t.id === sel.id) || tasks[0] || null;

  return h("section", { className: "card results-card" },
    h("div", { className: "card-head" },
      h("h2", null, headLabel),
      h("button", {
        className: "link-btn",
        title: "Sort tasks within each goal",
        onClick: () => setSortDir((d) => (d === "asc" ? "desc" : "asc"))
      }, sortDir === "asc" ? "Oldest first ↑" : "Newest first ↓")
    ),
    h("div", { className: "card-body no-pad" },
      h("div", { className: "results-grid" },
        h(TaskRail, { goals, tasks, sel, sortDir, onSelectTask: selectTask, onSelectGoal: selectGoal }),
        selectedGoal
          ? h(GoalDetail, { key: selectedGoal.id, project, goal: selectedGoal, tasks, sortDir, onSelectTask: selectTask, setProject, onChanged, health })
          : (panelTask
              ? h(TaskDetail, { key: panelTask.id, project, task: panelTask, setProject, onChanged, health })
              : h("div", { className: "hint big" }, "Select a task."))
      )
    )
  );
}

function sortTasks(list, sortDir) {
  const dir = sortDir === "desc" ? -1 : 1;
  return [...list].sort((a, b) => dir * ((Date.parse(a.startTimestamp) || 0) - (Date.parse(b.startTimestamp) || 0)));
}

function TaskRail({ goals, tasks, sel, sortDir, onSelectTask, onSelectGoal }) {
  const renderCard = (task) => h(TaskCard, {
    key: task.id,
    task,
    active: sel.kind === "task" && task.id === sel.id,
    onClick: () => onSelectTask(task.id)
  });

  if (!goals?.length) {
    return h("div", { className: "task-rail" }, sortTasks(tasks, sortDir).map(renderCard));
  }

  const taskById = new Map(tasks.map((task) => [task.id, task]));
  return h("div", { className: "task-rail" },
    goals.map((goal) => {
      const goalTasks = sortTasks((goal.taskIds || []).map((id) => taskById.get(id)).filter(Boolean), sortDir);
      return h("div", { key: goal.id, className: "goal-group" },
        h("button", {
          className: `goal-head ${sel.kind === "goal" && sel.id === goal.id ? "active" : ""}`,
          title: "View the whole-goal timeline",
          onClick: () => onSelectGoal(goal.id)
        },
          h("span", { className: "goal-title" }, goal.title),
          h("span", { className: "goal-count" }, goalTasks.length)
        ),
        goal.summary ? h("div", { className: "goal-summary" }, goal.summary) : null,
        goalTasks.map(renderCard)
      );
    })
  );
}

function GoalDetail({ project, goal, tasks, sortDir, onSelectTask, setProject, onChanged, health }) {
  const [tab, setTab] = useState("timeline");
  const [skillStream, setSkillStream] = useState([]);
  const [generating, setGenerating] = useState(false);
  const [launcherOpen, setLauncherOpen] = useState(false);
  const goalTasks = sortTasks((goal.taskIds || []).map((id) => tasks.find((t) => t.id === id)).filter(Boolean), sortDir);
  const steps = goalTasks.flatMap(stepsFromTask);
  const totalActive = goalTasks.reduce((sum, t) => sum + taskActiveMinutes(t), 0);
  const totalActions = goalTasks.reduce((sum, t) => sum + (t.metrics?.actions ?? t.actionCount ?? 0), 0);
  const totalAttempts = goalTasks.reduce((sum, t) => sum + (t.attempts ?? 1), 0);
  const savedSkill = project.skills?.[goal.id] || null;
  const canLaunchAgent = Boolean(savedSkill?.markdown) && !generating;
  const skillButtonLabel = generating ? "Building…" : savedSkill?.markdown ? "View skill" : "Create skill";

  useEffect(() => { setSkillStream([]); setTab("timeline"); setLauncherOpen(false); }, [goal.id]);

  async function generateSkill() {
    setGenerating(true);
    setSkillStream([]);
    setTab("skill");
    try {
      await streamPost(`/api/projects/${project.id}/goals/${goal.id}/skill`, { model: health.model }, (event) => {
        setSkillStream((current) => [...current, event]);
        if (event.type === "saved" && event.project) { setProject(event.project); onChanged(); }
      });
    } catch (err) {
      setSkillStream((current) => [...current, { type: "error", message: err.message }]);
    } finally {
      setGenerating(false);
    }
  }

  async function saveSkillMarkdown(markdown) {
    const data = await api(`/api/projects/${project.id}/goals/${goal.id}/skill`, { method: "PATCH", body: { markdown } });
    setProject(data.project);
    onChanged();
  }

  function copySkill() { if (savedSkill?.markdown) navigator.clipboard?.writeText(savedSkill.markdown); }
  function downloadSkill() {
    if (!savedSkill?.markdown) return;
    const blob = new Blob([savedSkill.markdown], { type: "text/markdown" });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = `${slugify(goal.title)}.SKILL.md`;
    anchor.click();
    URL.revokeObjectURL(url);
  }

  return h("div", { className: "task-detail" },
    h("div", { className: "task-detail-head goal-detail-head" },
      h("div", null,
        h("h3", null, goal.title),
        goal.summary ? h("p", { className: "muted" }, goal.summary) : null
      ),
      h("div", { className: "task-detail-actions goal-actions", "aria-label": "Goal actions" },
        h("button", {
          className: "btn primary sm goal-action",
          disabled: generating,
          title: savedSkill?.markdown ? "View generated universal skill" : "Create universal skill for this task",
          "aria-label": savedSkill?.markdown ? "View generated universal skill" : "Create universal skill for this task",
          onClick: () => savedSkill?.markdown ? setTab("skill") : generateSkill()
        }, h("span", { className: "action-dot skill", "aria-hidden": true }), skillButtonLabel),
        h("button", {
          className: "btn sm goal-action",
          disabled: !canLaunchAgent,
          title: canLaunchAgent ? "Deploy autonomous agent" : "Create a skill before deploying an agent",
          "aria-label": canLaunchAgent ? "Deploy autonomous agent" : "Create a skill before deploying an agent",
          onClick: () => { if (canLaunchAgent) setLauncherOpen(true); }
        }, h("span", { className: "action-dot run", "aria-hidden": true }), "Deploy")
      )
    ),
    launcherOpen ? h(AgentLauncherModal, { target: goal, onClose: () => setLauncherOpen(false) }) : null,
    h("div", { className: "effort" },
      h(EffortStat, { value: goalTasks.length, label: "Tasks" }),
      h(EffortStat, { value: formatDuration(totalActive), label: "Active time" }),
      h(EffortStat, { value: totalActions, label: "Actions" }),
      h(EffortStat, { value: totalAttempts, label: "Attempts" })
    ),
    h("div", { className: "goal-tasklinks" },
      goalTasks.map((t) => h("button", { key: t.id, className: "goal-tasklink", onClick: () => onSelectTask(t.id) },
        t.title, h("span", { className: "goal-tasklink-time" }, taskTimeDisplay(t).value)
      ))
    ),
    h("div", { className: "tabs" },
      tab2("timeline", "Timeline", tab, setTab),
      savedSkill || skillStream.length || generating ? tab2("skill", "Skill", tab, setTab) : null
    ),
    tab === "timeline" ? h(React.Fragment, null,
      h("h4", { className: "goal-tl-title" }, "Goal timeline"),
      h(StepTimeline, { steps, showTask: true, emptyText: "No timestamps were captured for this goal." })
    ) : null,
    tab === "skill" ? h(SkillView, {
      savedSkill,
      stream: skillStream,
      generating,
      emptyText: "No goal skill yet — press “Create universal skill for this task”.",
      onCopy: copySkill,
      onDownload: downloadSkill,
      onSaveMarkdown: saveSkillMarkdown
    }) : null
  );
}

function Overview({ analysis, performance, goals = [], tasks = [] }) {
  const apps = appUsage(tasks);
  return h("section", { className: "card overview" },
    h("div", { className: "card-body stack" },
      analysis.warning ? h("div", { className: "banner warn" }, "⚠︎ " + analysis.warning + " Re-analyze to retry the AI analysis.") : null,
      h("p", { className: "overview-text" }, analysis.overview || performance.summary || "Analysis complete."),
      goals.length ? h("div", { className: "goal-chips" },
        h("span", { className: "goal-chips-label" }, "Goals:"),
        goals.map((goal) => h("span", { key: goal.id, className: "goal-chip" },
          goal.title, h("span", { className: "goal-chip-count" }, (goal.taskIds || []).length)
        ))
      ) : null,
      apps.length ? h("div", { className: "goal-chips" },
        h("span", { className: "goal-chips-label" }, "Apps:"),
        apps.slice(0, 12).map(([name, count]) => h("span", { key: name, className: "app-chip" },
          h(AppIcon, { app: name }),
          h("span", { className: "app-chip-name" }, name),
          h("span", { className: "app-chip-count" }, count)
        ))
      ) : null,
      h("div", { className: "insight-cols" },
        h(InsightCol, { title: "Strengths", tone: "green", items: performance.strengths }),
        h(InsightCol, { title: "Bottlenecks", tone: "amber", items: performance.bottlenecks }),
        h(InsightCol, { title: "Recommendations", tone: "blue", items: performance.recommendations })
      )
    )
  );
}

// Inline SVG glyphs per app category — 16×16 grid, stroked with currentColor
// so each category's accent color comes from CSS.
const APP_ICON_SHAPES = {
  browser: () => [
    h("circle", { key: "a", cx: 8, cy: 8, r: 6 }),
    h("path", { key: "b", d: "M2 8h12" }),
    h("path", { key: "c", d: "M8 2a9 9 0 0 1 2.5 6A9 9 0 0 1 8 14a9 9 0 0 1-2.5-6A9 9 0 0 1 8 2Z" })
  ],
  email: () => [
    h("rect", { key: "a", x: 1.5, y: 3, width: 13, height: 10, rx: 1.5 }),
    h("path", { key: "b", d: "m2.5 5 5.5 4 5.5-4" })
  ],
  pdf: () => [
    h("path", { key: "a", d: "M9.5 1.5h-5a1 1 0 0 0-1 1v11a1 1 0 0 0 1 1h7a1 1 0 0 0 1-1V4.5Z" }),
    h("path", { key: "b", d: "M9.5 1.5V4.5h3" }),
    h("path", { key: "c", d: "M6 9h4M6 11.5h4" })
  ],
  sap: () => [
    h("rect", { key: "a", x: 1.5, y: 4.5, width: 13, height: 9, rx: 1.5 }),
    h("path", { key: "b", d: "M5.5 4.5v-1a1 1 0 0 1 1-1h3a1 1 0 0 1 1 1v1" }),
    h("path", { key: "c", d: "M1.5 8h13M8 8v1.5" })
  ],
  word: () => [
    h("rect", { key: "a", x: 3, y: 1.5, width: 10, height: 13, rx: 1.5 }),
    h("path", { key: "b", d: "M5.5 5.5h5M5.5 8h5M5.5 10.5h3" })
  ],
  excel: () => [
    h("rect", { key: "a", x: 2, y: 2.5, width: 12, height: 11, rx: 1.5 }),
    h("path", { key: "b", d: "M2 6h12M2 9.5h12M6.5 2.5v11" })
  ],
  slides: () => [
    h("rect", { key: "a", x: 1.5, y: 2.5, width: 13, height: 8.5, rx: 1 }),
    h("path", { key: "b", d: "M5.5 8.5V7M8 8.5V5.5M10.5 8.5V6.5" }),
    h("path", { key: "c", d: "M8 11v1.5m-2.5 2L8 12.5l2.5 2" })
  ],
  code: () => [
    h("path", { key: "a", d: "m5 5-3 3 3 3" }),
    h("path", { key: "b", d: "m11 5 3 3-3 3" }),
    h("path", { key: "c", d: "M9.5 3 6.5 13" })
  ],
  chat: () => [
    h("path", { key: "a", d: "M14.5 9.5A1.5 1.5 0 0 1 13 11H6l-3.5 3V4A1.5 1.5 0 0 1 4 2.5h9A1.5 1.5 0 0 1 14.5 4Z" })
  ],
  files: () => [
    h("path", { key: "a", d: "M14.5 12.5a1 1 0 0 1-1 1h-11a1 1 0 0 1-1-1v-9a1 1 0 0 1 1-1H6l2 2h5.5a1 1 0 0 1 1 1Z" })
  ],
  notes: () => [
    h("path", { key: "a", d: "m11.5 2 2.5 2.5L6 12.5l-3 .5.5-3Z" }),
    h("path", { key: "b", d: "M2.5 14.5h11" })
  ],
  calendar: () => [
    h("rect", { key: "a", x: 2, y: 3, width: 12, height: 11, rx: 1.5 }),
    h("path", { key: "b", d: "M2 6.5h12M5.5 1.5v3M10.5 1.5v3" })
  ]
};

// App icon: SVG glyph per category, app-initial fallback. Tooltip carries the full name.
function AppIcon({ app, size }) {
  const meta = appMeta(app);
  const shapes = APP_ICON_SHAPES[meta.cls];
  // Category class is namespaced (cat-*) so it can't collide with component
  // classes like .chat (chat panel) or .code (code block).
  return h("span", { className: `app-ico cat-${meta.cls}${size === "sm" ? " sm" : ""}`, title: meta.name },
    shapes
      ? h("svg", {
          viewBox: "0 0 16 16",
          fill: "none",
          stroke: "currentColor",
          strokeWidth: 1.5,
          strokeLinecap: "round",
          strokeLinejoin: "round",
          "aria-hidden": true
        }, shapes())
      : meta.initial
  );
}

// Event counts per app across all tasks, most used first.
function appUsage(tasks) {
  const counts = new Map();
  for (const task of tasks) {
    for (const event of (task.events || [])) {
      if (!event.appName) continue;
      counts.set(event.appName, (counts.get(event.appName) || 0) + 1);
    }
  }
  return [...counts.entries()].sort((a, b) => b[1] - a[1]);
}

// Unique apps touched by a task, in order of first appearance in its steps/events.
function taskApps(task) {
  const seen = new Set();
  for (const step of (task.steps || [])) if (step.appName) seen.add(step.appName);
  for (const event of (task.events || [])) if (event.appName) seen.add(event.appName);
  return [...seen];
}

function InsightCol({ title, tone, items }) {
  if (!items?.length) return null;
  return h("div", { className: `insight-col ${tone}` },
    h("h4", null, title),
    h("ul", null, items.map((item, index) => h("li", { key: index }, item)))
  );
}

function TaskCard({ task, active, onClick }) {
  const outcome = outcomeMeta(task.outcome);
  const apps = taskApps(task);
  return h("button", { className: `task-card ${active ? "active" : ""}`, onClick },
    h("div", { className: "task-card-top" },
      h("span", { className: "task-card-title" }, task.title),
      h("span", { className: `pill ${outcome.cls}` }, outcome.label)
    ),
    h("p", { className: "task-card-summary" }, task.summary),
    h("div", { className: "task-card-stats" },
      h(MiniStat, { value: taskTimeDisplay(task).value, label: "time" }),
      h(MiniStat, { value: task.attempts ?? 1, label: task.attempts === 1 ? "try" : "tries" }),
      h(MiniStat, { value: task.actionCount ?? task.metrics?.actions ?? 0, label: "actions" }),
      apps.length ? h("div", { className: "task-card-apps" },
        apps.slice(0, 4).map((app) => h(AppIcon, { key: app, app, size: "sm" })),
        apps.length > 4 ? h("span", { className: "task-card-apps-more" }, `+${apps.length - 4}`) : null
      ) : null
    )
  );
}

function MiniStat({ value, label }) {
  return h("div", { className: "ministat" }, h("strong", null, value), h("span", null, label));
}

function TaskDetail({ project, task, setProject, onChanged, health }) {
  const [tab, setTab] = useState("steps");
  const [selectedEventId, setSelectedEventId] = useState(null);
  const [editing, setEditing] = useState(false);

  useEffect(() => { setSelectedEventId(null); setTab("steps"); setEditing(false); }, [task.id]);

  async function saveEdit({ title, summary, steps }) {
    const data = await api(`/api/projects/${project.id}/tasks/${task.id}`, { method: "PATCH", body: { title, summary, steps } });
    setProject(data.project);
    onChanged();
    setEditing(false);
  }

  const events = task.events || [];
  const selectedEvent = events.find((event) => event.id === selectedEventId) || null;
  const metrics = task.metrics || {};

  if (editing) {
    return h("div", { className: "task-detail" },
      h(TaskEditor, { task, onSave: saveEdit, onCancel: () => setEditing(false) })
    );
  }

  return h("div", { className: "task-detail" },
    h("div", { className: "task-detail-head" },
      h("div", null,
        h("h3", null, task.title, task.edited ? h("span", { className: "edited-tag" }, "edited") : null),
        h("p", { className: "muted" }, task.summary)
      ),
      h("div", { className: "task-detail-actions" },
        h("button", { className: "btn sm", onClick: () => setEditing(true) }, "Edit")
      )
    ),
    h(EffortStrip, { task, metrics }),
    h("div", { className: "tabs" },
      tab2("steps", "Steps", tab, setTab),
      tab2("flow", "Timeline", tab, setTab),
      tab2("timeline", "Raw events", tab, setTab)
    ),
    tab === "steps" ? h(StepsView, { task }) : null,
    tab === "flow" ? h(TimelineView, { task }) : null,
    tab === "timeline" ? h(EventsView, { events, selectedEvent, onSelect: setSelectedEventId, activityRoot: project.activityRoot }) : null
  );
}

const MOCK_COMPUTERS = [
  "Atlas-MBP-14",
  "Prague-Finance-01",
  "Nebula Cloud VM",
  "Orpheus Workstation",
  "Vega QA Mac",
  "InvoiceBot Runner"
];

const MOCK_AGENT_RUNTIMES = [
  "Cloud Code",
  "OpenCloud",
  "Codex",
  "Hermes",
  "Custom BrainCache Agent"
];

function AgentLauncherModal({ target, onClose }) {
  const [computer, setComputer] = useState(MOCK_COMPUTERS[0]);
  const [runtime, setRuntime] = useState(MOCK_AGENT_RUNTIMES[2]);
  const [deploying, setDeploying] = useState(false);
  const [launched, setLaunched] = useState(false);
  const deployTimer = useRef(null);

  useEffect(() => () => {
    if (deployTimer.current) window.clearTimeout(deployTimer.current);
  }, []);

  function deploy() {
    setDeploying(true);
    setLaunched(false);
    deployTimer.current = window.setTimeout(() => {
      setDeploying(false);
      setLaunched(true);
    }, 1100);
  }

  return h("div", { className: "modal-backdrop", role: "presentation", onMouseDown: (event) => event.target === event.currentTarget && onClose() },
    h("div", { className: "modal launcher-modal", role: "dialog", "aria-modal": "true", "aria-label": "Deploy autonomous agent" },
      h("div", { className: "modal-head" },
        h("div", null,
          h("h3", null, "Deploy autonomous agent"),
          h("p", { className: "muted" }, `Mock deployment for “${target.title}”.`)
        ),
        h("button", { className: "icon-btn light", title: "Close", onClick: onClose }, "×")
      ),
      h("div", { className: "launcher-section" },
        h("div", { className: "launcher-label" }, "1. Pick a computer"),
        h("div", { className: "option-grid" },
          MOCK_COMPUTERS.map((name) => h("button", {
            key: name,
            className: `option-card ${computer === name ? "selected" : ""}`,
            onClick: () => setComputer(name)
          },
            h("span", { className: "option-title" }, name),
            h("span", { className: "option-sub" }, computerKind(name))
          ))
        )
      ),
      h("div", { className: "launcher-section" },
        h("div", { className: "launcher-label" }, "2. Pick where to run"),
        h("div", { className: "option-grid runtimes" },
          MOCK_AGENT_RUNTIMES.map((name) => h("button", {
            key: name,
            className: `option-card ${runtime === name ? "selected" : ""}`,
            onClick: () => setRuntime(name)
          },
            h("span", { className: "option-title" }, name),
            h("span", { className: "option-sub" }, runtimeDescription(name))
          ))
        )
      ),
      deploying ? h("div", { className: "banner mock deploying" },
        h("span", { className: "mini-spinner", "aria-hidden": true }),
        "Deploying mock agent to ",
        h("strong", null, computer),
        " via ",
        h("strong", null, runtime),
        "…"
      ) : null,
      launched ? h("div", { className: "banner mock" },
        "Mock launch queued: ",
        h("strong", null, target.title),
        " on ",
        h("strong", null, computer),
        " via ",
        h("strong", null, runtime),
        "."
      ) : null,
      h("div", { className: "modal-actions" },
        h("button", { className: "btn sm", disabled: deploying, onClick: onClose }, "Cancel"),
        h("button", { className: "btn primary sm", disabled: deploying || launched, onClick: deploy },
          deploying ? h(React.Fragment, null, h("span", { className: "mini-spinner light", "aria-hidden": true }), "Deploying…") : launched ? "Queued" : "Deploy mock agent")
      )
    )
  );
}

function computerKind(name) {
  if (name.includes("Cloud") || name.includes("Runner")) return "Cloud runner";
  if (name.includes("Finance")) return "Finance desktop";
  if (name.includes("QA")) return "QA machine";
  return "Local workstation";
}

function runtimeDescription(name) {
  return {
    "Cloud Code": "Cloud IDE worker",
    OpenCloud: "Managed cloud runtime",
    Codex: "Coding agent runtime",
    Hermes: "Operations runner",
    "Custom BrainCache Agent": "Project-specific agent"
  }[name] || "Agent runtime";
}

function stepsFromTask(task) {
  return (task.steps || []).map((step, index) => ({
    key: `${task.id || ""}-${step.id || step.evidenceEventId || index}`,
    label: step.label || friendlyEventLabel(stepAsEvent(step)),
    app: step.appName,
    notes: step.notes,
    t: step.timestamp ? new Date(step.timestamp).getTime() : null,
    taskTitle: task.title
  }));
}

function StepTimeline({ steps, showTask, emptyText }) {
  const timed = steps.filter((s) => s.t && !Number.isNaN(s.t)).sort((a, b) => a.t - b.t);
  if (!timed.length) return h("div", { className: "hint big" }, emptyText || "No timestamps were captured.");

  return h("ol", { className: "vtimeline" },
    timed.map((step, index) => {
      const prev = timed[index - 1];
      const gapMs = prev ? step.t - prev.t : 0;
      const bigGap = gapMs > 5 * 60 * 1000;
      const newDay = !prev || new Date(prev.t).toDateString() !== new Date(step.t).toDateString();
      return h("li", { key: step.key, className: "vt-item" },
        newDay ? h("div", { className: "vt-day" }, formatDay(step.t)) : null,
        !newDay && gapMs > 60 * 1000 ? h("div", { className: `vt-gap ${bigGap ? "big" : ""}` }, `${formatDuration(gapMs / 60000)} later`) : null,
        h("div", { className: "vt-row" },
          h("div", { className: "vt-rail" },
            step.app ? h(AppIcon, { app: step.app }) : h("span", { className: "vt-dot" }),
            index < timed.length - 1 ? h("span", { className: "vt-line" }) : null
          ),
          h("div", { className: "vt-body" },
            h("div", { className: "vt-time" }, formatClockShort(step.t)),
            showTask && step.taskTitle ? h("div", { className: "vt-task" }, step.taskTitle) : null,
            h("div", { className: "vt-label" }, step.label),
            step.notes ? h("div", { className: "vt-notes" }, step.notes) : null,
            step.app ? h("div", { className: "vt-app" }, step.app) : null
          )
        )
      );
    })
  );
}

function TimelineView({ task }) {
  return h(StepTimeline, { steps: stepsFromTask(task), emptyText: "No timestamps were captured for this process." });
}

function TaskEditor({ task, onSave, onCancel }) {
  const [title, setTitle] = useState(task.title || "");
  const [summary, setSummary] = useState(task.summary || "");
  const [steps, setSteps] = useState((task.steps || []).map((step) => ({ ...step, label: step.label || "" })));
  const [saving, setSaving] = useState(false);

  function updateStep(index, patch) { setSteps((current) => current.map((step, i) => (i === index ? { ...step, ...patch } : step))); }
  function removeStep(index) { setSteps((current) => current.filter((_, i) => i !== index)); }
  function addStep() { setSteps((current) => [...current, { label: "", appName: "", notes: "" }]); }

  async function submit() {
    setSaving(true);
    try {
      await onSave({ title: title.trim() || task.title, summary, steps: steps.filter((step) => (step.label || "").trim()) });
    } finally {
      setSaving(false);
    }
  }

  return h("div", { className: "task-editor" },
    h("div", { className: "task-detail-head" },
      h("h3", null, "Edit process"),
      h("div", { className: "task-detail-actions" },
        h("button", { className: "btn sm", disabled: saving, onClick: onCancel }, "Cancel"),
        h("button", { className: "btn primary sm", disabled: saving, onClick: submit }, saving ? "Saving…" : "Save changes")
      )
    ),
    h("label", { className: "field" }, "Title",
      h("input", { value: title, onChange: (event) => setTitle(event.target.value) })
    ),
    h("label", { className: "field" }, "Summary",
      h("textarea", { rows: 3, value: summary, onChange: (event) => setSummary(event.target.value) })
    ),
    h("div", { className: "field" }, `Steps (${steps.length})`,
      h("div", { className: "step-editor" },
        steps.map((step, index) => h("div", { key: index, className: "step-edit-row" },
          h("span", { className: "step-num" }, index + 1),
          h("div", { className: "step-edit-fields" },
            h("input", { value: step.label || "", placeholder: "What happens in this step", onChange: (event) => updateStep(index, { label: event.target.value }) }),
            h("input", { className: "step-notes-input", value: step.notes || "", placeholder: "Notes (optional)", onChange: (event) => updateStep(index, { notes: event.target.value }) })
          ),
          h("button", { className: "row-delete", type: "button", title: "Remove step", onClick: () => removeStep(index) }, "×")
        )),
        h("button", { className: "btn sm", type: "button", onClick: addStep }, "+ Add step")
      )
    )
  );
}

function tab2(key, label, active, setTab) {
  return h("button", { key, className: `tab ${active === key ? "active" : ""}`, onClick: () => setTab(key) }, label);
}

function EffortStrip({ task, metrics }) {
  const outcome = outcomeMeta(task.outcome);
  const time = taskTimeDisplay(task);
  return h("div", { className: "effort" },
    h(EffortStat, { value: time.value, label: "Time spent", note: time.note }),
    h(EffortStat, { value: task.attempts ?? 1, label: "Attempts" }),
    h(EffortStat, { value: metrics.actions ?? task.actionCount ?? 0, label: "Actions" }),
    h(EffortStat, { value: metrics.corrections ?? 0, label: "Corrections" }),
    h(EffortStat, { value: metrics.appSwitches ?? 0, label: "App switches" }),
    h(EffortStat, { value: `${Math.round((task.confidence || 0) * 100)}%`, label: "Confidence" }),
    h("div", { className: "effort-outcome" }, h("span", { className: `pill ${outcome.cls}` }, outcome.label))
  );
}

function EffortStat({ value, label, note }) {
  return h("div", { className: "effort-stat" },
    h("strong", null, value),
    h("span", null, label),
    note ? h("span", { className: "effort-note" }, note) : null
  );
}

function StepsView({ task }) {
  const steps = (task.steps || []).map((step, index) => ({
    key: step.id || step.evidenceEventId || index,
    label: step.label || friendlyEventLabel(stepAsEvent(step)),
    app: step.appName,
    time: step.timestamp,
    notes: step.notes
  }));
  if (!steps.length) return h("div", { className: "hint big" }, "No discrete steps were captured for this task.");
  return h("ol", { className: "steps" },
    steps.map((step) => h("li", { key: step.key, className: "step" },
      h("div", { className: "step-body" },
        h("div", { className: "step-label" }, step.label),
        step.notes ? h("div", { className: "step-notes" }, step.notes) : null,
        h("div", { className: "step-meta" },
          step.app ? h("span", { className: "step-app" }, h(AppIcon, { app: step.app, size: "sm" }), step.app) : null,
          step.time ? h("span", null, formatTime(step.time)) : null
        )
      )
    ))
  );
}

function EventsView({ events, selectedEvent, onSelect, activityRoot }) {
  if (!events.length) return h("div", { className: "hint big" }, "No raw events stored for this task.");
  return h("div", { className: "events-split" },
    h("div", { className: "events-list" },
      events.map((event) => h("button", {
        key: event.id,
        className: `event-row ${selectedEvent?.id === event.id ? "active" : ""}`,
        onClick: () => onSelect(event.id)
      },
        h("span", { className: "event-time" }, formatClock(event.timestamp)),
        event.appName ? h(AppIcon, { app: event.appName, size: "sm" }) : null,
        h("span", { className: "event-label" }, friendlyEventLabel(event)),
        event.screenshotPath ? h("span", { className: "event-tag" }, "shot") : null
      ))
    ),
    h(EventInspector, { event: selectedEvent, activityRoot })
  );
}

function EventInspector({ event, activityRoot }) {
  const [transcript, setTranscript] = useState("");
  useEffect(() => setTranscript(""), [event?.id]);
  if (!event) return h("div", { className: "event-inspector empty" }, h("div", { className: "hint" }, "Select an event to inspect."));

  const screenshotUrl = event.screenshotPath
    ? `/media?kind=screenshots&root=${encodeURIComponent(activityRoot || "")}&path=${encodeURIComponent(event.screenshotPath)}`
    : null;

  async function loadTranscript() {
    if (!event.transcriptPath) return;
    const response = await fetch(`/api/transcript?root=${encodeURIComponent(activityRoot || "")}&path=${encodeURIComponent(event.transcriptPath)}`);
    setTranscript(await response.text());
  }

  return h("div", { className: "event-inspector" },
    screenshotUrl ? h("img", { className: "shot", src: screenshotUrl, alt: "Screenshot" }) : null,
    h("div", { className: "inspector-title" }, friendlyEventLabel(event)),
    h("dl", { className: "kv" },
      kv("What happened", friendlyEventType(event.eventType)),
      kv("When", formatTime(event.timestamp)),
      kv("App", event.appName ? h("span", { className: "kv-app" }, h(AppIcon, { app: event.appName, size: "sm" }), event.appName) : null),
      kv("Window", event.windowTitle),
      event.url ? kv("Link", event.url) : null,
      event.aiPrompt ? kv("AI prompt", event.aiPrompt) : null,
      event.aiResponse ? kv("AI response", event.aiResponse) : null
    ),
    event.transcriptPath ? h("div", { className: "stack" },
      h("button", { className: "btn sm", onClick: loadTranscript }, "Load transcript"),
      transcript ? h("pre", { className: "code" }, transcript) : null
    ) : null
  );
}

function SkillView({ savedSkill, stream, generating, emptyText, onCopy, onDownload, onSaveMarkdown }) {
  const [editing, setEditing] = useState(false);
  const [draft, setDraft] = useState("");
  const [saving, setSaving] = useState(false);

  // A regenerate replaces the markdown — drop any in-progress edit.
  useEffect(() => { setEditing(false); }, [savedSkill?.generatedAt]);

  function startEdit() {
    setDraft(savedSkill?.markdown || "");
    setEditing(true);
  }

  async function save() {
    setSaving(true);
    try {
      await onSaveMarkdown(draft);
      setEditing(false);
    } finally {
      setSaving(false);
    }
  }

  return h("div", { className: "skill-view" },
    generating || (stream.length && !savedSkill) ? h(AgentStream, { events: stream, title: "Writing skill", embedded: true }) : null,
    savedSkill
      ? (editing
          ? h(React.Fragment, null,
              h("div", { className: "skill-actions" },
                h("button", { className: "btn primary sm", disabled: saving || !draft.trim(), onClick: save }, saving ? "Saving…" : "Save changes"),
                h("button", { className: "btn sm", disabled: saving, onClick: () => setEditing(false) }, "Cancel")
              ),
              h("textarea", {
                className: "skill-editor",
                value: draft,
                spellCheck: false,
                onChange: (event) => setDraft(event.target.value)
              })
            )
          : h(React.Fragment, null,
              h("div", { className: "skill-actions" },
                h("span", { className: `pill ${savedSkill.source === "openai" ? "green" : "muted"}` }, savedSkill.source === "openai" ? `AI · ${savedSkill.model || ""}` : "template"),
                savedSkill.editedAt ? h("span", { className: "edited-tag" }, "edited") : null,
                h("button", { className: "btn sm", onClick: startEdit }, "Edit"),
                h("button", { className: "btn sm", onClick: onCopy }, "Copy"),
                h("button", { className: "btn sm", onClick: onDownload }, "Download .md")
              ),
              h("pre", { className: "code skill-md" }, savedSkill.markdown)
            ))
      : (!generating ? h("div", { className: "hint big" }, emptyText || "No skill yet.") : null)
  );
}

// ===========================================================================
// Chat — ask questions about the logs and extracted tasks (with history)
// ===========================================================================

function ChatPanel({ project, setProject, onChanged, health }) {
  const [draft, setDraft] = useState("");
  const [pending, setPending] = useState(null); // { question, stream: [] }
  const [busy, setBusy] = useState(false);
  const bottomRef = useRef(null);

  const messages = project.conversation || [];
  useEffect(() => { bottomRef.current?.scrollIntoView({ block: "end" }); }, [messages.length, pending]);

  async function send() {
    const text = draft.trim();
    if (!text || busy) return;
    setDraft("");
    setBusy(true);
    setPending({ question: text, stream: [] });
    try {
      await streamPost(`/api/projects/${project.id}/chat`, { message: text, model: health.model }, (event) => {
        if (event.type === "saved" && event.project) {
          setProject(event.project);
          onChanged();
          setPending(null);
        } else {
          setPending((current) => ({ ...(current || { question: text, stream: [] }), stream: [...((current && current.stream) || []), event] }));
        }
      });
    } catch (err) {
      setPending((current) => ({ ...(current || { question: text, stream: [] }), stream: [...((current && current.stream) || []), { type: "error", message: err.message }] }));
      setBusy(false);
    } finally {
      setBusy(false);
    }
  }

  const empty = !messages.length && !pending;

  return h("section", { className: "card chat" },
    h("div", { className: "chat-scroll" },
      empty
        ? h("div", { className: "chat-empty" },
            h("div", { className: "chat-empty-title" }, "Ask anything about these logs"),
            h("div", { className: "chat-suggestions" },
              (project.analysis
                ? ["How long did each task take?", "Which apps did I switch between most?", "Where did I waste the most time?", "Summarize what I worked on."]
                : ["What was I doing in these logs?", "Which apps appear most?", "When was I most active?"]
              ).map((suggestion) => h("button", { key: suggestion, className: "chip", onClick: () => setDraft(suggestion) }, suggestion))
            )
          )
        : null,
      messages.map((message) => h(ChatBubble, { key: message.id, message })),
      pending ? h(ChatBubble, { message: { role: "user", content: pending.question } }) : null,
      pending ? h(PendingBubble, { pending }) : null,
      h("div", { ref: bottomRef })
    ),
    h("form", { className: "chat-input", onSubmit: (event) => { event.preventDefault(); send(); } },
      h("textarea", {
        value: draft,
        rows: 1,
        placeholder: health.aiEnabled ? "Ask a question…" : "Set OPENAI_API_KEY to chat",
        disabled: !health.aiEnabled,
        onChange: (event) => setDraft(event.target.value),
        onKeyDown: (event) => { if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); send(); } }
      }),
      h("button", { className: "btn primary", type: "submit", disabled: busy || !draft.trim() }, busy ? "…" : "Send")
    )
  );
}

function ChatBubble({ message }) {
  const isUser = message.role === "user";
  return h("div", { className: `bubble-row ${isUser ? "user" : "assistant"}` },
    h("div", { className: `bubble ${isUser ? "user" : "assistant"}` },
      isUser ? h("div", { className: "bubble-text" }, message.content) : h(Markdown, { text: message.content }),
      !isUser && message.toolTrace?.length ? h(ToolTrace, { trace: message.toolTrace }) : null
    )
  );
}

function PendingBubble({ pending }) {
  const answer = pending.stream.find((event) => event.type === "done")?.answer;
  return h("div", { className: "bubble-row assistant" },
    h("div", { className: "bubble assistant" },
      answer ? h(Markdown, { text: answer }) : h(AgentStream, { events: pending.stream, title: "Thinking", embedded: true })
    )
  );
}

function ToolTrace({ trace }) {
  const [open, setOpen] = useState(false);
  const calls = trace.filter((item) => item.type === "tool_call");
  if (!calls.length) return null;
  return h("div", { className: "tooltrace" },
    h("button", { className: "tooltrace-toggle", onClick: () => setOpen((value) => !value) },
      `${open ? "Hide" : "Show"} how I looked this up (${calls.length} step${calls.length === 1 ? "" : "s"})`),
    open ? h("div", { className: "tooltrace-body" },
      calls.map((item, index) => h("div", { key: index, className: "tooltrace-item" }, `${friendlyToolName(item.name)}${argHint(item.arguments)}`))
    ) : null
  );
}

// Minimal, safe Markdown renderer (escape first, then a few inline rules).
function Markdown({ text }) {
  return h("div", { className: "md", dangerouslySetInnerHTML: { __html: mdToHtml(String(text || "")) } });
}

function mdToHtml(src) {
  const esc = (s) => s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const inline = (s) => esc(s)
    .replace(/`([^`]+)`/g, "<code>$1</code>")
    .replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>")
    .replace(/\*([^*]+)\*/g, "<em>$1</em>")
    .replace(/\[([^\]]+)\]\((https?:[^)]+)\)/g, '<a href="$2" target="_blank" rel="noopener">$1</a>');

  const splitRow = (line) => {
    let t = line.trim();
    if (t.startsWith("|")) t = t.slice(1);
    if (t.endsWith("|")) t = t.slice(0, -1);
    return t.split("|").map((cell) => cell.trim());
  };
  const isSepRow = (line) => {
    if (!line || !line.includes("|")) return false;
    const cells = splitRow(line);
    return cells.length > 0 && cells.every((cell) => /^:?-{1,}:?$/.test(cell));
  };
  const renderTable = (header, rows) => {
    const head = `<tr>${header.map((cell) => `<th>${inline(cell)}</th>`).join("")}</tr>`;
    const body = rows.map((row) => `<tr>${row.map((cell) => `<td>${inline(cell)}</td>`).join("")}</tr>`).join("");
    return `<table class="md-table"><thead>${head}</thead><tbody>${body}</tbody></table>`;
  };

  const lines = src.replace(/\r\n/g, "\n").split("\n");
  const out = [];
  let listType = null;
  const closeList = () => { if (listType) { out.push(`</${listType}>`); listType = null; } };

  let i = 0;
  while (i < lines.length) {
    const line = lines[i].trimEnd();
    const trimmed = line.trim();

    // GFM table: a header row, then a |---|---| separator, then body rows.
    if (trimmed.includes("|") && i + 1 < lines.length && isSepRow(lines[i + 1].trim())) {
      closeList();
      const header = splitRow(trimmed);
      const rows = [];
      i += 2;
      while (i < lines.length && lines[i].trim() && lines[i].includes("|") && !isSepRow(lines[i].trim())) {
        rows.push(splitRow(lines[i].trim()));
        i += 1;
      }
      out.push(renderTable(header, rows));
      continue;
    }

    const heading = line.match(/^(#{1,4})\s+(.*)$/);
    const bullet = line.match(/^\s*[-*]\s+(.*)$/);
    const numbered = line.match(/^\s*\d+\.\s+(.*)$/);
    if (heading) { closeList(); const level = heading[1].length + 1; out.push(`<h${level}>${inline(heading[2])}</h${level}>`); }
    else if (bullet) { if (listType !== "ul") { closeList(); listType = "ul"; out.push("<ul>"); } out.push(`<li>${inline(bullet[1])}</li>`); }
    else if (numbered) { if (listType !== "ol") { closeList(); listType = "ol"; out.push("<ol>"); } out.push(`<li>${inline(numbered[1])}</li>`); }
    else if (!trimmed) { closeList(); }
    else { closeList(); out.push(`<p>${inline(line)}</p>`); }
    i += 1;
  }
  closeList();
  return out.join("\n");
}

// ===========================================================================
// Agent stream view
// ===========================================================================

function AgentStream({ events = [], title, collapsed = false, embedded = false }) {
  const [open, setOpen] = useState(!collapsed);
  const bottomRef = useRef(null);
  useEffect(() => { bottomRef.current?.scrollIntoView({ block: "nearest" }); }, [events.length]);
  if (!events.length) return null;

  return h("section", { className: `agent-stream ${embedded ? "embedded" : "card"}` },
    h("div", { className: "stream-head", onClick: () => setOpen((value) => !value) },
      h("span", { className: "stream-dot" }),
      h("strong", null, title),
      h("span", { className: "stream-count" }, `${events.length} steps`),
      h("span", { className: "stream-toggle" }, open ? "−" : "+")
    ),
    open ? h("div", { className: "stream-body" },
      events.map((event, index) => h(StreamItem, { key: index, event })),
      h("div", { ref: bottomRef })
    ) : null
  );
}

function StreamItem({ event }) {
  const meta = {
    thinking: { icon: "○", cls: "think", text: event.message },
    tool_call: { icon: "→", cls: "call", text: `${friendlyToolName(event.name)}${argHint(event.arguments)}` },
    tool_output: { icon: "←", cls: "out", text: `${friendlyToolName(event.name)} responded` },
    output: { icon: "✓", cls: "done", text: "Agent drafted its answer" },
    saved: { icon: "✓", cls: "done", text: "Saved to project" },
    done: { icon: "✓", cls: "done", text: "Done" },
    error: { icon: "!", cls: "err", text: event.message }
  }[event.type] || { icon: "·", cls: "", text: event.type };
  return h("div", { className: `stream-item ${meta.cls}` },
    h("span", { className: "stream-icon" }, meta.icon),
    h("span", { className: "stream-text" }, meta.text)
  );
}

function friendlyToolName(name) {
  return {
    list_events: "Reading the activity timeline",
    search_events: "Searching the activity",
    get_event_detail: "Looking at one event closely",
    inspect_screenshot: "Looking at a screenshot",
    read_transcript: "Reading a transcript"
  }[name] || name;
}

function argHint(args) {
  if (!args) return "";
  if (args.query) return ` for “${args.query}”`;
  if (args.appName) return ` in ${args.appName}`;
  if (args.eventType) return ` (${friendlyEventType(args.eventType)})`;
  return "";
}

// ===========================================================================
// Small helpers
// ===========================================================================

function kv(label, value) {
  if (!value) return null;
  return [h("dt", { key: `${label}-k` }, label), h("dd", { key: `${label}-v` }, value)];
}

function stepAsEvent(step) {
  return { eventType: step.eventType, appName: step.appName, controlName: step.target, windowTitle: step.windowTitle, nearbyText: step.target };
}

function basename(value) {
  return String(value || "").split("/").pop();
}

function formatBytes(bytes) {
  if (!bytes) return "0 B";
  const units = ["B", "KB", "MB"];
  let size = bytes;
  let unit = 0;
  while (size >= 1024 && unit < units.length - 1) { size /= 1024; unit += 1; }
  return `${size.toFixed(unit ? 1 : 0)} ${units[unit]}`;
}

// Active (focused) minutes — sum of short gaps between the task's step
// timestamps (the curated milestones), falling back to the server metric. This
// avoids reporting a multi-day first→last span as "time spent".
function taskActiveMinutes(task) {
  const stamps = (task.steps || [])
    .map((step) => (step.timestamp ? new Date(step.timestamp).getTime() : null))
    .filter((t) => t && !Number.isNaN(t))
    .sort((a, b) => a - b);
  if (stamps.length >= 2) {
    let ms = 0;
    for (let i = 1; i < stamps.length; i += 1) {
      const gap = stamps[i] - stamps[i - 1];
      if (gap > 0 && gap <= 5 * 60 * 1000) ms += gap;
    }
    return Math.round(ms / 60000);
  }
  if (Number.isFinite(task.metrics?.activeMinutes)) return task.metrics.activeMinutes;
  return task.durationMinutes || 0;
}

// What to show for "Time spent": focused active time when we can estimate it,
// otherwise the elapsed span — always formatted, with a clarifying note.
function taskTimeDisplay(task) {
  const active = taskActiveMinutes(task);
  const span = task.metrics?.spanMinutes ?? task.durationMinutes ?? active;
  if (active >= 1) {
    const note = span > active * 1.5 && span - active > 30 ? `over ${formatDuration(span)}` : null;
    return { value: formatDuration(active), note };
  }
  return { value: formatDuration(span), note: span >= 60 ? "elapsed, incl. idle" : null };
}

function formatDuration(minutes) {
  const min = Math.max(0, Math.round(Number(minutes) || 0));
  if (min < 1) return "<1m";
  if (min < 60) return `${min}m`;
  const hours = Math.floor(min / 60);
  const mins = min % 60;
  if (hours < 24) return mins ? `${hours}h ${mins}m` : `${hours}h`;
  const days = Math.floor(hours / 24);
  const hrs = hours % 24;
  return hrs ? `${days}d ${hrs}h` : `${days}d`;
}

function formatTime(timestamp) {
  if (!timestamp) return "";
  const date = new Date(timestamp);
  if (Number.isNaN(date.getTime())) return timestamp;
  return date.toLocaleString([], { month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" });
}

function formatDay(timestamp) {
  const date = new Date(timestamp);
  if (Number.isNaN(date.getTime())) return "";
  return date.toLocaleDateString([], { weekday: "short", month: "short", day: "numeric" });
}

function formatClockShort(timestamp) {
  const date = new Date(timestamp);
  if (Number.isNaN(date.getTime())) return "";
  return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

function formatClock(timestamp) {
  if (!timestamp) return "";
  const date = new Date(timestamp);
  if (Number.isNaN(date.getTime())) return "";
  return date.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
}

function slugify(value) {
  return String(value || "braincache-skill").toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "").slice(0, 72) || "braincache-skill";
}

createRoot(document.getElementById("root")).render(h(App));
