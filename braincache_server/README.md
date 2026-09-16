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

### AI features — NVIDIA Nemotron on Nebius Token Factory

All inference goes through **Nebius Token Factory**, which is OpenAI-compatible
at `https://api.tokenfactory.nebius.com/v1` (bearer auth, `POST /chat/completions`,
`POST /embeddings`, `GET /models`). There is no Responses API and no
`/audio/transcriptions` endpoint there, so this server talks Chat Completions
only, and audio goes through the omni model as a chat message part.

```bash
cp ../.env.example ../.env   # then fill in NEBIUS_API_KEY
npm start
```

Without a key nothing calls out: analysis degrades to the built-in heuristic
analyzer, skills fall back to the deterministic template, and every surface says
which variable to set.

#### How Nemotron and Token Factory are used

Workflow Studio is an agent, not a single prompt: it reads your logs through
tool calls, decides what to look at next, and only then writes the analysis.
Token Factory serves four Nemotron variants from one endpoint and one bearer
token, so routing each job to the right size of model is a model-name change on
the same code path — that is the whole reason the pipeline below is affordable
to run over a month of logs.

| Job | Role | Default model | Why this one |
|---|---|---|---|
| Tool-calling analysis loop, skill authoring | `agent` | **Nemotron 3 Super** (`nvidia/nemotron-3-super-120b-a12b`) | Long context over event batches, dependable multi-round tool calling. |
| Final cross-app goal grouping | `reasoning` | **Nemotron 3 Ultra** (`nvidia/Nemotron-3-Ultra-550b-a55b`) | The one step where reasoning quality decides whether the extracted workflow is right. |
| Chat follow-ups in the Chat tab | `fast` | **Nemotron 3 Nano** (`nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B`) | Interactive questions; latency matters more than depth. |
| Screenshot inspection, recording transcription | `omni` | **Nemotron 3 Nano Omni** (`nvidia/Nemotron-3-Nano-Omni-30B-A3B-Reasoning`) | Omni-modal: images and audio go straight into chat completions, no separate vision or ASR service. |

The analysis run is two passes. First the **agent** model loops over the tools
(`list_events`, `search_events`, `get_event_detail`, `inspect_screenshot`,
`read_transcript`, `transcribe_recording`) for at most `AI_MAX_TOOL_ROUNDS`
rounds / `AI_MAX_TOOL_CALLS` calls and returns tasks as JSON; when the budget
runs out the next request is sent with `tool_choice: "none"` so the model has to
answer. Then the **reasoning** model gets the finished task list (plus your
defined goals, if any) and returns only the goal grouping — the cross-app step
where "SAP, then a browser, then Excel, then email" has to be recognised as one
business outcome. If that pass fails or returns unusable JSON, the agent's own
goals are kept and the Overview shows a warning. The models actually used appear
as a chip in the Overview (`analysis.models`).

Nemotron reasoning models may wrap their thinking in `<think>…</think>`; every
response is passed through `stripThinkTags()` before it is parsed.

#### Meeting transcription with the omni model

The **Logs** tab lists everything under `<activityRoot>/recordings/` with its
transcript status and a **Transcribe recordings (Nemotron Omni)** button that
streams progress. Per recording:

1. Convert to 16 kHz mono 16-bit WAV (`afconvert` on macOS, otherwise `ffmpeg`;
   an existing `.wav` is used as-is).
2. Split the PCM into `AI_TRANSCRIBE_CHUNK_SECONDS` (default 10-minute) chunks,
   rewriting a canonical WAV header per chunk.
3. Send each chunk to the omni model as an `audio_url` data URI in a chat
   message, with thinking disabled and `top_k: 1`.
4. Join the pieces and write `<activityRoot>/transcripts/<same path>.txt`.

The transcript then behaves like any other transcript: the agent can read it
with `read_transcript`, or transcribe a recording on demand mid-analysis with
`transcribe_recording`. Already-transcribed recordings are read from disk, never
re-billed.

Endpoints: `GET /api/projects/:id/recordings` lists recordings and whether each
has a transcript; `POST /api/projects/:id/transcribe` (SSE) transcribes the ones
that don't, or the `paths` you name.

#### Environment

| Variable | Default | Purpose |
|---|---|---|
| `NEBIUS_API_KEY` | — | Token Factory key. Without it the heuristic analyzer runs. |
| `NEBIUS_BASE_URL` | `https://api.tokenfactory.nebius.com/v1` | API base URL |
| `NEMOTRON_FAST_MODEL` | `nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B` | Chat follow-ups |
| `NEMOTRON_AGENT_MODEL` | `nvidia/nemotron-3-super-120b-a12b` | Analysis loop + skills |
| `NEMOTRON_REASONING_MODEL` | `nvidia/Nemotron-3-Ultra-550b-a55b` | Goal grouping pass |
| `NEMOTRON_OMNI_MODEL` | `nvidia/Nemotron-3-Nano-Omni-30B-A3B-Reasoning` | Audio + vision |

Model ids are the part of this configuration most likely to drift. If the
provider rejects one as unknown, the client asks `GET /models` what it actually
serves, picks the model matching that role (nano, super, ultra or omni),
remembers it for the rest of the process, and retries the request once. A wrong
id therefore costs one extra round trip instead of breaking the feature.
| `AI_MAX_TOOL_ROUNDS` | `8` | Tool-calling rounds per run |
| `AI_MAX_TOOL_CALLS` | `14` | Total tool calls per run |
| `AI_TIMEOUT_MS` | `240000` | Per chat-completions request |
| `AI_MAX_OUTPUT_TOKENS` | `24000` | `max_tokens` for the analysis JSON |
| `AI_TRANSCRIBE_TIMEOUT_MS` | `600000` | Per audio chunk |
| `AI_TRANSCRIBE_CHUNK_SECONDS` | `600` | Audio chunk length |
| `AI_API_KEY` / `AI_BASE_URL` | — | Point every role at any other OpenAI-compatible gateway |
| `OPENAI_API_KEY` / `OPENAI_MODEL` | — | Legacy fallback, used only when no Nebius/generic key is set |

The server auto-loads a `.env` from the repo root or `braincache_server/`.

## Test

```bash
cd braincache_server
npm test
```

## Workflow

1. **Create a project** in the left sidebar.
2. **Add logs** — drop in `.jsonl`/`.json` files, or use "Load from disk" to add
   a local path or the latest 31 days from a `logs/` directory.
3. **Transcribe recordings** (optional) — run any meeting audio under
   `recordings/` through Nemotron 3 Nano Omni so the agent can quote it.
4. **Initialize** — the agent reads the events (and inspects screenshots and
   transcripts when helpful) and groups them into tasks. Progress streams live.
5. **Review** — each task shows plain-language steps, time spent, attempts,
   corrections, app switches, and outcome. Open "Raw events" to inspect any
   single event with its screenshot.
6. **Create a skill** — the agent studies the task's evidence and writes a
   `SKILL.md` you can copy or download.
7. **Edit a process** — fix any task's title, summary, or steps from the task
   detail's **Edit** button.
8. **Chat** — the **Chat** tab lets you ask follow-up questions about the logs
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

This defaults to `BRAINCACHE_ACTIVITY_ROOT` (or `~/Documents/LogsActivity`)
and is stored per project.

## Notes

- No login by design — meant for local, trusted use. Do not expose the API to a
  network without adding authentication and path allow-listing.
- Click coordinates are treated as evidence, not stable automation targets.
  Generated skills prefer URLs, visible text, accessibility labels, and file
  paths.
- Labels are written for non-technical readers: raw event types, CSS selectors,
  UUIDs, and typed-text contents are never surfaced.
