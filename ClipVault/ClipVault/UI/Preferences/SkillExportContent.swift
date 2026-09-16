import Foundation

/// SKILL.md content the AI Preferences tab writes when the user clicks
/// "Get Skill File", plus the human-readable install manual shown by
/// "How to add skill to your AI".
///
/// The skill teaches external AI tools (Claude Code, Codex, Hermes, OpenClaw)
/// how to query BrainCache's local SQLite database and JSONL activity logs.
enum SkillExportContent {

    /// File the save panel writes by default. We bundle the directory + SKILL.md
    /// into a single file since NSSavePanel can't represent a folder write.
    /// Users who want the folder form can wrap it themselves — the manual
    /// explains both shapes.
    static let defaultFileName = "SKILL.md"

    static func skillMarkdown(bridge: BrainCacheBridgeProvision) -> String {
        """
        ---
        name: braincache
        description: Query BrainCache, a local macOS clipboard manager that stores clipboard history with AI tags, image descriptions, vector embeddings, voice transcripts, and an optional activity recorder. Use when the user asks about anything they recently copied, screenshots they took, links they saved, audio they recorded, or what they were doing on their Mac.
        ---

        # BrainCache

        BrainCache is a local-first macOS app. The user's data stays on their Mac. Use the local read-only bridge first; fall back to the CLI or direct files only if the bridge is unreachable in your harness.

        ## Preferred access: local read-only bridge

        Candidate URLs:

        ```sh
        BRAINCACHE_URLS=\(shellArrayLiteral(bridge.candidateBaseURLs))
        BRAINCACHE_HOSTS=\(shellArrayLiteral(hosts(from: bridge.candidateBaseURLs)))
        BRAINCACHE_DISCOVERY_FILES=(
          "$HOME/Library/Application Support/ClipVault/braincache-bridge.json"
          "$HOME/Library/Application Support/ClipVault-Dev/braincache-bridge.json"
        )
        ```

        Bearer token:

        ```sh
        BRAINCACHE_TOKEN="\(bridge.token)"
        ```

        Every request must include:

        ```sh
        -H "Authorization: Bearer $BRAINCACHE_TOKEN"
        ```

        Start by checking bridge status:

        ```sh
        # Prefer BrainCache's live discovery file when this harness can read the
        # Mac filesystem. It survives app updates and records the current port.
        if command -v jq >/dev/null 2>&1; then
          for file in "${BRAINCACHE_DISCOVERY_FILES[@]}"; do
            if [ -r "$file" ]; then
              discovered_token=$(jq -r '.token // empty' "$file")
              if [ -n "$discovered_token" ]; then BRAINCACHE_TOKEN="$discovered_token"; fi
              mapfile -t discovered_urls < <(jq -r '.candidateBaseURLs[]? // empty' "$file")
              if [ "${#discovered_urls[@]}" -gt 0 ]; then BRAINCACHE_URLS=("${discovered_urls[@]}"); fi
              break
            fi
          done
        fi

        BRAINCACHE_URL=""
        for url in "${BRAINCACHE_URLS[@]}"; do
          if curl -fsS --max-time 3 -H "Authorization: Bearer $BRAINCACHE_TOKEN" "$url/v1/info" >/tmp/braincache-info.json; then
            BRAINCACHE_URL="$url"
            cat /tmp/braincache-info.json
            break
          fi
        done

        # If the app moved to a new port after an update/restart and the
        # discovery file is not mounted in this sandbox, scan BrainCache's small
        # reserved range using the same token.
        if [ -z "$BRAINCACHE_URL" ]; then
          for host in "${BRAINCACHE_HOSTS[@]}"; do
            for port in $(seq 18732 18782); do
              url="http://$host:$port"
              if curl -fsS --max-time 1 -H "Authorization: Bearer $BRAINCACHE_TOKEN" "$url/v1/info" >/tmp/braincache-info.json; then
                BRAINCACHE_URL="$url"
                cat /tmp/braincache-info.json
                break 2
              fi
            done
          done
        fi

        test -n "$BRAINCACHE_URL" || echo "BrainCache bridge is not reachable from this AI harness."
        ```

        Available endpoints:

        ```text
        GET /v1/info
        GET /v1/clips/recent?limit=50
        GET /v1/clips/search?q=<keyword>&limit=20
        GET /v1/audio/recent?limit=20
        GET /v1/audio/search?q=<keyword>&limit=20
        GET /v1/activity/day?day=YYYY-MM-DD&limit=500
        GET /v1/live/transcript
        ```

        Live conversation access:

        `/v1/live/transcript` returns the transcript of the voice/meeting recording BrainCache is capturing right now — `state` ("idle" / "recording" / "transcribing" / "completed" / "error"), `isLive`, `startedAt`, `durationSeconds`, `text` (finalized transcript so far), `micPartial` / `systemPartial` (words being spoken right now), and timestamped `entries`. Poll it (every few seconds is plenty) to follow a meeting as it happens:

        ```sh
        curl -fsS -H "Authorization: Bearer $BRAINCACHE_TOKEN" \\
          "$BRAINCACHE_URL/v1/live/transcript"
        ```

        If `isLive` is false, no recording is in progress — use `/v1/audio/recent` for saved transcripts instead.

        Example searches:

        ```sh
        curl -fsS -G -H "Authorization: Bearer $BRAINCACHE_TOKEN" \\
          --data-urlencode "q=invoice" \\
          --data-urlencode "limit=20" \\
          "$BRAINCACHE_URL/v1/clips/search"

        curl -fsS -G -H "Authorization: Bearer $BRAINCACHE_TOKEN" \\
          --data-urlencode "day=2026-06-14" \\
          --data-urlencode "limit=500" \\
          "$BRAINCACHE_URL/v1/activity/day"
        ```

        Security notes:

        - The bridge is read-only.
        - It binds to IPv4 interfaces so local VM/container sandboxes can reach the host.
        - All endpoints require the bearer token above.
        - BrainCache writes live bridge metadata to `~/Library/Application Support/ClipVault/braincache-bridge.json` on every bridge start, so a saved skill can survive app updates and port changes.
        - If this AI runs in a remote sandbox and none of the candidate URLs are reachable, say that clearly and ask the user to run from a host-local harness or export a limited data bundle.

        ## Fallback: bundled CLI

        If the bridge is unreachable but the Mac filesystem is visible, try the CLI:

        ```sh
        BRAINCACHE=$(command -v braincache || echo "/Applications/BrainCache.app/Contents/Resources/braincache")
        "$BRAINCACHE" info --output json
        "$BRAINCACHE" clips search "invoice" --output json
        "$BRAINCACHE" activity day 2026-06-14 --output json
        "$BRAINCACHE" audio search "launch" --output json
        ```

        ## Fallback: direct files

        Clipboard database:

        ```text
        ~/Library/Application Support/ClipVault/clipvault.db
        ```

        Dev builds use `ClipVault-Dev` instead of `ClipVault`.

        Activity logs, if enabled, are under the user-chosen Activity Recorder folder:

        ```text
        <activity root>/logs/YYYY-MM-DD.jsonl
        <activity root>/screenshots/YYYY-MM-DD/*.jpg
        <activity root>/summaries/YYYY-MM-DD.json
        ```

        ## Privacy posture

        Prefer narrow queries. Do not upload the database, activity logs, screenshots, or token to any service unless the user explicitly asks. If you encounter secure-field data, treat it as a bug and do not repeat it.
        """
    }

    private static func shellArrayLiteral(_ values: [String]) -> String {
        let quoted = values
            .map { "'\($0.replacingOccurrences(of: "'", with: "'\\''"))'" }
            .joined(separator: " ")
        return "(\(quoted))"
    }

    private static func hosts(from urls: [String]) -> [String] {
        var seen = Set<String>()
        return urls.compactMap { raw in
            guard let url = URL(string: raw), let host = url.host, seen.insert(host).inserted else {
                return nil
            }
            return host
        }
    }

    static var skillMarkdown: String {
        """
        ---
        name: braincache
        description: Query BrainCache, a local macOS clipboard manager that stores clipboard history with AI tags, image descriptions, vector embeddings, and an optional activity recorder. Use when the user asks about anything they recently copied, screenshots they took, links they saved, or what they were doing on their Mac.
        ---

        # BrainCache

        BrainCache is a macOS app that captures the user's clipboard history and (optionally) their on-screen activity. All data lives **locally** on the user's machine — there is no cloud API. To answer questions about what the user copied, looked at, or worked on, you read BrainCache's SQLite database and JSONL log files directly.

        ## Where the data lives

        **Clipboard database (SQLite, always present):**

        ```
        ~/Library/Application Support/ClipVault/clipvault.db
        ```

        (Dev builds use `ClipVault-Dev` instead of `ClipVault`.)

        **Activity logs (only if the user enabled the Activity Recorder):**

        ```
        <user-chosen root>/logs/YYYY-MM-DD.jsonl
        <user-chosen root>/screenshots/YYYY-MM-DD/*.jpg
        <user-chosen root>/summaries/YYYY-MM-DD.json
        ```

        Ask the user where they pointed the Activity Recorder if you can't find it — the root is configurable.

        ## clipvault.db schema (high-confidence parts)

        ### `clips` table — one row per clipboard entry
        | Column | Type | Notes |
        |---|---|---|
        | `id` | INTEGER PK | |
        | `content_type` | TEXT | `text`, `html`, `rtf`, `image`, `file`, … |
        | `text_content` | TEXT | Plain text payload (may be NULL for image clips) |
        | `data_hash` | TEXT | Dedupe hash |
        | `media_file_name` | TEXT | Image / file payload on disk |
        | `source_app` | TEXT | Bundle ID or display name of the app the user copied from |
        | `byte_size` | INTEGER | |
        | `created_at` | DOUBLE | Unix timestamp (seconds) |
        | `last_used_at` | DOUBLE | Last paste time |
        | `is_pinned` | INTEGER | 1 = pinned (excluded from purge) |
        | `is_indexed` | INTEGER | 1 = present in FTS index |
        | `tags` | TEXT | JSON array of LLM-assigned tags |
        | `image_description` | TEXT | Vision-LLM description for image clips |
        | `ai_processed` | INTEGER | 0=unprocessed, 1=processed, 2=failed |
        | `ai_processed_at` | DOUBLE | |

        ### `clips_fts` — FTS5 virtual table for full-text search
        Indexed columns: `text_content`, `image_description`. Use `MATCH` for queries.

        ### `clip_embeddings` — vector embeddings
        | Column | Type |
        |---|---|
        | `clip_id` | INTEGER PK → clips(id) ON DELETE CASCADE |
        | `embedding` | BLOB (raw Float32, 256 dims) |
        | `model` | TEXT |
        | `dimensions` | INTEGER |

        Exact cosine similarity in pure SQL is impractical without the sqlite-vector extension, so for "semantic" queries either fall back to FTS5 (`clips_fts MATCH`) or extract embeddings and compute similarity in your runtime.

        ### `conversations` / `chat_messages` — in-app chat history
        Cascade delete on `conversation_id`. `cited_clip_ids` is a JSON array of `clips.id`.

        ## How to answer common questions

        **"What did I copy yesterday?"**
        ```sql
        SELECT id, content_type, source_app, text_content, datetime(created_at, 'unixepoch', 'localtime') AS ts
          FROM clips
         WHERE created_at >= unixepoch('now', '-1 day')
         ORDER BY created_at DESC
         LIMIT 50;
        ```

        **"Find clips that mention <keyword>"**
        ```sql
        SELECT c.id, c.source_app, snippet(clips_fts, 0, '[', ']', '…', 12) AS hit
          FROM clips_fts JOIN clips c ON c.id = clips_fts.rowid
         WHERE clips_fts MATCH ?
         ORDER BY rank
         LIMIT 20;
        ```

        **"What apps did I copy from this week?"**
        ```sql
        SELECT source_app, COUNT(*) AS n
          FROM clips
         WHERE created_at >= unixepoch('now', '-7 days')
         GROUP BY source_app
         ORDER BY n DESC;
        ```

        **"Pull up the screenshot of the email I was reading at 3pm yesterday."**
        Read the JSONL line in `logs/YYYY-MM-DD.jsonl` whose `timestamp` is closest to 15:00, then open the file at the matching `screenshotPath`.

        ## Activity JSONL — one event per line

        Each line is a JSON object with at minimum:
        - `timestamp` — ISO 8601 with ms precision
        - `eventType` — `click`, `keyShortcut`, `focusChange`, `screenshot`, …
        - `appBundleID`, `appName` — frontmost app at event time
        - `windowTitle` — best-effort window title
        - `axRole`, `axName`, `controlValue` — accessibility attributes (NEVER populated for `kAXSecureTextFieldRole`)
        - `screenshotPath` — relative path under `screenshots/` if a screenshot was captured

        BrainCache **never** records raw keystrokes — only modifier-key shortcuts (⌘C, ⌃⌥⌘T). Secure text fields and apps on the user's exclusion list are silently skipped.

        ## Privacy posture

        BrainCache is local-first by design. Don't suggest uploading the database or activity logs to any service the user hasn't already explicitly chosen. If a question can be answered from the SQLite DB alone, prefer that over the JSONL logs — clips are less sensitive than the full activity trail.

        ## Things to NOT do

        - Don't write to `clipvault.db`. The app is the only writer; concurrent writes can corrupt the FTS index.
        - Don't claim semantic search works without checking whether `clip_embeddings` has rows for the relevant clip IDs. Many clips are unprocessed (`ai_processed = 0`) if the user hasn't set an API key.
        - Don't paste the contents of secure-field events even if `controlValue` somehow appears — that's a bug to report, not data to use.
        """
    }

    static var installGuideMarkdown: String {
        """
        BrainCache exports a single `SKILL.md` file following the open Agent Skills format (agentskills.io). When you save the file, BrainCache creates a read-only localhost bridge token, checks for an available loopback port, and writes both into the skill. All four tools below auto-discover skills from a directory — drop a folder containing your `SKILL.md` into the right path and they pick it up on next launch.

        ## Folder shape

        Each tool expects:

        ```
        <skills-root>/braincache/SKILL.md
        ```

        The folder name becomes the slash-command name.

        ## Per-tool install paths

        ### Claude Code — Anthropic CLI / IDE
        - Personal: `~/.claude/skills/braincache/SKILL.md`
        - Project: `.claude/skills/braincache/SKILL.md`
        - Picks up live; no restart needed. Verify with `/skills`.
        - Docs: https://code.claude.com/docs/en/skills

        ### Codex — OpenAI CLI coding agent
        - Personal: `~/.agents/skills/braincache/SKILL.md`
        - Project: `.agents/skills/braincache/SKILL.md`
        - Codex scans `.agents/skills` from the working directory up to the repo root, then falls back to `~/.agents/skills`.
        - Docs: https://developers.openai.com/codex/skills

        ### Hermes Agent — Nous Research
        - Path: `~/.hermes/skills/braincache/SKILL.md`
        - Auto-discovered on startup. Hermes also accepts a single-file SKILL.md from a URL.
        - Docs: https://hermes-agent.nousresearch.com/docs/user-guide/features/skills

        ### OpenClaw — open-source agent
        - Path: `~/.openclaw/skills/braincache/SKILL.md`
        - Or your configured `agents.defaults.workspace` skills directory.
        - Repo: https://github.com/openclaw/openclaw

        ## Quick install (copy-paste)

        Replace `<TOOL>` with `claude`, `agents`, `hermes`, or `openclaw`:

        ```
        mkdir -p ~/.<TOOL>/skills/braincache
        cp ~/Downloads/SKILL.md ~/.<TOOL>/skills/braincache/SKILL.md
        ```

        ## Verifying it works

        After installing, ask the AI something like *"What did I copy from Slack yesterday?"* — a loaded skill will reference BrainCache's database path and offer to run a query.

        The generated skill tries BrainCache's token-protected local bridge first. If the AI harness runs in a remote sandbox that cannot reach `127.0.0.1` on your Mac, use a host-local harness or export a limited data bundle instead.

        ## Updating the skill

        Re-export from BrainCache and overwrite the file in place. All four tools re-read `SKILL.md` on next launch (Claude Code re-reads live).
        """
    }
}
