import AppKit

private enum SearchPanelPalette {
    static let panelBackground = NSColor(white: 0.08, alpha: 0.84)
    static let panelBorder = NSColor(white: 1.0, alpha: 0.12)
    static let chromeBackground = NSColor(white: 1.0, alpha: 0.14)
    static let chromeBorder = NSColor(white: 1.0, alpha: 0.18)
    static let iconBubbleBackground = NSColor(white: 1.0, alpha: 0.18)
    static let secondaryText = NSColor(white: 1.0, alpha: 0.82)
    static let tertiaryText = NSColor(white: 1.0, alpha: 0.64)
}

enum SearchHistoryMode {
    case clips
    case audioTranscripts
}

/// Controls the floating search panel: owns the search field, collection view, and results list.
final class SearchPanelController: NSObject {

    static let shared = SearchPanelController()

    // MARK: - Public — set before first toggle()

    var clipStore: ClipStore?
    var pasteService: PasteService?
    var clipboardMonitor: ClipboardMonitor?
    var conversationStore: ConversationStore?

    // MARK: - Private state

    private(set) var results: [ClipRecord] = []
    private(set) var historyMode: SearchHistoryMode = .clips
    private var debounceWorkItem: DispatchWorkItem?
    private var searchWorkItem: DispatchWorkItem?
    private let searchQueue = DispatchQueue(label: "com.clipvault.search", qos: .userInitiated)
    private let searchDebounceSeconds: TimeInterval = 0.12
    private var searchGeneration: UInt = 0
    private var isSearching = false
    private var clickOutsideMonitor: Any?

    /// Number of items currently exposed to the collection view (paginated).
    private(set) var displayedCount: Int = 0
    private let pageSize = 20
    private let dbPageSize = 50
    private var isLoadingMore = false
    private var currentQuery = ""
    private var allResultsFetched = false
    private var askAnswerCards: [String] = []
    private var askFullAnswer: String?
    private var askPendingResultCards: [ClipRecord] = []
    private var askResultsQuestion: String?
    private var askTask: Task<Void, Never>?
    private var askStreamingWorkItem: DispatchWorkItem?
    private var isAskStreaming = false
    private var isAskShowingTrace = false
    private var ragEngine: RAGEngine?
    private var agenticEngine: AgenticRAGEngine?
    private var audioTranscriptPopover: NSPopover?
    private var audioTranscriptLoadID: UUID?

    // MARK: - Setup

    /// Pre-create the window so the first show is instant.
    func setup() {
        let screenWidth = NSScreen.main?.frame.width ?? 1440
        let panel = SearchPanelWindow(
            contentRect: NSRect(x: 0, y: 0,
                                width: screenWidth,
                                height: SearchPanelWindow.panelHeight),
            styleMask: [],
            backing: .buffered,
            defer: false
        )
        panel.positionAtBottomCenter()
        buildContentView(in: panel)
        window = panel
    }

    // MARK: - Toggle

    func toggle() {
        guard let panel = window else { return }

        if panel.isVisible {
            hide()
        } else {
            debounceWorkItem?.cancel()
            debounceWorkItem = nil
            searchField?.stringValue = ""
            setHistoryMode(.clips, reload: false)
            panel.showWithAnimation()
            if let field = searchField {
                panel.makeFirstResponder(field)
            }
            reloadWithQuery("")
            installClickOutsideMonitor()
        }
    }

    // MARK: - Content view

    private(set) var window: SearchPanelWindow?
    private(set) var searchField: NSTextField?
    private var collectionView: NSCollectionView?
    private var spinner: NSProgressIndicator?
    private var inputContainerView: NSView?
    private var modeIconBubbleView: NSView?
    private var modeIconView: NSImageView?
    private var clearButton: NSButton?
    private var voiceButton: NSButton?
    private var historyModeControl: NSSegmentedControl?
    private var resultsScrollView: NSScrollView?
    private var scrollerHideWorkItem: DispatchWorkItem?
    private let scrollerIdleHideDelay: TimeInterval = 0.8
    private var askHintLabel: NSTextField?
    private var panGestureRecognizer: NSPanGestureRecognizer?
    private var panStartOffsetX: CGFloat = 0
    private let panMomentumProjection: CGFloat = 0.18
    private let panMomentumDuration: TimeInterval = 0.24

    private func buildContentView(in panel: NSPanel) {
        let effectView = NSVisualEffectView()
        effectView.material = .hudWindow
        effectView.state = .active
        effectView.blendingMode = .behindWindow
        effectView.wantsLayer = true
        effectView.layer?.backgroundColor = SearchPanelPalette.panelBackground.cgColor
        effectView.layer?.borderWidth = 1
        effectView.layer?.borderColor = SearchPanelPalette.panelBorder.cgColor
        effectView.layer?.cornerRadius = 12
        effectView.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        effectView.layer?.masksToBounds = true

        // Close button
        let closeBtn = NSButton()
        closeBtn.translatesAutoresizingMaskIntoConstraints = false
        closeBtn.bezelStyle = .inline
        closeBtn.isBordered = false
        closeBtn.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                 accessibilityDescription: "Close")
        closeBtn.contentTintColor = SearchPanelPalette.tertiaryText
        closeBtn.imageScaling = .scaleProportionallyDown
        closeBtn.target = self
        closeBtn.action = #selector(closePanel)
        closeBtn.setContentHuggingPriority(.required, for: .horizontal)
        effectView.addSubview(closeBtn)

        let inputContainer = NSView()
        inputContainer.translatesAutoresizingMaskIntoConstraints = false
        inputContainer.wantsLayer = true
        inputContainer.layer?.cornerRadius = 10
        inputContainer.layer?.borderWidth = 1
        effectView.addSubview(inputContainer)
        inputContainerView = inputContainer

        let iconBubble = NSView()
        iconBubble.translatesAutoresizingMaskIntoConstraints = false
        iconBubble.wantsLayer = true
        iconBubble.layer?.cornerRadius = 9
        inputContainer.addSubview(iconBubble)
        modeIconBubbleView = iconBubble

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        inputContainer.addSubview(iconView)
        modeIconView = iconView

        // Search field
        let field = NSTextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.placeholderString = "Search clipboard history…"
        field.delegate = self
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 14)
        field.isBordered = false
        field.drawsBackground = false
        field.backgroundColor = .clear
        inputContainer.addSubview(field)
        searchField = field

        let clearBtn = NSButton()
        clearBtn.translatesAutoresizingMaskIntoConstraints = false
        clearBtn.bezelStyle = .inline
        clearBtn.isBordered = false
        clearBtn.image = NSImage(systemSymbolName: "xmark.circle.fill",
                                 accessibilityDescription: "Clear")
        clearBtn.contentTintColor = SearchPanelPalette.tertiaryText
        clearBtn.imageScaling = .scaleProportionallyDown
        clearBtn.target = self
        clearBtn.action = #selector(clearSearch(_:))
        clearBtn.isHidden = true
        inputContainer.addSubview(clearBtn)
        clearButton = clearBtn

        let voiceBtn = NSButton()
        voiceBtn.translatesAutoresizingMaskIntoConstraints = false
        voiceBtn.bezelStyle = .inline
        voiceBtn.isBordered = false
        voiceBtn.image = NSImage(systemSymbolName: "mic.fill",
                                 accessibilityDescription: "Voice transcription")
        voiceBtn.contentTintColor = SearchPanelPalette.secondaryText
        voiceBtn.imageScaling = .scaleProportionallyDown
        voiceBtn.target = self
        voiceBtn.action = #selector(triggerVoiceTranscription(_:))
        voiceBtn.toolTip = "Voice transcription"
        inputContainer.addSubview(voiceBtn)
        voiceButton = voiceBtn

        let historySwitch = NSSegmentedControl(
            labels: ["Clips", "Audio"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(historyModeChanged(_:))
        )
        historySwitch.translatesAutoresizingMaskIntoConstraints = false
        historySwitch.selectedSegment = 0
        historySwitch.segmentStyle = .rounded
        historySwitch.controlSize = .small
        historySwitch.toolTip = "Switch between clipboard clips and audio transcripts"
        effectView.addSubview(historySwitch)
        historyModeControl = historySwitch

        // Separator
        let sep = NSBox()
        sep.boxType = .separator
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.borderColor = SearchPanelPalette.panelBorder.withAlphaComponent(0.7)
        effectView.addSubview(sep)

        // Collection view with horizontal flow
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(width: ClipCardItem.cardWidth, height: 230)
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)

        let cv = NSCollectionView()
        cv.collectionViewLayout = layout
        cv.delegate = self
        cv.dataSource = self
        cv.isSelectable = true
        cv.allowsMultipleSelection = false
        cv.backgroundColors = [.clear]
        cv.register(ClipCardItem.self, forItemWithIdentifier: ClipCardItem.identifier)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = cv
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        scrollView.scrollerKnobStyle = .light
        effectView.addSubview(scrollView)
        resultsScrollView = scrollView
        if let scroller = scrollView.horizontalScroller {
            scroller.controlSize = .mini
            scroller.alphaValue = 0
        }
        collectionView = cv

        let indicator = NSProgressIndicator()
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.style = .spinning
        indicator.controlSize = .small
        indicator.isDisplayedWhenStopped = false
        effectView.addSubview(indicator)
        spinner = indicator

        let hint = NSTextField(labelWithString: "")
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.font = .systemFont(ofSize: 13, weight: .regular)
        hint.textColor = SearchPanelPalette.tertiaryText
        hint.alignment = .center
        hint.isHidden = true
        effectView.addSubview(hint)
        askHintLabel = hint

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        // Context menu
        let contextMenu = NSMenu()
        contextMenu.delegate = self
        cv.menu = contextMenu

        let singleClick = NSClickGestureRecognizer(
            target: self, action: #selector(handleSingleClick(_:)))
        singleClick.numberOfClicksRequired = 1
        cv.addGestureRecognizer(singleClick)

        // Double-click to paste, or preview for transcript cards.
        let doubleClick = NSClickGestureRecognizer(
            target: self, action: #selector(handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        cv.addGestureRecognizer(doubleClick)

        // Drag to scroll cards (iOS-like pan interaction).
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handleCollectionPan(_:)))
        cv.addGestureRecognizer(pan)
        panGestureRecognizer = pan

        NSLayoutConstraint.activate([
            closeBtn.centerYAnchor.constraint(equalTo: inputContainer.centerYAnchor),
            closeBtn.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -12),
            closeBtn.widthAnchor.constraint(equalToConstant: 20),
            closeBtn.heightAnchor.constraint(equalToConstant: 20),

            inputContainer.topAnchor.constraint(equalTo: effectView.topAnchor, constant: 14),
            inputContainer.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 16),
            inputContainer.trailingAnchor.constraint(equalTo: historySwitch.leadingAnchor, constant: -8),
            inputContainer.heightAnchor.constraint(equalToConstant: 34),

            historySwitch.centerYAnchor.constraint(equalTo: inputContainer.centerYAnchor),
            historySwitch.trailingAnchor.constraint(equalTo: closeBtn.leadingAnchor, constant: -8),
            historySwitch.widthAnchor.constraint(equalToConstant: 112),
            historySwitch.heightAnchor.constraint(equalToConstant: 26),

            iconBubble.leadingAnchor.constraint(equalTo: inputContainer.leadingAnchor, constant: 10),
            iconBubble.centerYAnchor.constraint(equalTo: inputContainer.centerYAnchor),
            iconBubble.widthAnchor.constraint(equalToConstant: 18),
            iconBubble.heightAnchor.constraint(equalToConstant: 18),

            iconView.centerXAnchor.constraint(equalTo: iconBubble.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconBubble.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 12),
            iconView.heightAnchor.constraint(equalToConstant: 12),

            clearBtn.trailingAnchor.constraint(equalTo: inputContainer.trailingAnchor, constant: -8),
            clearBtn.centerYAnchor.constraint(equalTo: inputContainer.centerYAnchor),
            clearBtn.widthAnchor.constraint(equalToConstant: 14),
            clearBtn.heightAnchor.constraint(equalToConstant: 14),

            voiceBtn.trailingAnchor.constraint(equalTo: clearBtn.leadingAnchor, constant: -8),
            voiceBtn.centerYAnchor.constraint(equalTo: inputContainer.centerYAnchor),
            voiceBtn.widthAnchor.constraint(equalToConstant: 14),
            voiceBtn.heightAnchor.constraint(equalToConstant: 14),

            field.leadingAnchor.constraint(equalTo: iconBubble.trailingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: voiceBtn.leadingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: inputContainer.centerYAnchor),
            field.heightAnchor.constraint(equalToConstant: 22),

            sep.topAnchor.constraint(equalTo: inputContainer.bottomAnchor, constant: 10),
            sep.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            sep.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: effectView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: effectView.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: effectView.bottomAnchor),

            indicator.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            indicator.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            hint.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            hint.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            hint.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 24),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -24),
        ])

        panel.contentView = effectView
        updateAskModeVisuals(for: "")

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: panel
        )
    }

    @objc private func windowWillClose(_ notification: Notification) {
        clearPanelResults()
    }

    private func clearPanelResults() {
        askTask?.cancel()
        askTask = nil
        cancelAskStreaming()
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        searchWorkItem?.cancel()
        searchWorkItem = nil
        searchGeneration &+= 1
        scrollerHideWorkItem?.cancel()
        scrollerHideWorkItem = nil
        hideHorizontalScroller(animated: false)
        setSearching(false)
        searchField?.stringValue = ""
        results = []
        askAnswerCards = []
        askFullAnswer = nil
        askPendingResultCards = []
        askResultsQuestion = nil
        isAskShowingTrace = false
        displayedCount = 0
        currentQuery = ""
        allResultsFetched = false
        isLoadingMore = false
        collectionView?.selectionIndexPaths = []
        collectionView?.reloadData()
        updateClearButtonVisibility()
        updateAskModeVisuals(for: "")
        askHintLabel?.isHidden = true
    }

    // MARK: - Loading State

    private func setSearching(_ active: Bool) {
        guard active != isSearching else { return }
        isSearching = active
        if active {
            spinner?.startAnimation(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                self.collectionView?.animator().alphaValue = 0.35
            }
        } else {
            spinner?.stopAnimation(nil)
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                self.collectionView?.animator().alphaValue = 1.0
            }
        }
    }

    // MARK: - Search

    func reloadWithQuery(_ query: String) {
        updateAskModeVisuals(for: query)
        if let askQuestion = askQuestion(from: query) {
            applyAskDraftState(question: askQuestion, rawQuery: query)
            return
        }

        guard let store = clipStore else { return }

        clearAskOutput()
        updateAskHintVisibility()

        // When no collection view is attached (headless / test mode), run synchronously.
        guard collectionView != nil else {
            do {
                results = try Self.fetchHistory(
                    from: store,
                    mode: historyMode,
                    query: query,
                    limit: dbPageSize
                )
                displayedCount = results.count
                currentQuery = query
                allResultsFetched = results.count < dbPageSize
            } catch {
                NSLog("SearchPanelController: search error: \(error)")
                results = []
                displayedCount = 0
            }
            return
        }

        searchGeneration &+= 1
        let gen = searchGeneration
        let limit = dbPageSize
        let mode = historyMode

        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            setSearching(true)
        }

        searchWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.searchGeneration == gen else { return }
            let fetched: [ClipRecord]
            do {
                fetched = try Self.fetchHistory(
                    from: store,
                    mode: mode,
                    query: query,
                    limit: limit
                )
            } catch {
                NSLog("SearchPanelController: search error: \(error)")
                fetched = []
            }
            guard self.searchGeneration == gen else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.searchGeneration == gen else { return }
                self.applyResults(fetched, exhausted: fetched.count < limit)
            }
        }
        searchWorkItem = work
        searchQueue.async(execute: work)
    }

    private static func fetchHistory(
        from store: ClipStore,
        mode: SearchHistoryMode,
        query: String,
        limit: Int,
        offset: Int = 0
    ) throws -> [ClipRecord] {
        switch mode {
        case .clips:
            return try store.searchClipboardHistory(query: query, limit: limit, offset: offset)
        case .audioTranscripts:
            return try store.searchAudioTranscripts(query: query, limit: limit, offset: offset)
        }
    }

    private func askQuestion(from query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        guard lower == "/ask" || lower.hasPrefix("/ask ") else { return nil }
        return String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func modeIconImage(aiModeEnabled: Bool) -> NSImage? {
        let symbolName: String
        if aiModeEnabled {
            symbolName = "sparkles"
        } else if historyMode == .audioTranscripts {
            symbolName = "waveform"
        } else {
            symbolName = "magnifyingglass"
        }
        let config = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
        return NSImage(systemSymbolName: symbolName,
                       accessibilityDescription: aiModeEnabled ? "Ask AI" : "Search")?
            .withSymbolConfiguration(config)
    }

    private func updateClearButtonVisibility() {
        clearButton?.isHidden = (searchField?.stringValue.isEmpty ?? true)
    }

    private func updateSearchFieldPlaceholder(enabled: Bool) {
        let placeholder: String
        if enabled {
            switch historyMode {
            case .clips:
                placeholder = "Ask AI about your clipboard…"
            case .audioTranscripts:
                placeholder = "Ask AI about your audio transcripts…"
            }
        } else {
            switch historyMode {
            case .clips:
                placeholder = "Search clipboard history…"
            case .audioTranscripts:
                placeholder = "Search audio transcripts…"
            }
        }
        searchField?.placeholderString = placeholder
        guard let cell = searchField?.cell as? NSTextFieldCell else { return }
        cell.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [
                .foregroundColor: enabled
                    ? NSColor.white.withAlphaComponent(0.76)
                    : SearchPanelPalette.tertiaryText,
                .font: searchField?.font ?? NSFont.systemFont(ofSize: 14),
            ]
        )
    }

    private func updateAskModeVisuals(for query: String) {
        let enabled = askQuestion(from: query) != nil
        updateSearchFieldPlaceholder(enabled: enabled)
        inputContainerView?.layer?.backgroundColor = enabled
            ? NSColor.systemBlue.withAlphaComponent(0.22).cgColor
            : SearchPanelPalette.chromeBackground.cgColor
        inputContainerView?.layer?.borderColor = enabled
            ? NSColor.systemBlue.withAlphaComponent(0.62).cgColor
            : SearchPanelPalette.chromeBorder.cgColor
        inputContainerView?.layer?.shadowColor = enabled
            ? NSColor.systemBlue.withAlphaComponent(0.35).cgColor
            : NSColor.clear.cgColor
        inputContainerView?.layer?.shadowOpacity = enabled ? 1 : 0
        inputContainerView?.layer?.shadowRadius = enabled ? 10 : 0
        inputContainerView?.layer?.shadowOffset = .zero
        modeIconBubbleView?.layer?.backgroundColor = enabled
            ? NSColor.systemBlue.withAlphaComponent(0.34).cgColor
            : SearchPanelPalette.iconBubbleBackground.cgColor
        modeIconBubbleView?.layer?.borderWidth = enabled ? 1 : 0
        modeIconBubbleView?.layer?.borderColor = enabled
            ? NSColor.systemBlue.withAlphaComponent(0.45).cgColor
            : NSColor.clear.cgColor
        modeIconView?.image = modeIconImage(aiModeEnabled: enabled)
        modeIconView?.contentTintColor = enabled ? .white : SearchPanelPalette.secondaryText
        searchField?.textColor = .white
        clearButton?.contentTintColor = enabled
            ? NSColor.white.withAlphaComponent(0.78)
            : SearchPanelPalette.tertiaryText
        updateClearButtonVisibility()
    }

    func setHistoryMode(_ mode: SearchHistoryMode, reload: Bool = true) {
        historyModeControl?.selectedSegment = mode == .clips ? 0 : 1

        guard historyMode != mode else {
            updateAskModeVisuals(for: searchField?.stringValue ?? "")
            if reload {
                reloadWithQuery(searchField?.stringValue ?? "")
            }
            return
        }

        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        searchWorkItem?.cancel()
        searchWorkItem = nil
        clearAskOutput()
        searchGeneration &+= 1
        setSearching(false)

        historyMode = mode
        updateAskModeVisuals(for: searchField?.stringValue ?? "")

        if reload {
            reloadWithQuery(searchField?.stringValue ?? "")
        }
    }

    private func updateAskHintVisibility(askQuestion: String? = nil) {
        let inAskMode = askQuestion != nil
        let questionEmpty = askQuestion?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
        let noContent = askAnswerCards.isEmpty && results.isEmpty
        let shouldShow = inAskMode && questionEmpty && noContent
        if shouldShow {
            askHintLabel?.stringValue = askHintText(for: historyMode)
        }
        askHintLabel?.isHidden = !shouldShow
    }

    private func askHintText(for mode: SearchHistoryMode) -> String {
        switch mode {
        case .clips:
            return "Ask a question and AI will answer using your clipboard data"
        case .audioTranscripts:
            return "Ask a question and AI will answer using your audio transcripts"
        }
    }

    private func cancelAskStreaming() {
        askStreamingWorkItem?.cancel()
        askStreamingWorkItem = nil
        isAskStreaming = false
    }

    private func applyAskDraftState(question: String, rawQuery: String) {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        searchWorkItem?.cancel()
        searchWorkItem = nil
        searchGeneration &+= 1
        setSearching(false)
        currentQuery = rawQuery
        allResultsFetched = true
        isLoadingMore = false

        if askResultsQuestion != question {
            clearAskOutput()
        }

        displayedCount = askAnswerCards.count + results.count
        collectionView?.reloadData()
        updateAskHintVisibility(askQuestion: question)
    }

    private func clearAskOutput() {
        askTask?.cancel()
        askTask = nil
        cancelAskStreaming()
        agenticEngine?.onTraceUpdate = nil
        askAnswerCards = []
        askFullAnswer = nil
        askPendingResultCards = []
        askResultsQuestion = nil
        isAskShowingTrace = false
        results = []
    }

    private static func autoTitle(from message: String) -> String {
        String(message.prefix(60))
    }

    private func runAskQuery(question: String) {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let store = clipStore else {
            applyAskError(question: trimmed, message: "AI search is not available (ClipStore not connected).")
            return
        }
        guard Settings.shared.isAIEnabled else {
            applyAskError(question: trimmed,
                          message: "AI features require an OpenAI API key. Configure it in Preferences > AI.")
            return
        }

        if ragEngine == nil {
            ragEngine = RAGEngine(clipStore: store)
        }
        if agenticEngine == nil {
            agenticEngine = AgenticRAGEngine(clipStore: store)
        }

        askTask?.cancel()
        askTask = nil
        cancelAskStreaming()
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        searchWorkItem?.cancel()
        searchWorkItem = nil
        searchGeneration &+= 1
        setSearching(true)
        agenticEngine?.onTraceUpdate = nil
        askResultsQuestion = trimmed
        askFullAnswer = nil
        askPendingResultCards = []
        askAnswerCards = ["Thinking…"]
        results = []
        displayedCount = 1
        allResultsFetched = true
        isLoadingMore = false
        isAskStreaming = true
        isAskShowingTrace = true
        askHintLabel?.isHidden = true
        collectionView?.reloadData()
        collectionView?.selectionIndexPaths = [IndexPath(item: 0, section: 0)]

        let rag = ragEngine
        let agentic = agenticEngine
        let mode = historyMode
        // Transcripts /ask uses classic RAG with a source_app filter — agentic tools don't
        // propagate the filter, so they would mix in non-transcript clips.
        let useAgentic = mode == .clips && Settings.shared.agenticSearchEnabled && agentic != nil
        let conversationStore = self.conversationStore
        let currentStore = store

        askTask = Task { [weak self] in
            guard let self else { return }
            var conversationID: Int64?
            if let conversationStore {
                do {
                    let conversation = try conversationStore.createConversation(
                        title: Self.autoTitle(from: trimmed),
                        topic: ConversationTopic(historyMode: mode)
                    )
                    conversationID = conversation.id
                    if let cid = conversationID {
                        try conversationStore.appendMessage(
                            conversationId: cid,
                            role: "user",
                            content: trimmed
                        )
                    }
                } catch {
                    NSLog("SearchPanelController: failed to create /ask conversation: \(error)")
                }
            }

            do {
                let result: RAGResult
                if useAgentic, let agentic {
                    agentic.onTraceUpdate = { [weak self] snapshot in
                        guard let self else { return }
                        self.applyAskTraceUpdate(question: trimmed, text: snapshot.displayText)
                    }
                    result = try await agentic.query(trimmed, conversationHistory: nil)
                    agentic.onTraceUpdate = nil
                } else if let rag {
                    let filter: SearchFilter? = mode == .audioTranscripts
                        ? SearchFilter(sourceApp: ClipRecord.audioTranscriptSourceApp)
                        : nil
                    let topic: RAGTopic = mode == .audioTranscripts ? .audioTranscripts : .clipboard
                    result = try await rag.query(
                        trimmed,
                        conversationHistory: nil,
                        filter: filter,
                        topic: topic
                    )
                } else {
                    throw NSError(
                        domain: "ClipVault",
                        code: 0,
                        userInfo: [NSLocalizedDescriptionKey: "No RAG engine available"]
                    )
                }

                guard !Task.isCancelled else { return }

                if let cid = conversationID {
                    _ = try? conversationStore?.appendMessage(
                        conversationId: cid,
                        role: "assistant",
                        content: result.answer,
                        citedClipIds: result.citedClipIDs
                    )
                }

                var citedClips = (try? currentStore.fetchByIds(result.citedClipIDs)) ?? []
                if mode == .audioTranscripts {
                    citedClips = citedClips.filter { $0.isAudioTranscript }
                }
                if citedClips.isEmpty {
                    switch mode {
                    case .clips:
                        citedClips = (try? currentStore.search(query: trimmed, limit: 20)) ?? []
                    case .audioTranscripts:
                        citedClips = (try? currentStore.searchAudioTranscripts(query: trimmed, limit: 20)) ?? []
                    }
                }
                let citedSnapshot = citedClips

                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.applyAskResponse(
                        question: trimmed,
                        answer: result.answer,
                        citedClips: citedSnapshot
                    )
                }
            } catch {
                guard !Task.isCancelled else { return }
                agentic?.onTraceUpdate = nil
                let text = "Error: \(error.localizedDescription)"
                if let cid = conversationID {
                    _ = try? conversationStore?.appendMessage(
                        conversationId: cid,
                        role: "assistant",
                        content: text
                    )
                }
                await MainActor.run { [weak self] in
                    self?.applyAskError(question: trimmed, message: text)
                }
            }
        }
    }

    private func applyAskTraceUpdate(question: String, text: String) {
        guard askResultsQuestion == question else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        askAnswerCards = [trimmed.isEmpty ? "Thinking…" : trimmed]
        isAskShowingTrace = true
        displayedCount = 1
        collectionView?.reloadData()
    }

    private func applyAskResponse(question: String, answer: String, citedClips: [ClipRecord]) {
        setSearching(false)
        askTask = nil
        cancelAskStreaming()
        askResultsQuestion = question
        askFullAnswer = normalizeAskAnswer(answer)
        askPendingResultCards = citedClips
        askAnswerCards = [""]
        results = []
        displayedCount = 1
        allResultsFetched = true
        isLoadingMore = false
        isAskShowingTrace = false
        collectionView?.reloadData()
        let first: Set<IndexPath> = [IndexPath(item: 0, section: 0)]
        collectionView?.selectionIndexPaths = first
        collectionView?.scrollToItems(at: first, scrollPosition: .left)
        isAskStreaming = true
        streamAskAnswer(
            question: question,
            characters: Array(askFullAnswer ?? ""),
            from: 0
        )
    }

    private func applyAskError(question: String, message: String) {
        applyAskResponse(question: question, answer: message, citedClips: [])
    }

    private func normalizeAskAnswer(_ answer: String) -> String {
        let trimmed = answer.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "No answer returned." : trimmed
    }

    private func streamAskAnswer(question: String, characters: [Character], from start: Int) {
        guard isAskStreaming,
              askResultsQuestion == question,
              askTask == nil else { return }

        if start >= characters.count {
            finishAskStreaming()
            return
        }

        let chunkSize = 18
        let delay: TimeInterval = 0.03
        let end = min(start + chunkSize, characters.count)
        let chunk = String(characters[start..<end])
        if askAnswerCards.isEmpty {
            askAnswerCards = [chunk]
        } else {
            askAnswerCards[0].append(chunk)
        }
        collectionView?.reloadData()

        let work = DispatchWorkItem { [weak self] in
            self?.streamAskAnswer(question: question, characters: characters, from: end)
        }
        askStreamingWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func finishAskStreaming() {
        cancelAskStreaming()
        results = askPendingResultCards
        askPendingResultCards = []
        displayedCount = askAnswerCards.count + results.count
        collectionView?.reloadData()
    }

    /// Replaces results and resets pagination to the first page.
    private func applyResults(_ fetched: [ClipRecord], exhausted: Bool = true) {
        setSearching(false)
        results = fetched
        displayedCount = min(pageSize, fetched.count)
        allResultsFetched = exhausted
        currentQuery = searchField?.stringValue ?? ""
        let panel = window
        let editor = searchField?.currentEditor()
        let searchFieldIsFocused = panel?.firstResponder === editor || panel?.firstResponder === searchField
        let savedSelection = editor?.selectedRange
        collectionView?.reloadData()
        if !fetched.isEmpty {
            let first: Set<IndexPath> = [IndexPath(item: 0, section: 0)]
            collectionView?.selectionIndexPaths = first
            // Avoid scroll-jumps while typing; they can make input feel sticky.
            if !searchFieldIsFocused {
                collectionView?.scrollToItems(at: first, scrollPosition: .left)
            }
        }
        if searchFieldIsFocused, let field = searchField {
            panel?.makeFirstResponder(field)
        }
        if let editor = searchField?.currentEditor(), let range = savedSelection {
            editor.selectedRange = range
        }
    }

    /// Schedule a debounced search from the latest typed query.
    /// Immediately cancels any in-flight search so the input field stays responsive.
    func scheduleSearch(query: String) {
        debounceWorkItem?.cancel()
        searchWorkItem?.cancel()
        askTask?.cancel()
        askTask = nil
        cancelAskStreaming()
        agenticEngine?.onTraceUpdate = nil
        updateAskModeVisuals(for: query)
        searchGeneration &+= 1
        setSearching(false)
        let work = DispatchWorkItem { [weak self] in
            self?.reloadWithQuery(query)
        }
        debounceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + searchDebounceSeconds, execute: work)
    }

    // MARK: - Keyboard actions

    private var totalCardCount: Int {
        askAnswerCards.count + results.count
    }

    private func clipRecord(atCardIndex index: Int) -> ClipRecord? {
        let clipIndex = index - askAnswerCards.count
        guard clipIndex >= 0 else { return nil }
        return results[safe: clipIndex]
    }

    private var selectedAnswerForPaste: String? {
        guard let cv = collectionView,
              let index = cv.selectionIndexPaths.first?.item,
              index < askAnswerCards.count else { return nil }
        return askFullAnswer
    }

    /// Move collection view selection one card to the left.
    func moveSelectionLeft() {
        guard let cv = collectionView, totalCardCount > 0 else { return }
        let current = cv.selectionIndexPaths.first?.item ?? 0
        let newItem = max(current - 1, 0)
        let ip = IndexPath(item: newItem, section: 0)
        cv.selectionIndexPaths = [ip]
        cv.scrollToItems(at: [ip], scrollPosition: .centeredHorizontally)
    }

    /// Move collection view selection one card to the right.
    func moveSelectionRight() {
        guard let cv = collectionView, totalCardCount > 0 else { return }
        let current = cv.selectionIndexPaths.first?.item ?? -1
        let newItem = min(current + 1, displayedCount - 1)
        let ip = IndexPath(item: newItem, section: 0)
        cv.selectionIndexPaths = [ip]
        cv.scrollToItems(at: [ip], scrollPosition: .centeredHorizontally)
        if newItem >= displayedCount - 3 {
            loadMoreIfNeeded()
        }
    }

    /// Hide the panel and cancel any pending debounced search.
    func hide() {
        removeClickOutsideMonitor()
        clearPanelResults()
        audioTranscriptPopover?.close()
        audioTranscriptPopover = nil
        audioTranscriptLoadID = nil
        if let panel = window {
            panel.hideWithAnimation {}
        }
    }

    // MARK: - Click-outside dismiss

    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.window, panel.isVisible else { return }
            if !panel.frame.contains(NSEvent.mouseLocation) {
                DispatchQueue.main.async { self.hide() }
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    /// Returns the currently selected clip record, if any.
    var selectedClip: ClipRecord? {
        guard let cv = collectionView,
              let ip = cv.selectionIndexPaths.first else { return nil }
        return clipRecord(atCardIndex: ip.item)
    }

    /// Paste the currently selected clip and dismiss the panel.
    func confirmSelection() {
        if let question = askQuestion(from: searchField?.stringValue ?? "") {
            if question.isEmpty {
                return
            }
            if askTask != nil || isAskStreaming {
                return
            }
            if askResultsQuestion != question || askAnswerCards.isEmpty {
                runAskQuery(question: question)
                return
            }
        }

        if let clip = selectedClip {
            performDefaultAction(for: clip)
        } else if let answer = selectedAnswerForPaste {
            pasteAnswerAndHide(answer)
        } else {
            hide()
        }
    }

    /// Resolve the paste mode for the current confirm action. The user's
    /// preferred default (Settings.defaultPasteMode) is inverted when Shift
    /// is held on the triggering event — e.g. Shift+Return / Shift+double-click.
    func currentPasteMode() -> PasteMode {
        let shiftHeld = NSApp.currentEvent?
            .modifierFlags
            .contains(.shift) ?? false
        let defaultMode = Settings.shared.defaultPasteMode
        if shiftHeld {
            return defaultMode == .plain ? .rich : .plain
        }
        return defaultMode
    }

    /// Forward a key event to the search field/editor.
    func redirectToSearchField(event: NSEvent, in panel: NSWindow) {
        guard let field = searchField else { return }
        if panel.firstResponder !== field.currentEditor() && panel.firstResponder !== field {
            panel.makeFirstResponder(field)
        }
        if let editor = field.currentEditor() {
            editor.keyDown(with: event)
        } else {
            field.keyDown(with: event)
        }
    }

    @objc private func scrollViewDidScroll(_ notification: Notification) {
        revealHorizontalScrollerTemporarily()
        loadMoreIfNeeded()
    }

    @objc private func handleCollectionPan(_ gesture: NSPanGestureRecognizer) {
        guard let scrollView = resultsScrollView else { return }
        let clipView = scrollView.contentView
        switch gesture.state {
        case .began:
            panStartOffsetX = clipView.bounds.origin.x
            scrollerHideWorkItem?.cancel()
        case .changed:
            let translation = gesture.translation(in: clipView)
            let targetX = clampedHorizontalOffset(panStartOffsetX - translation.x, in: scrollView)
            clipView.setBoundsOrigin(NSPoint(x: targetX, y: clipView.bounds.origin.y))
            scrollView.reflectScrolledClipView(clipView)
            revealHorizontalScrollerTemporarily()
        case .ended:
            let velocityX = gesture.velocity(in: clipView).x
            applyPanMomentum(velocityX: velocityX)
            loadMoreIfNeeded()
        case .cancelled, .failed:
            revealHorizontalScrollerTemporarily()
        default:
            break
        }
    }

    private func revealHorizontalScrollerTemporarily() {
        guard let scroller = resultsScrollView?.horizontalScroller else { return }
        scrollerHideWorkItem?.cancel()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.08
            scroller.animator().alphaValue = 1
        }
        let work = DispatchWorkItem { [weak self] in
            self?.hideHorizontalScroller(animated: true)
        }
        scrollerHideWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + scrollerIdleHideDelay, execute: work)
    }

    private func hideHorizontalScroller(animated: Bool) {
        guard let scroller = resultsScrollView?.horizontalScroller else { return }
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                scroller.animator().alphaValue = 0
            }
        } else {
            scroller.alphaValue = 0
        }
    }

    private func applyPanMomentum(velocityX: CGFloat) {
        guard let scrollView = resultsScrollView else { return }
        let clipView = scrollView.contentView
        let currentX = clipView.bounds.origin.x
        let projectedX = clampedHorizontalOffset(
            currentX - velocityX * panMomentumProjection,
            in: scrollView
        )
        guard abs(projectedX - currentX) > 1 else { return }

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = panMomentumDuration
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            clipView.animator().setBoundsOrigin(NSPoint(x: projectedX, y: clipView.bounds.origin.y))
        }, completionHandler: { [weak self] in
            guard let self else { return }
            scrollView.reflectScrolledClipView(clipView)
            self.revealHorizontalScrollerTemporarily()
            self.loadMoreIfNeeded()
        })
    }

    private func clampedHorizontalOffset(_ candidate: CGFloat, in scrollView: NSScrollView) -> CGFloat {
        let viewportWidth = scrollView.contentView.bounds.width
        let contentWidth = scrollView.documentView?.bounds.width ?? 0
        let maxX = max(0, contentWidth - viewportWidth)
        return min(max(0, candidate), maxX)
    }

    /// Appends the next page of results when the user scrolls near the trailing edge.
    /// Handles two levels of pagination:
    ///   1. Show more already-fetched results (UI-level)
    ///   2. Fetch the next batch from the DB when all fetched results are displayed
    private func loadMoreIfNeeded() {
        guard askAnswerCards.isEmpty else { return }
        guard !isLoadingMore,
              let cv = collectionView,
              let scrollView = cv.enclosingScrollView else { return }

        let hasMoreUI = displayedCount < results.count
        let hasMoreDB = !allResultsFetched
        guard hasMoreUI || hasMoreDB else { return }

        let clipBounds = scrollView.contentView.bounds
        let contentWidth = cv.collectionViewLayout?.collectionViewContentSize.width ?? 0
        guard contentWidth > 0 else { return }

        let trailingEdge = clipBounds.origin.x + clipBounds.width
        let threshold = contentWidth - clipBounds.width * 0.5
        guard trailingEdge >= threshold else { return }

        isLoadingMore = true

        if hasMoreUI {
            showMoreLoadedResults(in: cv)
        } else {
            fetchNextDBPage(in: cv)
        }
    }

    /// Reveals the next page of already-fetched results in the collection view.
    private func showMoreLoadedResults(in cv: NSCollectionView) {
        let oldCount = displayedCount
        let newCount = min(oldCount + pageSize, results.count)
        displayedCount = newCount

        let newPaths: Set<IndexPath> = Set(
            (oldCount..<newCount).map { IndexPath(item: $0, section: 0) }
        )
        cv.performBatchUpdates({
            cv.insertItems(at: newPaths)
        }, completionHandler: { [weak self] _ in
            self?.isLoadingMore = false
        })
    }

    /// Fetches the next batch from the database and appends to results.
    private func fetchNextDBPage(in cv: NSCollectionView) {
        guard let store = clipStore else { isLoadingMore = false; return }
        let query = currentQuery
        let offset = results.count
        let limit = dbPageSize
        let gen = searchGeneration
        let mode = historyMode

        searchQueue.async { [weak self] in
            guard let self else { return }
            let fetched: [ClipRecord]
            do {
                fetched = try Self.fetchHistory(
                    from: store,
                    mode: mode,
                    query: query,
                    limit: limit,
                    offset: offset
                )
            } catch {
                NSLog("SearchPanelController: fetchNextDBPage error: \(error)")
                fetched = []
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.searchGeneration == gen else {
                    self?.isLoadingMore = false
                    return
                }
                if fetched.isEmpty {
                    self.allResultsFetched = true
                    self.isLoadingMore = false
                    return
                }
                self.allResultsFetched = fetched.count < limit

                let insertStart = self.results.count
                self.results.append(contentsOf: fetched)

                let showCount = min(self.pageSize, fetched.count)
                let oldDisplayed = self.displayedCount
                self.displayedCount = oldDisplayed + showCount

                let newPaths: Set<IndexPath> = Set(
                    (insertStart..<(insertStart + showCount)).map {
                        IndexPath(item: $0, section: 0)
                    }
                )
                cv.performBatchUpdates({
                    cv.insertItems(at: newPaths)
                }, completionHandler: { [weak self] _ in
                    self?.isLoadingMore = false
                })
            }
        }
    }

    @objc private func closePanel() {
        hide()
    }

    @objc private func clearSearch(_ sender: Any?) {
        searchField?.stringValue = ""
        updateClearButtonVisibility()
        reloadWithQuery("")
    }

    @objc private func historyModeChanged(_ sender: NSSegmentedControl) {
        setHistoryMode(sender.selectedSegment == 1 ? .audioTranscripts : .clips)
    }

    @objc private func triggerVoiceTranscription(_ sender: Any?) {
        // Capture the app that was frontmost before the search panel opened — the
        // transcribed text will be pasted there. Then dismiss this panel and show
        // the voice recording panel.
        removeClickOutsideMonitor()
        if let panel = window {
            panel.orderOut(nil)
        }
        clearPanelResults()
        DispatchQueue.main.async {
            VoiceRecordingPanelController.shared.startRecording()
        }
    }

    // MARK: - Click actions

    @objc private func handleSingleClick(_ gesture: NSClickGestureRecognizer) {
        guard gesture.state == .ended,
              historyMode == .audioTranscripts,
              let cv = collectionView else { return }

        let point = gesture.location(in: cv)
        guard let ip = findIndexPath(at: point, in: cv),
              let clip = clipRecord(atCardIndex: ip.item),
              clip.isAudioTranscript else { return }

        cv.selectionIndexPaths = [ip]
        showAudioTranscriptPreview(record: clip, anchorIndexPath: ip)
    }

    @objc private func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
        guard let cv = collectionView else { return }
        let point = gesture.location(in: cv)
        guard let ip = findIndexPath(at: point, in: cv) else { return }
        if let clip = clipRecord(atCardIndex: ip.item) {
            performDefaultAction(for: clip, anchorIndexPath: ip)
        } else if ip.item < askAnswerCards.count, let answer = askFullAnswer {
            pasteAnswerAndHide(answer)
        }
    }

    func defaultAction(for clip: ClipRecord) -> SearchPanelDefaultAction {
        clip.isAudioTranscript ? .preview : .paste
    }

    private func performDefaultAction(for clip: ClipRecord, anchorIndexPath: IndexPath? = nil) {
        switch defaultAction(for: clip) {
        case .preview:
            showAudioTranscriptPreview(record: clip, anchorIndexPath: anchorIndexPath)
        case .paste:
            pasteAndHide(clip, mode: currentPasteMode())
        }
    }

    private func pasteAndHide(_ clip: ClipRecord, mode: PasteMode) {
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
        let targetBundleID = AppDetector.shared.lastFrontmostApp
        clipboardMonitor?.suppressNextCapture(hash: clip.dataHash)
        audioTranscriptPopover?.close()
        audioTranscriptPopover = nil
        audioTranscriptLoadID = nil
        removeClickOutsideMonitor()
        window?.orderOut(nil)
        clearPanelResults()
        // Defer to the next run loop iteration so the search field's key-event
        // processing finishes before we activate the target app and inject ⌘V.
        DispatchQueue.main.async { [weak self] in
            self?.pasteService?.paste(record: clip, targetBundleID: targetBundleID, mode: mode)
            if let id = clip.id {
                try? self?.clipStore?.touchLastUsed(id: id)
            }
        }
    }

    private func pasteAnswerAndHide(_ answer: String) {
        let hash = Hashing.sha256(data: Data(answer.utf8))
        let targetBundleID = AppDetector.shared.lastFrontmostApp
        let answerRecord = ClipRecord(
            id: nil,
            contentType: ClipboardContentType.text.rawValue,
            textContent: answer,
            dataHash: hash,
            mediaFileName: nil,
            fileURL: nil,
            sourceApp: "BrainCache AI",
            byteSize: answer.utf8.count,
            createdAt: Date().timeIntervalSince1970,
            lastUsedAt: nil,
            isPinned: false,
            isIndexed: true,
            tags: nil,
            imageDescription: nil,
            aiProcessed: 1,
            aiProcessedAt: nil
        )
        clipboardMonitor?.suppressNextCapture(hash: hash)
        audioTranscriptPopover?.close()
        audioTranscriptPopover = nil
        audioTranscriptLoadID = nil
        removeClickOutsideMonitor()
        window?.orderOut(nil)
        clearPanelResults()
        DispatchQueue.main.async { [weak self] in
            self?.pasteService?.paste(record: answerRecord, targetBundleID: targetBundleID)
        }
    }

    private func findIndexPath(at point: NSPoint, in cv: NSCollectionView) -> IndexPath? {
        for ip in cv.indexPathsForVisibleItems() {
            guard let item = cv.item(at: ip) else { continue }
            if item.view.frame.contains(point) {
                return ip
            }
        }
        return nil
    }

    private func showAudioTranscriptPreview(record: ClipRecord, anchorIndexPath: IndexPath? = nil) {
        guard record.isAudioTranscript else { return }
        guard let text = record.textContent,
              !text.isEmpty else { return }
        guard let cv = collectionView else { return }

        let anchorView: NSView
        if let ip = anchorIndexPath,
           let item = cv.item(at: ip) {
            anchorView = item.view
        } else if let selected = cv.selectionIndexPaths.first,
                  let item = cv.item(at: selected) {
            anchorView = item.view
        } else {
            anchorView = cv
        }

        audioTranscriptPopover?.close()
        let loadID = UUID()
        audioTranscriptLoadID = loadID

        let popoverWidth: CGFloat = 520
        let popoverHeight: CGFloat = 380
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: popoverWidth, height: popoverHeight)

        let vc = NSViewController()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight))

        let title = NSTextField(labelWithString: "Audio Transcript")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        container.addSubview(title)

        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        let dateString = dateFormatter.string(from: Date(timeIntervalSince1970: record.createdAt))
        let subtitle = NSTextField(labelWithString: "#\(record.id ?? 0)  •  \(dateString)  •  \(Self.formatCharacterCount(record.byteSize))")
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor
        container.addSubview(subtitle)

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.autoresizingMask = [.width]
        textView.string = "Loading transcript..."

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        container.addSubview(scrollView)

        let chatButton = makePreviewButton(
            title: "Chat",
            symbolName: "bubble.left.and.bubble.right.fill",
            toolTip: "Chat with this transcript"
        )
        let pasteButton = makePreviewButton(
            title: "Paste",
            symbolName: "doc.on.clipboard",
            toolTip: "Paste this transcript into the previous app"
        )
        let copyButton = makePreviewButton(
            title: "Copy",
            symbolName: "doc.on.doc",
            toolTip: "Copy this transcript"
        )
        container.addSubview(chatButton)
        container.addSubview(pasteButton)
        container.addSubview(copyButton)

        let chatTarget = ActionTarget { [weak self] in
            guard let self else { return }
            self.audioTranscriptPopover?.close()
            self.hide()
            ChatPanelController.shared.summariseTranscript(
                text,
                title: "Transcript #\(record.id ?? 0)"
            )
        }
        chatButton.target = chatTarget
        chatButton.action = #selector(ActionTarget.run)

        let pasteTarget = ActionTarget { [weak self] in
            guard let self else { return }
            self.audioTranscriptPopover?.close()
            self.audioTranscriptPopover = nil
            self.pasteAndHide(record, mode: .plain)
        }
        pasteButton.target = pasteTarget
        pasteButton.action = #selector(ActionTarget.run)

        let copyTarget = ActionTarget {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copyButton.title = "Copied"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                copyButton.title = "Copy"
            }
        }
        copyButton.target = copyTarget
        copyButton.action = #selector(ActionTarget.run)

        objc_setAssociatedObject(popover, "chatTarget", chatTarget, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(popover, "pasteTarget", pasteTarget, .OBJC_ASSOCIATION_RETAIN)
        objc_setAssociatedObject(popover, "copyTarget", copyTarget, .OBJC_ASSOCIATION_RETAIN)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            title.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -16),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 3),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 12),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: chatButton.topAnchor, constant: -12),

            chatButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            chatButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),

            pasteButton.leadingAnchor.constraint(equalTo: chatButton.trailingAnchor, constant: 8),
            pasteButton.centerYAnchor.constraint(equalTo: chatButton.centerYAnchor),

            copyButton.leadingAnchor.constraint(equalTo: pasteButton.trailingAnchor, constant: 8),
            copyButton.centerYAnchor.constraint(equalTo: chatButton.centerYAnchor),
        ])

        vc.view = container
        popover.contentViewController = vc
        audioTranscriptPopover = popover
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY)
        loadTranscriptPreview(text, into: textView, loadID: loadID)
    }

    private func loadTranscriptPreview(_ text: String, into textView: NSTextView, loadID: UUID) {
        let nsText = text as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
        ]
        DispatchQueue.main.async { [weak self, weak textView] in
            guard let self, let textView else { return }
            textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
            self.appendTranscriptPreviewChunk(
                nsText,
                attributes: attributes,
                into: textView,
                start: 0,
                loadID: loadID
            )
        }
    }

    private func appendTranscriptPreviewChunk(
        _ nsText: NSString,
        attributes: [NSAttributedString.Key: Any],
        into textView: NSTextView,
        start: Int,
        loadID: UUID
    ) {
        guard audioTranscriptLoadID == loadID,
              audioTranscriptPopover?.isShown == true else { return }

        let totalLength = nsText.length
        guard start < totalLength else { return }

        let chunkSize = 24_000
        let length = min(chunkSize, totalLength - start)
        let chunk = nsText.substring(with: NSRange(location: start, length: length))
        textView.textStorage?.append(NSAttributedString(string: chunk, attributes: attributes))

        DispatchQueue.main.async { [weak self, weak textView] in
            guard let self, let textView else { return }
            self.appendTranscriptPreviewChunk(
                nsText,
                attributes: attributes,
                into: textView,
                start: start + length,
                loadID: loadID
            )
        }
    }

    private func makePreviewButton(title: String, symbolName: String, toolTip: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12)
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        button.imagePosition = .imageLeading
        button.toolTip = toolTip
        return button
    }

    private static func formatCharacterCount(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let value = formatter.string(from: NSNumber(value: count)) ?? "\(count)"
        return "\(value) characters"
    }
}

enum SearchPanelDefaultAction: Equatable {
    case paste
    case preview
}

// MARK: - NSTextFieldDelegate

extension SearchPanelController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        updateClearButtonVisibility()
        scheduleSearch(query: field.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveLeft(_:)):
            moveSelectionLeft()
            return true
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveRight(_:)):
            moveSelectionRight()
            return true
        case #selector(NSResponder.insertNewline(_:)):
            confirmSelection()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide()
            return true
        default:
            return false
        }
    }
}

// MARK: - NSCollectionViewDataSource

extension SearchPanelController: NSCollectionViewDataSource {
    func collectionView(_ collectionView: NSCollectionView,
                        numberOfItemsInSection section: Int) -> Int {
        displayedCount
    }

    func collectionView(_ collectionView: NSCollectionView,
                        itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(
            withIdentifier: ClipCardItem.identifier, for: indexPath)
        if let cardItem = item as? ClipCardItem {
            if indexPath.item < askAnswerCards.count {
                cardItem.configureAsAIAnswer(
                    text: askAnswerCards[indexPath.item],
                    isStreaming: isAskStreaming,
                    isInterimTrace: isAskShowingTrace
                )
            } else if let record = clipRecord(atCardIndex: indexPath.item) {
                cardItem.configure(with: record)
            }
        }
        return item
    }
}

// MARK: - NSCollectionViewDelegate

extension SearchPanelController: NSCollectionViewDelegate, NSCollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: NSCollectionView,
                        layout collectionViewLayout: NSCollectionViewLayout,
                        sizeForItemAt indexPath: IndexPath) -> NSSize {
        if indexPath.item < askAnswerCards.count {
            // Merge the first three logical cards into one wider AI response card.
            let mergedWidth = ClipCardItem.cardWidth * 3 + 24
            return NSSize(width: mergedWidth, height: 230)
        }
        return NSSize(width: ClipCardItem.cardWidth, height: 230)
    }
}

// MARK: - NSMenuDelegate (context menu)

extension SearchPanelController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let cv = collectionView,
              let event = NSApp.currentEvent else { return }
        let point = cv.convert(event.locationInWindow, from: nil)
        guard let ip = findIndexPath(at: point, in: cv),
              let record = clipRecord(atCardIndex: ip.item) else { return }

        let pinTitle = record.isPinned ? "Unpin" : "Pin"
        let pinItem = NSMenuItem(title: pinTitle,
                                 action: #selector(togglePin(_:)),
                                 keyEquivalent: "")
        pinItem.target = self
        pinItem.tag = Int(record.id ?? 0)
        menu.addItem(pinItem)

        if record.isAudioTranscript {
            let previewItem = NSMenuItem(title: "Preview Transcript",
                                         action: #selector(previewTranscript(_:)),
                                         keyEquivalent: "")
            previewItem.target = self
            previewItem.tag = Int(record.id ?? 0)
            menu.addItem(previewItem)

            let chatItem = NSMenuItem(title: "Chat with Transcript",
                                      action: #selector(chatWithTranscript(_:)),
                                      keyEquivalent: "")
            chatItem.target = self
            chatItem.tag = Int(record.id ?? 0)
            menu.addItem(chatItem)

            let pasteItem = NSMenuItem(title: "Paste Transcript",
                                       action: #selector(pasteTranscript(_:)),
                                       keyEquivalent: "")
            pasteItem.target = self
            pasteItem.tag = Int(record.id ?? 0)
            menu.addItem(pasteItem)
        }

        let aiItem = NSMenuItem(title: "View AI Details",
                                action: #selector(showAIDetails(_:)),
                                keyEquivalent: "")
        aiItem.target = self
        aiItem.tag = Int(record.id ?? 0)
        menu.addItem(aiItem)

        menu.addItem(.separator())

        let deleteItem = NSMenuItem(title: "Delete",
                                    action: #selector(deleteClip(_:)),
                                    keyEquivalent: "")
        deleteItem.target = self
        deleteItem.tag = Int(record.id ?? 0)
        menu.addItem(deleteItem)
    }

    @objc private func showAIDetails(_ sender: NSMenuItem) {
        let id = Int64(sender.tag)
        guard let record = results.first(where: { $0.id == id }) else { return }
        guard let cv = collectionView else { return }

        // Anchor the popover to the card view if we can find it; fall back to
        // the collection view itself otherwise.
        let anchorView: NSView
        let clipIndex = results.firstIndex(where: { $0.id == id }) ?? 0
        let cardIndex = clipIndex + askAnswerCards.count
        let ip = IndexPath(item: cardIndex, section: 0)
        if let item = cv.item(at: ip), let view = item.view as NSView? {
            anchorView = view
        } else {
            anchorView = cv
        }

        showAIDetailsPopover(record: record, relativeTo: anchorView)
    }

    private func showAIDetailsPopover(record: ClipRecord, relativeTo sourceView: NSView) {
        let popoverWidth: CGFloat = 380
        let popoverHeight: CGFloat = 320

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: popoverWidth, height: popoverHeight)

        let vc = NSViewController()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: popoverWidth, height: popoverHeight))

        let headerLabel = NSTextField(labelWithString: "AI Details · #\(record.id ?? 0)")
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        container.addSubview(headerLabel)

        let statusLabel = NSTextField(labelWithString: aiStatusText(for: record))
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = aiStatusColor(for: record)
        container.addSubview(statusLabel)

        let tagsHeader = NSTextField(labelWithString: "Tags")
        tagsHeader.translatesAutoresizingMaskIntoConstraints = false
        tagsHeader.font = .systemFont(ofSize: 10, weight: .medium)
        tagsHeader.textColor = .tertiaryLabelColor
        container.addSubview(tagsHeader)

        let tagsLabel = NSTextField(labelWithString: "")
        tagsLabel.translatesAutoresizingMaskIntoConstraints = false
        tagsLabel.font = .systemFont(ofSize: 12)
        tagsLabel.textColor = .labelColor
        tagsLabel.maximumNumberOfLines = 0
        tagsLabel.lineBreakMode = .byWordWrapping
        let tags = record.parsedTags
        tagsLabel.stringValue = tags.isEmpty ? "—" : tags.joined(separator: ", ")
        container.addSubview(tagsLabel)

        let descHeader = NSTextField(labelWithString: "Description")
        descHeader.translatesAutoresizingMaskIntoConstraints = false
        descHeader.font = .systemFont(ofSize: 10, weight: .medium)
        descHeader.textColor = .tertiaryLabelColor
        container.addSubview(descHeader)

        let descTV = NSTextView()
        descTV.isEditable = false
        descTV.isSelectable = true
        descTV.drawsBackground = false
        descTV.textContainerInset = NSSize(width: 4, height: 4)
        descTV.font = .systemFont(ofSize: 12)
        descTV.textColor = .labelColor
        descTV.isVerticallyResizable = true
        descTV.isHorizontallyResizable = false
        descTV.textContainer?.widthTracksTextView = true
        descTV.autoresizingMask = [.width]
        if let desc = record.imageDescription, !desc.isEmpty {
            descTV.string = desc
        } else if record.contentType == "image" {
            descTV.string = "(no description yet)"
            descTV.textColor = .tertiaryLabelColor
        } else {
            descTV.string = "(not an image clip)"
            descTV.textColor = .tertiaryLabelColor
        }

        let sv = NSScrollView()
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.documentView = descTV
        sv.hasVerticalScroller = true
        sv.autohidesScrollers = true
        sv.drawsBackground = false
        container.addSubview(sv)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            headerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            headerLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            statusLabel.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 2),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            tagsHeader.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 12),
            tagsHeader.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),

            tagsLabel.topAnchor.constraint(equalTo: tagsHeader.bottomAnchor, constant: 2),
            tagsLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            tagsLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            descHeader.topAnchor.constraint(equalTo: tagsLabel.bottomAnchor, constant: 12),
            descHeader.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),

            sv.topAnchor.constraint(equalTo: descHeader.bottomAnchor, constant: 4),
            sv.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            sv.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),
            sv.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])

        vc.view = container
        popover.contentViewController = vc
        popover.show(relativeTo: sourceView.bounds, of: sourceView, preferredEdge: .maxY)
    }

    private func aiStatusText(for record: ClipRecord) -> String {
        let dateFmt = DateFormatter()
        dateFmt.dateStyle = .short
        dateFmt.timeStyle = .short
        let when = record.aiProcessedAt.map { dateFmt.string(from: Date(timeIntervalSince1970: $0)) }
        switch record.aiProcessed {
        case 1: return "Processed" + (when.map { " · \($0)" } ?? "")
        case 2: return "Failed" + (when.map { " · \($0)" } ?? "")
        default: return "Pending"
        }
    }

    private func aiStatusColor(for record: ClipRecord) -> NSColor {
        switch record.aiProcessed {
        case 1: return .systemGreen
        case 2: return .systemRed
        default: return .secondaryLabelColor
        }
    }

    @objc private func previewTranscript(_ sender: NSMenuItem) {
        let id = Int64(sender.tag)
        guard let record = results.first(where: { $0.id == id }) else { return }
        showAudioTranscriptPreview(record: record)
    }

    @objc private func chatWithTranscript(_ sender: NSMenuItem) {
        let id = Int64(sender.tag)
        guard let record = results.first(where: { $0.id == id }),
              let text = record.textContent,
              !text.isEmpty else { return }
        hide()
        ChatPanelController.shared.summariseTranscript(text, title: "Transcript #\(id)")
    }

    @objc private func pasteTranscript(_ sender: NSMenuItem) {
        let id = Int64(sender.tag)
        guard let record = results.first(where: { $0.id == id }) else { return }
        pasteAndHide(record, mode: .plain)
    }

    @objc private func togglePin(_ sender: NSMenuItem) {
        let id = Int64(sender.tag)
        guard let record = results.first(where: { $0.id == id }) else { return }
        do {
            if record.isPinned {
                try clipStore?.unpinClip(id: id)
            } else {
                try clipStore?.pinClip(id: id)
            }
            reloadWithQuery(searchField?.stringValue ?? "")
        } catch {
            NSLog("SearchPanelController: pin toggle error: \(error)")
        }
    }

    @objc private func deleteClip(_ sender: NSMenuItem) {
        let id = Int64(sender.tag)
        do {
            try clipStore?.deleteById(id)
            reloadWithQuery(searchField?.stringValue ?? "")
        } catch {
            NSLog("SearchPanelController: delete error: \(error)")
        }
    }
}

// MARK: - Safe subscript helper

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
