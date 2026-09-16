// Browser copy of the friendly-label logic (mirrors server/labels.js).
// Activity Capture stores technical signals; this renders them in plain language.

const SHORTCUT_NAMES = {
  "⌘C": "Copy", "⌘V": "Paste", "⌘X": "Cut", "⌘A": "Select all",
  "⌘S": "Save", "⌘Z": "Undo", "⌘⇧Z": "Redo", "⇧⌘Z": "Redo",
  "⌘F": "Find", "⌘G": "Find next", "⌘T": "New tab", "⌘W": "Close tab",
  "⌘⇧T": "Reopen tab", "⌘N": "New window", "⌘P": "Print", "⌘R": "Reload",
  "⌘L": "Focus address bar", "⌘Q": "Quit app", "⌘,": "Open settings",
  "⌘⏎": "Confirm", "⌘↩": "Confirm", "⌘K": "Command palette",
  "⌘⇧P": "Command palette", "⌘B": "Toggle sidebar", "⌘/": "Toggle comment",
  "⌃C": "Stop the running process (Control-C)", "⌃D": "Sign out / end input (Control-D)",
  "⌃Z": "Pause the process (Control-Z)", "⌃R": "Search history (Control-R)",
  "⌃A": "Jump to line start", "⌃E": "Jump to line end"
};

const EVENT_TYPE_LABELS = {
  session_started: "Started recording",
  session_stopped: "Stopped recording",
  app_activated: "Switched app",
  window_focused: "Focused a window",
  window_title_changed: "Changed window",
  left_click: "Clicked",
  right_click: "Right-clicked",
  other_click: "Clicked",
  key_shortcut: "Keyboard shortcut",
  text_input: "Typed text",
  screenshot_captured: "Took a screenshot",
  periodic_capture: "Snapshot",
  idle_resumed: "Returned after a break",
  ai_assist_response: "Used AI Assist",
  meeting_transcript_started: "Started a transcript",
  meeting_transcript_stopped: "Saved a transcript"
};

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const CSS_SELECTOR_RE = /^[.#]?[A-Za-z0-9_-]+(?:[.#][A-Za-z0-9_-]+)+$/;
const LEADING_DOT_RE = /^\.[A-Za-z]/;

function isTechnicalToken(value) {
  const text = String(value ?? "").trim();
  if (!text) return true;
  if (UUID_RE.test(text)) return true;
  if (LEADING_DOT_RE.test(text)) return true;
  if (CSS_SELECTOR_RE.test(text) && /[.#]/.test(text)) return true;
  if (!/[A-Za-z0-9]/.test(text)) return true;
  return false;
}

function cleanTitle(title) {
  return String(title || "")
    .replace(/\s+/g, " ")
    .replace(/\s+[—–-]\s+(Google Chrome|Safari|Cursor|Visual Studio Code|Xcode)$/i, "")
    .trim();
}

function shorten(value, limit) {
  const text = String(value ?? "").replace(/\s+/g, " ").trim();
  if (text.length <= limit) return text;
  return `${text.slice(0, limit - 1)}…`;
}

function friendlyTarget(event) {
  const candidates = [event.nearbyText, event.controlName, event.controlValue, event.url];
  for (const candidate of candidates) {
    if (candidate && !isTechnicalToken(candidate)) return shorten(cleanTitle(candidate), 64);
  }
  if (event.windowTitle && !isTechnicalToken(event.windowTitle)) return shorten(cleanTitle(event.windowTitle), 64);
  return "";
}

function friendlyShortcut(combo) {
  const text = String(combo || "").trim();
  if (!text) return "";
  const name = SHORTCUT_NAMES[text];
  return name ? `${name} (${text})` : text;
}

export function friendlyEventType(type) {
  if (EVENT_TYPE_LABELS[type]) return EVENT_TYPE_LABELS[type];
  return String(type || "Activity").split("_").filter(Boolean).map((word) => word[0]?.toUpperCase() + word.slice(1)).join(" ");
}

export function friendlyEventLabel(event) {
  if (!event) return "";
  const app = event.appName || "the app";
  const target = friendlyTarget(event);
  switch (event.eventType) {
    case "session_started": return `Started recording in ${app}`;
    case "session_stopped": return "Stopped recording";
    case "app_activated": {
      const window = event.windowTitle && !isTechnicalToken(event.windowTitle) ? ` — ${shorten(cleanTitle(event.windowTitle), 56)}` : "";
      return `Opened ${app}${window}`;
    }
    case "window_focused": return target ? `Focused “${target}” in ${app}` : `Focused a window in ${app}`;
    case "window_title_changed": return target ? `Switched to “${target}” in ${app}` : `Switched windows in ${app}`;
    case "left_click":
    case "other_click": return target ? `Clicked “${target}” in ${app}` : `Clicked in ${app}`;
    case "right_click": return target ? `Right-clicked “${target}” in ${app}` : `Right-clicked in ${app}`;
    case "key_shortcut": {
      const shortcut = friendlyShortcut(event.controlName);
      return shortcut ? `Pressed ${shortcut} in ${app}` : `Used a keyboard shortcut in ${app}`;
    }
    case "text_input": return `Typed text in ${app}`;
    case "screenshot_captured":
    case "periodic_capture": return `Took a screenshot of ${app}`;
    case "idle_resumed": return `Returned to ${app} after a break`;
    case "ai_assist_response": return event.aiPrompt ? `Asked AI Assist: “${shorten(event.aiPrompt, 64)}”` : `Used AI Assist in ${app}`;
    case "meeting_transcript_stopped": return "Saved a meeting transcript";
    default: return target ? `${friendlyEventType(event.eventType)}: ${target}` : `${friendlyEventType(event.eventType)} in ${app}`;
  }
}

// App icon categories (UI-only — not mirrored on the server). Order matters:
// the first matching pattern wins, so e.g. Outlook hits "email" before "word".
// The SVG glyph for each category lives in app.js (APP_ICON_SHAPES).
const APP_CATEGORIES = [
  { cls: "browser", match: /safari|chrome|firefox|\barc\b|edge|brave|opera|vivaldi/i },
  { cls: "email", match: /\bmail\b|gmail|outlook|spark|airmail|thunderbird|mimestream|superhuman/i },
  { cls: "pdf", match: /preview|acrobat|pdf/i },
  { cls: "sap", match: /\bsap\b|fiori/i },
  { cls: "word", match: /\bword\b|\bpages\b/i },
  { cls: "excel", match: /excel|numbers|sheets/i },
  { cls: "slides", match: /powerpoint|keynote/i },
  { cls: "code", match: /cursor|visual studio|vs ?code|xcode|terminal|iterm|warp|intellij|pycharm|webstorm/i },
  { cls: "chat", match: /slack|messages|telegram|discord|whatsapp|teams|zoom/i },
  { cls: "files", match: /finder/i },
  { cls: "notes", match: /\bnotes\b|notion|obsidian|\bbear\b/i },
  { cls: "calendar", match: /calendar|fantastical/i }
];

export function appMeta(appName) {
  const name = String(appName || "").trim();
  for (const category of APP_CATEGORIES) {
    if (category.match.test(name)) return { cls: category.cls, name };
  }
  return { cls: "default", initial: (name[0] || "•").toUpperCase(), name };
}

export function outcomeMeta(outcome) {
  return {
    completed: { label: "Completed", cls: "green" },
    incomplete: { label: "Incomplete", cls: "amber" },
    partial: { label: "Partial", cls: "amber" },
    abandoned: { label: "Abandoned", cls: "red" }
  }[outcome] || { label: "Completed", cls: "green" };
}
