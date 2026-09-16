import assert from "node:assert/strict";
import fs from "node:fs/promises";
import test from "node:test";
import { parseActivityText, resolveMediaPath, summarizeEvents } from "../server/activityParser.js";

test("parses JSONL activity events and keeps unknown fields", async () => {
  const text = await fs.readFile(new URL("./fixtures/sample.jsonl", import.meta.url), "utf8");
  const { events, errors } = parseActivityText(text, "sample.jsonl");

  assert.equal(errors.length, 0);
  assert.equal(events.length, 7);
  assert.equal(events[0].eventType, "session_started");
  assert.equal(events[4].screenshotPath, "2026-06-04/shot.jpg");
});

test("parses JSON array exports", () => {
  const { events, errors } = parseActivityText(JSON.stringify([
    { id: "a", timestamp: "2026-06-04T00:00:00.000Z", eventType: "left_click", custom: true }
  ]));

  assert.equal(errors.length, 0);
  assert.equal(events.length, 1);
  assert.equal(events[0].unknown.custom, true);
});

test("summarizes app, type, screenshot, and transcript counts", async () => {
  const text = await fs.readFile(new URL("./fixtures/sample.jsonl", import.meta.url), "utf8");
  const { events } = parseActivityText(text, "sample.jsonl");
  const summary = summarizeEvents(events);

  assert.equal(summary.eventCount, 7);
  assert.equal(summary.screenshotCount, 1);
  assert.equal(summary.apps[0].name, "Google Chrome");
});

test("rejects media traversal outside activity root", () => {
  assert.equal(resolveMediaPath("/tmp/activity", "screenshots", "../secret.txt"), null);
  assert.match(resolveMediaPath("/tmp/activity", "screenshots", "2026-06-04/shot.jpg"), /screenshots/);
});
