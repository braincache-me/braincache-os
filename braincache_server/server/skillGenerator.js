import { humanizeEventType } from "./taskInference.js";

export function generateSkillMarkdown(task, options = {}) {
  const skillName = options.skillName || slugify(task.title || task.id || "activity-task");
  const title = titleCase(skillName.replace(/-/g, " "));
  const tools = inferRequiredTools(task);
  const docs = inferDocumentationNeeds(task);
  const steps = task.steps?.length ? task.steps : task.evidence ?? [];

  return `# ${title}

## Purpose

A reusable procedure for the class of task observed as "${task.title}" — generalize it to complete similar cases, not just replay this one.

Use this skill when the user asks to repeat, automate, document, or audit this kind of workflow. It typically uses ${task.apps.map((app) => app.name).join(", ") || "the captured apps"}.

## Inputs

The values below change from case to case. Identify each one before starting — do not hard-code the observed example.

- Case-specific identifiers (e.g. record/invoice/ticket numbers, names, amounts, dates) — read them from the triggering document or message that starts the workflow.
- The target record or destination — locate it in ${task.apps?.[0]?.name || "the primary app"} using its identifier.

## Required Access

${tools.map((tool) => `- ${tool}`).join("\n")}

## Procedure

> Generalized from one observed run. Treat case-specific values as placeholders to fill from the Inputs above.

${steps.map((step, index) => formatWorkflowStep(step, index)).join("\n")}

## Where to find details

- The triggering item (email, message, document) holds the case identifiers and amounts — read it first.
- Look up the master record in the system of record (${task.apps?.[0]?.name || "the primary app"}) by its identifier.
- Cross-reference supporting documents (PDFs, contracts, prior records) named or linked from the trigger.
- Routing/approval targets are usually determined by the record's own fields (owner, cost center, category).

## Verification

- Confirm the destination app/window and record match the case before acting.
- Prefer accessibility labels, visible text, URLs, and stable file paths over raw click coordinates.
- Re-read the record after the change to confirm the goal was achieved.
- Preserve privacy: never request or store secure text-field values.

## Notes & Risks

${docs.map((item) => `- ${item}`).join("\n")}
`;
}

export function inferRequiredTools(task) {
  const apps = task.apps?.map((app) => app.name.toLowerCase()) ?? [];
  const eventTypes = new Set(task.eventTypes?.map((type) => type.name) ?? []);
  const tools = new Set();

  if (apps.some((app) => app.includes("chrome") || app.includes("safari") || app.includes("browser"))) {
    tools.add("Browser automation access for the relevant web app or URL.");
  }
  if (apps.some((app) => app.includes("cursor") || app.includes("xcode") || app.includes("terminal"))) {
    tools.add("Filesystem and shell access to inspect or edit the project involved.");
  }
  if (eventTypes.has("left_click") || eventTypes.has("right_click") || eventTypes.has("key_shortcut")) {
    tools.add("macOS Accessibility automation for native UI clicks, shortcuts, and focused-window inspection.");
  }
  if ((task.screenshotCount ?? 0) > 0) {
    tools.add("Read access to Activity Capture screenshots for visual verification.");
  }
  if ((task.transcriptCount ?? 0) > 0) {
    tools.add("Read access to transcript files for meeting or spoken-context reconstruction.");
  }
  if (!tools.size) {
    tools.add("Read access to the relevant Activity Capture JSONL logs.");
  }
  return [...tools];
}

export function inferDocumentationNeeds(task) {
  const docs = new Set([
    "Business goal and acceptable success criteria for this workflow.",
    "Which accounts, workspaces, folders, or projects the agent may access.",
    "Any approval gates before sending messages, changing records, or uploading files."
  ]);

  const appNames = task.apps?.map((app) => app.name).join(", ") || "the captured apps";
  docs.add(`Stable identifiers for ${appNames}: URLs, project paths, object IDs, or naming conventions.`);

  if ((task.transcriptCount ?? 0) > 0) {
    docs.add("Rules for handling transcript content, retention, and sensitive meeting data.");
  }
  if ((task.screenshotCount ?? 0) > 0) {
    docs.add("Screenshot retention policy and whether screenshots may be used in generated documentation.");
  }

  return [...docs];
}

function formatWorkflowStep(step, index) {
  const label = step.label || humanizeEventType(step.eventType);
  const context = [step.appName, step.windowTitle].filter(Boolean).join(" - ");
  const evidence = [
    step.screenshotPath ? `screenshot: ${step.screenshotPath}` : "",
    step.transcriptPath ? `transcript: ${step.transcriptPath}` : "",
    step.coordinate ? `captured coordinate: ${Math.round(step.coordinate.x)}, ${Math.round(step.coordinate.y)}` : ""
  ].filter(Boolean);
  const evidenceText = evidence.length ? ` Evidence: ${evidence.join("; ")}.` : "";
  return `${index + 1}. ${label}${context ? ` (${context})` : ""}.${evidenceText}`;
}

function slugify(value) {
  return String(value)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "")
    .slice(0, 72) || "activity-task";
}

function titleCase(value) {
  return String(value)
    .split(/\s+/)
    .filter(Boolean)
    .map((word) => word[0]?.toUpperCase() + word.slice(1))
    .join(" ");
}
