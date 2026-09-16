# BrainCache Workflow Studio

Local Node.js + React console that turns recorded Activity Capture logs into a
clear map of what you were doing — and then into reusable agent skills.

Built for enterprise/B2B review of BrainCache activity data. You create a
**project**, add one or more daily JSONL log files, **initialize** it (an AI
agent reads the logs through tool calls and infers your real-world tasks), then
review each task — how long it took, how many attempts, where the friction was —
and generate an automation-ready `SKILL.md` for any task.

## Run

```bash
cd braincache_server
npm start
```

Open `http://127.0.0.1:8787`.

The Node server has no runtime npm dependencies. The browser UI imports React
from `esm.sh`, so internet access is needed for the first page load.

Requires **Node ≥ 22.5** (uses the built-in `node:sqlite` module).

### AI features

Task analysis and skill authoring use the OpenAI Responses API. Set a key:

```bash
export OPENAI_API_KEY=sk-...
# optional overrides
export OPENAI_MODEL=gpt-5.5          # default
export OPENAI_MAX_TOOL_ROUNDS=8      # agentic loop depth
export OPENAI_MAX_TOOL_CALLS=14      # total tool calls per run
export OPENAI_TIMEOUT_MS=120000      # per-request timeout
```

The server also auto-loads a `.env` at the repo root or in `braincache_server/`.
Without a key, a built-in heuristic analyzer is used (and skills fall back to a
deterministic template) so the app still works offline.

## Test

```bash
cd braincache_server
npm test
```

## Workflow

1. **Create a project** in the left sidebar.
2. **Add logs** — drop in `.jsonl`/`.json` files, or use "Load from disk" to add
   a local path or the latest 31 days from a `logs/` directory.
3. **Initialize** — the agent reads the events (and inspects screenshots and
   transcripts when helpful) and groups them into tasks. Progress streams live.
4. **Review** — each task shows plain-language steps, time spent, attempts,
   corrections, app switches, and outcome. Open "Raw events" to inspect any
   single event with its screenshot.
5. **Create a skill** — the agent studies the task's evidence and writes a
   `SKILL.md` you can copy or download.
6. **Edit a process** — fix any task's title, summary, or steps from the task
   detail's **Edit** button.
7. **Chat** — the **Chat** tab lets you ask follow-up questions about the logs
   and the extracted tasks. Conversation history is kept, so follow-ups
   ("which of those did I do first?") work, and the agent uses the same tools to
   look up real evidence before answering.

## Storage

Everything persists in a single **SQLite database** at `braincache_server/data/braincache.db`
(gitignored), via Node's built-in `node:sqlite` — no database server or npm
dependency to install. Tables: `projects` (with analysis + last-run as JSON
columns), `sources` (raw uploaded JSONL), `skills`, and `messages` (chat
history). Override the location with `BRAINCACHE_DATA_ROOT` or `BRAINCACHE_DB_PATH`.

All storage goes through `server/projectStore.js`, so the rest of the app is
storage-agnostic.

## Activity root

Screenshots and transcripts referenced by events live under an activity root:

```text
logs/
screenshots/
transcripts/
recordings/
```

This defaults to `BRAINCACHE_ACTIVITY_ROOT` (or `/Users/bespaloff/Documents/LogsActivity`)
and is stored per project.

## Notes

- No login by design — meant for local, trusted use. Do not expose the API to a
  network without adding authentication and path allow-listing.
- Click coordinates are treated as evidence, not stable automation targets.
  Generated skills prefer URLs, visible text, accessibility labels, and file
  paths.
- Labels are written for non-technical readers: raw event types, CSS selectors,
  UUIDs, and typed-text contents are never surfaced.
