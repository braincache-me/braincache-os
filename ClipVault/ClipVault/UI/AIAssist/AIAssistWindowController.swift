import AppKit

/// AI Assist window — single live Answer view + a History tab listing past
/// Q&A pairs. Singleton, so re-pressing "Ask AI" lands in the same window
/// and replaces what's shown rather than opening a new window.
///
/// Each ask creates an `AIAssistEntry`, becomes the current entry, and starts
/// streaming. Past entries are kept in memory and surfaced through the
/// History tab; clicking a row switches back to Answer with that entry.
final class AIAssistWindowController: NSObject {

    static let shared = AIAssistWindowController()

    // MARK: - Storage

    private(set) var entries: [AIAssistEntry] = []
    private(set) var currentIndex: Int = -1

    enum Tab: Int { case answer = 0, history = 1 }
    private(set) var currentTab: Tab = .answer

    // MARK: - Window + Views

    private(set) var window: AIAssistWindow?
    /// Root NSView returned by `buildContentView()`. When non-nil it has been
    /// either set as the standalone window's contentView or embedded into a
    /// host (e.g. the voice panel's drawer). Lazily built on first need.
    private var contentRoot: NSView?
    /// Set when an external container hosts our content view in place of the
    /// standalone window. While non-nil, `askAI()` / `show()` invoke
    /// `onRequestPresentation` instead of activating an `AIAssistWindow`.
    private weak var embedHost: NSView?
    /// Fired when `askAI()` or `show()` is called while embedded. The host
    /// uses this to surface the embedded view (e.g. expand a collapsed drawer).
    var onRequestPresentation: (() -> Void)?
    private var isEmbedded: Bool { embedHost != nil }

    private var segmented: NSSegmentedControl?
    private var copyButton: NSButton?
    private var closeButton: NSButton?

    // Answer-view subviews
    private var answerContainer: NSView?
    private var attachmentChip: NSView?
    private var attachmentLabel: NSTextField?
    private var attachmentImageView: NSImageView?
    private var responseWebView: MarkdownWebView?
    private var statusLabel: NSTextField?

    // History-view subviews
    private var historyContainer: NSView?
    private var historyTableView: NSTableView?
    private var historyEmptyLabel: NSTextField?

    // MARK: - Streaming

    private var streamingTask: Task<Void, Never>?

    // MARK: - Logging hook (set by AppDelegate)

    /// Optional callback fired on stream completion (or error) so the app can
    /// persist the response into the activity log.
    var onEntryFinalized: ((AIAssistEntry) -> Void)?

    /// Wired by AppDelegate. Used to fetch clipboard items captured during
    /// the active voice recording so they can be injected as additional
    /// context for the LLM (and any images sent as vision input).
    var clipStore: ClipStore?

    /// Maximum number of image clips inlined into the AI request.
    static let recordingImageContextLimit = 2
    /// Maximum number of text clips listed in the prompt context block.
    static let recordingTextContextLimit = 10
    /// Per-clip text truncation cap (characters) for the prompt context block.
    static let recordingTextClipCharLimit = 600

    private override init() {
        super.init()
    }

    // MARK: - Public API

    /// Start (or replace the current) AI Assist roundtrip with the given
    /// prompt and optional image attachment. The window is shown, focused,
    /// switched to the Answer tab, and the response begins streaming.
    ///
    /// `customPromptPrefix` overrides `Settings.shared.aiAssistSystemPrompt`
    /// for this single call — used by the voice panel's "Custom Question"
    /// dropdown so a one-shot user-typed instruction takes the place of the
    /// default prefix without mutating the persisted preference.
    func askAI(
        prompt: String,
        imageData: Data? = nil,
        attachedWindowSummary: String? = nil,
        attachedThumbnail: NSImage? = nil,
        customPromptPrefix: String? = nil,
        recordingStartedAt: Date? = nil
    ) {
        ensureWindow()
        cancelStreaming()

        let entry = AIAssistEntry(
            prompt: prompt,
            attachedWindowSummary: attachedWindowSummary,
            attachedThumbnail: attachedThumbnail
        )
        entries.append(entry)
        currentIndex = entries.count - 1
        switchTo(.answer)
        renderCurrent()
        refreshSegmentLabels()
        showAndFocus()

        startStreaming(
            entry: entry,
            imageData: imageData,
            customPromptPrefix: customPromptPrefix,
            recordingStartedAt: recordingStartedAt
        )
    }

    func show() {
        ensureWindow()
        if currentIndex >= 0 { renderCurrent() }
        showAndFocus()
    }

    private func showAndFocus() {
        if isEmbedded {
            onRequestPresentation?()
            return
        }
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Embedding API

    /// Install the content view into `container`, so AI Assist renders inside
    /// the host instead of its standalone `AIAssistWindow`. Idempotent — if
    /// the view is already mounted in `container`, no-op.
    func embed(in container: NSView) {
        let view = ensureContentRoot()
        if view.superview === container { return }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        embedHost = container
        // The close button dismisses the standalone window; when embedded the
        // host owns its own chrome, so hide it.
        closeButton?.isHidden = true
        // Tear down the standalone window — it would otherwise hold a stale
        // reference to a view we just reparented.
        window?.contentView = nil
        window?.orderOut(nil)
        window = nil
    }

    @discardableResult
    private func ensureContentRoot() -> NSView {
        if let contentRoot { return contentRoot }
        let root = buildContentView()
        contentRoot = root
        return root
    }

    // MARK: - Prompt composition

    static var systemPrompt: String { Prompts.shared.aiAssist.system }

    static var transcriptFraming: String { Prompts.shared.aiAssist.transcriptFraming }

    static func composeUserContent(
        userPromptPrefix: String,
        transcript: String,
        clipContextBlock: String? = nil
    ) -> String {
        var parts: [String] = []
        let trimmedPrefix = userPromptPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPrefix.isEmpty {
            parts.append(trimmedPrefix)
        }
        parts.append(transcriptFraming)
        parts.append(transcript)
        if let clipContextBlock,
           !clipContextBlock.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(clipContextBlock)
        }
        return parts.joined(separator: "\n\n")
    }

    /// Renders the reasoning-summary trace as a collapsible `<details>` HTML
    /// block. marked.js passes raw block HTML through unsanitised, so the
    /// text must be escaped here; newlines become `<br>` because markdown
    /// inside a block-level HTML element is not processed.
    static func thinkingBlock(_ thinking: String, open: Bool) -> String {
        let escaped = thinking
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
        let openAttr = open ? " open" : ""
        return "<details\(openAttr)>"
            + "<summary style=\"cursor:pointer;opacity:0.6;font-size:0.85em;\">Thinking</summary>"
            + "<div style=\"opacity:0.6;font-size:0.85em;font-style:italic;padding:4px 0 4px 10px;"
            + "border-left:2px solid rgba(255,255,255,0.25);margin:4px 0;\">\(escaped)</div>"
            + "</details>"
    }

    // MARK: - Recording-window clip context

    /// Pulls clipboard items captured between `since` and now, formats text
    /// clips as a prompt block, and converts image clips to JPEG data so they
    /// can be sent as vision input alongside the transcript. Returns empty
    /// values when `since` is nil, the store isn't wired, no clips fall in
    /// the window, or all qualifying clips are BrainCache's own entries.
    func gatherRecordingClipContext(since: Date?) -> (textBlock: String?, images: [Data]) {
        guard let since,
              let store = clipStore else {
            return (nil, [])
        }
        let startTs = since.timeIntervalSince1970
        let endTs = Date().timeIntervalSince1970
        guard endTs > startTs else { return (nil, []) }

        let raw: [ClipRecord]
        do {
            raw = try store.fetchByDateRange(start: startTs, end: endTs, limit: 50)
        } catch {
            return (nil, [])
        }

        // Drop BrainCache's own entries (live transcript draft, prior AI
        // responses logged as clips, etc.) so the model isn't reading back
        // its own framing. Then order oldest-first so the LLM sees the
        // chronological flow of what the user copied during the call.
        let filtered = raw
            .filter { ($0.sourceApp?.localizedCaseInsensitiveContains("BrainCache") ?? false) == false }
            .sorted { $0.createdAt < $1.createdAt }

        guard !filtered.isEmpty else { return (nil, []) }

        let imageClips = filtered
            .filter { $0.contentType == "image" && $0.mediaFileName != nil }
            .prefix(Self.recordingImageContextLimit)
        let textClips = filtered
            .filter { $0.contentType != "image" }
            .prefix(Self.recordingTextContextLimit)

        let imageData: [Data] = imageClips.compactMap { clip in
            guard let filename = clip.mediaFileName,
                  let raw = try? MediaFileManager.shared.load(filename: filename)
            else { return nil }
            return Self.encodeAsJPEG(rawImageData: raw)
        }

        let textBlock = Self.formatClipContextBlock(
            textClips: Array(textClips),
            imageClips: Array(imageClips),
            sentImageCount: imageData.count
        )

        return (textBlock, imageData)
    }

    /// Builds the markdown context block that lists every clip captured
    /// during the recording. Text clips show their content (truncated);
    /// image clips list metadata only — the actual bytes go through as
    /// vision input. Returns nil when nothing useful was captured.
    static func formatClipContextBlock(
        textClips: [ClipRecord],
        imageClips: [ClipRecord],
        sentImageCount: Int
    ) -> String? {
        guard !textClips.isEmpty || !imageClips.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium

        var lines: [String] = [
            "# Clipboard items captured during this recording",
            "",
            "The user copied the following items while speaking. Use them as additional context when answering.",
            "",
        ]

        for clip in textClips {
            let ts = formatter.string(from: Date(timeIntervalSince1970: clip.createdAt))
            let app = clip.sourceApp?.trimmingCharacters(in: .whitespacesAndNewlines)
            let header: String
            if let app, !app.isEmpty {
                header = "## Clip #\(clip.id.map(String.init) ?? "?") — \(app) — \(ts)"
            } else {
                header = "## Clip #\(clip.id.map(String.init) ?? "?") — \(ts)"
            }
            lines.append(header)
            let body = (clip.textContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let display: String
            if body.isEmpty {
                display = "_(empty text clip)_"
            } else if body.count > recordingTextClipCharLimit {
                let prefix = body.prefix(recordingTextClipCharLimit)
                display = "\(prefix)\n…(truncated, original \(body.count) chars)"
            } else {
                display = body
            }
            lines.append(display)
            lines.append("")
        }

        if !imageClips.isEmpty {
            lines.append("## Images attached")
            for (idx, clip) in imageClips.enumerated() {
                let ts = formatter.string(from: Date(timeIntervalSince1970: clip.createdAt))
                let app = clip.sourceApp?.trimmingCharacters(in: .whitespacesAndNewlines)
                let suffix = (idx < sentImageCount)
                    ? "attached as image input below"
                    : "not attached (image limit reached)"
                if let app, !app.isEmpty {
                    lines.append("- Clip #\(clip.id.map(String.init) ?? "?") — \(app) — \(ts) — \(suffix)")
                } else {
                    lines.append("- Clip #\(clip.id.map(String.init) ?? "?") — \(ts) — \(suffix)")
                }
            }
            lines.append("")
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decodes arbitrary image data (PNG / TIFF / etc.) and re-encodes as
    /// JPEG at ~0.7 quality, matching the format `streamChatCompletion`
    /// advertises in its data URL. Returns nil if the image can't be
    /// decoded — the calling site silently drops that clip from the
    /// attachment list.
    static func encodeAsJPEG(rawImageData: Data) -> Data? {
        guard let image = NSImage(data: rawImageData),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(
            using: .jpeg,
            properties: [.compressionFactor: 0.7]
        )
    }

    // MARK: - Streaming

    /// Ask AI streams through the Responses API (`OpenAIClient.streamResponse`)
    /// rather than Chat Completions: it is the only surface that streams
    /// reasoning summaries (the "thinking" trace shown above the answer) and
    /// hosts the built-in `web_search` tool. Local function tools (agent
    /// history search) are executed here in a bounded loop — each round
    /// continues the server-stored conversation via `previous_response_id`
    /// with the tool outputs as the only new input.
    private func startStreaming(
        entry: AIAssistEntry,
        imageData: Data?,
        customPromptPrefix: String? = nil,
        recordingStartedAt: Date? = nil
    ) {
        let model = Settings.shared.chatModel
        let promptPrefix = customPromptPrefix ?? Settings.shared.aiAssistSystemPrompt

        let clipContext = gatherRecordingClipContext(since: recordingStartedAt)

        let userText = Self.composeUserContent(
            userPromptPrefix: promptPrefix,
            transcript: entry.prompt,
            clipContextBlock: clipContext.textBlock
        )

        var contentBlocks: [[String: Any]] = [
            ["type": "input_text", "text": userText]
        ]
        let allImages: [Data] = ([imageData].compactMap { $0 }) + clipContext.images
        for data in allImages {
            contentBlocks.append([
                "type": "input_image",
                "image_url": "data:image/jpeg;base64,\(data.base64EncodedString())",
                "detail": "auto",
            ])
        }

        let webSearch = Settings.shared.askAIWebSearchEnabled
        let claudeHistory = Settings.shared.claudeCodeHistoryToolEnabled
        let codexHistory = Settings.shared.codexHistoryToolEnabled
        let tools = AskAIToolDefinitions.tools(
            webSearch: webSearch,
            claudeCodeHistory: claudeHistory,
            codexHistory: codexHistory
        )
        let instructions = Self.systemPrompt + AskAIToolDefinitions.systemPromptAddendum(
            webSearch: webSearch,
            claudeCodeHistory: claudeHistory,
            codexHistory: codexHistory
        )

        entry.statusDetail = nil
        updateStatus()

        streamingTask = Task { [weak self] in
            let historyService = AgentHistorySearchService()
            var previousResponseId: String?
            var functionOutputs: [OpenAIClient.FunctionCallOutput] = []
            // Bounded like the agentic RAG loop so a tool-happy model can't
            // spin forever; the final round streams whatever answer exists.
            let maxToolRounds = 4
            var round = 0

            @MainActor func apply(_ mutate: () -> Void) {
                guard let self else { return }
                mutate()
                if self.isCurrent(entry) && self.currentTab == .answer {
                    self.renderResponse(animated: true)
                    self.updateStatus()
                }
            }

            do {
                streamLoop: while true {
                    var pendingCalls: [(callId: String, name: String, arguments: String)] = []
                    var completedResponseId: String?

                    let stream = OpenAIClient.shared.streamResponse(
                        model: model,
                        instructions: instructions,
                        userContentBlocks: contentBlocks,
                        previousResponseId: previousResponseId,
                        functionOutputs: functionOutputs,
                        tools: tools,
                        maxOutputTokens: Settings.shared.ragMaxOutputTokens,
                        reasoningEffort: Settings.shared.reasoningEffort,
                        usageCategory: .chat
                    )

                    for try await event in stream {
                        if Task.isCancelled { break streamLoop }
                        switch event {
                        case .reasoningDelta(let delta):
                            await apply {
                                entry.thinking += delta
                                if entry.response.isEmpty { entry.statusDetail = "Thinking…" }
                            }
                        case .textDelta(let token):
                            await apply {
                                entry.response += token
                                entry.statusDetail = nil
                            }
                        case .webSearchStarted:
                            await apply { entry.statusDetail = "Searching the web…" }
                        case .functionCall(let callId, let name, let arguments):
                            pendingCalls.append((callId, name, arguments))
                            let summary = AskAIToolExecutor.activitySummary(
                                name: name, argumentsJSON: arguments
                            )
                            await apply {
                                entry.statusDetail = AskAIToolExecutor.statusDetail(name: name)
                                entry.thinking += entry.thinking.isEmpty ? "" : "\n\n"
                                entry.thinking += "→ \(summary)"
                            }
                        case .completed(let responseId, _):
                            completedResponseId = responseId
                        case .failed(let message):
                            throw OpenAIError.httpError(statusCode: 0, message: message)
                        }
                    }

                    if Task.isCancelled { break }
                    guard !pendingCalls.isEmpty,
                          round < maxToolRounds,
                          let responseId = completedResponseId else { break }
                    round += 1
                    previousResponseId = responseId
                    functionOutputs = pendingCalls.map { call in
                        OpenAIClient.FunctionCallOutput(
                            callId: call.callId,
                            output: AskAIToolExecutor.execute(
                                name: call.name,
                                argumentsJSON: call.arguments,
                                historyService: historyService
                            )
                        )
                    }
                }

                await MainActor.run {
                    guard let self else { return }
                    entry.statusDetail = nil
                    if case .streaming = entry.state {
                        entry.state = .done
                    }
                    if self.isCurrent(entry) {
                        self.renderResponse(animated: false)
                        self.updateStatus()
                    }
                    self.historyTableView?.reloadData()
                    self.onEntryFinalized?(entry)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    entry.statusDetail = nil
                    entry.state = .error(error.localizedDescription)
                    if self.isCurrent(entry) {
                        self.renderResponse(animated: false)
                        self.updateStatus()
                    }
                    self.historyTableView?.reloadData()
                    self.onEntryFinalized?(entry)
                }
            }
        }
    }

    private func cancelStreaming() {
        streamingTask?.cancel()
        streamingTask = nil
    }

    private func isCurrent(_ entry: AIAssistEntry) -> Bool {
        guard currentIndex >= 0, currentIndex < entries.count else { return false }
        return entries[currentIndex].id == entry.id
    }

    // MARK: - Window setup

    private func ensureWindow() {
        if isEmbedded {
            _ = ensureContentRoot()
            return
        }
        guard window == nil else { return }
        let w = AIAssistWindow()

        // Wrap the content root in a HUD-blur effect view so the standalone
        // window picks up the same translucent backdrop the content was
        // designed against (the voice panel's drawer). The toolbar's 0.18
        // alpha tint blends with this material instead of painting a hard
        // opaque band.
        let effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.blendingMode = .behindWindow
        effectView.wantsLayer = true
        effectView.layer?.backgroundColor = NSColor(white: 0.08, alpha: 0.88).cgColor
        effectView.layer?.cornerRadius = 14
        effectView.layer?.masksToBounds = true
        effectView.translatesAutoresizingMaskIntoConstraints = false

        let root = ensureContentRoot()
        root.removeFromSuperview()
        root.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: effectView.topAnchor),
            root.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            root.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
        ])

        w.contentView = effectView
        window = w
    }

    private func buildContentView() -> NSView {
        let root = NSView()
        root.wantsLayer = true

        // Toolbar with segmented control + Copy. The background uses a low
        // alpha so the view blends with whatever host it ends up in — the
        // standalone AIAssistWindow (dark aqua) or the voice panel's HUD
        // effect view — instead of painting a hard opaque band.
        let toolbar = NSView()
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.wantsLayer = true
        toolbar.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        root.addSubview(toolbar)

        let segs = NSSegmentedControl(labels: ["Answer", "History"], trackingMode: .selectOne, target: self, action: #selector(segmentChanged(_:)))
        segs.translatesAutoresizingMaskIntoConstraints = false
        segs.segmentStyle = .texturedRounded
        segs.selectedSegment = 0
        toolbar.addSubview(segs)
        segmented = segs

        let copy = NSButton()
        copy.translatesAutoresizingMaskIntoConstraints = false
        copy.bezelStyle = .inline
        copy.isBordered = false
        copy.font = .systemFont(ofSize: 11, weight: .medium)
        copy.title = "Copy"
        copy.image = NSImage(
            systemSymbolName: "doc.on.doc",
            accessibilityDescription: "Copy response"
        )
        copy.imagePosition = .imageLeading
        copy.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        copy.target = self
        copy.action = #selector(copyTapped)
        toolbar.addSubview(copy)
        copyButton = copy

        // Visible close button — the window hides the standard traffic-light
        // buttons for a clean floating surface, so without this the only way
        // to dismiss is Cmd+W. Hidden when the content view is embedded into
        // a host (e.g. the voice panel drawer), which manages its own chrome.
        let close = NSButton()
        close.translatesAutoresizingMaskIntoConstraints = false
        close.bezelStyle = .inline
        close.isBordered = false
        close.title = ""
        close.image = NSImage(
            systemSymbolName: "xmark",
            accessibilityDescription: "Close"
        )
        close.imagePosition = .imageOnly
        close.contentTintColor = NSColor.white.withAlphaComponent(0.85)
        close.toolTip = "Close"
        close.target = self
        close.action = #selector(closeTapped)
        toolbar.addSubview(close)
        closeButton = close

        // Answer container ----------------------------------------------------
        let answer = NSView()
        answer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(answer)
        answerContainer = answer

        let chip = NSView()
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.wantsLayer = true
        chip.layer?.cornerRadius = 4
        chip.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        chip.isHidden = true
        answer.addSubview(chip)
        attachmentChip = chip

        let chipImage = NSImageView()
        chipImage.translatesAutoresizingMaskIntoConstraints = false
        chipImage.imageScaling = .scaleProportionallyDown
        chip.addSubview(chipImage)
        attachmentImageView = chipImage

        let chipLabel = NSTextField(labelWithString: "")
        chipLabel.translatesAutoresizingMaskIntoConstraints = false
        chipLabel.font = .systemFont(ofSize: 10, weight: .medium)
        chipLabel.textColor = NSColor.white.withAlphaComponent(0.85)
        chipLabel.lineBreakMode = .byTruncatingMiddle
        chipLabel.maximumNumberOfLines = 1
        chip.addSubview(chipLabel)
        attachmentLabel = chipLabel

        // The web view owns its own scrolling — wrapping it in an outer
        // NSScrollView caused dual-scroll conflicts (wheel events going to
        // the wrong scroller depending on hover position). Auto-scroll
        // during streaming is handled inside the page's JS.
        let web = MarkdownWebView(compact: false, scrollable: true)
        answer.addSubview(web)
        responseWebView = web

        let status = NSTextField(labelWithString: "")
        status.translatesAutoresizingMaskIntoConstraints = false
        status.font = .systemFont(ofSize: 11)
        status.textColor = NSColor.white.withAlphaComponent(0.7)
        answer.addSubview(status)
        statusLabel = status

        // History container --------------------------------------------------
        let history = NSView()
        history.translatesAutoresizingMaskIntoConstraints = false
        history.isHidden = true
        root.addSubview(history)
        historyContainer = history

        let historyScroll = NSScrollView()
        historyScroll.translatesAutoresizingMaskIntoConstraints = false
        historyScroll.hasVerticalScroller = true
        historyScroll.drawsBackground = false
        historyScroll.borderType = .noBorder
        history.addSubview(historyScroll)

        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 56
        table.intercellSpacing = NSSize(width: 0, height: 1)
        table.backgroundColor = .clear
        table.style = .plain
        table.gridStyleMask = []
        table.selectionHighlightStyle = .regular
        table.target = self
        table.action = #selector(historyRowClicked)
        table.doubleAction = #selector(historyRowDoubleClicked)
        table.dataSource = self
        table.delegate = self
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        col.resizingMask = .autoresizingMask
        col.minWidth = 200
        table.addTableColumn(col)
        historyScroll.documentView = table
        historyTableView = table

        let empty = NSTextField(labelWithString: "No history yet — press Ask AI on the voice panel to get started.")
        empty.translatesAutoresizingMaskIntoConstraints = false
        empty.font = .systemFont(ofSize: 12)
        empty.textColor = NSColor.white.withAlphaComponent(0.6)
        empty.alignment = .center
        empty.maximumNumberOfLines = 2
        empty.cell?.wraps = true
        history.addSubview(empty)
        historyEmptyLabel = empty

        // Layout -------------------------------------------------------------
        let toolbarHeight: CGFloat = 40

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: toolbarHeight),

            segs.leadingAnchor.constraint(equalTo: toolbar.leadingAnchor, constant: 12),
            segs.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            close.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -12),
            close.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 20),
            close.heightAnchor.constraint(equalToConstant: 20),

            copy.trailingAnchor.constraint(equalTo: close.leadingAnchor, constant: -10),
            copy.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            answer.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            answer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            answer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            answer.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            chip.topAnchor.constraint(equalTo: answer.topAnchor, constant: 12),
            chip.leadingAnchor.constraint(equalTo: answer.leadingAnchor, constant: 16),
            chip.heightAnchor.constraint(equalToConstant: 22),

            chipImage.leadingAnchor.constraint(equalTo: chip.leadingAnchor, constant: 4),
            chipImage.centerYAnchor.constraint(equalTo: chip.centerYAnchor),
            chipImage.widthAnchor.constraint(equalToConstant: 14),
            chipImage.heightAnchor.constraint(equalToConstant: 14),

            chipLabel.leadingAnchor.constraint(equalTo: chipImage.trailingAnchor, constant: 4),
            chipLabel.trailingAnchor.constraint(equalTo: chip.trailingAnchor, constant: -8),
            chipLabel.centerYAnchor.constraint(equalTo: chip.centerYAnchor),

            web.topAnchor.constraint(equalTo: chip.bottomAnchor, constant: 8),
            web.leadingAnchor.constraint(equalTo: answer.leadingAnchor, constant: 12),
            web.trailingAnchor.constraint(equalTo: answer.trailingAnchor, constant: -12),
            web.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -6),

            status.leadingAnchor.constraint(equalTo: answer.leadingAnchor, constant: 16),
            status.bottomAnchor.constraint(equalTo: answer.bottomAnchor, constant: -10),

            history.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            history.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            history.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            history.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            historyScroll.topAnchor.constraint(equalTo: history.topAnchor, constant: 6),
            historyScroll.leadingAnchor.constraint(equalTo: history.leadingAnchor, constant: 6),
            historyScroll.trailingAnchor.constraint(equalTo: history.trailingAnchor, constant: -6),
            historyScroll.bottomAnchor.constraint(equalTo: history.bottomAnchor, constant: -6),

            empty.centerXAnchor.constraint(equalTo: history.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: history.centerYAnchor),
            empty.leadingAnchor.constraint(greaterThanOrEqualTo: history.leadingAnchor, constant: 24),
            empty.trailingAnchor.constraint(lessThanOrEqualTo: history.trailingAnchor, constant: -24),
        ])

        return root
    }

    // MARK: - Tab switching

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        let tab = Tab(rawValue: sender.selectedSegment) ?? .answer
        switchTo(tab)
    }

    private func switchTo(_ tab: Tab) {
        currentTab = tab
        segmented?.selectedSegment = tab.rawValue
        answerContainer?.isHidden = (tab != .answer)
        historyContainer?.isHidden = (tab != .history)
        if tab == .history {
            historyTableView?.reloadData()
            historyEmptyLabel?.isHidden = !entries.isEmpty
        } else {
            renderCurrent()
        }
    }

    private func refreshSegmentLabels() {
        segmented?.setLabel("History (\(entries.count))", forSegment: 1)
    }

    // MARK: - Rendering — Answer tab

    private func renderCurrent() {
        guard currentIndex >= 0, currentIndex < entries.count,
              let attachmentChip,
              let attachmentLabel, let attachmentImageView else {
            attachmentChip?.isHidden = true
            responseWebView?.reset()
            updateStatus()
            return
        }

        let entry = entries[currentIndex]
        if let summary = entry.attachedWindowSummary, !summary.isEmpty {
            attachmentChip.isHidden = false
            attachmentLabel.stringValue = summary
            attachmentImageView.image = entry.attachedThumbnail
                ?? NSImage(systemSymbolName: "paperclip", accessibilityDescription: nil)
        } else {
            attachmentChip.isHidden = true
        }
        renderResponse(animated: false)
        updateStatus()
    }

    private func renderResponse(animated: Bool) {
        guard let web = responseWebView,
              currentIndex >= 0, currentIndex < entries.count else { return }
        let entry = entries[currentIndex]
        let responseText: String
        if entry.response.isEmpty {
            switch entry.state {
            case .streaming: responseText = ""
            case .done: responseText = entry.thinking.isEmpty ? "_(empty response)_" : ""
            case .error(let msg): responseText = "**Error:** \(msg)"
            }
        } else {
            responseText = entry.response
        }

        var displayText = responseText
        if !entry.thinking.isEmpty {
            // Keep the trace expanded while it's the only content; collapse it
            // once answer tokens take over so it doesn't push the answer down.
            let block = Self.thinkingBlock(entry.thinking, open: entry.response.isEmpty)
            displayText = displayText.isEmpty ? block : block + "\n\n" + responseText
        }
        web.setMarkdown(displayText)
        // Scrolling-to-bottom is handled inside MarkdownWebView's
        // onHeightChanged callback so streaming tokens keep the user pinned
        // to the latest content without us having to fight WKWebView's
        // async layout cycle here.
        _ = animated
    }

    private func updateStatus() {
        guard let statusLabel else { return }
        guard currentIndex >= 0, currentIndex < entries.count else {
            statusLabel.stringValue = ""
            return
        }
        let entry = entries[currentIndex]
        switch entry.state {
        case .streaming:
            statusLabel.stringValue = entry.statusDetail ?? "Streaming…"
            statusLabel.textColor = NSColor.controlAccentColor
        case .done:
            statusLabel.stringValue = formattedTimestamp(entry.createdAt)
            statusLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        case .error(let msg):
            statusLabel.stringValue = "Error: \(msg)"
            statusLabel.textColor = NSColor.systemRed
        }
    }

    private func formattedTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: date)
    }

    // MARK: - History tab actions

    @objc private func historyRowClicked() {
        guard let table = historyTableView else { return }
        let row = table.clickedRow
        guard row >= 0, row < entries.count else { return }
        // Newest entries are listed first — invert.
        currentIndex = (entries.count - 1) - row
        switchTo(.answer)
    }

    @objc private func historyRowDoubleClicked() {
        historyRowClicked()
    }

    // MARK: - Close

    @objc private func closeTapped() {
        guard !isEmbedded else { return }
        window?.performClose(nil)
    }

    // MARK: - Copy

    @objc private func copyTapped() {
        guard currentIndex >= 0, currentIndex < entries.count else { return }
        let entry = entries[currentIndex]
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entry.response, forType: .string)
        if let copyButton {
            let originalTitle = copyButton.title
            copyButton.title = "Copied"
            copyButton.contentTintColor = NSColor.systemGreen
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak copyButton] in
                copyButton?.title = originalTitle
                copyButton?.contentTintColor = NSColor.white.withAlphaComponent(0.85)
            }
        }
    }
}

// MARK: - History table data source / delegate

extension AIAssistWindowController: NSTableViewDataSource, NSTableViewDelegate {

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = AIAssistHistoryCell()
        // Newest at the top.
        let entry = entries[(entries.count - 1) - row]
        cell.configure(with: entry)
        return cell
    }
}

// MARK: - History row cell

final class AIAssistHistoryCell: NSTableCellView {
    private let timestampLabel = NSTextField(labelWithString: "")
    private let promptLabel = NSTextField(labelWithString: "")
    private let responsePreview = NSTextField(labelWithString: "")
    private let stateIcon = NSImageView()

    init() {
        // Important: NSTableView positions row views via frames; setting
        // translatesAutoresizingMaskIntoConstraints = false on the cell
        // itself breaks that and rows render at zero height (invisible).
        // Subviews still use auto layout against the cell's anchors below.
        super.init(frame: NSRect(x: 0, y: 0, width: 200, height: 56))
        wantsLayer = true
        autoresizingMask = [.width]

        timestampLabel.translatesAutoresizingMaskIntoConstraints = false
        timestampLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
        timestampLabel.textColor = NSColor.white.withAlphaComponent(0.55)
        addSubview(timestampLabel)

        stateIcon.translatesAutoresizingMaskIntoConstraints = false
        stateIcon.imageScaling = .scaleProportionallyDown
        addSubview(stateIcon)

        promptLabel.translatesAutoresizingMaskIntoConstraints = false
        promptLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        promptLabel.textColor = NSColor.white
        promptLabel.lineBreakMode = .byTruncatingTail
        promptLabel.maximumNumberOfLines = 1
        addSubview(promptLabel)

        responsePreview.translatesAutoresizingMaskIntoConstraints = false
        responsePreview.font = .systemFont(ofSize: 11)
        responsePreview.textColor = NSColor.white.withAlphaComponent(0.6)
        responsePreview.lineBreakMode = .byTruncatingTail
        responsePreview.maximumNumberOfLines = 1
        addSubview(responsePreview)

        NSLayoutConstraint.activate([
            timestampLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            timestampLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            timestampLabel.widthAnchor.constraint(equalToConstant: 50),

            stateIcon.centerYAnchor.constraint(equalTo: timestampLabel.centerYAnchor),
            stateIcon.leadingAnchor.constraint(equalTo: timestampLabel.trailingAnchor, constant: 6),
            stateIcon.widthAnchor.constraint(equalToConstant: 12),
            stateIcon.heightAnchor.constraint(equalToConstant: 12),

            promptLabel.centerYAnchor.constraint(equalTo: timestampLabel.centerYAnchor),
            promptLabel.leadingAnchor.constraint(equalTo: stateIcon.trailingAnchor, constant: 8),
            promptLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            responsePreview.topAnchor.constraint(equalTo: promptLabel.bottomAnchor, constant: 4),
            responsePreview.leadingAnchor.constraint(equalTo: promptLabel.leadingAnchor),
            responsePreview.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            responsePreview.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    func configure(with entry: AIAssistEntry) {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        timestampLabel.stringValue = f.string(from: entry.createdAt)
        promptLabel.stringValue = entry.prompt
        switch entry.state {
        case .streaming:
            stateIcon.image = NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: nil)
            stateIcon.contentTintColor = NSColor.controlAccentColor
            responsePreview.stringValue = entry.response.isEmpty ? "Streaming…" : entry.response
        case .done:
            stateIcon.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
            stateIcon.contentTintColor = NSColor.systemGreen
            responsePreview.stringValue = entry.response
        case .error(let msg):
            stateIcon.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: nil)
            stateIcon.contentTintColor = NSColor.systemRed
            responsePreview.stringValue = "Error: \(msg)"
        }
    }
}
