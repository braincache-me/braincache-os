# ClipVault

A native macOS clipboard manager that lives in the menu bar. Written entirely in Swift with AppKit.

## Features

- Monitors clipboard history and stores it in SQLite via GRDB.swift
- Floating search panel accessible via a global hotkey (default: Cmd+Shift+V)
- Full-text search with FTS5, blended with recency ranking
- Supports text, RTF, HTML, images, and file URLs
- Pin clips to keep them from being purged
- Exclude specific apps from clipboard monitoring
- Auto-purge by age and count limit
- Universal binary (arm64 + x86_64)

### AI Features (requires OpenAI API key)

- Automatic classification and tagging of every clip using `gpt-5.4-nano` — tags like `code:swift`, `url`, `api-key`, `error-message` appear as coloured badges in search results
- Vision-based description of image clips via `gpt-5.4-mini` — makes screenshots and diagrams full-text searchable
- Vector embeddings via `text-embedding-3-small` (256 dimensions) stored in SQLite — enables semantic search
- Hybrid search: keyword (FTS5) + semantic (vector similarity) results merged with Reciprocal Rank Fusion
- "Chat with Clipboard" panel (Cmd+Shift+C) — ask natural-language questions; the app retrieves relevant clips via RAG and generates a grounded answer citing source clips
- All AI features disabled gracefully when no API key is configured — no crashes, no API calls

## System Requirements

- macOS 13.0 or later
- Xcode 16.0 or later (for building)
- XcodeGen (for generating the Xcode project from project.yml)

## Dependencies

Managed via Swift Package Manager, declared in `project.yml`:

- [GRDB.swift](https://github.com/groue/GRDB.swift) >= 6.29.3 — SQLite wrapper with FTS5
- [HotKey](https://github.com/soffes/HotKey) >= 0.2.0 — Global keyboard shortcuts
- [Sparkle](https://github.com/sparkle-project/Sparkle) >= 2.0.0 — Auto-update framework

## Building

### Prerequisites

Install XcodeGen if you don't have it:

```
brew install xcodegen
```

### Generate and open the project

```
cd ClipVault
xcodegen generate
open ClipVault.xcodeproj
```

Then build with Cmd+B in Xcode, or from the command line:

```
xcodebuild build -scheme ClipVault -destination 'platform=macOS'
```

## Running Tests

```
cd ClipVault
xcodebuild test -scheme ClipVault -destination 'platform=macOS'
```

The test suite has 330 tests covering Storage, Monitor, UI, Services, and AI modules.

## Distribution

### Build a DMG

```
cd ClipVault
bash scripts/build-dmg.sh
```

Requires `create-dmg` (`brew install create-dmg`) and a signed build.

### Notarize

```
cd ClipVault
bash scripts/notarize.sh ClipVault.app
```

Requires Apple Developer credentials configured via `xcrun notarytool store-credentials`.

### Smoke test

```
cd ClipVault
bash scripts/smoke-test.sh
```

Verifies the universal binary contains both arm64 and x86_64 slices.

## Permissions

ClipVault requires Accessibility access (System Settings > Privacy & Security > Accessibility) to simulate Cmd+V when pasting a clip back to another app. On first launch the app will prompt and open the relevant pane automatically.

## Setting Up AI Features

AI features require an OpenAI API key. Once configured, all features are enabled automatically with no additional setup.

1. Open ClipVault Preferences (click the menu bar icon → Preferences)
2. Go to the AI tab
3. Paste your OpenAI API key and click "Validate"
4. The background pipeline will start classifying and embedding your clipboard history

### Approximate cost

Based on typical clipboard usage (~100 clips/day, mix of short text and code snippets):

| Operation | Cost per 1,000 clips |
|---|---|
| Classification (gpt-5.4-nano) | ~$0.05 |
| Image description (gpt-5.4-mini, if images) | ~$0.10 per 1,000 images |
| Embedding (text-embedding-3-small, 256 dims) | ~$0.001 |

Most users spend well under $1/month. The pipeline never makes API calls without an explicit key, and you can pause or disable it from Preferences at any time.

## Project Structure

```
ClipVault/
  ClipVault/
    App/            - AppDelegate, ClipVaultApp entry point, Info.plist
    Monitor/        - ClipboardMonitor, PasteboardReader, ClipboardEntry
    Storage/        - DatabaseManager, ClipStore, MediaFileManager
    Services/       - HotkeyManager, PasteService, AppDetector, PurgeScheduler, SparkleUpdaterController
      AI/           - OpenAIClient, ContentClassifier, ImageDescriber, EmbeddingGenerator, AIIndexingPipeline, VectorSearchEngine, RAGEngine
    Storage/        - DatabaseManager, ClipStore, MediaFileManager, EmbeddingStore, VectorExtensionLoader
    UI/
      StatusMenu/   - StatusItemManager, StatusMenuBuilder
      SearchPanel/  - SearchPanelController, SearchPanelWindow, ClipRowView, ClipPreviewView
      ChatPanel/    - ChatPanelController, ChatPanelWindow, ChatBubbleView
      Preferences/  - PreferencesWindowController and tab views (including AI tab)
    Utilities/      - Settings, Hashing
    Resources/      - Assets, entitlements
  ClipVaultTests/   - Unit test suite
  scripts/          - build-dmg.sh, notarize.sh, smoke-test.sh
  project.yml       - XcodeGen project definition
```
