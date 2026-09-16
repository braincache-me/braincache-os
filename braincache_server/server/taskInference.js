import { friendlyEventLabel, friendlyEventType, friendlyShortcut, isTechnicalToken } from "./labels.js";

const DEFAULT_GAP_MINUTES = 10;
const NAVIGATION_EVENTS = new Set([
  "app_activated",
  "window_focused",
  "window_title_changed",
  "idle_resumed",
  "periodic_capture",
  "screenshot_captured"
]);
const ACTION_EVENTS = new Set([
  "left_click",
  "right_click",
  "other_click",
  "key_shortcut",
  "text_input",
  "ai_assist_response"
]);

export function inferTasks(events, options = {}) {
  const gapMs = (options.gapMinutes ?? DEFAULT_GAP_MINUTES) * 60 * 1000;
  const clusters = [];
  let current = null;

  for (const event of events) {
    if (!event.timeMs) continue;
    if (!current || shouldStartNewCluster(current, event, gapMs)) {
      current = { events: [] };
      clusters.push(current);
    }
    current.events.push(event);
  }

  return clusters
    .map((cluster, index) => buildTask(cluster.events, index + 1))
    .filter((task) => task.events.length > 0);
}

export function buildTask(events, ordinal) {
  const first = events[0];
  const last = events[events.length - 1];
  const appCounts = countBy(events, (event) => event.appName || "Unknown app");
  const typeCounts = countBy(events, (event) => event.eventType || "unknown");
  const titleCounts = countBy(
    events.filter((event) => event.windowTitle),
    (event) => cleanTitle(event.windowTitle)
  );
  const apps = topNames(appCounts, 4);
  const titles = topNames(titleCounts, 4);
  const verbs = inferVerbs(events);
  const evidence = buildEvidence(events);
  const steps = buildSteps(events);
  const metrics = computeTaskMetrics(events);

  return {
    id: `task-${ordinal}`,
    title: buildTitle({ apps, titles, verbs, events }),
    summary: buildSummary({ apps, titles, verbs, events }),
    confidence: confidenceScore(events, titles, steps),
    startTimestamp: first.timestamp,
    endTimestamp: last.timestamp,
    durationMinutes: Math.max(1, Math.round((last.timeMs - first.timeMs) / 60000)),
    eventCount: events.length,
    actionCount: events.filter((event) => ACTION_EVENTS.has(event.eventType)).length,
    screenshotCount: events.filter((event) => event.screenshotPath).length,
    transcriptCount: events.filter((event) => event.transcriptPath || event.eventType?.includes("transcript")).length,
    apps: apps.map((name) => ({ name, count: appCounts.get(name) })),
    eventTypes: [...typeCounts.entries()]
      .sort((a, b) => b[1] - a[1])
      .map(([name, count]) => ({ name, count })),
    windows: titles,
    verbs,
    steps,
    evidence,
    metrics,
    attempts: metrics.attempts,
    outcome: metrics.outcome,
    events
  };
}

// Estimate how much effort the task took: how many tries, how many corrections
// (undo / delete / interrupt), how many times the person bounced between apps,
// and whether it looks finished. These power the human-facing "effort" readout.
export function computeTaskMetrics(events) {
  const actions = events.filter((event) => ACTION_EVENTS.has(event.eventType));
  const appSwitches = events.filter((event) => event.eventType === "app_activated").length;
  const idlePeriods = events.filter((event) => event.eventType === "idle_resumed").length;

  let corrections = 0;
  for (const event of events) {
    if (event.eventType !== "key_shortcut") continue;
    const combo = String(event.controlName || "");
    if (/⌃C|⌃Z|⌫|⌦|⎋|⌘Z/.test(combo)) corrections += 1;
  }

  // Count near-immediate repeats of the same action as retries.
  let repeats = 0;
  let previousKey = "";
  for (const event of actions) {
    const key = `${event.eventType}|${event.controlName || event.nearbyText || event.url || ""}`;
    if (key === previousKey) repeats += 1;
    previousKey = key;
  }

  // "Attempts" = first pass + a try for every cluster of corrections/repeats.
  const friction = corrections + repeats;
  const attempts = Math.max(1, 1 + Math.round(friction / 3));

  const last = events[events.length - 1];
  const outcome = last?.eventType === "session_stopped" ? "incomplete" : "completed";

  // Time: "span" is wall-clock first→last (can be days, includes idle). "active"
  // sums only the gaps short enough to count as continuous work, so a task that
  // was picked up across several days doesn't report 71 hours of effort.
  const IDLE_GAP_MS = 5 * 60 * 1000;
  const timed = events.filter((event) => event.timeMs).sort((a, b) => a.timeMs - b.timeMs);
  let activeMs = 0;
  for (let i = 1; i < timed.length; i += 1) {
    const gap = timed[i].timeMs - timed[i - 1].timeMs;
    if (gap > 0 && gap <= IDLE_GAP_MS) activeMs += gap;
  }
  const spanMs = timed.length ? timed[timed.length - 1].timeMs - timed[0].timeMs : 0;

  return {
    actions: actions.length,
    appSwitches,
    idlePeriods,
    corrections,
    repeats,
    attempts,
    outcome,
    activeMinutes: Math.round(activeMs / 60000),
    spanMinutes: Math.round(spanMs / 60000)
  };
}

function shouldStartNewCluster(current, event, gapMs) {
  const previous = current.events[current.events.length - 1];
  if (!previous?.timeMs || !event.timeMs) return false;
  const gap = event.timeMs - previous.timeMs;
  if (gap > gapMs) return true;
  if (previous.eventType === "session_stopped" && event.eventType === "session_started") return true;
  return false;
}

function buildTitle({ apps, titles, verbs, events }) {
  const mainApp = apps[0] ?? "Unknown app";
  const mainTitle = titles[0];
  const verb = verbs[0] ?? "Review";
  if (mainTitle && mainTitle !== mainApp) {
    return `${verb} in ${mainApp}: ${shorten(mainTitle, 54)}`;
  }
  const urlHost = firstHost(events);
  if (urlHost) return `${verb} ${urlHost} in ${mainApp}`;
  return `${verb} activity in ${mainApp}`;
}

function buildSummary({ apps, titles, verbs, events }) {
  const appText = apps.slice(0, 3).join(", ");
  const verbText = verbs.length ? verbs.slice(0, 3).join(", ").toLowerCase() : "reviewed activity";
  const detail = titles[0] ? ` around "${shorten(titles[0], 80)}"` : "";
  const actionCount = events.filter((event) => ACTION_EVENTS.has(event.eventType)).length;
  return `Likely ${verbText}${detail} using ${appText}. ${actionCount} direct action${actionCount === 1 ? "" : "s"} captured.`;
}

function inferVerbs(events) {
  const text = events
    .flatMap((event) => [event.windowTitle, event.controlName, event.controlValue, event.nearbyText, event.url, event.aiPrompt])
    .filter(Boolean)
    .join(" ")
    .toLowerCase();
  const matches = [];
  const rules = [
    ["Research", /\b(search|google|linkedin|docs|documentation|read|browse|reddit|github)\b/],
    ["Code", /\b(cursor|xcode|swift|javascript|python|function|class|test|localhost|pull request|github)\b/],
    ["Write", /\b(doc|notes|draft|email|compose|message|proposal|rewrite|text)\b/],
    ["Analyze", /\b(csv|spreadsheet|report|dashboard|metrics|summary|finance|invoice|reconciliation)\b/],
    ["Meet", /\b(meet|zoom|teams|transcript|recording|call)\b/],
    ["Configure", /\b(settings|preferences|install|setup|api key|permission|accessibility)\b/]
  ];
  for (const [verb, pattern] of rules) {
    if (pattern.test(text)) matches.push(verb);
  }
  if (!matches.length) {
    if (events.some((event) => event.eventType === "key_shortcut")) matches.push("Operate");
    else if (events.some((event) => event.eventType?.includes("click"))) matches.push("Navigate");
  }
  return [...new Set(matches)].slice(0, 4);
}

function buildEvidence(events) {
  return events
    .filter((event) => {
      if (ACTION_EVENTS.has(event.eventType)) return true;
      if (event.screenshotPath || event.transcriptPath || event.aiPrompt || event.aiResponse) return true;
      return false;
    })
    .slice(0, 12)
    .map((event) => ({
      id: event.id,
      timestamp: event.timestamp,
      eventType: event.eventType,
      appName: event.appName,
      windowTitle: event.windowTitle,
      label: eventLabel(event),
      screenshotPath: event.screenshotPath,
      transcriptPath: event.transcriptPath
    }));
}

function buildSteps(events) {
  const steps = [];
  let lastLabel = "";

  for (const event of events) {
    if (!isStepEvent(event)) continue;
    const label = eventLabel(event);
    if (!label || label === lastLabel) continue;
    steps.push({
      id: event.id,
      timestamp: event.timestamp,
      appName: event.appName,
      eventType: event.eventType,
      label,
      target: event.controlName || event.nearbyText || event.url || event.windowTitle || "",
      windowTitle: event.windowTitle,
      coordinate: event.clickX !== null && event.clickY !== null ? { x: event.clickX, y: event.clickY } : null,
      screenshotPath: event.screenshotPath,
      transcriptPath: event.transcriptPath
    });
    lastLabel = label;
    if (steps.length >= 28) break;
  }

  return steps;
}

function isStepEvent(event) {
  if (ACTION_EVENTS.has(event.eventType)) return true;
  if (event.eventType === "app_activated") return true;
  if (event.eventType === "window_focused" && event.windowTitle) return true;
  if (event.eventType === "meeting_transcript_stopped") return true;
  return false;
}

// Human-friendly label for one event. Delegates to the shared labels module so
// the server, skill generator, and agent tooling all speak the same language.
export function eventLabel(event) {
  return friendlyEventLabel(event);
}

function confidenceScore(events, titles, steps) {
  let score = 0.35;
  if (events.length >= 6) score += 0.15;
  if (steps.length >= 3) score += 0.2;
  if (titles.length > 0) score += 0.1;
  if (events.some((event) => event.screenshotPath)) score += 0.1;
  if (events.some((event) => event.url || event.nearbyText || event.controlName)) score += 0.1;
  return Math.min(0.95, Math.round(score * 100) / 100);
}

function countBy(items, getKey) {
  const counts = new Map();
  for (const item of items) {
    const key = getKey(item);
    if (!key) continue;
    counts.set(key, (counts.get(key) ?? 0) + 1);
  }
  return counts;
}

function topNames(counts, limit) {
  return [...counts.entries()]
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .slice(0, limit)
    .map(([name]) => name);
}

function cleanTitle(title) {
  return String(title || "")
    .replace(/\s+/g, " ")
    .replace(/\s+[—-]\s+Google Chrome$/i, "")
    .trim();
}

function firstHost(events) {
  for (const event of events) {
    if (!event.url) continue;
    try {
      return new URL(event.url).hostname.replace(/^www\./, "");
    } catch {
      continue;
    }
  }
  return null;
}

export function humanizeEventType(type) {
  return friendlyEventType(type);
}

function shorten(value, limit) {
  const text = String(value ?? "").replace(/\s+/g, " ").trim();
  if (text.length <= limit) return text;
  return `${text.slice(0, limit - 1)}...`;
}
