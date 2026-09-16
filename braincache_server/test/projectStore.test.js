import assert from "node:assert/strict";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import test from "node:test";

// Point the store at a throwaway data dir before importing it.
const tmp = await fs.mkdtemp(path.join(os.tmpdir(), "braincache-test-"));
process.env.BRAINCACHE_DATA_ROOT = tmp;
const store = await import("../server/projectStore.js");

test("project lifecycle: create, add source, analyze, skill", async () => {
  const project = await store.createProject({ name: "Test", gapMinutes: 10 });
  assert.equal(project.status, "draft");
  assert.equal(project.files.length, 0);

  const sampleText = await fs.readFile(new URL("./fixtures/sample.jsonl", import.meta.url), "utf8");
  const withFile = await store.addSource(project.id, { name: "sample.jsonl", content: sampleText });
  assert.equal(withFile.files.length, 1);
  assert.ok(withFile.files[0].eventCount > 0);

  const { dataset } = await store.loadProjectDataset(project.id);
  assert.ok(dataset.events.length > 0);

  const analyzed = await store.saveAnalysis(project.id, {
    source: "heuristic",
    tasks: [{ id: "task-1", title: "T", events: [], eventIds: [] }]
  });
  assert.equal(analyzed.status, "initialized");

  const withSkill = await store.saveSkill(project.id, "task-1", { markdown: "# Skill", source: "template" });
  assert.equal(withSkill.skills["task-1"].markdown, "# Skill");
  assert.equal(withSkill.skills["task-1"].editedAt, undefined);

  // Manual edits are persisted and flagged.
  const edited = await store.updateSkill(project.id, "task-1", { markdown: "# Skill v2" });
  assert.equal(edited.skills["task-1"].markdown, "# Skill v2");
  assert.ok(edited.skills["task-1"].editedAt);
  await assert.rejects(() => store.updateSkill(project.id, "task-1", { markdown: "  " }));
  await assert.rejects(() => store.updateSkill(project.id, "missing-task", { markdown: "# X" }));

  // Regenerating replaces the edit and clears the flag.
  const regenerated = await store.saveSkill(project.id, "task-1", { markdown: "# Skill v3", source: "template" });
  assert.equal(regenerated.skills["task-1"].markdown, "# Skill v3");
  assert.equal(regenerated.skills["task-1"].editedAt, undefined);

  const list = await store.listProjects();
  assert.ok(list.find((item) => item.id === project.id));

  await store.deleteProject(project.id);
  const after = await store.listProjects();
  assert.equal(after.find((item) => item.id === project.id), undefined);
});

test.after(async () => {
  await fs.rm(tmp, { recursive: true, force: true });
});
