# BrainCache OS

**Privacy-first activity recorder for macOS + Workflow Studio that turns real work logs into reviewed tasks, effort metrics and reusable agent skills. Powered by NVIDIA Nemotron on Nebius Token Factory.**

Built for the [Nebius x NVIDIA Global AI Hackathon](https://nebiusglobalaihackathon.devpost.com/) (Best Apps and Agents track). MIT licensed.

> Every company runs on workflows that live only in people's heads. BrainCache watches real work (with consent), understands it with open models running on infrastructure you control, and writes the playbook.

## What is in this repo

| Component | Path | What it does |
|---|---|---|
| **BrainCache for macOS** | `ClipVault/` | Native Swift/AppKit menu-bar app: clipboard history with hybrid search, activity recorder (clicks, shortcuts, window screenshots, meeting/voice transcripts), writing assistant, Ask AI. |
| **`braincache` CLI** | `ClipVault/BrainCacheCLI/` | Read-only CLI over the on-disk SQLite DB and activity logs. Embedded in the app bundle. See [`docs/CLI.md`](docs/CLI.md). |
| **Workflow Studio** | `braincache_server/` | Local Node.js + React console for team leads: drop in daily activity logs, a Nemotron agent infers business-outcome tasks, effort metrics and generates `SKILL.md` files. Transcribes meeting recordings with Nemotron 3 Nano Omni. |
| **Demo dataset** | `demo_activity_ai_finance/` | A fictional month-end close workspace for recording a demo session (no real data). |

## How NVIDIA Nemotron and Nebius Token Factory are used

All inference goes through Nebius Token Factory's OpenAI-compatible API (`https://api.tokenfactory.nebius.com/v1`). Models are routed by job so the app stays responsive and credits stretch:

| Job | Model | Why |
|---|---|---|
| Per-event labelling, clip classification, voice rewrite, quick chat follow-ups | **Nemotron 3 Nano** (`nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B`) | Thousands of small calls per day of logs; latency and cost matter more than depth. |
| Agentic log analysis loop, skill authoring, RAG chat, writing assistant | **Nemotron 3 Super** (`nvidia/nemotron-3-super-120b-a12b`) | Long context over event batches and dependable multi-round tool calling. |
| Final cross-app goal assignment | **Nemotron 3 Ultra** (`nvidia/Nemotron-3-Ultra-550b-a55b`) | The one step where reasoning quality decides whether the extracted workflow is correct. |
| Voice / meeting transcription, screenshot inspection, image description | **Nemotron 3 Nano Omni** (`nvidia/Nemotron-3-Nano-Omni-30B-A3B-Reasoning`) | Omni-modal: audio is sent straight to the model through chat completions, no separate ASR service. |
| Semantic search embeddings | `Qwen/Qwen3-Embedding-8B` on Token Factory, truncated to 256 dims (Matryoshka) | Keeps the existing 1 KB-per-clip vector store. |

Every model ID is configurable (environment variables for the server, Preferences → AI in the app). OpenAI remains available as an alternative provider so nothing regresses, but Nemotron on Nebius is the default.

### Where Token Factory accelerated the work

* One OpenAI-compatible endpoint serves Nano, Super, Ultra and Omni, so per-job routing is a model-name change and the same client code path serves all of them.
* Streaming chat completions feed the live progress views in both the app and Workflow Studio.
* Audio understanding through the Omni model replaced a proprietary realtime speech API: the Mac app now chunks microphone / system audio into short WAV segments and transcribes them with Nemotron, and Workflow Studio transcribes whole meeting recordings the same way.

## Quick start

### 1. Get a Nebius Token Factory key

Create a key at [tokenfactory.nebius.com](https://tokenfactory.nebius.com/).

```bash
cp .env.example .env      # then put your key in NEBIUS_API_KEY
```

### 2. Workflow Studio (server)

Requires Node >= 22.5 (uses the built-in `node:sqlite`). No runtime npm dependencies.

```bash
cd braincache_server
npm test          # unit tests (node --test)
npm start         # http://127.0.0.1:8787
```

Create a project, add one or more daily `YYYY-MM-DD.jsonl` activity logs (the Mac app writes them, or use any JSONL in the same event format), press **Initialize**, review the tasks, generate a skill. Use **Transcribe recordings** to run meeting recordings through Nemotron 3 Nano Omni so the agent can quote them.

Environment variables (see `.env.example`):

| Variable | Default | Purpose |
|---|---|---|
| `NEBIUS_API_KEY` | — | Token Factory API key (required for AI features; without it a heuristic analyzer runs) |
| `NEBIUS_BASE_URL` | `https://api.tokenfactory.nebius.com/v1` | API base URL |
| `NEMOTRON_FAST_MODEL` | `nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B` | Nano |
| `NEMOTRON_AGENT_MODEL` | `nvidia/nemotron-3-super-120b-a12b` | Super |
| `NEMOTRON_REASONING_MODEL` | `nvidia/Nemotron-3-Ultra-550b-a55b` | Ultra |
| `NEMOTRON_OMNI_MODEL` | `nvidia/Nemotron-3-Nano-Omni-30B-A3B-Reasoning` | Omni (audio + vision) |

If the provider rejects any of these ids as unknown, the client asks `GET /models` what it serves, picks the model for that role, and retries once.

### 3. macOS app

Requires macOS 13+, Xcode 16+, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
cd ClipVault
xcodegen generate
xcodebuild build -scheme ClipVault -destination 'platform=macOS'
# or run an isolated dev variant (separate bundle ID and data):
./scripts/dev-run.sh
```

Then open **Preferences → AI**, pick **Nebius Token Factory**, paste the key. The background pipeline starts classifying and embedding clipboard history, Ask AI and the writing assistant use Nemotron 3 Super, and the voice panel transcribes through Nemotron 3 Nano Omni.

Run the test suite (1,000+ tests):

```bash
cd ClipVault
xcodebuild test -scheme ClipVault -destination 'platform=macOS'
```

## Privacy model

* Password fields are never captured; plain keystrokes are never stored (only shortcuts such as ⌘C).
* Password managers and banking apps are excluded from capture by default; any app can be excluded.
* Logs, screenshots and recordings stay in a folder the user picks. Nothing leaves the machine except the inference calls you configure.
* The Mac app never records its own windows.

## Architecture notes

* Mac app: AppKit only (no SwiftUI), GRDB + SQLite FTS5, ScreenCaptureKit, CoreAudio process monitoring for meeting detection, AVAssetWriter with fragment intervals for crash-safe recordings. Details in [`CLAUDE.md`](CLAUDE.md).
* Workflow Studio: single SQLite database via `node:sqlite`, agent loop with tools (`list_events`, `search_events`, `get_event_detail`, `inspect_screenshot`, `read_transcript`, `transcribe_recording`), SSE streaming to a no-build React UI. Details in [`braincache_server/README.md`](braincache_server/README.md).

## License

MIT. See [`LICENSE`](LICENSE).
