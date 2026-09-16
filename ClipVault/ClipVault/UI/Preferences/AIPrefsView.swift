import AppKit

final class AIPrefsView: NSView {

    // MARK: - Scroll infrastructure

    private let scrollView = NSScrollView()
    private let contentView = FlippedPrefsContentView()

    // MARK: - Provider section

    private let providerLabel = NSTextField(labelWithString: "AI Provider:")
    private let providerPopup = NSPopUpButton()

    private let baseURLLabel = NSTextField(labelWithString: "Base URL:")
    private let baseURLField = NSTextField()

    // MARK: - API Key section

    private let apiKeyLabel = NSTextField(labelWithString: "API Key:")
    private let apiKeyField = NSSecureTextField()
    private let validateButton = NSButton(title: "Validate", target: nil, action: nil)
    private let apiKeyHelpButton = NSButton(title: "How to get an API key", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let infoLabel = NSTextField(wrappingLabelWithString:
        "When an API key is set, BrainCache automatically classifies and tags each clipboard entry, " +
        "generates descriptions for images, and creates vector embeddings. " +
        "This enables semantic search and a conversational \"Chat with Data\" mode.")
    private let providerInfoLabel = NSTextField(wrappingLabelWithString: "")

    private let pipelineStatusLabel = NSTextField(labelWithString: "Paused — no API key")
    private let repairIndexButton = NSButton(title: "Repair Index", target: nil, action: nil)
    private let reindexButton = NSButton(title: "Re-index All", target: nil, action: nil)
    private let costLabel = NSTextField(wrappingLabelWithString: "")
    private let costHistoryLabel = NSTextField(wrappingLabelWithString: "")

    // MARK: - Model Selection controls

    private let modelSectionLabel = NSTextField(labelWithString: "Model Selection")

    private let chatModelLabel = NSTextField(labelWithString: "Chat Model:")
    private let chatModelPopup = NSPopUpButton()

    private let classificationModelLabel = NSTextField(labelWithString: "Classification Model:")
    private let classificationModelPopup = NSPopUpButton()

    private let visionModelLabel = NSTextField(labelWithString: "Vision Model:")
    private let visionModelPopup = NSPopUpButton()

    private let embeddingModelLabel = NSTextField(labelWithString: "Embedding Model:")
    private let embeddingModelPopup = NSPopUpButton()

    private let transcriptionModelLabel = NSTextField(labelWithString: "Transcription Model:")
    private let transcriptionModelPopup = NSPopUpButton()

    private let chunkWindowLabel = NSTextField(labelWithString: "Chunk Window:")
    private let chunkWindowField = NSTextField()
    private let chunkWindowStepper = NSStepper()
    private let chunkWindowUnitLabel = NSTextField(labelWithString: "seconds per audio chunk")

    private let translationModelLabel = NSTextField(labelWithString: "Translation Model:")
    private let translationModelPopup = NSPopUpButton()

    private let voiceRewriteModelLabel = NSTextField(labelWithString: "Voice Rewrite Model:")
    private let voiceRewriteModelPopup = NSPopUpButton()

    private let refreshModelsButton = NSButton(title: "Refresh Models", target: nil, action: nil)
    private let modelsStatusLabel = NSTextField(labelWithString: "")

    // MARK: - Chat Configuration controls

    private let chatConfigSectionLabel = NSTextField(labelWithString: "Chat Configuration")

    private let topKLabel = NSTextField(labelWithString: "Retrieved Clips:")
    private let topKField = NSTextField()

    private let contextCharsLabel = NSTextField(labelWithString: "Context Window:")
    private let contextCharsField = NSTextField()
    private let contextCharsValueLabel = NSTextField(labelWithString: "~6,000 tokens")

    private let maxOutputTokensLabel = NSTextField(labelWithString: "Max Response Length:")
    private let maxOutputTokensField = NSTextField()
    private let maxOutputTokensUnitLabel = NSTextField(labelWithString: "tokens")

    private let reasoningEffortLabel = NSTextField(labelWithString: "Reasoning Effort:")
    private let reasoningEffortPopup = NSPopUpButton()

    private let contextMessageLimitLabel = NSTextField(labelWithString: "Conversation Memory:")
    private let contextMessageLimitField = NSTextField()
    private let contextMessageLimitUnitLabel = NSTextField(labelWithString: "messages")

    // MARK: - Agentic Search controls

    private let agenticSectionLabel = NSTextField(labelWithString: "Agentic Search")

    private let agenticEnabledCheckbox = NSButton(checkboxWithTitle: "Enable Agentic Search",
                                                   target: nil, action: nil)

    private let agenticMaxIterationsLabel = NSTextField(labelWithString: "Max search iterations:")
    private let agenticMaxIterationsField = NSTextField()
    private let agenticMaxIterationsUnitLabel = NSTextField(labelWithString: "iterations")

    private let agenticInfoLabel = NSTextField(wrappingLabelWithString:
        "When enabled, the AI can autonomously search your clipboard using multiple strategies " +
        "(keyword, semantic, filters by app / date / tags) to find the best results.")

    // MARK: - Ask AI Tools controls

    private let askAIToolsSectionLabel = NSTextField(labelWithString: "Ask AI Tools")

    private let webSearchCheckbox = NSButton(checkboxWithTitle: "Enable web search",
                                             target: nil, action: nil)
    private let webSearchInfoLabel = NSTextField(wrappingLabelWithString:
        "Lets Ask AI use OpenAI's built-in web search — useful for the latest information " +
        "(news, releases, docs) or quick research on a topic from the conversation.")

    private let claudeHistoryCheckbox = NSButton(checkboxWithTitle: "Enable Claude Code CLI history",
                                                 target: nil, action: nil)
    private let codexHistoryCheckbox = NSButton(checkboxWithTitle: "Enable Codex history",
                                                target: nil, action: nil)
    private let agentHistoryInfoLabel = NSTextField(wrappingLabelWithString:
        "Registers tools that search your local Claude Code (~/.claude) and Codex (~/.codex) " +
        "session logs — and can ask the installed CLI directly (claude -p --continue / " +
        "codex exec resume) — so Ask AI can research your past AI-agent chats and work " +
        "history, e.g. when you ask \"How did you do that?\".")

    // MARK: - User prompt section
    private let promptSectionLabel = NSTextField(labelWithString: "Ask AI User Prompt")
    private let promptInfoLabel = NSTextField(wrappingLabelWithString:
        "Prefixed to every Ask AI request, before the conversation transcript. Use it to add standing instructions or context the assistant should keep in mind. Leave empty if not needed.")
    private let promptScrollView = NSScrollView()
    private let promptTextView = NSTextView()
    private let promptResetButton = NSButton(title: "Reset prompt", target: nil, action: nil)

    // MARK: - Transcription Summarisation section
    private let summariseSectionLabel = NSTextField(labelWithString: "Transcription Summarisation")
    private let summariseAutoCheckbox = NSButton(
        checkboxWithTitle: "Summarise mic and system audio recordings automatically",
        target: nil, action: nil)
    private let summariseAutoInfoLabel = NSTextField(wrappingLabelWithString:
        "When enabled, any finished recording transcript of 1,000 characters or more is sent to the chat panel for summarisation right after it's saved.")
    private let summarisePromptLabel = NSTextField(labelWithString: "Summarisation prompt")
    private let summarisePromptScrollView = NSScrollView()
    private let summarisePromptTextView = NSTextView()
    private let summarisePromptResetButton = NSButton(title: "Reset prompt", target: nil, action: nil)

    // MARK: - Skill Export section
    private let skillSectionLabel = NSTextField(labelWithString: "Export as Skill")
    private let skillInfoLabel = NSTextField(wrappingLabelWithString:
        "Generate a SKILL.md file that teaches Claude Code, Codex, Hermes, or OpenClaw how to query BrainCache's local database and activity logs. Save the file, then drop it into your AI tool's skills folder.")
    private let getSkillFileButton = NSButton(title: "Get Skill File…", target: nil, action: nil)
    private let howToInstallSkillButton = NSButton(title: "How to add skill to your AI", target: nil, action: nil)

    private let resetDefaultsButton = NSButton(title: "Reset to Defaults", target: nil, action: nil)

    /// Zero-height constraints that collapse the OpenAI-only rows (reasoning
    /// effort, hosted web search) when another provider is selected. Activated
    /// alongside `isHidden` so the rows don't leave a full-size gap.
    private var openAIOnlyCollapseConstraints: [NSLayoutConstraint] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
        loadValues()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    // MARK: - Build UI

    private func buildUI() {
        // Scroll view fills the entire tab area
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.scrollerStyle = .overlay
        addSubview(scrollView)

        contentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = contentView

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            contentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
        ])

        configureControls()
        layoutContent()
    }

    private func configureControls() {
        providerPopup.removeAllItems()
        for provider in AIProvider.allCases {
            let item = NSMenuItem(title: provider.displayName, action: nil, keyEquivalent: "")
            item.representedObject = provider.rawValue
            providerPopup.menu?.addItem(item)
        }
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)
        providerPopup.toolTip =
            "NVIDIA Nemotron models on Nebius Token Factory (default), OpenAI, or any other OpenAI-compatible endpoint."

        baseURLField.delegate = self
        baseURLField.target = self
        baseURLField.action = #selector(baseURLChanged)
        baseURLField.font = .monospacedSystemFont(ofSize: 11, weight: .regular)

        providerInfoLabel.textColor = .secondaryLabelColor
        providerInfoLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        apiKeyField.placeholderString = "API key"
        apiKeyField.delegate = self

        chunkWindowField.alignment = .right
        chunkWindowField.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        chunkWindowField.target = self
        chunkWindowField.action = #selector(chunkWindowChanged)
        chunkWindowField.delegate = self
        chunkWindowStepper.minValue = 4
        chunkWindowStepper.maxValue = 60
        chunkWindowStepper.increment = 1
        chunkWindowStepper.valueWraps = false
        chunkWindowStepper.target = self
        chunkWindowStepper.action = #selector(chunkWindowStepped)
        chunkWindowUnitLabel.textColor = .secondaryLabelColor
        chunkWindowUnitLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        chunkWindowLabel.toolTip =
            "Providers without a realtime socket transcribe buffered chunks of this length. Shorter feels more live; longer gives the model more context."

        validateButton.target = self
        validateButton.action = #selector(validateKey)
        apiKeyHelpButton.target = self
        apiKeyHelpButton.action = #selector(openAPIKeyInstructions)
        apiKeyHelpButton.bezelStyle = .inline
        apiKeyHelpButton.font = .systemFont(ofSize: 11)

        statusLabel.textColor = .secondaryLabelColor
        infoLabel.textColor = .secondaryLabelColor

        pipelineStatusLabel.textColor = .secondaryLabelColor
        pipelineStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        costLabel.textColor = .secondaryLabelColor
        costLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        costHistoryLabel.textColor = .secondaryLabelColor
        costHistoryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        repairIndexButton.target = self
        repairIndexButton.action = #selector(repairIndex)
        reindexButton.target = self
        reindexButton.action = #selector(reindexAll)

        // Model section
        modelSectionLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        for popup in [chatModelPopup, classificationModelPopup, visionModelPopup, embeddingModelPopup, transcriptionModelPopup, translationModelPopup, voiceRewriteModelPopup] {
            popup.font = .systemFont(ofSize: 11)
        }

        chatModelPopup.target = self
        chatModelPopup.action = #selector(chatModelChanged)
        classificationModelPopup.target = self
        classificationModelPopup.action = #selector(classificationModelChanged)
        visionModelPopup.target = self
        visionModelPopup.action = #selector(visionModelChanged)
        embeddingModelPopup.target = self
        embeddingModelPopup.action = #selector(embeddingModelChanged)
        transcriptionModelPopup.target = self
        transcriptionModelPopup.action = #selector(transcriptionModelChanged)
        translationModelPopup.target = self
        translationModelPopup.action = #selector(translationModelChanged)
        voiceRewriteModelPopup.target = self
        voiceRewriteModelPopup.action = #selector(voiceRewriteModelChanged)
        voiceRewriteModelPopup.toolTip =
            "Used by the Option+Shift+Space shortcut to clean up dictation transcripts before paste. Pick a fast/cheap chat model — quality matters less than latency here."

        refreshModelsButton.target = self
        refreshModelsButton.action = #selector(refreshModels)
        refreshModelsButton.font = .systemFont(ofSize: 11)

        modelsStatusLabel.textColor = .secondaryLabelColor
        modelsStatusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        // Chat Configuration
        chatConfigSectionLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        configureIntegerField(topKField, action: #selector(topKChanged))

        configureIntegerField(contextCharsField, action: #selector(contextCharsChanged))

        configureIntegerField(maxOutputTokensField, action: #selector(maxOutputTokensChanged))

        reasoningEffortPopup.removeAllItems()
        for value in Settings.validReasoningEfforts {
            let item = NSMenuItem(title: reasoningEffortDisplayName(value), action: nil, keyEquivalent: "")
            item.representedObject = value
            reasoningEffortPopup.menu?.addItem(item)
        }
        reasoningEffortPopup.target = self
        reasoningEffortPopup.action = #selector(reasoningEffortChanged)

        configureIntegerField(contextMessageLimitField, action: #selector(contextMessageLimitChanged))

        promptSectionLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        promptInfoLabel.textColor = .secondaryLabelColor
        promptInfoLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        promptScrollView.hasVerticalScroller = true
        promptScrollView.autohidesScrollers = true
        promptScrollView.borderType = .bezelBorder
        promptScrollView.drawsBackground = true

        promptTextView.isEditable = true
        promptTextView.isRichText = false
        promptTextView.allowsUndo = true
        promptTextView.font = .systemFont(ofSize: 12)
        promptTextView.isVerticallyResizable = true
        promptTextView.isHorizontallyResizable = false
        promptTextView.autoresizingMask = [.width]
        promptTextView.textContainer?.widthTracksTextView = true
        promptTextView.textContainerInset = NSSize(width: 4, height: 6)
        promptTextView.delegate = self
        promptScrollView.documentView = promptTextView

        promptResetButton.target = self
        promptResetButton.action = #selector(resetSystemPrompt)
        promptResetButton.bezelStyle = .inline
        promptResetButton.font = .systemFont(ofSize: 11)

        // Transcription Summarisation
        summariseSectionLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        summariseAutoCheckbox.target = self
        summariseAutoCheckbox.action = #selector(summariseAutoChanged)

        summariseAutoInfoLabel.textColor = .secondaryLabelColor
        summariseAutoInfoLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        summarisePromptLabel.font = .systemFont(ofSize: 13, weight: .semibold)

        summarisePromptScrollView.hasVerticalScroller = true
        summarisePromptScrollView.autohidesScrollers = true
        summarisePromptScrollView.borderType = .bezelBorder
        summarisePromptScrollView.drawsBackground = true

        summarisePromptTextView.isEditable = true
        summarisePromptTextView.isRichText = false
        summarisePromptTextView.allowsUndo = true
        summarisePromptTextView.font = .systemFont(ofSize: 12)
        summarisePromptTextView.isVerticallyResizable = true
        summarisePromptTextView.isHorizontallyResizable = false
        summarisePromptTextView.autoresizingMask = [.width]
        summarisePromptTextView.textContainer?.widthTracksTextView = true
        summarisePromptTextView.textContainerInset = NSSize(width: 4, height: 6)
        summarisePromptTextView.delegate = self
        summarisePromptScrollView.documentView = summarisePromptTextView

        summarisePromptResetButton.target = self
        summarisePromptResetButton.action = #selector(resetSummarisePrompt)
        summarisePromptResetButton.bezelStyle = .inline
        summarisePromptResetButton.font = .systemFont(ofSize: 11)

        // Skill Export section
        skillSectionLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        skillInfoLabel.textColor = .secondaryLabelColor
        skillInfoLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        getSkillFileButton.target = self
        getSkillFileButton.action = #selector(saveSkillFile)
        howToInstallSkillButton.target = self
        howToInstallSkillButton.action = #selector(showSkillInstallGuide)

        resetDefaultsButton.target = self
        resetDefaultsButton.action = #selector(resetToDefaults)

        // Agentic Search
        agenticSectionLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        agenticEnabledCheckbox.target = self
        agenticEnabledCheckbox.action = #selector(agenticEnabledChanged)

        configureIntegerField(agenticMaxIterationsField, action: #selector(agenticMaxIterationsChanged))

        agenticInfoLabel.textColor = .secondaryLabelColor
        agenticInfoLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        // Ask AI Tools
        askAIToolsSectionLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        webSearchCheckbox.target = self
        webSearchCheckbox.action = #selector(webSearchEnabledChanged)
        claudeHistoryCheckbox.target = self
        claudeHistoryCheckbox.action = #selector(claudeHistoryEnabledChanged)
        codexHistoryCheckbox.target = self
        codexHistoryCheckbox.action = #selector(codexHistoryEnabledChanged)

        for lbl in [webSearchInfoLabel, agentHistoryInfoLabel] {
            lbl.textColor = .secondaryLabelColor
            lbl.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }

        // Value labels styling
        for lbl in [contextCharsValueLabel, maxOutputTokensUnitLabel,
                    contextMessageLimitUnitLabel,
                    agenticMaxIterationsUnitLabel] as [NSTextField] {
            lbl.textColor = .secondaryLabelColor
            lbl.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            lbl.alignment = .left
        }
    }

    private func configureIntegerField(_ field: NSTextField, action: Selector) {
        field.alignment = .right
        field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        field.target = self
        field.action = action
        field.delegate = self
        field.controlSize = .regular
    }

    private func layoutContent() {
        let allViews: [NSView] = [
            providerLabel, providerPopup, baseURLLabel, baseURLField, providerInfoLabel,
            apiKeyLabel, apiKeyField, validateButton, statusLabel, apiKeyHelpButton, infoLabel,
            pipelineStatusLabel, repairIndexButton, reindexButton, costLabel, costHistoryLabel,
            modelSectionLabel,
            chatModelLabel, chatModelPopup,
            classificationModelLabel, classificationModelPopup,
            visionModelLabel, visionModelPopup,
            embeddingModelLabel, embeddingModelPopup,
            transcriptionModelLabel, transcriptionModelPopup,
            chunkWindowLabel, chunkWindowField, chunkWindowStepper, chunkWindowUnitLabel,
            translationModelLabel, translationModelPopup,
            voiceRewriteModelLabel, voiceRewriteModelPopup,
            refreshModelsButton, modelsStatusLabel,
            chatConfigSectionLabel,
            topKLabel, topKField,
            contextCharsLabel, contextCharsField, contextCharsValueLabel,
            maxOutputTokensLabel, maxOutputTokensField, maxOutputTokensUnitLabel,
            reasoningEffortLabel, reasoningEffortPopup,
            contextMessageLimitLabel, contextMessageLimitField, contextMessageLimitUnitLabel,
            agenticSectionLabel,
            agenticEnabledCheckbox,
            agenticMaxIterationsLabel, agenticMaxIterationsField, agenticMaxIterationsUnitLabel,
            agenticInfoLabel,
            askAIToolsSectionLabel,
            webSearchCheckbox, webSearchInfoLabel,
            claudeHistoryCheckbox, codexHistoryCheckbox, agentHistoryInfoLabel,
            promptSectionLabel, promptInfoLabel, promptScrollView, promptResetButton,
            summariseSectionLabel, summariseAutoCheckbox, summariseAutoInfoLabel,
            summarisePromptLabel, summarisePromptScrollView, summarisePromptResetButton,
            skillSectionLabel, skillInfoLabel, getSkillFileButton, howToInstallSkillButton,
            resetDefaultsButton,
        ]
        for view in allViews { view.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(view) }

        let labelWidth: CGFloat = 150
        let m: CGFloat = 20  // margin

        NSLayoutConstraint.activate([
            // Provider row
            providerLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: m),
            providerLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            providerLabel.widthAnchor.constraint(equalToConstant: 110),
            providerPopup.centerYAnchor.constraint(equalTo: providerLabel.centerYAnchor),
            providerPopup.leadingAnchor.constraint(equalTo: providerLabel.trailingAnchor, constant: 8),
            providerPopup.widthAnchor.constraint(equalToConstant: 220),

            baseURLLabel.topAnchor.constraint(equalTo: providerLabel.bottomAnchor, constant: 10),
            baseURLLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            baseURLLabel.widthAnchor.constraint(equalToConstant: 110),
            baseURLField.centerYAnchor.constraint(equalTo: baseURLLabel.centerYAnchor),
            baseURLField.leadingAnchor.constraint(equalTo: baseURLLabel.trailingAnchor, constant: 8),
            baseURLField.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            providerInfoLabel.topAnchor.constraint(equalTo: baseURLLabel.bottomAnchor, constant: 6),
            providerInfoLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            providerInfoLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            // API Key row
            apiKeyLabel.topAnchor.constraint(equalTo: providerInfoLabel.bottomAnchor, constant: 16),
            apiKeyLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            apiKeyLabel.widthAnchor.constraint(equalToConstant: 110),

            apiKeyField.centerYAnchor.constraint(equalTo: apiKeyLabel.centerYAnchor),
            apiKeyField.leadingAnchor.constraint(equalTo: apiKeyLabel.trailingAnchor, constant: 8),
            apiKeyField.trailingAnchor.constraint(equalTo: validateButton.leadingAnchor, constant: -8),

            validateButton.centerYAnchor.constraint(equalTo: apiKeyLabel.centerYAnchor),
            validateButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),
            validateButton.widthAnchor.constraint(equalToConstant: 80),

            statusLabel.topAnchor.constraint(equalTo: apiKeyLabel.bottomAnchor, constant: 6),
            statusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            statusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            apiKeyHelpButton.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            apiKeyHelpButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),

            infoLabel.topAnchor.constraint(equalTo: apiKeyHelpButton.bottomAnchor, constant: 12),
            infoLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            infoLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            pipelineStatusLabel.topAnchor.constraint(equalTo: infoLabel.bottomAnchor, constant: 12),
            pipelineStatusLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            pipelineStatusLabel.trailingAnchor.constraint(equalTo: repairIndexButton.leadingAnchor, constant: -8),

            repairIndexButton.centerYAnchor.constraint(equalTo: pipelineStatusLabel.centerYAnchor),
            repairIndexButton.trailingAnchor.constraint(equalTo: reindexButton.leadingAnchor, constant: -8),
            repairIndexButton.widthAnchor.constraint(equalToConstant: 105),

            reindexButton.centerYAnchor.constraint(equalTo: pipelineStatusLabel.centerYAnchor),
            reindexButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),
            reindexButton.widthAnchor.constraint(equalToConstant: 100),

            costLabel.topAnchor.constraint(equalTo: pipelineStatusLabel.bottomAnchor, constant: 6),
            costLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            costLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            costHistoryLabel.topAnchor.constraint(equalTo: costLabel.bottomAnchor, constant: 8),
            costHistoryLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            costHistoryLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            // ── Model Selection ──
            modelSectionLabel.topAnchor.constraint(equalTo: costHistoryLabel.bottomAnchor, constant: 20),
            modelSectionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),

            chatModelLabel.topAnchor.constraint(equalTo: modelSectionLabel.bottomAnchor, constant: 12),
            chatModelLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            chatModelLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            chatModelPopup.centerYAnchor.constraint(equalTo: chatModelLabel.centerYAnchor),
            chatModelPopup.leadingAnchor.constraint(equalTo: chatModelLabel.trailingAnchor, constant: 8),
            chatModelPopup.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            classificationModelLabel.topAnchor.constraint(equalTo: chatModelLabel.bottomAnchor, constant: 10),
            classificationModelLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            classificationModelLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            classificationModelPopup.centerYAnchor.constraint(equalTo: classificationModelLabel.centerYAnchor),
            classificationModelPopup.leadingAnchor.constraint(equalTo: classificationModelLabel.trailingAnchor, constant: 8),
            classificationModelPopup.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            visionModelLabel.topAnchor.constraint(equalTo: classificationModelLabel.bottomAnchor, constant: 10),
            visionModelLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            visionModelLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            visionModelPopup.centerYAnchor.constraint(equalTo: visionModelLabel.centerYAnchor),
            visionModelPopup.leadingAnchor.constraint(equalTo: visionModelLabel.trailingAnchor, constant: 8),
            visionModelPopup.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            embeddingModelLabel.topAnchor.constraint(equalTo: visionModelLabel.bottomAnchor, constant: 10),
            embeddingModelLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            embeddingModelLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            embeddingModelPopup.centerYAnchor.constraint(equalTo: embeddingModelLabel.centerYAnchor),
            embeddingModelPopup.leadingAnchor.constraint(equalTo: embeddingModelLabel.trailingAnchor, constant: 8),
            embeddingModelPopup.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            transcriptionModelLabel.topAnchor.constraint(equalTo: embeddingModelLabel.bottomAnchor, constant: 10),
            transcriptionModelLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            transcriptionModelLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            transcriptionModelPopup.centerYAnchor.constraint(equalTo: transcriptionModelLabel.centerYAnchor),
            transcriptionModelPopup.leadingAnchor.constraint(equalTo: transcriptionModelLabel.trailingAnchor, constant: 8),
            transcriptionModelPopup.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            chunkWindowLabel.topAnchor.constraint(equalTo: transcriptionModelLabel.bottomAnchor, constant: 10),
            chunkWindowLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            chunkWindowLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            chunkWindowField.centerYAnchor.constraint(equalTo: chunkWindowLabel.centerYAnchor),
            chunkWindowField.leadingAnchor.constraint(equalTo: chunkWindowLabel.trailingAnchor, constant: 8),
            chunkWindowField.widthAnchor.constraint(equalToConstant: 60),
            chunkWindowStepper.centerYAnchor.constraint(equalTo: chunkWindowLabel.centerYAnchor),
            chunkWindowStepper.leadingAnchor.constraint(equalTo: chunkWindowField.trailingAnchor, constant: 4),
            chunkWindowUnitLabel.centerYAnchor.constraint(equalTo: chunkWindowLabel.centerYAnchor),
            chunkWindowUnitLabel.leadingAnchor.constraint(equalTo: chunkWindowStepper.trailingAnchor, constant: 8),
            chunkWindowUnitLabel.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -m),

            translationModelLabel.topAnchor.constraint(equalTo: chunkWindowLabel.bottomAnchor, constant: 10),
            translationModelLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            translationModelLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            translationModelPopup.centerYAnchor.constraint(equalTo: translationModelLabel.centerYAnchor),
            translationModelPopup.leadingAnchor.constraint(equalTo: translationModelLabel.trailingAnchor, constant: 8),
            translationModelPopup.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            voiceRewriteModelLabel.topAnchor.constraint(equalTo: translationModelLabel.bottomAnchor, constant: 10),
            voiceRewriteModelLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            voiceRewriteModelLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            voiceRewriteModelPopup.centerYAnchor.constraint(equalTo: voiceRewriteModelLabel.centerYAnchor),
            voiceRewriteModelPopup.leadingAnchor.constraint(equalTo: voiceRewriteModelLabel.trailingAnchor, constant: 8),
            voiceRewriteModelPopup.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            refreshModelsButton.topAnchor.constraint(equalTo: voiceRewriteModelLabel.bottomAnchor, constant: 10),
            refreshModelsButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            modelsStatusLabel.centerYAnchor.constraint(equalTo: refreshModelsButton.centerYAnchor),
            modelsStatusLabel.leadingAnchor.constraint(equalTo: refreshModelsButton.trailingAnchor, constant: 8),
            modelsStatusLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            // ── Chat Configuration ──
            chatConfigSectionLabel.topAnchor.constraint(equalTo: refreshModelsButton.bottomAnchor, constant: 20),
            chatConfigSectionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),

            topKLabel.topAnchor.constraint(equalTo: chatConfigSectionLabel.bottomAnchor, constant: 12),
            topKLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            topKLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            topKField.centerYAnchor.constraint(equalTo: topKLabel.centerYAnchor),
            topKField.leadingAnchor.constraint(equalTo: topKLabel.trailingAnchor, constant: 8),
            topKField.widthAnchor.constraint(equalToConstant: 72),

            contextCharsLabel.topAnchor.constraint(equalTo: topKLabel.bottomAnchor, constant: 10),
            contextCharsLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            contextCharsLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            contextCharsField.centerYAnchor.constraint(equalTo: contextCharsLabel.centerYAnchor),
            contextCharsField.leadingAnchor.constraint(equalTo: contextCharsLabel.trailingAnchor, constant: 8),
            contextCharsField.widthAnchor.constraint(equalToConstant: 96),
            contextCharsValueLabel.centerYAnchor.constraint(equalTo: contextCharsLabel.centerYAnchor),
            contextCharsValueLabel.leadingAnchor.constraint(equalTo: contextCharsField.trailingAnchor, constant: 8),
            contextCharsValueLabel.widthAnchor.constraint(equalToConstant: 90),

            maxOutputTokensLabel.topAnchor.constraint(equalTo: contextCharsLabel.bottomAnchor, constant: 10),
            maxOutputTokensLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            maxOutputTokensLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            maxOutputTokensField.centerYAnchor.constraint(equalTo: maxOutputTokensLabel.centerYAnchor),
            maxOutputTokensField.leadingAnchor.constraint(equalTo: maxOutputTokensLabel.trailingAnchor, constant: 8),
            maxOutputTokensField.widthAnchor.constraint(equalToConstant: 88),
            maxOutputTokensUnitLabel.centerYAnchor.constraint(equalTo: maxOutputTokensLabel.centerYAnchor),
            maxOutputTokensUnitLabel.leadingAnchor.constraint(equalTo: maxOutputTokensField.trailingAnchor, constant: 8),
            maxOutputTokensUnitLabel.widthAnchor.constraint(equalToConstant: 80),

            reasoningEffortLabel.topAnchor.constraint(equalTo: maxOutputTokensLabel.bottomAnchor, constant: 10),
            reasoningEffortLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            reasoningEffortLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            reasoningEffortPopup.centerYAnchor.constraint(equalTo: reasoningEffortLabel.centerYAnchor),
            reasoningEffortPopup.leadingAnchor.constraint(equalTo: reasoningEffortLabel.trailingAnchor, constant: 8),
            reasoningEffortPopup.widthAnchor.constraint(equalToConstant: 140),

            contextMessageLimitLabel.topAnchor.constraint(equalTo: reasoningEffortLabel.bottomAnchor, constant: 10),
            contextMessageLimitLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            contextMessageLimitLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            contextMessageLimitField.centerYAnchor.constraint(equalTo: contextMessageLimitLabel.centerYAnchor),
            contextMessageLimitField.leadingAnchor.constraint(equalTo: contextMessageLimitLabel.trailingAnchor, constant: 8),
            contextMessageLimitField.widthAnchor.constraint(equalToConstant: 72),
            contextMessageLimitUnitLabel.centerYAnchor.constraint(equalTo: contextMessageLimitLabel.centerYAnchor),
            contextMessageLimitUnitLabel.leadingAnchor.constraint(equalTo: contextMessageLimitField.trailingAnchor, constant: 8),
            contextMessageLimitUnitLabel.widthAnchor.constraint(equalToConstant: 80),

            // ── Agentic Search ──
            agenticSectionLabel.topAnchor.constraint(equalTo: contextMessageLimitLabel.bottomAnchor, constant: 20),
            agenticSectionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),

            agenticEnabledCheckbox.topAnchor.constraint(equalTo: agenticSectionLabel.bottomAnchor, constant: 12),
            agenticEnabledCheckbox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),

            agenticMaxIterationsLabel.topAnchor.constraint(equalTo: agenticEnabledCheckbox.bottomAnchor, constant: 10),
            agenticMaxIterationsLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            agenticMaxIterationsLabel.widthAnchor.constraint(equalToConstant: labelWidth),
            agenticMaxIterationsField.centerYAnchor.constraint(equalTo: agenticMaxIterationsLabel.centerYAnchor),
            agenticMaxIterationsField.leadingAnchor.constraint(equalTo: agenticMaxIterationsLabel.trailingAnchor, constant: 8),
            agenticMaxIterationsField.widthAnchor.constraint(equalToConstant: 72),
            agenticMaxIterationsUnitLabel.centerYAnchor.constraint(equalTo: agenticMaxIterationsLabel.centerYAnchor),
            agenticMaxIterationsUnitLabel.leadingAnchor.constraint(equalTo: agenticMaxIterationsField.trailingAnchor, constant: 8),
            agenticMaxIterationsUnitLabel.widthAnchor.constraint(equalToConstant: 80),

            agenticInfoLabel.topAnchor.constraint(equalTo: agenticMaxIterationsLabel.bottomAnchor, constant: 10),
            agenticInfoLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            agenticInfoLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            // ── Ask AI Tools ──
            askAIToolsSectionLabel.topAnchor.constraint(equalTo: agenticInfoLabel.bottomAnchor, constant: 24),
            askAIToolsSectionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),

            webSearchCheckbox.topAnchor.constraint(equalTo: askAIToolsSectionLabel.bottomAnchor, constant: 12),
            webSearchCheckbox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            webSearchCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -m),

            webSearchInfoLabel.topAnchor.constraint(equalTo: webSearchCheckbox.bottomAnchor, constant: 4),
            webSearchInfoLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            webSearchInfoLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            claudeHistoryCheckbox.topAnchor.constraint(equalTo: webSearchInfoLabel.bottomAnchor, constant: 10),
            claudeHistoryCheckbox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            claudeHistoryCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -m),

            codexHistoryCheckbox.topAnchor.constraint(equalTo: claudeHistoryCheckbox.bottomAnchor, constant: 6),
            codexHistoryCheckbox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            codexHistoryCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -m),

            agentHistoryInfoLabel.topAnchor.constraint(equalTo: codexHistoryCheckbox.bottomAnchor, constant: 4),
            agentHistoryInfoLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            agentHistoryInfoLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            promptSectionLabel.topAnchor.constraint(equalTo: agentHistoryInfoLabel.bottomAnchor, constant: 24),
            promptSectionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            promptSectionLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            promptInfoLabel.topAnchor.constraint(equalTo: promptSectionLabel.bottomAnchor, constant: 4),
            promptInfoLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            promptInfoLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            promptScrollView.topAnchor.constraint(equalTo: promptInfoLabel.bottomAnchor, constant: 8),
            promptScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            promptScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),
            promptScrollView.heightAnchor.constraint(equalToConstant: 110),

            promptResetButton.topAnchor.constraint(equalTo: promptScrollView.bottomAnchor, constant: 8),
            promptResetButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),

            // ── Transcription Summarisation ──
            summariseSectionLabel.topAnchor.constraint(equalTo: promptResetButton.bottomAnchor, constant: 24),
            summariseSectionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            summariseSectionLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            summariseAutoCheckbox.topAnchor.constraint(equalTo: summariseSectionLabel.bottomAnchor, constant: 10),
            summariseAutoCheckbox.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            summariseAutoCheckbox.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -m),

            summariseAutoInfoLabel.topAnchor.constraint(equalTo: summariseAutoCheckbox.bottomAnchor, constant: 4),
            summariseAutoInfoLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            summariseAutoInfoLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            summarisePromptLabel.topAnchor.constraint(equalTo: summariseAutoInfoLabel.bottomAnchor, constant: 12),
            summarisePromptLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            summarisePromptLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            summarisePromptScrollView.topAnchor.constraint(equalTo: summarisePromptLabel.bottomAnchor, constant: 6),
            summarisePromptScrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            summarisePromptScrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),
            summarisePromptScrollView.heightAnchor.constraint(equalToConstant: 110),

            summarisePromptResetButton.topAnchor.constraint(equalTo: summarisePromptScrollView.bottomAnchor, constant: 8),
            summarisePromptResetButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),

            // ── Export as Skill ──
            skillSectionLabel.topAnchor.constraint(equalTo: summarisePromptResetButton.bottomAnchor, constant: 24),
            skillSectionLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            skillSectionLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            skillInfoLabel.topAnchor.constraint(equalTo: skillSectionLabel.bottomAnchor, constant: 6),
            skillInfoLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            skillInfoLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),

            getSkillFileButton.topAnchor.constraint(equalTo: skillInfoLabel.bottomAnchor, constant: 10),
            getSkillFileButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),

            howToInstallSkillButton.centerYAnchor.constraint(equalTo: getSkillFileButton.centerYAnchor),
            howToInstallSkillButton.leadingAnchor.constraint(equalTo: getSkillFileButton.trailingAnchor, constant: 10),

            resetDefaultsButton.topAnchor.constraint(equalTo: getSkillFileButton.bottomAnchor, constant: 20),
            resetDefaultsButton.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
            resetDefaultsButton.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -m),
        ])

        openAIOnlyCollapseConstraints = [
            reasoningEffortLabel.heightAnchor.constraint(equalToConstant: 0),
            reasoningEffortPopup.heightAnchor.constraint(equalToConstant: 0),
            webSearchCheckbox.heightAnchor.constraint(equalToConstant: 0),
            webSearchInfoLabel.heightAnchor.constraint(equalToConstant: 0),
        ]
    }

    // MARK: - Provider

    /// Shows the OpenAI-only controls only when OpenAI is the active provider,
    /// and enables the Base URL field only for the Custom provider.
    private func applyProviderVisibility() {
        let provider = Settings.shared.aiProvider
        let isOpenAI = Settings.shared.isOpenAIProvider

        baseURLField.isEnabled = provider == .custom
        baseURLField.isEditable = provider == .custom
        baseURLField.textColor = provider == .custom ? .labelColor : .secondaryLabelColor

        for view in [reasoningEffortLabel, reasoningEffortPopup,
                     webSearchCheckbox, webSearchInfoLabel] as [NSView] {
            view.isHidden = !isOpenAI
        }
        for constraint in openAIOnlyCollapseConstraints {
            constraint.isActive = !isOpenAI
        }

        // The transcription popup lists realtime models on OpenAI and chat
        // (omni) models everywhere else, so its hint changes too.
        transcriptionModelLabel.toolTip = isOpenAI
            ? "Realtime transcription model used by the voice panel."
            : "Omni chat model used to transcribe buffered audio chunks."
        chunkWindowLabel.isEnabled = !isOpenAI
        chunkWindowField.isEnabled = !isOpenAI
        chunkWindowStepper.isEnabled = !isOpenAI

        providerInfoLabel.stringValue = {
            switch provider {
            case .nebius:
                return "NVIDIA Nemotron models served by Nebius Token Factory. Voice transcription runs through the Nemotron omni model in chunks — there is no realtime socket."
            case .openai:
                return "OpenAI's API. Enables the Responses API (thinking traces), hosted web search, and realtime voice transcription."
            case .custom:
                return "Any OpenAI-compatible endpoint. Set the base URL below (it must expose /chat/completions, /embeddings and /models)."
            }
        }()

        apiKeyHelpButton.title = provider == .openai
            ? "How to get an OpenAI API key"
            : "Get a Nebius Token Factory API key"
    }

    private func loadProviderValues() {
        let provider = Settings.shared.aiProvider
        for item in providerPopup.itemArray where (item.representedObject as? String) == provider.rawValue {
            providerPopup.select(item)
        }
        baseURLField.stringValue = Settings.shared.aiBaseURL
        applyProviderVisibility()
    }

    @objc private func providerChanged() {
        guard let raw = providerPopup.selectedItem?.representedObject as? String,
              let provider = AIProvider(rawValue: raw) else { return }
        // Setting the provider clears the stored model IDs so they fall back
        // to the new provider's defaults instead of 404-ing on every request.
        Settings.shared.aiProvider = provider
        loadProviderValues()
        loadModelPopups()
        loadChatConfigValues()
        NotificationCenter.default.post(name: .clipVaultAPIKeyDidChange, object: nil)
    }

    @objc private func baseURLChanged() {
        guard Settings.shared.aiProvider == .custom else { return }
        Settings.shared.aiBaseURL = baseURLField.stringValue
        baseURLField.stringValue = Settings.shared.aiBaseURL
        NotificationCenter.default.post(name: .clipVaultAPIKeyDidChange, object: nil)
    }

    @objc private func chunkWindowChanged() {
        Settings.shared.chunkedTranscriptionWindowSeconds =
            integerValue(from: chunkWindowField, fallback: Settings.shared.chunkedTranscriptionWindowSeconds)
        syncChunkWindowControls()
    }

    @objc private func chunkWindowStepped() {
        Settings.shared.chunkedTranscriptionWindowSeconds = chunkWindowStepper.integerValue
        syncChunkWindowControls()
    }

    private func syncChunkWindowControls() {
        let value = Settings.shared.chunkedTranscriptionWindowSeconds
        chunkWindowField.integerValue = value
        chunkWindowStepper.integerValue = value
    }

    // MARK: - Load Values

    private func loadValues() {
        loadProviderValues()
        apiKeyField.stringValue = Settings.shared.openAIAPIKey
        updateStatusLabel()
        updatePipelineStatus(AIIndexingPipeline.shared.state)
        updateCostLabel()
        loadModelPopups()
        loadChatConfigValues()
        AIIndexingPipeline.shared.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.updatePipelineStatus(state)
                self?.updateCostLabel()
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAIUsageDidChange),
            name: .clipVaultAIUsageDidChange,
            object: nil
        )
    }

    // MARK: - Model Popups

    private func loadModelPopups() {
        let cached = Settings.shared.cachedModelList
        let chatModels: [String]
        let embModels: [String]
        let transcriptionModels: [String]
        let translationModels: [String]

        // Only OpenAI has dedicated realtime transcription / translation
        // models. Elsewhere transcription runs through an omni *chat* model,
        // so those popups list the chat models instead.
        let isOpenAI = Settings.shared.isOpenAIProvider

        if cached.isEmpty {
            chatModels = OpenAIClient.defaultChatModels
            embModels = OpenAIClient.defaultEmbeddingModels
            transcriptionModels = isOpenAI ? OpenAIUsageCost.defaultTranscriptionModels : chatModels
            translationModels = isOpenAI ? OpenAIClient.defaultTranslationModels : chatModels
        } else {
            chatModels = OpenAIClient.chatModels(from: cached)
            embModels = OpenAIClient.embeddingModels(from: cached)
            if isOpenAI {
                let fromAPI = OpenAIClient.transcriptionModels(from: cached)
                transcriptionModels = fromAPI.isEmpty ? OpenAIUsageCost.defaultTranscriptionModels : fromAPI
                let translationFromAPI = OpenAIClient.translationModels(from: cached)
                translationModels = translationFromAPI.isEmpty ? OpenAIClient.defaultTranslationModels : translationFromAPI
            } else {
                transcriptionModels = chatModels
                translationModels = chatModels
            }
        }

        populatePopup(chatModelPopup, models: chatModels, selected: Settings.shared.chatModel)
        populatePopup(classificationModelPopup, models: chatModels, selected: Settings.shared.classificationModel)
        populatePopup(visionModelPopup, models: chatModels, selected: Settings.shared.visionModel)
        populatePopup(embeddingModelPopup, models: embModels, selected: Settings.shared.embeddingModel)
        populatePopup(transcriptionModelPopup, models: transcriptionModels, selected: Settings.shared.transcriptionModel)
        populatePopup(translationModelPopup, models: translationModels, selected: Settings.shared.translationModel)
        populatePopup(voiceRewriteModelPopup, models: chatModels, selected: Settings.shared.voiceRewriteModel)

        if cached.isEmpty {
            modelsStatusLabel.stringValue = "Using defaults. Click Refresh to load from API."
        } else {
            modelsStatusLabel.stringValue = "\(cached.count) models available"
        }
    }

    private func populatePopup(_ popup: NSPopUpButton, models: [String], selected: String) {
        popup.removeAllItems()
        var items = models
        if !items.contains(selected) {
            items.insert(selected, at: 0)
        }
        popup.addItems(withTitles: items)
        popup.selectItem(withTitle: selected)
    }

    @objc private func refreshModels() {
        guard Settings.shared.isAIEnabled else {
            modelsStatusLabel.stringValue = "Set an API key first"
            modelsStatusLabel.textColor = .systemRed
            return
        }
        refreshModelsButton.isEnabled = false
        modelsStatusLabel.stringValue = "Fetching…"
        modelsStatusLabel.textColor = .secondaryLabelColor

        Task { @MainActor in
            defer { refreshModelsButton.isEnabled = true }
            do {
                let models = try await OpenAIClient.shared.fetchAvailableModels()
                Settings.shared.cachedModelList = models
                loadModelPopups()
                modelsStatusLabel.stringValue = "\(models.count) models loaded"
                modelsStatusLabel.textColor = .secondaryLabelColor
            } catch {
                modelsStatusLabel.stringValue = "Failed: \(error.localizedDescription)"
                modelsStatusLabel.textColor = .systemRed
            }
        }
    }

    @objc private func chatModelChanged() {
        if let title = chatModelPopup.titleOfSelectedItem {
            Settings.shared.chatModel = title
        }
    }

    @objc private func classificationModelChanged() {
        if let title = classificationModelPopup.titleOfSelectedItem {
            Settings.shared.classificationModel = title
        }
    }

    @objc private func visionModelChanged() {
        if let title = visionModelPopup.titleOfSelectedItem {
            Settings.shared.visionModel = title
        }
    }

    @objc private func embeddingModelChanged() {
        if let title = embeddingModelPopup.titleOfSelectedItem {
            Settings.shared.embeddingModel = title
        }
    }

    @objc private func transcriptionModelChanged() {
        if let title = transcriptionModelPopup.titleOfSelectedItem {
            Settings.shared.transcriptionModel = title
        }
    }

    @objc private func translationModelChanged() {
        if let title = translationModelPopup.titleOfSelectedItem {
            Settings.shared.translationModel = title
        }
    }

    @objc private func voiceRewriteModelChanged() {
        if let title = voiceRewriteModelPopup.titleOfSelectedItem {
            Settings.shared.voiceRewriteModel = title
        }
    }

    // MARK: - Chat Config Values

    private func loadChatConfigValues() {
        let s = Settings.shared

        topKField.integerValue = s.ragTopK

        contextCharsField.integerValue = s.ragMaxContextChars
        updateContextCharsLabel(s.ragMaxContextChars)

        maxOutputTokensField.integerValue = s.ragMaxOutputTokens

        selectReasoningEffort(s.reasoningEffort)

        contextMessageLimitField.integerValue = s.chatContextMessageLimit

        agenticEnabledCheckbox.state = s.agenticSearchEnabled ? .on : .off
        agenticMaxIterationsField.integerValue = s.agenticMaxIterations

        webSearchCheckbox.state = s.askAIWebSearchEnabled ? .on : .off
        claudeHistoryCheckbox.state = s.claudeCodeHistoryToolEnabled ? .on : .off
        codexHistoryCheckbox.state = s.codexHistoryToolEnabled ? .on : .off

        promptTextView.string = s.aiAssistSystemPrompt

        summariseAutoCheckbox.state = s.transcriptionAutoSummariseEnabled ? .on : .off
        summarisePromptTextView.string = s.transcriptionSummarisationPrompt

        syncChunkWindowControls()
    }

    private func updateContextCharsLabel(_ chars: Int) {
        let estimatedTokens = chars / 4
        let formatted: String
        if estimatedTokens >= 1_000 {
            formatted = String(format: "~%.0fK tokens", Double(estimatedTokens) / 1_000.0)
        } else {
            formatted = "~\(estimatedTokens) tokens"
        }
        contextCharsValueLabel.stringValue = formatted
    }

    func updateCostLabel() {
        let s = Settings.shared
        let indexingLine = formattedUsageLine(
            title: "Indexing",
            inputTokens: s.indexingTokensInputToday,
            cachedInputTokens: s.indexingTokensCachedInputToday,
            outputTokens: s.indexingTokensOutputToday,
            costUSD: s.indexingCostTodayUSD
        )
        let chatLine = formattedUsageLine(
            title: "Chat",
            inputTokens: s.chatTokensInputToday,
            cachedInputTokens: s.chatTokensCachedInputToday,
            outputTokens: s.chatTokensOutputToday,
            costUSD: s.chatCostTodayUSD
        )
        let transcriptionLine = "Transcription today: \(formatCostUSD(s.transcriptionCostTodayUSD))"
        costLabel.stringValue = "\(indexingLine)\n\(chatLine)\n\(transcriptionLine)"
        costHistoryLabel.stringValue = formattedCostHistory()
    }

    private func formattedUsageLine(
        title: String,
        inputTokens: Int,
        cachedInputTokens: Int,
        outputTokens: Int,
        costUSD: Double
    ) -> String {
        let totalTokens = inputTokens + outputTokens
        guard totalTokens > 0 else {
            return "\(title) today: 0 tokens (\(formatCostUSD(0)))"
        }

        let cachedSuffix: String
        if cachedInputTokens > 0 {
            cachedSuffix = " (\(formatTokenCount(cachedInputTokens)) cached)"
        } else {
            cachedSuffix = ""
        }

        return "\(title) today: \(formatTokenCount(inputTokens)) in\(cachedSuffix), \(formatTokenCount(outputTokens)) out (\(formatCostUSD(costUSD)))"
    }

    private func formatTokenCount(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func formatCostUSD(_ value: Double) -> String {
        if value >= 1 {
            return String(format: "$%.2f", value)
        }
        return String(format: "$%.4f", value)
    }

    private func formattedCostHistory() -> String {
        let daily = Settings.shared.recentDailyCostHistory(limit: 7)
        let monthly = Settings.shared.recentMonthlyCostHistory(limit: 6)

        guard !daily.isEmpty || !monthly.isEmpty else {
            return "Daily and monthly AI cost history will appear here as you use indexing and chat."
        }

        var lines: [String] = []

        if !daily.isEmpty {
            lines.append("Recent days:")
            lines.append(contentsOf: daily.map { formattedHistoryLine(key: $0.key, entry: $0.value, granularity: .day) })
        }

        if !monthly.isEmpty {
            if !lines.isEmpty {
                lines.append("")
            }
            lines.append("Recent months:")
            lines.append(contentsOf: monthly.map { formattedHistoryLine(key: $0.key, entry: $0.value, granularity: .month) })
        }

        return lines.joined(separator: "\n")
    }

    private enum CostHistoryGranularity {
        case day
        case month
    }

    private func formattedHistoryLine(
        key: String,
        entry: AICostHistoryEntry,
        granularity: CostHistoryGranularity
    ) -> String {
        var parts = ["chat \(formatCostUSD(entry.chatCostUSD))", "indexing \(formatCostUSD(entry.indexingCostUSD))"]
        if entry.transcriptionCostUSD > 0 {
            parts.append("voice \(formatCostUSD(entry.transcriptionCostUSD))")
        }
        return "\(displayDate(for: key, granularity: granularity)): total \(formatCostUSD(entry.totalCostUSD)) (\(parts.joined(separator: ", ")))"
    }

    private func displayDate(for key: String, granularity: CostHistoryGranularity) -> String {
        let parser = DateFormatter()
        let formatter = DateFormatter()

        switch granularity {
        case .day:
            parser.dateFormat = "yyyy-MM-dd"
            formatter.dateFormat = "MMM d"
        case .month:
            parser.dateFormat = "yyyy-MM"
            formatter.dateFormat = "MMM yyyy"
        }

        guard let date = parser.date(from: key) else { return key }
        return formatter.string(from: date)
    }

    @objc private func handleAIUsageDidChange() {
        updateCostLabel()
    }

    private func updateStatusLabel() {
        if Settings.shared.isAIEnabled {
            statusLabel.stringValue = "Key configured — AI features enabled"
            statusLabel.textColor = .secondaryLabelColor
        } else {
            statusLabel.stringValue = "No key configured — AI features disabled"
            statusLabel.textColor = .secondaryLabelColor
        }
    }

    func updatePipelineStatus(_ state: PipelineState) {
        switch state {
        case .idle:
            pipelineStatusLabel.stringValue = "All clips indexed"
            pipelineStatusLabel.textColor = .secondaryLabelColor
        case .processing(_, let progress):
            pipelineStatusLabel.stringValue = "Processing… \(progress)"
            pipelineStatusLabel.textColor = .secondaryLabelColor
        case .paused:
            pipelineStatusLabel.stringValue = Settings.shared.isAIEnabled
                ? "Paused (system sleep)"
                : "Paused — no API key"
            pipelineStatusLabel.textColor = .secondaryLabelColor
        case .error(let message):
            pipelineStatusLabel.stringValue = message
            pipelineStatusLabel.textColor = .systemRed
        }
    }

    // MARK: - Chat Config Actions

    @objc private func topKChanged() {
        Settings.shared.ragTopK = integerValue(from: topKField, fallback: Settings.shared.ragTopK)
        topKField.integerValue = Settings.shared.ragTopK
    }

    @objc private func contextCharsChanged() {
        Settings.shared.ragMaxContextChars = integerValue(from: contextCharsField, fallback: Settings.shared.ragMaxContextChars)
        contextCharsField.integerValue = Settings.shared.ragMaxContextChars
        updateContextCharsLabel(Settings.shared.ragMaxContextChars)
    }

    @objc private func maxOutputTokensChanged() {
        Settings.shared.ragMaxOutputTokens = integerValue(from: maxOutputTokensField, fallback: Settings.shared.ragMaxOutputTokens)
        maxOutputTokensField.integerValue = Settings.shared.ragMaxOutputTokens
    }

    @objc private func reasoningEffortChanged() {
        guard let raw = reasoningEffortPopup.selectedItem?.representedObject as? String else { return }
        Settings.shared.reasoningEffort = raw
    }

    private func selectReasoningEffort(_ value: String) {
        for item in reasoningEffortPopup.itemArray {
            if (item.representedObject as? String) == value {
                reasoningEffortPopup.select(item)
                return
            }
        }
    }

    private func reasoningEffortDisplayName(_ value: String) -> String {
        switch value {
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "XHigh"
        default: return value.capitalized
        }
    }

    @objc private func contextMessageLimitChanged() {
        let raw = integerValue(from: contextMessageLimitField, fallback: Settings.shared.chatContextMessageLimit)
        Settings.shared.chatContextMessageLimit = max(0, min(50, raw))
        contextMessageLimitField.integerValue = Settings.shared.chatContextMessageLimit
    }

    @objc private func agenticEnabledChanged() {
        Settings.shared.agenticSearchEnabled = agenticEnabledCheckbox.state == .on
    }

    @objc private func webSearchEnabledChanged() {
        Settings.shared.askAIWebSearchEnabled = webSearchCheckbox.state == .on
    }

    @objc private func claudeHistoryEnabledChanged() {
        Settings.shared.claudeCodeHistoryToolEnabled = claudeHistoryCheckbox.state == .on
    }

    @objc private func codexHistoryEnabledChanged() {
        Settings.shared.codexHistoryToolEnabled = codexHistoryCheckbox.state == .on
    }

    @objc private func agenticMaxIterationsChanged() {
        Settings.shared.agenticMaxIterations = integerValue(from: agenticMaxIterationsField, fallback: Settings.shared.agenticMaxIterations)
        agenticMaxIterationsField.integerValue = Settings.shared.agenticMaxIterations
    }

    private func integerValue(from field: NSTextField, fallback: Int) -> Int {
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return Int(trimmed) ?? fallback
    }

    @objc private func resetToDefaults() {
        Settings.shared.ragTopK = Settings.Defaults.ragTopK
        Settings.shared.ragMaxContextChars = Settings.Defaults.ragMaxContextChars
        Settings.shared.ragMaxOutputTokens = Settings.Defaults.ragMaxOutputTokens
        Settings.shared.reasoningEffort = Settings.Defaults.reasoningEffort
        Settings.shared.chatContextMessageLimit = Settings.Defaults.chatContextMessageLimit
        Settings.shared.agenticSearchEnabled = Settings.Defaults.agenticSearchEnabled
        Settings.shared.agenticMaxIterations = Settings.Defaults.agenticMaxIterations
        Settings.shared.askAIWebSearchEnabled = Settings.Defaults.askAIWebSearchEnabled
        Settings.shared.claudeCodeHistoryToolEnabled = Settings.Defaults.claudeCodeHistoryToolEnabled
        Settings.shared.codexHistoryToolEnabled = Settings.Defaults.codexHistoryToolEnabled
        Settings.shared.chatModel = Settings.Defaults.chatModel
        Settings.shared.classificationModel = Settings.Defaults.classificationModel
        Settings.shared.visionModel = Settings.Defaults.visionModel
        Settings.shared.embeddingModel = Settings.Defaults.embeddingModel
        Settings.shared.transcriptionModel = Settings.Defaults.transcriptionModel
        Settings.shared.translationModel = Settings.Defaults.translationModel
        Settings.shared.voiceRewriteModel = Settings.Defaults.voiceRewriteModel
        Settings.shared.aiAssistSystemPrompt = Settings.Defaults.aiAssistSystemPrompt
        Settings.shared.transcriptionAutoSummariseEnabled = Settings.Defaults.transcriptionAutoSummariseEnabled
        Settings.shared.transcriptionSummarisationPrompt = ""
        Settings.shared.chunkedTranscriptionWindowSeconds = Settings.Defaults.chunkedTranscriptionWindowSeconds
        loadModelPopups()
        loadChatConfigValues()
        applyProviderVisibility()
    }

    @objc private func resetSystemPrompt() {
        Settings.shared.aiAssistSystemPrompt = Settings.Defaults.aiAssistSystemPrompt
        promptTextView.string = Settings.Defaults.aiAssistSystemPrompt
    }

    @objc private func summariseAutoChanged() {
        Settings.shared.transcriptionAutoSummariseEnabled = summariseAutoCheckbox.state == .on
    }

    @objc private func resetSummarisePrompt() {
        // Clearing the stored value lets the getter fall back to the default,
        // matching the aiAssistSystemPrompt pattern.
        Settings.shared.transcriptionSummarisationPrompt = ""
        summarisePromptTextView.string = Settings.Defaults.transcriptionSummarisationPrompt
    }

    // MARK: - Skill Export Actions

    @objc private func saveSkillFile() {
        let panel = NSSavePanel()
        panel.title = "Save BrainCache Skill"
        panel.message = "Save the SKILL.md file, then drop the folder into your AI tool's skills directory."
        panel.nameFieldStringValue = SkillExportContent.defaultFileName
        panel.allowedContentTypes = [.init(filenameExtension: "md")].compactMap { $0 }
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }

        do {
            let bridge = try BrainCacheLocalBridgeServer.shared.provisionForSkillExport(
                clipStore: PreferencesWindowController.shared.clipStore
            )
            try SkillExportContent.skillMarkdown(bridge: bridge).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't save SKILL.md"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc private func showSkillInstallGuide() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "How to add the BrainCache skill to your AI"
        alert.informativeText = "Save the SKILL.md file, then drop it into one of these directories. Each tool auto-discovers skills on next launch."
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Copy Instructions")

        let width: CGFloat = 600
        let height: CGFloat = 420
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = false

        let textView = NSTextView(frame: scrollView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]

        let rendered = NSMutableAttributedString(attributedString:
            MarkdownRenderer.render(SkillExportContent.installGuideMarkdown, fontSize: 12))
        linkifyURLs(in: rendered)
        textView.textStorage?.setAttributedString(rendered)

        scrollView.documentView = textView
        alert.accessoryView = scrollView

        let response = alert.runModal()
        if response == .alertSecondButtonReturn {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(SkillExportContent.installGuideMarkdown, forType: .string)
        }
    }

    /// `MarkdownRenderer` doesn't auto-linkify bare URLs in the chat use case, so we
    /// post-process matches with NSDataDetector to make the docs links clickable.
    private func linkifyURLs(in attrStr: NSMutableAttributedString) {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return }
        let full = attrStr.string
        let range = NSRange(location: 0, length: (full as NSString).length)
        detector.enumerateMatches(in: full, options: [], range: range) { match, _, _ in
            guard let match = match, let url = match.url else { return }
            attrStr.addAttribute(.link, value: url, range: match.range)
        }
    }

    // MARK: - Actions

    @objc private func openAPIKeyInstructions() {
        guard let url = URL(string: Settings.shared.aiProvider.apiKeyURL) else {
            statusLabel.stringValue = "Couldn't open the API key instructions"
            statusLabel.textColor = .systemRed
            return
        }

        if !NSWorkspace.shared.open(url) {
            statusLabel.stringValue = "Couldn't open the API key instructions"
            statusLabel.textColor = .systemRed
        }
    }

    @objc private func repairIndex() {
        do {
            let result = try AIIndexingPipeline.shared.repairIndexingIssues()
            let count = result.requeuedClipCount

            if count > 0 {
                if Settings.shared.isAIEnabled {
                    pipelineStatusLabel.stringValue = "Search index rebuilt — repairing \(count) clips…"
                } else {
                    pipelineStatusLabel.stringValue = "Search index rebuilt — \(count) clips need repair once an API key is set"
                }
            } else {
                pipelineStatusLabel.stringValue = result.rebuiltSearchIndex
                    ? "Search index rebuilt — no missing AI items found"
                    : "No repair was needed"
            }
            pipelineStatusLabel.textColor = .secondaryLabelColor
        } catch {
            pipelineStatusLabel.stringValue = "Failed to repair index: \(error.localizedDescription)"
            pipelineStatusLabel.textColor = .systemRed
        }
    }

    @objc private func reindexAll() {
        do {
            try AIIndexingPipeline.shared.reindexAll()
            pipelineStatusLabel.stringValue = "Re-indexing started…"
            pipelineStatusLabel.textColor = .secondaryLabelColor
        } catch {
            pipelineStatusLabel.stringValue = "Failed to start re-index: \(error.localizedDescription)"
            pipelineStatusLabel.textColor = .systemRed
        }
    }

    @objc private func validateKey() {
        let key = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            statusLabel.stringValue = "Enter an API key to validate"
            statusLabel.textColor = .secondaryLabelColor
            return
        }

        Settings.shared.openAIAPIKey = key
        statusLabel.stringValue = "Validating..."
        statusLabel.textColor = .secondaryLabelColor
        validateButton.isEnabled = false

        Task { @MainActor in
            defer { validateButton.isEnabled = true }
            do {
                let models = try await OpenAIClient.shared.fetchAvailableModels()
                Settings.shared.cachedModelList = models
                statusLabel.stringValue = "Key valid ✓"
                statusLabel.textColor = .systemGreen
                updateStatusLabel()
                loadModelPopups()
                NotificationCenter.default.post(name: .clipVaultAPIKeyDidChange, object: nil)
            } catch OpenAIError.apiKeyMissing {
                statusLabel.stringValue = "No API key set"
                statusLabel.textColor = .systemRed
            } catch OpenAIError.httpError(let code, _) where code == 401 {
                Settings.shared.openAIAPIKey = ""
                statusLabel.stringValue = "Invalid key — unauthorized (401)"
                statusLabel.textColor = .systemRed
            } catch {
                statusLabel.stringValue = "Validation failed: \(error.localizedDescription)"
                statusLabel.textColor = .systemRed
            }
        }
    }
}

// MARK: - NSTextFieldDelegate

extension AIPrefsView: NSTextViewDelegate {

    /// Persist the system prompt on every keystroke so the user doesn't need
    /// to confirm. Empty input falls back to the default at read time.
    func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? NSTextView else { return }
        if textView === promptTextView {
            Settings.shared.aiAssistSystemPrompt = textView.string
        } else if textView === summarisePromptTextView {
            // If the user clears the field, persist as empty so the getter falls back to default.
            let trimmed = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
            Settings.shared.transcriptionSummarisationPrompt =
                trimmed == Settings.Defaults.transcriptionSummarisationPrompt ? "" : textView.string
        }
    }
}

extension AIPrefsView: NSTextFieldDelegate {
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }

        if field === apiKeyField {
            let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            Settings.shared.openAIAPIKey = key
            updateStatusLabel()
            NotificationCenter.default.post(name: .clipVaultAPIKeyDidChange, object: nil)
        } else if field === topKField {
            topKChanged()
        } else if field === contextCharsField {
            contextCharsChanged()
        } else if field === maxOutputTokensField {
            maxOutputTokensChanged()
        } else if field === contextMessageLimitField {
            contextMessageLimitChanged()
        } else if field === agenticMaxIterationsField {
            agenticMaxIterationsChanged()
        } else if field === baseURLField {
            baseURLChanged()
        } else if field === chunkWindowField {
            chunkWindowChanged()
        }
    }
}

extension Notification.Name {
    static let clipVaultAPIKeyDidChange = Notification.Name("com.clipvault.apiKeyDidChange")
    static let clipVaultAIUsageDidChange = Notification.Name("com.clipvault.aiUsageDidChange")
}
