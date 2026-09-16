import AppKit

/// Controls the "Chat with Data" floating panel.
///
/// Owns the sidebar (ConversationListView), message scroll area, input field, and RAGEngine.
/// Conversations and messages are persisted via ConversationStore.
final class ChatPanelController: NSObject {

    static let shared = ChatPanelController()

    // MARK: - Public — set before first toggle()

    var clipStore: ClipStore?
    var conversationStore: ConversationStore?

    // MARK: - Private state

    private(set) var window: ChatPanelWindow?
    private var scrollView:         NSScrollView?
    private var messageStack:       NSStackView?
    private var transientAssistantBubble: ChatBubbleView?
    private var inputField:         NSTextField?
    private var sendButton:         NSButton?
    private var loadingSpinner:     NSProgressIndicator?
    private var conversationListView: ConversationListView?
    private var emptyStateContainer: NSView?
    private var shouldScrollToTransientAssistantOnNextUpdate = false

    private(set) var messages: [ChatMessage] = []
    private var ragEngine: RAGEngine?
    private var agenticEngine: AgenticRAGEngine?

    /// Label that shows intermediate agentic search status (e.g. "Searching by keyword: …").
    private var statusLabel: NSTextField?

    private var currentConversationId: Int64?
    private var isNewConversation = false
    private var conversations: [ConversationRecord] = []

    // MARK: - Topic (Clips vs Audio Transcripts)

    /// Mode used when creating the next new conversation, or for the currently selected
    /// conversation when it has no messages yet. Persisted onto the conversation row at
    /// first send and never changes after that.
    private var pendingTopic: SearchHistoryMode = .clips
    private var topicControl: NSSegmentedControl?
    private var titleLabelView: NSTextField?

    // MARK: - Setup

    func setup() {
        let panel = ChatPanelWindow(
            contentRect: NSRect(x: 0, y: 0,
                                width: ChatPanelWindow.defaultWidth,
                                height: ChatPanelWindow.defaultHeight),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        panel.positionAtCenter()
        buildContentView(in: panel)
        window = panel

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: panel
        )
    }

    // MARK: - Toggle

    func toggle() {
        guard let panel = window else { return }
        if panel.isVisible {
            hide()
        } else {
            if let store = clipStore {
                if ragEngine == nil {
                    ragEngine = RAGEngine(clipStore: store)
                }
                if agenticEngine == nil {
                    agenticEngine = AgenticRAGEngine(clipStore: store)
                }
            }
            loadConversations()
            panel.positionAtCenter()
            panel.makeKeyAndOrderFront(nil)
            inputField?.becomeFirstResponder()
        }
    }

    func hide() {
        window?.orderOut(nil)
    }

    // MARK: - Summarisation entry point

    /// Open the chat panel, create a fresh conversation in audio-transcripts
    /// mode, and send the configured summarisation prompt + the transcript
    /// directly to the LLM — bypassing RAG retrieval for this first message.
    ///
    /// Why bypass RAG: the audio-transcripts RAG system prompt instructs the
    /// model to answer ONLY from the retrieved context. Since the transcript
    /// is in the user message (not the retrieved set), the model otherwise
    /// refuses with "not available in the provided transcripts". Follow-up
    /// messages still go through `sendMessage()` and the normal RAG flow.
    func summariseTranscript(_ transcript: String, title: String? = nil) {
        let trimmedTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty, let panel = window else { return }

        if !panel.isVisible {
            if let store = clipStore {
                if ragEngine == nil { ragEngine = RAGEngine(clipStore: store) }
                if agenticEngine == nil { agenticEngine = AgenticRAGEngine(clipStore: store) }
            }
            loadConversations()
            panel.positionAtCenter()
            panel.makeKeyAndOrderFront(nil)
        }

        pendingTopic = .audioTranscripts
        refreshTopicControl()
        createAndSelectNewConversation()

        guard Settings.shared.isAIEnabled else {
            appendMessage(ChatMessage(role: .assistant,
                                      text: "AI features require an API key. Configure it in Preferences > AI.",
                                      conversationId: currentConversationId))
            return
        }

        let prompt = Settings.shared.transcriptionSummarisationPrompt
        let userMessage = "\(prompt)\n\nTranscript:\n\(trimmedTranscript)"
        let convId = currentConversationId

        // Persist + render the user message.
        if let cid = convId {
            try? conversationStore?.appendMessage(conversationId: cid, role: "user", content: userMessage)
            let resolvedTitle: String
            if let title, !title.isEmpty {
                resolvedTitle = title
            } else {
                resolvedTitle = "Summary: " + Self.autoTitle(from: trimmedTranscript)
            }
            try? conversationStore?.updateTitle(conversationId: cid, title: resolvedTitle)
            if let convs = try? conversationStore?.fetchAll() {
                conversations = convs
                conversationListView?.reload(conversations: conversations, selectedId: cid)
            }
            isNewConversation = false
        }
        appendMessage(ChatMessage(role: .user, text: userMessage, conversationId: convId))
        setLoading(true)

        let messages: [OpenAIClient.ChatMessage] = [
            OpenAIClient.ChatMessage(role: "user", content: userMessage)
        ]

        Task { @MainActor in
            do {
                let response = try await OpenAIClient.shared.chatCompletion(
                    model: Settings.shared.chatModel,
                    messages: messages,
                    maxTokens: Settings.shared.ragMaxOutputTokens,
                    reasoningEffort: Settings.shared.reasoningEffort
                )
                self.setLoading(false)
                let answer = response.choices.first?.message.content ?? ""
                if let cid = convId {
                    try? self.conversationStore?.appendMessage(
                        conversationId: cid,
                        role: "assistant",
                        content: answer
                    )
                }
                self.appendMessage(ChatMessage(role: .assistant, text: answer, conversationId: convId))
            } catch {
                self.setLoading(false)
                self.appendMessage(ChatMessage(role: .assistant,
                                               text: "Error: \(error.localizedDescription)",
                                               conversationId: convId))
            }
        }
    }

    // MARK: - Content View

    private func buildContentView(in panel: NSPanel) {
        let effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.blendingMode = .behindWindow
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 12
        effectView.layer?.masksToBounds = true

        // Title bar
        let titleLabel = NSTextField(labelWithString: titleText(for: pendingTopic))
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.textColor = .labelColor
        effectView.addSubview(titleLabel)
        titleLabelView = titleLabel

        // Clips / Audio segmented control — drives RAG retrieval scope per conversation.
        let topicSwitch = NSSegmentedControl(
            labels: ["Clips", "Audio"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(topicSegmentChanged(_:))
        )
        topicSwitch.translatesAutoresizingMaskIntoConstraints = false
        topicSwitch.selectedSegment = pendingTopic == .clips ? 0 : 1
        topicSwitch.segmentStyle = .rounded
        topicSwitch.controlSize = .small
        topicSwitch.toolTip = "Chat with clipboard clips or audio transcripts"
        effectView.addSubview(topicSwitch)
        topicControl = topicSwitch

        // Horizontal separator below title bar
        let titleSep = NSBox()
        titleSep.boxType = .separator
        titleSep.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(titleSep)

        // Sidebar
        let sidebar = ConversationListView(frame: .zero)
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.delegate = self
        effectView.addSubview(sidebar)
        conversationListView = sidebar

        // Vertical separator between sidebar and chat area
        let vertSep = NSBox()
        vertSep.boxType = .separator
        vertSep.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(vertSep)

        // Message scroll area
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultLow, for: .horizontal)
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        messageStack = stack

        let sv = NSScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.documentView = stack
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = false
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        sv.scrollerStyle = .overlay
        effectView.addSubview(sv)
        scrollView = sv

        stack.widthAnchor.constraint(equalTo: sv.widthAnchor).isActive = true

        let statusRow = NSView()
        statusRow.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(statusRow)

        // Loading spinner
        let spinner = NSProgressIndicator()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isHidden = true
        statusRow.addSubview(spinner)
        loadingSpinner = spinner

        // Intermediate status label (shows agentic search progress next to spinner)
        let statusLbl = NSTextField(labelWithString: "")
        statusLbl.translatesAutoresizingMaskIntoConstraints = false
        statusLbl.font = .systemFont(ofSize: 11)
        statusLbl.textColor = .secondaryLabelColor
        statusLbl.isHidden = true
        statusLbl.lineBreakMode = .byTruncatingTail
        statusRow.addSubview(statusLbl)
        statusLabel = statusLbl

        // Input separator
        let inputSep = NSBox()
        inputSep.boxType = .separator
        inputSep.translatesAutoresizingMaskIntoConstraints = false
        effectView.addSubview(inputSep)

        // Input field
        let field = NSTextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholderString = placeholderText(for: pendingTopic)
        field.delegate = self
        field.font = .systemFont(ofSize: 13)
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
        effectView.addSubview(field)
        inputField = field

        // Send button
        let btn = NSButton()
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.image = NSImage(systemSymbolName: "arrow.up.circle.fill",
                            accessibilityDescription: "Send")
        btn.imageScaling = .scaleProportionallyDown
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.contentTintColor = .controlAccentColor
        btn.target = self
        btn.action = #selector(sendMessage)
        effectView.addSubview(btn)
        sendButton = btn

        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        topicSwitch.setContentHuggingPriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            // Title bar — leading inset clears the standard traffic-light buttons on the left.
            titleLabel.topAnchor.constraint(equalTo: effectView.topAnchor, constant: 14),
            titleLabel.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 78),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: topicSwitch.leadingAnchor, constant: -8),

            topicSwitch.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            topicSwitch.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -12),

            titleSep.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            titleSep.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            titleSep.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),

            // Sidebar (200pt fixed width, full height below title sep)
            sidebar.topAnchor.constraint(equalTo: titleSep.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 200),
            sidebar.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),

            // Vertical separator
            vertSep.topAnchor.constraint(equalTo: titleSep.bottomAnchor),
            vertSep.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            vertSep.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),
            vertSep.widthAnchor.constraint(equalToConstant: 1),

            // Scroll view (right side)
            sv.topAnchor.constraint(equalTo: titleSep.bottomAnchor, constant: 4),
            sv.leadingAnchor.constraint(equalTo: vertSep.trailingAnchor),
            sv.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            sv.bottomAnchor.constraint(equalTo: statusRow.topAnchor, constant: -4),

            // Dedicated status row between the message list and input area.
            statusRow.leadingAnchor.constraint(equalTo: vertSep.trailingAnchor),
            statusRow.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            statusRow.bottomAnchor.constraint(equalTo: inputSep.topAnchor),
            statusRow.heightAnchor.constraint(equalToConstant: 22),

            // Spinner (left of status label inside the status row)
            spinner.leadingAnchor.constraint(equalTo: statusRow.leadingAnchor, constant: 12),
            spinner.centerYAnchor.constraint(equalTo: statusRow.centerYAnchor),

            // Status label (to the right of spinner)
            statusLbl.centerYAnchor.constraint(equalTo: spinner.centerYAnchor),
            statusLbl.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 6),
            statusLbl.trailingAnchor.constraint(lessThanOrEqualTo: statusRow.trailingAnchor, constant: -12),

            // Input area (right side)
            inputSep.leadingAnchor.constraint(equalTo: vertSep.trailingAnchor),
            inputSep.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            inputSep.bottomAnchor.constraint(equalTo: field.topAnchor, constant: -8),

            field.leadingAnchor.constraint(equalTo: vertSep.trailingAnchor, constant: 12),
            field.trailingAnchor.constraint(equalTo: btn.leadingAnchor, constant: -8),
            field.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -12),
            field.heightAnchor.constraint(equalToConstant: 30),

            btn.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            btn.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -12),
            btn.widthAnchor.constraint(equalToConstant: 28),
            btn.heightAnchor.constraint(equalToConstant: 28),
        ])

        panel.contentView = effectView
    }

    // MARK: - Message Rendering

    /// Append a message to the conversation and render its bubble.
    func appendMessage(_ message: ChatMessage) {
        let shouldKeepLatestVisible = message.role == .user || isScrolledNearBottom()
        // Remove the empty state placeholder when the first real message arrives.
        if let container = emptyStateContainer {
            container.removeFromSuperview()
            emptyStateContainer = nil
        }
        messages.append(message)
        renderBubble(for: message)
        if shouldKeepLatestVisible {
            scrollToBottom()
        }
    }

    private func renderBubble(for message: ChatMessage) {
        guard let stack = messageStack else { return }
        let bubble = ChatBubbleView(message: message) { [weak self] clipID, sourceView in
            self?.showClipPopover(id: clipID, relativeTo: sourceView)
        }
        stack.addArrangedSubview(bubble)
        bubble.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func scrollToBottom() {
        guard let sv = scrollView,
              let docView = sv.documentView else { return }
        let doScroll = {
            self.window?.contentView?.layoutSubtreeIfNeeded()
            sv.layoutSubtreeIfNeeded()
            sv.contentView.layoutSubtreeIfNeeded()
            docView.layoutSubtreeIfNeeded()
            let targetY = Self.bottomScrollOriginY(
                documentBounds: docView.bounds,
                visibleHeight: sv.contentView.bounds.height,
                isFlipped: docView.isFlipped
            )
            let target = NSPoint(x: 0, y: targetY)
            sv.contentView.scroll(to: target)
            sv.reflectScrolledClipView(sv.contentView)
        }
        if Thread.isMainThread {
            doScroll()
            DispatchQueue.main.async { doScroll() }
        } else {
            DispatchQueue.main.async { doScroll() }
        }
    }

    private func isScrolledNearBottom(tolerance: CGFloat = 24) -> Bool {
        guard let sv = scrollView,
              let docView = sv.documentView else { return true }
        self.window?.contentView?.layoutSubtreeIfNeeded()
        sv.layoutSubtreeIfNeeded()
        sv.contentView.layoutSubtreeIfNeeded()
        docView.layoutSubtreeIfNeeded()

        let bottomOriginY = Self.bottomScrollOriginY(
            documentBounds: docView.bounds,
            visibleHeight: sv.contentView.bounds.height,
            isFlipped: docView.isFlipped
        )
        return abs(sv.contentView.bounds.origin.y - bottomOriginY) <= tolerance
    }

    static func bottomScrollOriginY(
        documentBounds: NSRect,
        visibleHeight: CGFloat,
        isFlipped: Bool
    ) -> CGFloat {
        if isFlipped {
            return max(documentBounds.minY, documentBounds.maxY - visibleHeight)
        }
        return documentBounds.minY
    }

    private func showTransientAssistantTrace(_ text: String, conversationId: Int64?) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let stack = messageStack else { return }
        let shouldKeepLatestVisible =
            shouldScrollToTransientAssistantOnNextUpdate || isScrolledNearBottom()

        transientAssistantBubble?.removeFromSuperview()
        let bubble = ChatBubbleView(
            message: ChatMessage(
                role: .assistant,
                text: trimmed,
                usesPlainTextRenderer: true,
                conversationId: conversationId
            )
        ) { [weak self] clipID, sourceView in
            self?.showClipPopover(id: clipID, relativeTo: sourceView)
        }
        stack.addArrangedSubview(bubble)
        bubble.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        transientAssistantBubble = bubble
        statusLabel?.isHidden = true
        statusLabel?.stringValue = ""
        if shouldKeepLatestVisible {
            scrollToBottom()
        }
        shouldScrollToTransientAssistantOnNextUpdate = false
    }

    private func clearTransientAssistantTrace() {
        transientAssistantBubble?.removeFromSuperview()
        transientAssistantBubble = nil
    }

    private func showClipPopover(id: Int64, relativeTo sourceView: NSView) {
        guard let clip = try? clipStore?.fetchById(id) else { return }

        let popoverWidth: CGFloat = 420
        let popoverHeight: CGFloat = 320

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: popoverWidth, height: popoverHeight)

        let vc = NSViewController()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight))

        // Header
        let headerLabel = NSTextField(labelWithString: "")
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.font = .systemFont(ofSize: 11, weight: .medium)
        headerLabel.textColor = .secondaryLabelColor
        let isoFmt = DateFormatter()
        isoFmt.dateStyle = .medium
        isoFmt.timeStyle = .short
        let dateStr = isoFmt.string(from: Date(timeIntervalSince1970: clip.createdAt))
        let app = clip.sourceApp ?? "Unknown"
        headerLabel.stringValue = "#\(id)  •  \(app)  •  \(dateStr)"
        container.addSubview(headerLabel)

        // Tags
        let tagsLabel = NSTextField(labelWithString: "")
        tagsLabel.translatesAutoresizingMaskIntoConstraints = false
        tagsLabel.font = .systemFont(ofSize: 10)
        tagsLabel.textColor = .tertiaryLabelColor
        if let tagsJSON = clip.tags,
           let data = tagsJSON.data(using: .utf8),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String] {
            tagsLabel.stringValue = arr.joined(separator: ", ")
        }
        container.addSubview(tagsLabel)

        // Content area — uses NSTextView inside NSScrollView (same pattern as ClipPreviewView)
        let contentTV = NSTextView()
        contentTV.isEditable = false
        contentTV.isSelectable = true
        contentTV.drawsBackground = false
        contentTV.textContainerInset = NSSize(width: 4, height: 4)
        contentTV.isVerticallyResizable = true
        contentTV.isHorizontallyResizable = false
        contentTV.textContainer?.widthTracksTextView = true
        contentTV.autoresizingMask = [.width]

        let isHTML = clip.contentType == ClipboardContentType.html.rawValue
        let isImage = clip.contentType == ClipboardContentType.image.rawValue

        if isImage, let filename = clip.mediaFileName,
           let imgData = try? MediaFileManager.shared.load(filename: filename),
           let image = NSImage(data: imgData) {
            let maxW = popoverWidth - 32
            let scale = min(1.0, maxW / image.size.width)
            let scaledSize = NSSize(width: image.size.width * scale,
                                    height: image.size.height * scale)
            let resized = NSImage(size: scaledSize)
            resized.lockFocus()
            image.draw(in: NSRect(origin: .zero, size: scaledSize))
            resized.unlockFocus()

            let attachment = NSTextAttachment()
            let cell = NSTextAttachmentCell(imageCell: resized)
            attachment.attachmentCell = cell

            let imgAttr = NSMutableAttributedString()
            imgAttr.append(NSAttributedString(attachment: attachment))
            if let desc = clip.imageDescription {
                imgAttr.append(NSAttributedString(string: "\n\n\(desc)", attributes: [
                    .font: NSFont.systemFont(ofSize: 12),
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]))
            }
            contentTV.textStorage?.setAttributedString(imgAttr)
        } else if isHTML, let text = clip.textContent,
                  let attributed = text.attributedStringFromHTML(
                      defaultFont: NSFont.systemFont(ofSize: 12)) {
            contentTV.textStorage?.setAttributedString(attributed)
        } else {
            contentTV.font = .systemFont(ofSize: 12)
            contentTV.textColor = .labelColor
            contentTV.string = clip.textContent ?? clip.imageDescription ?? "(binary content)"
        }

        let sv = NSScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.documentView = contentTV
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        container.addSubview(sv)

        // Copy button
        let rawText = clip.textContent ?? clip.imageDescription ?? ""
        let copyBtn = NSButton(title: "Copy Full Content", target: nil, action: nil)
        copyBtn.translatesAutoresizingMaskIntoConstraints = false
        copyBtn.bezelStyle = .rounded
        copyBtn.font = .systemFont(ofSize: 11)
        let copyTarget = ActionTarget {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(rawText, forType: .string)
            copyBtn.title = "Copied ✓"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                copyBtn.title = "Copy Full Content"
            }
        }
        copyBtn.target = copyTarget
        copyBtn.action = #selector(ActionTarget.run)
        container.addSubview(copyBtn)

        objc_setAssociatedObject(popover, "copyTarget", copyTarget, .OBJC_ASSOCIATION_RETAIN)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            headerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            headerLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            tagsLabel.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 4),
            tagsLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            tagsLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            sv.topAnchor.constraint(equalTo: tagsLabel.bottomAnchor, constant: 8),
            sv.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            sv.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            sv.bottomAnchor.constraint(equalTo: copyBtn.topAnchor, constant: -8),

            copyBtn.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            copyBtn.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
        ])

        vc.view = container
        popover.contentViewController = vc
        popover.show(relativeTo: sourceView.bounds, of: sourceView, preferredEdge: .maxY)
    }

    // MARK: - Conversation Management

    /// Generates an auto-title from the first user message (up to 60 chars).
    static func autoTitle(from message: String) -> String {
        String(message.prefix(60))
    }

    private func loadConversations() {
        guard let store = conversationStore else { return }
        do {
            // Auto-cleanup: keep at most maxConversationCount conversations.
            try? store.deleteOldestExceeding(keepNewest: Settings.shared.maxConversationCount)
            conversations = try store.fetchAll()
            if conversations.isEmpty {
                currentConversationId = nil
                conversationListView?.reload(conversations: [], selectedId: nil)
                if messages.isEmpty {
                    clearMessageArea()
                    showEmptyState()
                }
            } else if let cid = currentConversationId,
                      conversations.contains(where: { $0.id == cid }) {
                // Restore previously selected conversation in the sidebar.
                conversationListView?.reload(conversations: conversations, selectedId: cid)
            } else {
                // Select the most recent conversation on first open or after external changes.
                if let first = conversations.first, let firstId = first.id {
                    conversationListView?.reload(conversations: conversations, selectedId: firstId)
                    loadAndDisplayConversation(id: firstId)
                }
            }
        } catch {
            NSLog("ClipVault: Failed to load conversations: \(error)")
        }
    }

    private func loadAndDisplayConversation(id: Int64) {
        guard let store = conversationStore else { return }
        do {
            let records = try store.fetchMessages(conversationId: id)
            currentConversationId = id
            isNewConversation = false
            clearMessageArea()
            messages = records.map { record in
                ChatMessage(
                    role: record.role == "user" ? .user : .assistant,
                    text: record.content,
                    citedIDs: record.decodedCitedClipIds(),
                    timestamp: Date(timeIntervalSince1970: record.createdAt),
                    id: record.id,
                    conversationId: id
                )
            }
            messages.forEach { renderBubble(for: $0) }
            if messages.isEmpty {
                showEmptyState()
            }
            // Sync the topic toggle to whatever the loaded conversation was created with.
            if let record = conversations.first(where: { $0.id == id }) {
                pendingTopic = ConversationTopic(rawValue: record.topic)?.historyMode ?? .clips
                refreshTopicControl()
            }
            scrollToBottom()
        } catch {
            NSLog("ClipVault: Failed to load conversation \(id): \(error)")
        }
    }

    private func createAndSelectNewConversation() {
        guard let store = conversationStore else { return }
        do {
            let conv = try store.createConversation(
                title: "New Chat",
                topic: ConversationTopic(historyMode: pendingTopic)
            )
            currentConversationId = conv.id
            isNewConversation = true
            conversations = (try? store.fetchAll()) ?? conversations
            conversationListView?.reload(conversations: conversations, selectedId: conv.id)
            clearMessageArea()
            refreshTopicControl()
        } catch {
            NSLog("ClipVault: Failed to create conversation: \(error)")
        }
    }

    private func clearMessageArea() {
        messages = []
        transientAssistantBubble = nil
        messageStack?.arrangedSubviews.forEach { $0.removeFromSuperview() }
        emptyStateContainer = nil
    }

    private func showEmptyState() {
        guard emptyStateContainer == nil, let stack = messageStack else { return }

        let container = NSStackView()
        container.orientation = .vertical
        container.spacing = 12
        container.alignment = .centerX
        container.translatesAutoresizingMaskIntoConstraints = false

        let lbl = NSTextField(wrappingLabelWithString: emptyStateText(for: pendingTopic))
        lbl.translatesAutoresizingMaskIntoConstraints = false
        lbl.alignment = .center
        lbl.font = .systemFont(ofSize: 13)
        lbl.textColor = .secondaryLabelColor
        lbl.isEditable = false
        lbl.isBordered = false
        lbl.drawsBackground = false
        container.addArrangedSubview(lbl)

        let btn = NSButton()
        btn.title = "New Chat"
        btn.bezelStyle = .rounded
        btn.target = self
        btn.action = #selector(emptyStateNewChatTapped)
        container.addArrangedSubview(btn)

        stack.addArrangedSubview(container)
        container.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        emptyStateContainer = container
    }

    // MARK: - Topic helpers

    private func titleText(for mode: SearchHistoryMode) -> String {
        switch mode {
        case .clips: return "Chat with Data"
        case .audioTranscripts: return "Chat with Transcripts"
        }
    }

    private func emptyStateText(for mode: SearchHistoryMode) -> String {
        switch mode {
        case .clips:
            return "Start a new conversation to chat with your clipboard history."
        case .audioTranscripts:
            return "Start a new conversation to chat with your audio transcripts."
        }
    }

    private func placeholderText(for mode: SearchHistoryMode) -> String {
        switch mode {
        case .clips: return "Ask your clipboard\u{2026}"
        case .audioTranscripts: return "Ask your transcripts\u{2026}"
        }
    }

    private func refreshTopicControl() {
        topicControl?.selectedSegment = pendingTopic == .clips ? 0 : 1
        titleLabelView?.stringValue = titleText(for: pendingTopic)
        inputField?.placeholderString = placeholderText(for: pendingTopic)
        // Refresh empty-state copy if it's currently visible.
        if let container = emptyStateContainer {
            container.removeFromSuperview()
            emptyStateContainer = nil
            showEmptyState()
        }
    }

    @objc private func topicSegmentChanged(_ sender: NSSegmentedControl) {
        let newMode: SearchHistoryMode = sender.selectedSegment == 1 ? .audioTranscripts : .clips
        guard newMode != pendingTopic else { return }

        // If the current conversation already has messages, the topic is locked — start a
        // fresh chat in the new mode so retrieval scope stays consistent within a chat.
        if currentConversationId != nil, !messages.isEmpty {
            pendingTopic = newMode
            refreshTopicControl()
            createAndSelectNewConversation()
            inputField?.becomeFirstResponder()
            return
        }

        pendingTopic = newMode

        // If we have an empty selected conversation, persist the topic change to its row.
        if let cid = currentConversationId, messages.isEmpty {
            try? conversationStore?.updateTopic(
                conversationId: cid,
                topic: ConversationTopic(historyMode: newMode)
            )
            // Refresh the cached conversation list so loadAndDisplayConversation later sees the new topic.
            if let store = conversationStore, let convs = try? store.fetchAll() {
                conversations = convs
            }
        }

        refreshTopicControl()
    }

    @objc private func emptyStateNewChatTapped() {
        createAndSelectNewConversation()
        inputField?.becomeFirstResponder()
    }

    // MARK: - Send

    @objc private func sendMessage() {
        guard let field = inputField else { return }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        clearTransientAssistantTrace()

        guard Settings.shared.isAIEnabled else {
            appendMessage(ChatMessage(role: .assistant,
                                      text: "AI features require an API key. Configure it in Preferences > AI."))
            return
        }

        // Ensure an active conversation exists when persistence is available.
        if conversationStore != nil && currentConversationId == nil {
            createAndSelectNewConversation()
        }
        let convId = currentConversationId

        field.stringValue = ""
        shouldScrollToTransientAssistantOnNextUpdate = true

        // Capture prior conversation history BEFORE appending the new user message,
        // so we don't include the current question in the history sent to the LLM.
        let history: [OpenAIClient.ChatMessage]? = convId.flatMap { cid in
            guard let store = conversationStore,
                  let records = try? store.fetchMessages(conversationId: cid),
                  !records.isEmpty else { return nil }
            return records.map { OpenAIClient.ChatMessage(role: $0.role, content: $0.content) }
        }

        // Persist and render user message.
        if let cid = convId {
            try? conversationStore?.appendMessage(conversationId: cid, role: "user", content: text)
            // Auto-title from the first message in a new conversation.
            if isNewConversation {
                isNewConversation = false
                let title = Self.autoTitle(from: text)
                try? conversationStore?.updateTitle(conversationId: cid, title: title)
                if let convs = try? conversationStore?.fetchAll() {
                    conversations = convs
                    conversationListView?.reload(conversations: conversations, selectedId: cid)
                }
            }
        }
        appendMessage(ChatMessage(role: .user, text: text, conversationId: convId))
        setLoading(true)

        guard ragEngine != nil || agenticEngine != nil else {
            setLoading(false)
            appendMessage(ChatMessage(role: .assistant,
                                      text: "Chat is not available (ClipStore not connected).",
                                      conversationId: convId))
            return
        }

        // Audio-transcripts mode skips the agentic loop because its tool definitions don't
        // propagate the source-app filter — they would mix in non-transcript clips. Use
        // classic RAG with an explicit filter+topic instead. Same approach as the /ask panel.
        let topic = pendingTopic
        let useAgentic = topic == .clips
            && Settings.shared.agenticSearchEnabled
            && agenticEngine != nil

        Task { @MainActor in
            do {
                let result: RAGResult
                if useAgentic, let agentic = self.agenticEngine {
                    agentic.onIterationUpdate = { [weak self] status in
                        // Already dispatched to main by AgenticRAGEngine.
                        self?.statusLabel?.stringValue = status
                        self?.statusLabel?.isHidden = false
                    }
                    agentic.onTraceUpdate = { [weak self] snapshot in
                        self?.showTransientAssistantTrace(snapshot.displayText, conversationId: convId)
                    }
                    result = try await agentic.query(text, conversationHistory: history)
                    agentic.onIterationUpdate = nil
                    agentic.onTraceUpdate = nil
                } else if let classic = self.ragEngine {
                    let filter: SearchFilter? = topic == .audioTranscripts
                        ? SearchFilter(sourceApp: ClipRecord.audioTranscriptSourceApp)
                        : nil
                    let ragTopic: RAGTopic = topic == .audioTranscripts ? .audioTranscripts : .clipboard
                    result = try await classic.query(
                        text,
                        conversationHistory: history,
                        filter: filter,
                        topic: ragTopic
                    )
                } else {
                    throw NSError(domain: "ClipVault", code: 0,
                                  userInfo: [NSLocalizedDescriptionKey: "No RAG engine available"])
                }
                self.statusLabel?.isHidden = true
                self.statusLabel?.stringValue = ""
                self.setLoading(false)
                if let cid = convId {
                    try? self.conversationStore?.appendMessage(
                        conversationId: cid,
                        role: "assistant",
                        content: result.answer,
                        citedClipIds: result.citedClipIDs
                    )
                }
                self.appendMessage(ChatMessage(role: .assistant,
                                               text: result.answer,
                                               citedIDs: result.citedClipIDs,
                                               conversationId: convId))
            } catch {
                self.agenticEngine?.onIterationUpdate = nil
                self.agenticEngine?.onTraceUpdate = nil
                self.statusLabel?.isHidden = true
                self.statusLabel?.stringValue = ""
                self.setLoading(false)
                self.appendMessage(ChatMessage(role: .assistant,
                                               text: "Error: \(error.localizedDescription)",
                                               conversationId: convId))
            }
        }
    }

    private func setLoading(_ loading: Bool) {
        loadingSpinner?.isHidden = !loading
        if loading {
            loadingSpinner?.startAnimation(nil)
        } else {
            shouldScrollToTransientAssistantOnNextUpdate = false
            loadingSpinner?.stopAnimation(nil)
            clearTransientAssistantTrace()
            statusLabel?.isHidden = true
            statusLabel?.stringValue = ""
        }
        sendButton?.isEnabled = !loading
        inputField?.isEnabled = !loading
    }

    // MARK: - Actions

    @objc private func windowWillClose(_ notification: Notification) {
        // Messages are now persisted — do not clear on panel close.
        // Reset loading state in case a request was in-flight when the panel was closed.
        setLoading(false)
    }
}

// MARK: - NSTextFieldDelegate

extension ChatPanelController: NSTextFieldDelegate {
    func control(_ control: NSControl,
                 textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            sendMessage()
            return true
        }
        return false
    }
}

// MARK: - ConversationListViewDelegate

extension ChatPanelController: ConversationListViewDelegate {

    func conversationListViewDidRequestNewChat(_ view: ConversationListView) {
        createAndSelectNewConversation()
        inputField?.becomeFirstResponder()
    }

    func conversationListView(_ view: ConversationListView, didSelectConversation id: Int64) {
        guard id != currentConversationId else { return }
        loadAndDisplayConversation(id: id)
    }

    func conversationListView(_ view: ConversationListView, didDeleteConversation id: Int64) {
        do {
            try conversationStore?.deleteConversation(id: id)
            let wasSelected = (id == currentConversationId)
            if wasSelected { currentConversationId = nil }
            conversations = (try? conversationStore?.fetchAll()) ?? []

            if conversations.isEmpty {
                conversationListView?.reload(conversations: [], selectedId: nil)
                clearMessageArea()
                showEmptyState()
            } else if wasSelected {
                // Auto-select the next most recent conversation.
                if let first = conversations.first, let firstId = first.id {
                    conversationListView?.reload(conversations: conversations, selectedId: firstId)
                    loadAndDisplayConversation(id: firstId)
                }
            } else {
                conversationListView?.reload(conversations: conversations,
                                             selectedId: currentConversationId)
            }
        } catch {
            NSLog("ClipVault: Failed to delete conversation \(id): \(error)")
        }
    }

    func conversationListView(_ view: ConversationListView,
                               didRenameConversation id: Int64,
                               newTitle currentTitle: String) {
        let alert = NSAlert()
        alert.messageText = "Rename Conversation"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = currentTitle
        alert.accessoryView = field

        guard let panelWindow = window else { return }
        alert.beginSheetModal(for: panelWindow) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            let newTitle = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !newTitle.isEmpty else { return }
            do {
                try self?.conversationStore?.updateTitle(conversationId: id, title: newTitle)
                if let convs = try? self?.conversationStore?.fetchAll() {
                    self?.conversations = convs
                    self?.conversationListView?.reload(conversations: convs,
                                                       selectedId: self?.currentConversationId)
                }
            } catch {
                NSLog("ClipVault: Failed to rename conversation \(id): \(error)")
            }
        }
    }

    // MARK: - Keyboard Shortcuts

    /// Cmd+N — create a new conversation.
    @objc func newConversationShortcut() {
        guard window?.isVisible == true else { return }
        createAndSelectNewConversation()
        inputField?.becomeFirstResponder()
    }

    /// Cmd+Backspace — delete the currently selected conversation (with confirmation alert).
    @objc func deleteConversationShortcut() {
        guard window?.isVisible == true,
              let id = currentConversationId,
              let panelWindow = window else { return }
        let alert = NSAlert()
        alert.messageText = "Delete Conversation"
        alert.informativeText = "This will permanently delete this conversation and all its messages."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        alert.beginSheetModal(for: panelWindow) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            self.conversationListView(ConversationListView(frame: .zero), didDeleteConversation: id)
        }
    }

    /// Cmd+[ — select the previous conversation in the list.
    @objc func navigatePreviousConversation() {
        guard window?.isVisible == true else { return }
        navigateConversation(direction: -1)
    }

    /// Cmd+] — select the next conversation in the list.
    @objc func navigateNextConversation() {
        guard window?.isVisible == true else { return }
        navigateConversation(direction: 1)
    }

    private func navigateConversation(direction: Int) {
        guard !conversations.isEmpty else { return }
        let currentIdx = currentConversationId.flatMap { cid in
            conversations.firstIndex(where: { $0.id == cid })
        } ?? -1
        let newIdx = ((currentIdx + direction) % conversations.count + conversations.count) % conversations.count
        guard newIdx < conversations.count, let id = conversations[newIdx].id else { return }
        conversationListView?.reload(conversations: conversations, selectedId: id)
        loadAndDisplayConversation(id: id)
    }

    func conversationListViewDidRequestClearAll(_ view: ConversationListView) {
        let alert = NSAlert()
        alert.messageText = "Clear All Conversations"
        alert.informativeText = "This will permanently delete all conversations and their messages. This action cannot be undone."
        alert.addButton(withTitle: "Clear All")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning

        guard let panelWindow = window else { return }
        alert.beginSheetModal(for: panelWindow) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            do {
                try self?.conversationStore?.deleteAllConversations()
                self?.currentConversationId = nil
                self?.conversations = []
                self?.conversationListView?.reload(conversations: [], selectedId: nil)
                self?.clearMessageArea()
                self?.showEmptyState()
            } catch {
                NSLog("ClipVault: Failed to clear all conversations: \(error)")
            }
        }
    }
}
