import assert from "node:assert/strict";
import fs from "node:fs/promises";
import test from "node:test";
import { parseActivityText } from "../server/activityParser.js";
import { inferTasks } from "../server/taskInference.js";

test("clusters events into tasks by time gap", async () => {
  const text = await fs.readFile(new URL("./fixtures/sample.jsonl", import.meta.url), "utf8");
  const { events } = parseActivityText(text, "sample.jsonl");
  const tasks = inferTasks(events, { gapMinutes: 10 });

  assert.equal(tasks.length, 2);
  assert.match(tasks[0].title, /Cursor|Chrome|LinkedIn/i);
  assert.ok(tasks[0].steps.length >= 3);
  assert.ok(tasks[0].confidence > 0.5);
});
