import path from "node:path";

const ISO_DAY_RE = /^\d{4}-\d{2}-\d{2}$/;

export const ACTIVITY_EVENT_FIELDS = [
  "id",
  "timestamp",
  "appName",
  "bundleID",
  "windowTitle",
  "eventType",
  "controlRole",
  "controlName",
  "controlValue",
  "clickX",
  "clickY",
  "windowClickX",
  "windowClickY",
  "nearbyText",
  "url",
  "screenshotPath",
  "audioPath",
  "transcriptPath",
  "windowIdentifier",
  "triggerMetadata",
  "aiPrompt",
  "aiResponse",
  "aiAttachedWindow"
];

export function parseActivityText(text, sourceName = "uploaded.jsonl") {
  const trimmed = String(text ?? "").trim();
  if (!trimmed) {
    return { events: [], errors: [] };
  }

  if (trimmed.startsWith("[")) {
    try {
      const parsed = JSON.parse(trimmed);
      if (!Array.isArray(parsed)) {
        return { events: [], errors: [{ line: 1, message: "Top-level JSON is not an array." }] };
      }
      return normalizeEvents(parsed, sourceName, []);
    } catch (error) {
      return { events: [], errors: [{ line: 1, message: error.message }] };
    }
  }

  const events = [];
  const errors = [];
  const lines = String(text).split(/\r?\n/);
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index].trim();
    if (!line) continue;
    try {
      events.push(normalizeEvent(JSON.parse(line), sourceName, index + 1));
    } catch (error) {
      errors.push({ line: index + 1, message: error.message });
    }
  }
  return { events: sortEvents(events), errors };
}

export function normalizeEvents(rawEvents, sourceName = "events.json", errors = []) {
  const events = [];
  rawEvents.forEach((raw, index) => {
    try {
      events.push(normalizeEvent(raw, sourceName, index + 1));
    } catch (error) {
      errors.push({ line: index + 1, message: error.message });
    }
  });
  return { events: sortEvents(events), errors };
}

export function normalizeEvent(raw, sourceName, lineNumber) {
  if (!raw || typeof raw !== "object") {
    throw new Error("Event must be an object.");
  }
  const timestamp = stringOrNull(raw.timestamp);
  const parsedTime = timestamp ? Date.parse(timestamp) : Number.NaN;
  const unknown = {};
  for (const [key, value] of Object.entries(raw)) {
    if (!ACTIVITY_EVENT_FIELDS.includes(key)) unknown[key] = value;
  }

  return {
    id: stringOrNull(raw.id) ?? `${sourceName}:${lineNumber}`,
    timestamp,
    timeMs: Number.isFinite(parsedTime) ? parsedTime : null,
    day: timestamp?.slice(0, 10) ?? dayFromSourceName(sourceName),
    appName: stringOrNull(raw.appName) ?? "Unknown app",
    bundleID: stringOrNull(raw.bundleID) ?? "",
    windowTitle: stringOrNull(raw.windowTitle) ?? "",
    eventType: stringOrNull(raw.eventType) ?? "unknown",
    controlRole: stringOrNull(raw.controlRole),
    controlName: stringOrNull(raw.controlName),
    controlValue: stringOrNull(raw.controlValue),
    clickX: numberOrNull(raw.clickX),
    clickY: numberOrNull(raw.clickY),
    windowClickX: numberOrNull(raw.windowClickX),
    windowClickY: numberOrNull(raw.windowClickY),
    nearbyText: stringOrNull(raw.nearbyText),
    url: stringOrNull(raw.url),
    screenshotPath: stringOrNull(raw.screenshotPath),
    audioPath: stringOrNull(raw.audioPath),
    transcriptPath: stringOrNull(raw.transcriptPath),
    windowIdentifier: stringOrNull(raw.windowIdentifier),
    triggerMetadata: stringOrNull(raw.triggerMetadata),
    aiPrompt: stringOrNull(raw.aiPrompt),
    aiResponse: stringOrNull(raw.aiResponse),
    aiAttachedWindow: stringOrNull(raw.aiAttachedWindow),
    sourceName,
    lineNumber,
    unknown,
    raw
  };
}

export function buildDataset(files) {
  const events = [];
  const errors = [];
  for (const file of files) {
    const parsed = parseActivityText(file.content, file.name);
    events.push(...parsed.events);
    errors.push(...parsed.errors.map((error) => ({ ...error, sourceName: file.name })));
  }

  const sortedEvents = sortEvents(events);
  return {
    events: sortedEvents,
    errors,
    summary: summarizeEvents(sortedEvents)
  };
}

export function summarizeEvents(events) {
  const byApp = new Map();
  const byType = new Map();
  const days = new Set();
  let firstTime = null;
  let lastTime = null;
  let screenshotCount = 0;
  let transcriptCount = 0;
  let aiAssistCount = 0;

  for (const event of events) {
    increment(byApp, event.appName || "Unknown app");
    increment(byType, event.eventType || "unknown");
    if (event.day) days.add(event.day);
    if (event.screenshotPath) screenshotCount += 1;
    if (event.transcriptPath || event.eventType?.includes("transcript")) transcriptCount += 1;
    if (event.eventType === "ai_assist_response") aiAssistCount += 1;
    if (event.timeMs) {
      firstTime = firstTime === null ? event.timeMs : Math.min(firstTime, event.timeMs);
      lastTime = lastTime === null ? event.timeMs : Math.max(lastTime, event.timeMs);
    }
  }

  return {
    eventCount: events.length,
    dayCount: days.size,
    days: [...days].sort(),
    firstTimestamp: firstTime ? new Date(firstTime).toISOString() : null,
    lastTimestamp: lastTime ? new Date(lastTime).toISOString() : null,
    durationMinutes: firstTime && lastTime ? Math.round((lastTime - firstTime) / 60000) : 0,
    screenshotCount,
    transcriptCount,
    aiAssistCount,
    apps: topEntries(byApp, 12),
    eventTypes: topEntries(byType, 16)
  };
}

export function resolveMediaPath(activityRoot, kind, relativePath) {
  if (!activityRoot || !relativePath) return null;
  const allowed = new Set(["screenshots", "recordings", "transcripts"]);
  if (!allowed.has(kind)) return null;
  const root = path.resolve(activityRoot);
  const resolved = path.resolve(root, kind, relativePath);
  const kindRoot = path.resolve(root, kind);
  if (!resolved.startsWith(kindRoot + path.sep) && resolved !== kindRoot) return null;
  return resolved;
}

function sortEvents(events) {
  return [...events].sort((a, b) => {
    if (a.timeMs !== null && b.timeMs !== null && a.timeMs !== b.timeMs) return a.timeMs - b.timeMs;
    return String(a.id).localeCompare(String(b.id));
  });
}

function dayFromSourceName(sourceName) {
  const base = path.basename(sourceName, path.extname(sourceName));
  return ISO_DAY_RE.test(base) ? base : null;
}

function stringOrNull(value) {
  if (value === null || value === undefined) return null;
  const text = String(value);
  return text.length ? text : null;
}

function numberOrNull(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function increment(map, key) {
  map.set(key, (map.get(key) ?? 0) + 1);
}

function topEntries(map, limit) {
  return [...map.entries()]
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .slice(0, limit)
    .map(([name, count]) => ({ name, count }));
}
