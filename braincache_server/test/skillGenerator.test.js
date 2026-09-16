import assert from "node:assert/strict";
import fs from "node:fs/promises";
import test from "node:test";
import { parseActivityText } from "../server/activityParser.js";
import { inferTasks } from "../server/taskInference.js";
import { generateSkillMarkdown } from "../server/skillGenerator.js";

test("generates a generalized, reusable skill with access, procedure, and where-to-find sections", async () => {
  const text = await fs.readFile(new URL("./fixtures/sample.jsonl", import.meta.url), "utf8");
  const { events } = parseActivityText(text, "sample.jsonl");
  const [task] = inferTasks(events, { gapMinutes: 10 });
  const markdown = generateSkillMarkdown(task);

  assert.match(markdown, /^# /);
  assert.match(markdown, /## Required Access/);
  assert.match(markdown, /## Procedure/);
  assert.match(markdown, /## Where to find details/);
  assert.match(markdown, /## Inputs/);
  assert.match(markdown, /Browser automation|Filesystem|Accessibility/);
});
