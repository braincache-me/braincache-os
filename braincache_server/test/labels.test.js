import assert from "node:assert/strict";
import test from "node:test";
import { friendlyEventLabel, friendlyEventType, friendlyShortcut, isTechnicalToken } from "../server/labels.js";
import { computeTaskMetrics } from "../server/taskInference.js";

test("hides technical tokens (CSS selectors, UUIDs)", () => {
  assert.equal(isTechnicalToken(".xterm-screen"), true);
  assert.equal(isTechnicalToken(".lines-content.monaco-editor-background"), true);
  assert.equal(isTechnicalToken("251B330A-CC6B-4DCD-ADCE-10A2C8E6A218"), true);
  assert.equal(isTechnicalToken("\r"), true);
  assert.equal(isTechnicalToken("Search jobs"), false);
});

test("renders friendly click labels without technical control names", () => {
  const label = friendlyEventLabel({ eventType: "left_click", appName: "Cursor", controlName: ".xterm-screen", nearbyText: "" });
  assert.equal(label, "Clicked in Cursor");
  assert.doesNotMatch(label, /xterm/);

  const withText = friendlyEventLabel({ eventType: "left_click", appName: "Google Chrome", nearbyText: "Search jobs" });
  assert.match(withText, /Clicked “Search jobs” in Google Chrome/);
});

test("never surfaces typed text content", () => {
  const label = friendlyEventLabel({ eventType: "text_input", appName: "Cursor", controlValue: "secret value", controlName: "abc" });
  assert.equal(label, "Typed text in Cursor");
});

test("expands keyboard shortcuts to plain language", () => {
  assert.match(friendlyShortcut("⌃C"), /Stop the running process/);
  assert.equal(friendlyShortcut("⌘C"), "Copy (⌘C)");
  assert.match(friendlyEventLabel({ eventType: "key_shortcut", appName: "Cursor", controlName: "⌃C" }), /Stop the running process/);
});

test("friendly event types are readable", () => {
  assert.equal(friendlyEventType("app_activated"), "Switched app");
  assert.equal(friendlyEventType("left_click"), "Clicked");
});

test("computeTaskMetrics counts corrections and attempts", () => {
  const events = [
    { eventType: "left_click", controlName: "Run" },
    { eventType: "key_shortcut", controlName: "⌃C" },
    { eventType: "key_shortcut", controlName: "⌘Z" },
    { eventType: "app_activated" },
    { eventType: "left_click", controlName: "Run" },
    { eventType: "left_click", controlName: "Run" }
  ];
  const metrics = computeTaskMetrics(events);
  assert.equal(metrics.corrections, 2);
  assert.ok(metrics.repeats >= 1);
  assert.ok(metrics.attempts >= 1);
  assert.equal(metrics.appSwitches, 1);
});
