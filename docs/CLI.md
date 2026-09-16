# `braincache` — Command-Line Interface

`braincache` is a small Swift binary that gives other apps and scripts
read-only access to the data BrainCache stores on your Mac: clipboard
history, voice transcripts, and the UI activity recorder's JSONL logs &
screenshots.

It ships **inside the BrainCache app bundle**, so installing BrainCache
also installs the CLI. There is no separate package, no admin prompt, no
symlink dance. Updates that Sparkle delivers refresh the CLI too.

---

## TL;DR

```sh
# Inside the app bundle, no install step needed:
/Applications/BrainCache.app/Contents/Resources/braincache info

# Aliased once in ~/.zshrc / ~/.bashrc:
alias braincache='/Applications/BrainCache.app/Contents/Resources/braincache'

braincache clips list --last 20
braincache clips search "github" --mode hybrid
braincache audio show 21141 --raw
braincache activity day 2026-05-06 --app Safari --limit 50
braincache activity search "session_started" --last-days 7
```

`braincache` defaults to **JSON output when piped** and a **padded table
when run in a terminal**. Force one or the other with `--output json`
or `--output table`.

---

## Install / location

BrainCache is shipped as a regular `.app` bundle. The CLI lives at:

```
/Applications/BrainCache.app/Contents/Resources/braincache
```

(If you installed BrainCache somewhere else, substitute that path.)

Why `Contents/Resources/` and not `Contents/MacOS/`? macOS APFS is
case-insensitive by default — `braincache` and `BrainCache` would
collide as the same file inside `MacOS/`. `Resources/` is the standard
location for embedded helper binaries and avoids that collision.

### Recommended one-time alias

Drop one line into your shell profile so you can call the tool as
`braincache` from anywhere:

```sh
# zsh / bash
echo "alias braincache='/Applications/BrainCache.app/Contents/Resources/braincache'" >> ~/.zshrc
exec zsh

# fish
alias --save braincache '/Applications/BrainCache.app/Contents/Resources/braincache'
```

Or, if you prefer a symlink on `$PATH`:

```sh
sudo ln -s /Applications/BrainCache.app/Contents/Resources/braincache /usr/local/bin/braincache
```

A Sparkle app update will refresh the file inside the bundle; the
symlink (or alias) keeps pointing at the new version automatically.

---

## How it works

The CLI does **not** require the BrainCache app to be running. BrainCache
is not sandboxed, so its on-disk data is plain files in your home
directory. The CLI reads them directly:

| What | Where |
| --- | --- |
| SQLite database | `~/Library/Application Support/ClipVault/clipvault.db` |
| Clipboard media (images, HTML, RTF) | `~/Library/Application Support/ClipVault/media/` |
| Preferences (suite plist) | `~/Library/Preferences/com.clipvault.settings.plist` |
| OpenAI API key | macOS Keychain, service `com.clipvault.openai` |
| Activity JSONL logs | user-chosen folder: `<root>/logs/YYYY-MM-DD.jsonl` |
| Activity screenshots | `<root>/screenshots/YYYY-MM-DD/*.jpg` |
| Activity summaries | `<root>/summaries/YYYY-MM-DD.json` |

Run `braincache info` to see all of those paths resolved on your machine
plus runtime counts (number of clips, embeddings, available activity
days, etc.).

### Concurrent reads with the running app

The CLI opens the SQLite database with the `query_only = 1` PRAGMA and
the `readonly = true` GRDB flag, so it can never write to the database.
SQLite WAL mode (which BrainCache uses) supports multiple read
connections in parallel, so it is safe to run `braincache` while the
BrainCache app is running.

### Development builds (`--dev`)

If you build BrainCache yourself from source (`scripts/dev-run.sh`),
the dev variant writes to `ClipVault-Dev` and a separate UserDefaults
suite. Pass `--dev` to point the CLI at the dev install:

```sh
braincache --dev info
```

`--dev` is recognised by every subcommand.

### Authentication (vector search, AI)

Vector search needs to embed your query against OpenAI's API. The CLI
finds an API key in this order:

1. `OPENAI_API_KEY` environment variable (overrides everything)
2. The same Keychain item BrainCache stores (`com.clipvault.openai`)
3. Legacy plaintext value in UserDefaults (pre-migration)

The first time the CLI reads from the Keychain, macOS asks for your
permission with a system prompt — that's expected. Click "Always Allow"
if you want subsequent runs to be silent.

If no key is configured, vector search returns the friendly error
`No OpenAI API key found.` and exits with code 1. FTS and grep searches
work without a key.

---

## Output format

| Mode | When | What you get |
| --- | --- | --- |
| `auto` (default) | stdout is a TTY | Aligned table with truncated columns |
| `auto` (default) | stdout is piped or redirected | NDJSON — one JSON object per line |
| `--output json` | always | NDJSON, or pretty JSON for `info` / `show` |
| `--output table` | always | Aligned table |

Tables are intentionally lossy: long fields are truncated with `…` so
each row fits one line. If you need the full content of a clip, use
`braincache clips show <id>` (full text in JSON), or pass `--raw` to
get just the body on stdout. The `--full` flag on `list` and `search`
includes the full text/transcript inside the JSON output as well.

### NDJSON schema overview

Every NDJSON line is one record. Field names are camelCase. Timestamps
are ISO-8601 with millisecond precision in UTC (`Z`).

`clips list` / `clips search`:
```json
{
  "id": 21138,
  "createdAt": "2026-05-11T18:35:26.103Z",
  "contentType": "text",
  "sourceApp": "com.google.Chrome",
  "byteSize": 6,
  "isPinned": false,
  "tags": [],
  "mediaFile": null,
  "preview": "697747",
  "text": null,
  "imageDescription": null
}
```

(`text` and `imageDescription` are populated only with `--full`.)

`audio list` / `audio search`:
```json
{
  "id": 21141,
  "createdAt": "2026-05-11T19:11:26.510Z",
  "byteSize": 708,
  "tags": [],
  "preview": "I want other apps to be able to um get the data…",
  "transcript": null
}
```

`activity day` / `activity search` / `activity range`:
```json
{
  "id": "C0B4B…-9F31-…",
  "timestamp": "2026-05-06T14:23:45.123Z",
  "appName": "Safari",
  "bundleID": "com.apple.Safari",
  "windowTitle": "Apple",
  "eventType": "left_click",
  "controlRole": "AXLink",
  "controlName": "Get involved",
  "controlValue": null,
  "clickX": 412.5,
  "clickY": 880.0,
  "nearbyText": null,
  "url": "https://www.apple.com/",
  "screenshotPath": "2026-05-06/2026-05-06T14-23-45-123_Safari_left_click.jpg",
  "screenshotAbsolutePath": "/Users/you/Activity/screenshots/2026-05-06/2026-05-06T14-23-45-123_Safari_left_click.jpg",
  "audioPath": null,
  "audioAbsolutePath": null,
  "aiPrompt": null,
  "aiResponse": null
}
```

`screenshotAbsolutePath` and `audioAbsolutePath` are resolved by the CLI
against the activity root so callers don't have to know where it is.

---

## Subcommands

Every subcommand accepts `--dev` (use the dev variant of the data folder)
and `--output {auto,json,table}` (override the auto-detected format).

### `braincache info`

Print every path the CLI resolves on your machine plus aggregate
statistics. Run this first when you're integrating against the CLI from
another tool — it tells you whether the DB is reachable, whether
activity capture has been configured, and whether an API key is
available for vector search.

```sh
braincache info
braincache info --output json | jq '.activityRoot'
```

Field reference:

| Field | Meaning |
| --- | --- |
| `cliVersion` | CLI release. Bumped when output schema changes. |
| `variant` | `prod` or `dev`. |
| `database.path`, `.exists` | SQLite DB location & whether it's readable. |
| `mediaDirectory.path`, `.exists` | Blob storage for clipboard payloads. |
| `activityRoot` | User-chosen activity folder (null if not configured). |
| `activityDaysAvailable` | List of `YYYY-MM-DD` days with JSONL logs, newest first. |
| `stats.clips`, `.clipboardEntries`, `.audioTranscripts` | Row counts. |
| `stats.embeddings`, `.embeddingDimensions` | Vector index size. |
| `stats.oldestClipAt`, `.newestClipAt` | DB time range. |
| `ai.hasAPIKey`, `.apiKeySource` | Whether vector search will work. |
| `ai.embeddingModel` | Model name used for embeddings. |

### `braincache clips list`

```
braincache clips list [--last N] [--offset N] [--include-audio]
                      [--pinned-only] [--full]
```

The N most recent clipboard entries, newest first. Pinned clips
always come first inside their slice (matching the app's UI). Audio
transcripts are excluded unless `--include-audio` is set — they have a
dedicated subcommand (`braincache audio …`).

```sh
braincache clips list --last 5
braincache clips list --pinned-only
braincache clips list --last 100 --output json | jq '.tags | flatten' | sort | uniq -c
```

### `braincache clips search QUERY`

```
braincache clips search QUERY [--mode {grep,fts,vector,hybrid}]
                              [--limit N] [--case-sensitive]
                              [--fixed-strings] [--include-audio] [--full]
```

Search modes:

| Mode | What it does | Needs API key? |
| --- | --- | --- |
| `fts` *(default)* | SQLite FTS5 phrase search across text and image descriptions. Ranked by relevance with a slight recency boost (same algorithm the BrainCache search panel uses). | No |
| `grep` | NSRegularExpression match against `text_content` and `image_description`. Mirrors how `grep -E` would behave against the full text of every clip. Case-insensitive by default — pass `--case-sensitive`. Use `--fixed-strings` if you want a literal substring search instead of a regex. | No |
| `vector` | Embeds the query with the same model BrainCache uses (default `text-embedding-3-small` @ 256 dims) and returns the top-K clips by cosine distance over the embeddings stored in `clip_embeddings`. | **Yes** |
| `hybrid` | Reciprocal Rank Fusion (k=60) of `fts` and `vector` results — what BrainCache's "Hybrid Search" UI does. Falls back gracefully to FTS-only if vector search fails (no key, no embeddings). | Preferred |

Examples:

```sh
braincache clips search "supabase auth"                     # FTS
braincache clips search '^https://' --mode grep             # regex grep
braincache clips search 'foo.bar' --mode grep --fixed-strings  # literal
braincache clips search "github repo url" --mode vector     # semantic
braincache clips search "kubernetes secrets" --mode hybrid  # best of both
```

### `braincache clips show ID`

```
braincache clips show ID [--raw]
```

Full content of one clip, including the absolute path to the media
file if the clip is image / HTML / RTF.

`--raw` prints **only** the text body (or media path for binary clips),
making it easy to pipe somewhere else:

```sh
braincache clips show 21138 --raw | pbcopy
braincache clips show 21138 --raw > /tmp/clip.html
```

Without `--raw`, you get JSON metadata (id, timestamp, sourceApp,
mediaFile, byte size, etc.) plus the full text.

### `braincache audio list`

```
braincache audio list [--last N] [--offset N] [--full]
```

Last N voice transcription **sessions**, newest first. Each row is one
recorded session — the concatenated mic + system-audio transcript that
BrainCache produced when you used the Voice Panel. Behind the scenes
these live in the same `clips` table as clipboard rows; the CLI
filters to `source_app = "BrainCache Voice"` so you don't have to.

`--full` includes the entire transcript in each JSON record. By default
only a single-line preview is returned to keep the output scannable.

### `braincache audio search QUERY`

Same flags and mode names as `clips search`. Restricted to voice
transcript rows.

```sh
braincache audio search "kubernetes pod restart"
braincache audio search "Q3.*OKR" --mode grep
braincache audio search "ship it conversation" --mode vector
```

### `braincache audio show ID`

Full transcript of one session.

```sh
braincache audio show 21141            # JSON detail
braincache audio show 21141 --raw      # transcript text only
```

### `braincache activity day [DATE]`

```
braincache activity day [DATE] [--app NAME] [--types T1,T2,...]
                               [--with-screenshot] [--limit N]
```

Every event recorded on a given local-calendar day. `DATE` is
`YYYY-MM-DD`; defaults to today.

```sh
braincache activity day                            # today
braincache activity day 2026-05-06 --app Safari    # only Safari events
braincache activity day 2026-05-06 --types left_click,app_activated
braincache activity day 2026-05-06 --with-screenshot --output table
braincache activity day 2026-05-06 --limit 200     # cap output size
```

`--limit 0` (the default) means no cap. Events are returned in
chronological order.

Available `eventType` values include (non-exhaustive): `app_activated`,
`app_focused`, `window_focused`, `left_click`, `right_click`,
`scroll`, `key_shortcut`, `periodic_capture`, `session_started`,
`session_paused`, `session_resumed`, `aiAssistResponse`. See the app's
`ActivityEventType.swift` for the complete list.

### `braincache activity range`

```
braincache activity range --start ISO --end ISO [--app NAME]
                          [--types T1,T2,...] [--limit N]
```

Every event with `timestamp` in `[start, end]`. Useful for slicing
weekly reports or windowing around a specific incident.

```sh
braincache activity range \
  --start 2026-05-04T09:00:00 \
  --end   2026-05-04T18:00:00 \
  --app   "VS Code"

# Whole calendar days work too:
braincache activity range --start 2026-05-01 --end 2026-05-07
```

Timestamps accept either ISO-8601 or `YYYY-MM-DD`.

### `braincache activity search PATTERN`

```
braincache activity search PATTERN [--day YYYY-MM-DD] [--last-days N]
                                   [--case-sensitive] [--fixed-strings]
                                   [--text-only] [--limit N]
```

Grep across the JSONL logs. The pattern is an NSRegularExpression by
default; `--fixed-strings` treats it as a literal string. Matches are
checked against the textual fields of each event:

- by default: `appName`, `bundleID`, `controlName`, `controlValue`,
  `windowTitle`, `nearbyText`, `url`, `aiPrompt`, `aiResponse`
- with `--text-only`: drops `appName` / `bundleID` so you don't match
  on the application name itself

Scope:

- `--day YYYY-MM-DD` — search a single day (fastest)
- `--last-days N` — search the last N days of logs
- neither — search every JSONL file the CLI can find (newest first)

```sh
braincache activity search "kubernetes"                # all days
braincache activity search "kubernetes" --last-days 7
braincache activity search "kubernetes" --day 2026-05-06
braincache activity search '\bclick\b' --case-sensitive
braincache activity search "Settings.app" --fixed-strings
```

### `braincache activity show UUID`

```
braincache activity show UUID [--day YYYY-MM-DD]
```

Full event JSON for one UUID — including resolved absolute paths to
the screenshot and audio recording if the event has them. Passing
`--day` (when you know it) is much faster than scanning every day.

```sh
braincache activity show 0ED1E0EF-1EFC-4917-99C7-B1EF8305A232 \
  --day 2026-05-06 \
  | jq '.screenshotAbsolutePath'
# → "/Users/.../Activity/screenshots/2026-05-06/2026-05-06T22-00-57-607_loginwindow_periodic.jpg"
```

---

## Common recipes

**Pipe a clip into another tool**
```sh
braincache clips show $(braincache clips list --last 1 --output json | jq -r '.id') --raw \
  | pbcopy
```

**Watch a long voice transcript for a phrase**
```sh
braincache audio search "deadline" --mode vector --limit 5 --output json \
  | jq -r '.id, .preview'
```

**Bundle today's activity + screenshots for review**
```sh
DAY=$(date +%F)
mkdir -p ~/braincache-export/$DAY
braincache activity day $DAY --with-screenshot --output json > ~/braincache-export/$DAY/events.ndjson
jq -r '.screenshotAbsolutePath // empty' ~/braincache-export/$DAY/events.ndjson \
  | while read shot; do cp "$shot" ~/braincache-export/$DAY/; done
```

**Find every URL you pasted in the last 24 hours**
```sh
braincache clips search '^https?://' --mode grep --limit 200 --output json \
  | jq -r 'select((now - (.createdAt | fromdateiso8601)) < 86400) | .preview'
```

**Hybrid search a topic across both clipboard and voice notes**
```sh
braincache clips search "next quarter goals" --mode hybrid --include-audio
```

---

## Exit codes

| Code | Meaning |
| --- | --- |
| 0 | Success. |
| 1 | Generic error: missing DB, missing API key, unparseable date, no such clip/event, OpenAI error. The CLI prints a human-readable explanation to stderr. |
| 64 | Argument-parsing error (raised by ArgumentParser). Run with `--help` for usage. |

NDJSON output is always written to stdout; errors and progress notes go
to stderr. That means `braincache … 2>/dev/null > out.ndjson` will give
you a clean machine-readable artifact even when something goes wrong.

---

## Limitations & caveats

- **Read-only.** The CLI cannot add, delete, pin, or modify clips. By
  design — it's a data-consumption surface, not a control surface. If
  you need to mutate state, drive the BrainCache app via its hotkeys
  / menu / preferences UI.
- **No streaming / tail mode.** Each invocation is a one-shot query.
  If you want live updates, poll on a timer; the SQLite WAL means
  repeated reads are cheap. A `--watch` mode could be added if there's
  demand.
- **Vector search is exact, not approximate.** Until the bundled
  sqlite-vector extension lands (see CLAUDE.md → "sqlite-vector
  integration"), `--mode vector` does a Swift-side brute-force cosine
  scan over every embedding. Fast enough for tens of thousands of
  clips; if your library is much larger expect 100-200 ms latency on
  vector queries.
- **Grep is on the full text only.** Regexes match `text_content` and
  `image_description`. They do not match binary blobs (images, HTML
  payloads stored in `media/`).
- **Activity scope = whatever you recorded.** The activity recorder
  only writes events when it's enabled in BrainCache → Preferences →
  Activity Capture, and only inside the folder you grant it. If
  `braincache info` shows `activityRoot: null`, no activity commands
  will return anything until you configure it in the app.
- **Embedding model must match.** Vector search assumes the query
  embedding has the same dimension count as the stored clip
  embeddings. If you change `embeddingModel` in BrainCache, re-run the
  AI indexing pipeline before relying on vector search from the CLI.
- **Keychain prompt on first run.** macOS asks for confirmation the
  first time the CLI reads the API key from the Keychain. This is a
  one-time prompt per user; click "Always Allow" to silence it.
- **Case sensitivity of fields.** SQLite FTS5 is unaccented and
  case-insensitive. NSRegularExpression follows the `--case-sensitive`
  flag.
- **Time zones.** Day-bucketed activity commands use your **local
  calendar day** (matching how the app rotates JSONL files at local
  midnight). ISO timestamps in JSON output are always UTC `Z`.

---

## Versioning

`braincache --version` reports the CLI release. The CLI version is
independent from the BrainCache app version but updated together.
A bump indicates one of:

- A new subcommand or flag (additive — old scripts still work).
- A new field in the JSON output (additive — old keys remain).
- An incompatible change. These are called out in the CHANGELOG and
  the major version is bumped. We aim never to break field names you
  already depend on; new behavior gets a new flag or field.

Pin your scripts to the major version reported by `braincache info`
(`cliVersion` field) if you want reproducibility.
