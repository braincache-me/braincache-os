import AppKit
import ApplicationServices

final class OnboardingWindowController: NSWindowController {

    // MARK: - Permissions step string constants (internal for testability)

    static let permissionsStepSubtitle = "BrainCache needs Accessibility to paste clips back, Microphone to dictate and record meetings, and optionally Screen Recording for Activity Capture screenshots. Recording features are off by default."
    static let accessibilityCardBody = "Required to paste selected clips back into the app you were using. Also used by Activity Capture to read control names and roles when logging UI interactions — only when you enable recording. On macOS 13 or later, clicking the button below opens System Settings — find BrainCache in the list and toggle the switch to enable it."
    static let microphoneCardBody = "Required for voice transcription (⌥Space). The first time you grant it, macOS shows a permission dialog — after that, you can manage it any time in System Settings → Privacy & Security → Microphone."
    static let screenRecordingCardBody = "Used by Activity Capture to take a frontmost-window screenshot when you switch apps or windows, and to record system audio alongside the mic during transcription. All activity data stays local — no OCR, no network. Activity recording is off by default."
    static let permissionsFooterNote = "You can continue now and grant permissions later from Preferences > Permissions. On macOS 13 or later, you must manually enable each permission in System Settings after the prompt opens. Activity Capture is disabled by default — you can pause or stop recording at any time from the menu bar. All interaction data stays on your Mac."

    enum Step: Int, CaseIterable {
        case overview
        case liveAI
        case transcription
        case writingAssistant
        case activityCapture
        case permissions
        case hotkey
        case ai

        var title: String {
            switch self {
            case .overview:
                return "Your clipboard, remembered."
            case .liveAI:
                return "Get answers while you're on the call."
            case .permissions:
                return "Grant the permissions BrainCache needs."
            case .hotkey:
                return "Open your history with one shortcut."
            case .ai:
                return "Offline by default. AI only if you want it."
            case .transcription:
                return "Speak it. Save it. Search it."
            case .writingAssistant:
                return "Rewrite anything you type."
            case .activityCapture:
                return "Capture how you work."
            }
        }

        var subtitle: String {
            switch self {
            case .overview:
                return "BrainCache saves what you copy, makes it searchable in seconds, and turns everyday copy/paste into a personal memory backup."
            case .liveAI:
                return "This is the feature people use the most. Tap your chat shortcut during any meeting — interview, technical sync, sales pitch, doctor visit — type or paste the question, and get an instant answer before the silence gets weird."
            case .permissions:
                return OnboardingWindowController.permissionsStepSubtitle
            case .hotkey:
                return "Press the shortcut any time, search what you copied, then hit Return to paste the selected item right back where you were working."
            case .ai:
                return "The core app stays local and free. If you want smarter search, summaries, and image indexing, you can add your own AI provider API key later — BrainCache ships with NVIDIA Nemotron on Nebius Token Factory."
            case .transcription:
                return "Hit a shortcut to dictate from anywhere, flip on System audio to capture meetings, then turn the transcript into clean notes when you're done."
            case .writingAssistant:
                return "Double-tap the right Command key in any text field — Slack, Mail, a Google Doc, an issue comment. Type an instruction like \u{201C}make it more concise\u{201D} or \u{201C}translate to Spanish\u{201D}, then Replace, Append, or Copy."
            case .activityCapture:
                return "Activity Capture quietly logs how you work locally — so an LLM connected through BrainCache MCP can later learn, and reproduce, your patterns."
            }
        }
    }

    private static let openAIAPIKeyGuideURL = URL(
        string: "https://platform.openai.com/api-keys"
    )!
    private static let onboardingScreenshotAssetName = NSImage.Name("OnboardingScreenshot")

    static let shared = OnboardingWindowController()

    private let effectView = NSVisualEffectView()
    private let slideContainer = NSView()
    private let appNameLabel = NSTextField(labelWithString: "BrainCache")
    private let stepLabel = NSTextField(labelWithString: "")
    private let progressStack = NSStackView()
    private let secondaryButton = NSButton(title: "Skip", target: nil, action: nil)
    private let primaryButton = NSButton(title: "Continue", target: nil, action: nil)

    private var progressSegments: [NSView] = []
    var currentStep: Step = .overview
    private var permissionCards: [PermissionStatusCardView] = []
    private var completionHandler: (() -> Void)?
    private var permissionRefreshTimer: DispatchSourceTimer?
    private let timerQueue = DispatchQueue(label: "com.clipvault.onboarding-permissions-timer", qos: .utility)

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to BrainCache"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.appearance = NSAppearance(named: .darkAqua)

        super.init(window: window)

        standardWindowButtonsHidden(on: window)
        buildUI()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAppDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    func show(completion: (() -> Void)? = nil) {
        completionHandler = completion
        currentStep = .overview
        renderCurrentStep()
        window?.center()
        _ = NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async { [weak self] in
            self?.showWindow(nil)
            self?.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - UI

    private func buildUI() {
        guard let window, let contentView = window.contentView else { return }

        let solidBackground = NSView()
        solidBackground.translatesAutoresizingMaskIntoConstraints = false
        solidBackground.wantsLayer = true
        solidBackground.layer?.backgroundColor = NSColor(white: 0.13, alpha: 1.0).cgColor
        solidBackground.layer?.cornerRadius = 18
        solidBackground.layer?.cornerCurve = .continuous
        solidBackground.layer?.masksToBounds = true
        contentView.addSubview(solidBackground)

        effectView.translatesAutoresizingMaskIntoConstraints = false
        effectView.material = .windowBackground
        effectView.state = .active
        effectView.blendingMode = .withinWindow
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 18
        effectView.layer?.cornerCurve = .continuous
        effectView.layer?.masksToBounds = true
        effectView.layer?.borderWidth = 1
        effectView.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        contentView.addSubview(effectView)

        NSLayoutConstraint.activate(pinEdges(solidBackground, to: contentView))

        let rootStack = NSStackView()
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        rootStack.orientation = .vertical
        rootStack.spacing = 24
        effectView.addSubview(rootStack)

        let header = makeHeaderView()
        rootStack.addArrangedSubview(header)

        slideContainer.translatesAutoresizingMaskIntoConstraints = false
        slideContainer.setContentHuggingPriority(.defaultLow, for: .vertical)
        slideContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 340).isActive = true
        rootStack.addArrangedSubview(slideContainer)

        let footer = makeFooterView()
        rootStack.addArrangedSubview(footer)

        NSLayoutConstraint.activate(pinEdges(effectView, to: contentView))
        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: effectView.topAnchor, constant: 26),
            rootStack.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 28),
            rootStack.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -28),
            rootStack.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -26),
        ])
    }

    private func makeHeaderView() -> NSView {
        let appIconBubble = NSView()
        appIconBubble.translatesAutoresizingMaskIntoConstraints = false
        appIconBubble.wantsLayer = true
        appIconBubble.layer?.cornerRadius = 12
        appIconBubble.layer?.cornerCurve = .continuous
        appIconBubble.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.22).cgColor

        let appIconView = NSImageView()
        appIconView.translatesAutoresizingMaskIntoConstraints = false
        appIconView.image = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "BrainCache")
        appIconView.imageScaling = .scaleProportionallyDown
        appIconView.contentTintColor = .systemBlue
        appIconBubble.addSubview(appIconView)

        NSLayoutConstraint.activate([
            appIconBubble.widthAnchor.constraint(equalToConstant: 42),
            appIconBubble.heightAnchor.constraint(equalToConstant: 42),
            appIconView.centerXAnchor.constraint(equalTo: appIconBubble.centerXAnchor),
            appIconView.centerYAnchor.constraint(equalTo: appIconBubble.centerYAnchor),
            appIconView.widthAnchor.constraint(equalToConstant: 20),
            appIconView.heightAnchor.constraint(equalToConstant: 20),
        ])

        appNameLabel.font = .systemFont(ofSize: 18, weight: .semibold)

        let brandStack = NSStackView(views: [appIconBubble, appNameLabel])
        brandStack.orientation = .horizontal
        brandStack.alignment = .centerY
        brandStack.spacing = 12

        stepLabel.font = .systemFont(ofSize: 12, weight: .medium)
        stepLabel.textColor = .secondaryLabelColor
        stepLabel.alignment = .right

        progressStack.orientation = .horizontal
        progressStack.alignment = .centerY
        progressStack.spacing = 8

        for _ in Step.allCases {
            let segment = NSView()
            segment.translatesAutoresizingMaskIntoConstraints = false
            segment.wantsLayer = true
            segment.layer?.cornerRadius = 3
            segment.layer?.cornerCurve = .continuous
            NSLayoutConstraint.activate([
                segment.widthAnchor.constraint(equalToConstant: 34),
                segment.heightAnchor.constraint(equalToConstant: 6),
            ])
            progressSegments.append(segment)
            progressStack.addArrangedSubview(segment)
        }

        let progressColumn = NSStackView(views: [stepLabel, progressStack])
        progressColumn.orientation = .vertical
        progressColumn.alignment = .trailing
        progressColumn.spacing = 8

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [brandStack, spacer, progressColumn])
        header.orientation = .horizontal
        header.alignment = .centerY
        return header
    }

    private func makeFooterView() -> NSView {
        secondaryButton.target = self
        secondaryButton.action = #selector(handleSecondaryAction)
        secondaryButton.bezelStyle = .inline
        secondaryButton.font = .systemFont(ofSize: 13, weight: .medium)

        primaryButton.target = self
        primaryButton.action = #selector(handlePrimaryAction)
        primaryButton.bezelStyle = .rounded
        primaryButton.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let footer = NSStackView(views: [secondaryButton, spacer, primaryButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        return footer
    }

    private func renderCurrentStep() {
        permissionCards.removeAll()
        slideContainer.subviews.forEach { $0.removeFromSuperview() }

        let slide = makeSlide(
            title: currentStep.title,
            subtitle: currentStep.subtitle,
            body: makeBody(for: currentStep)
        )
        slide.translatesAutoresizingMaskIntoConstraints = false
        slideContainer.addSubview(slide)
        NSLayoutConstraint.activate(pinEdges(slide, to: slideContainer))

        updateProgress()
        updateButtons()
        refreshPermissionCardsIfNeeded()

        if currentStep == .permissions {
            startPermissionPolling()
        } else {
            stopPermissionPolling()
        }
    }

    private func makeSlide(title: String, subtitle: String, body: NSView) -> NSView {
        let titleLabel = NSTextField(wrappingLabelWithString: title)
        titleLabel.font = .systemFont(ofSize: 30, weight: .bold)
        titleLabel.maximumNumberOfLines = 0

        let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 14)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.maximumNumberOfLines = 0

        let stack = NSStackView(views: [titleLabel, subtitleLabel, body])
        stack.orientation = .vertical
        stack.spacing = 14
        stack.setCustomSpacing(20, after: subtitleLabel)
        return stack
    }

    private func makeBody(for step: Step) -> NSView {
        switch step {
        case .overview:
            return makeOverviewBody()
        case .liveAI:
            return makeLiveAIBody()
        case .permissions:
            return makePermissionsBody()
        case .hotkey:
            return makeHotkeyBody()
        case .ai:
            return makeAIBody()
        case .transcription:
            return makeTranscriptionBody()
        case .writingAssistant:
            return makeWritingAssistantBody()
        case .activityCapture:
            return makeActivityCaptureBody()
        }
    }

    private func makeOverviewBody() -> NSView {
        let summaryCard = makeScreenshotShowcaseCard()

        let features = NSStackView(views: [
            makeFeatureCard(
                symbol: "tray.full.fill",
                tint: .systemTeal,
                title: "Save the flow",
                body: "Your recent clipboard history stays available instead of being replaced by the next copy."
            ),
            makeFeatureCard(
                symbol: "magnifyingglass",
                tint: .systemOrange,
                title: "Search in seconds",
                body: "Bring up the panel, type a few words, and jump straight back to the thing you copied earlier."
            ),
            makeFeatureCard(
                symbol: "archivebox.fill",
                tint: .systemPurple,
                title: "Memory backup",
                body: "Treat copy/paste like a lightweight external memory for ideas, references, and fragments of work."
            ),
        ])
        features.orientation = .horizontal
        features.spacing = 14
        features.distribution = .fillEqually

        let noteLabel = NSTextField(
            wrappingLabelWithString: "Everything on this screen is built around one idea: useful things you copied should still be recoverable later."
        )
        noteLabel.font = .systemFont(ofSize: 12)
        noteLabel.textColor = .secondaryLabelColor

        let body = NSStackView(views: [summaryCard, features, noteLabel])
        body.orientation = .vertical
        body.spacing = 14
        return body
    }

    private func makeLiveAIBody() -> NSView {
        let chatMock = makeLiveChatMockup()

        let chatShortcut = KeyRecorderView.humanReadable(
            keyCode: Settings.shared.chatHotkeyKeyCode,
            modifiers: Settings.shared.chatHotkeyModifiers
        )

        let cards = NSStackView(views: [
            makeFeatureCard(
                symbol: "person.crop.rectangle.stack.fill",
                tint: .systemBlue,
                title: "Interview assistance",
                body: "Technical clarifications, definitions, edge-case follow-ups. Paste the question, get the answer before the silence gets weird."
            ),
            makeFeatureCard(
                symbol: "phone.bubble.fill",
                tint: .systemPink,
                title: "Sales & customer calls",
                body: "Pricing, specs, past objection-handling — without switching tabs. Stay on the call, get the context."
            ),
            makeFeatureCard(
                symbol: "stethoscope",
                tint: .systemOrange,
                title: "Doctor & expert visits",
                body: "Medication questions, second opinions, terminology you didn't catch — silently, without breaking eye contact."
            ),
        ])
        cards.orientation = .horizontal
        cards.spacing = 14
        cards.distribution = .fillEqually

        let noteLabel = NSTextField(
            wrappingLabelWithString: "Press \(chatShortcut) during any call to open the chat panel. BrainCache pulls relevant context from your clipboard history when AI is enabled."
        )
        noteLabel.font = .systemFont(ofSize: 12)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.maximumNumberOfLines = 0

        let body = NSStackView(views: [chatMock, cards, noteLabel])
        body.orientation = .vertical
        body.spacing = 14
        return body
    }

    private func makeWritingAssistantBody() -> NSView {
        let panelMock = makeWritingPanelMockup()

        let cards = NSStackView(views: [
            makeFeatureCard(
                symbol: "pencil.and.outline",
                tint: .systemPurple,
                title: "Rewrite in place",
                body: "Press \u{2318}\u{21A9} to replace what's in the field. \u{2318}Z restores your original draft in one step."
            ),
            makeFeatureCard(
                symbol: "globe.americas.fill",
                tint: .systemTeal,
                title: "Translate or restyle",
                body: "Tell it \u{201C}translate to Spanish\u{201D}, \u{201C}more formal\u{201D}, or \u{201C}just give me the shell command\u{201D} — any instruction works."
            ),
            makeFeatureCard(
                symbol: "slider.horizontal.3",
                tint: .systemOrange,
                title: "Customize the prompt",
                body: "Tune the rewrite system prompt and pick the chat model in Preferences \u{2192} Writing."
            ),
        ])
        cards.orientation = .horizontal
        cards.spacing = 14
        cards.distribution = .fillEqually

        let noteLabel = NSTextField(
            wrappingLabelWithString: "Double-tap the right \u{2318} key, or use \u{2325}\u{21E7}Space, to open the rewrite panel. Highlight a slice first to rewrite just that part; secure text fields are never read."
        )
        noteLabel.font = .systemFont(ofSize: 12)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.maximumNumberOfLines = 0

        let body = NSStackView(views: [panelMock, cards, noteLabel])
        body.orientation = .vertical
        body.spacing = 14
        return body
    }

    private func makePermissionsBody() -> NSView {
        let accessibilityCard = PermissionStatusCardView(
            symbol: "figure.wave",
            tint: .systemBlue,
            title: "Accessibility",
            body: OnboardingWindowController.accessibilityCardBody,
            buttonTitle: "Grant Accessibility…",
            statusProvider: { AccessibilityChecker.isGranted },
            actionHandler: {
                if AccessibilityChecker.isGranted { return }
                _ = AccessibilityChecker.requestAccess()
            }
        )

        let microphoneCard = PermissionStatusCardView(
            symbol: "mic.fill",
            tint: .systemGreen,
            title: "Microphone",
            body: OnboardingWindowController.microphoneCardBody,
            buttonTitle: "Grant Microphone…",
            statusProvider: { AccessibilityChecker.isMicrophoneGranted },
            actionHandler: {
                AccessibilityChecker.requestMicrophoneAccess { _ in }
            }
        )

        let screenRecordingCard = PermissionStatusCardView(
            symbol: "display",
            tint: .systemPurple,
            title: "Screen Recording (optional)",
            body: OnboardingWindowController.screenRecordingCardBody,
            buttonTitle: "Grant Screen Recording…",
            statusProvider: { AccessibilityChecker.isScreenRecordingGranted },
            actionHandler: {
                if AccessibilityChecker.isScreenRecordingGranted { return }
                _ = AccessibilityChecker.openScreenRecordingSettings()
            }
        )

        permissionCards = [accessibilityCard, microphoneCard, screenRecordingCard]

        let cards = NSStackView(views: permissionCards.map { $0 as NSView })
        cards.orientation = .horizontal
        cards.spacing = 14
        cards.distribution = .fillEqually

        let noteLabel = NSTextField(
            wrappingLabelWithString: OnboardingWindowController.permissionsFooterNote
        )
        noteLabel.font = .systemFont(ofSize: 12)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.maximumNumberOfLines = 0

        let body = NSStackView(views: [cards, noteLabel])
        body.orientation = .vertical
        body.spacing = 14
        return body
    }

    private func makeHotkeyBody() -> NSView {
        let clipboardPill = makeShortcutPill(
            text: KeyRecorderView.humanReadable(
                keyCode: Settings.shared.hotkeyKeyCode,
                modifiers: Settings.shared.hotkeyModifiers
            ),
            eyebrow: "CLIPBOARD HISTORY",
            body: "Open BrainCache and search anything you've copied."
        )
        let voicePill = makeShortcutPill(
            text: KeyRecorderView.humanReadable(
                keyCode: Settings.shared.voiceHotkeyKeyCode,
                modifiers: Settings.shared.voiceHotkeyModifiers
            ),
            eyebrow: "VOICE TRANSCRIPTION",
            body: "Start recording from anywhere — speak, stop, paste."
        )

        let shortcutRow = NSStackView(views: [clipboardPill, voicePill])
        shortcutRow.translatesAutoresizingMaskIntoConstraints = false
        shortcutRow.orientation = .horizontal
        shortcutRow.spacing = 14
        shortcutRow.distribution = .fillEqually

        let steps = NSStackView(views: [
            makeFeatureCard(
                symbol: "keyboard",
                tint: .systemBlue,
                title: "Bring up BrainCache",
                body: "Press the shortcut from anywhere to open your clipboard history without breaking your flow."
            ),
            makeFeatureCard(
                symbol: "text.magnifyingglass",
                tint: .systemGreen,
                title: "Search what you copied",
                body: "Start typing right away to narrow the list to the exact snippet, link, or note you want back."
            ),
            makeFeatureCard(
                symbol: "arrowshape.turn.up.left.fill",
                tint: .systemOrange,
                title: "Press Return to paste",
                body: "Select an item and hit Return. BrainCache puts it back into the previous app for you."
            ),
        ])
        steps.orientation = .horizontal
        steps.spacing = 14
        steps.distribution = .fillEqually

        let noteLabel = NSTextField(
            wrappingLabelWithString: "Want a different shortcut later? Change it any time in Preferences > Hotkey."
        )
        noteLabel.font = .systemFont(ofSize: 12)
        noteLabel.textColor = .secondaryLabelColor

        let body = NSStackView(views: [shortcutRow, steps, noteLabel])
        body.orientation = .vertical
        body.spacing = 16
        return body
    }

    private func makeAIBody() -> NSView {
        let offlineCard = makeFeatureCard(
            symbol: "externaldrive.fill.badge.checkmark",
            tint: .systemBlue,
            title: "All offline. All free.",
            body: "Core clipboard capture and search stay on your Mac. No account. No subscription. No API traffic unless you add a key yourself.",
            footer: makeBulletList(items: [
                "Clipboard history stays local.",
                "Regular search works with no setup.",
                "You can use BrainCache forever for free.",
            ])
        )

        let aiButtons = NSStackView(views: [
            makeCardButton(title: "Open AI Preferences", action: #selector(openAIPreferences)),
            makeInlineButton(title: "Open API key guide", action: #selector(openOpenAIAPIKeyGuide)),
        ])
        aiButtons.orientation = .vertical
        aiButtons.alignment = .leading
        aiButtons.spacing = 8

        let aiFooter = NSStackView(views: [
            makeBulletList(items: [
                "Semantic search for fuzzier recall.",
                "Summaries when you find a cluster of clips.",
                "Image descriptions and indexing.",
            ]),
            aiButtons,
        ])
        aiFooter.orientation = .vertical
        aiFooter.alignment = .leading
        aiFooter.spacing = 10

        let aiCard = makeFeatureCard(
            symbol: "sparkles",
            tint: .systemPurple,
            title: "Bring your own AI key",
            body: "AI is optional. If you want it, adding your own key unlocks better search, summaries of found items, and indexing for images.",
            footer: aiFooter
        )

        let cards = NSStackView(views: [offlineCard, aiCard])
        cards.orientation = .horizontal
        cards.spacing = 14
        cards.distribution = .fillEqually

        let noteLabel = NSTextField(
            wrappingLabelWithString: "BrainCache never calls an AI provider unless you explicitly paste in an API key. The default provider is NVIDIA Nemotron on Nebius Token Factory; OpenAI stays selectable in Preferences → AI."
        )
        noteLabel.font = .systemFont(ofSize: 12)
        noteLabel.textColor = .secondaryLabelColor

        let body = NSStackView(views: [cards, noteLabel])
        body.orientation = .vertical
        body.spacing = 14
        return body
    }

    private func makeTranscriptionBody() -> NSView {
        let panelMock = makeVoicePanelMockup()

        let voiceShortcutText = KeyRecorderView.humanReadable(
            keyCode: Settings.shared.voiceHotkeyKeyCode,
            modifiers: Settings.shared.voiceHotkeyModifiers
        )

        let cards = NSStackView(views: [
            makeFeatureCard(
                symbol: "mic.fill",
                tint: .systemBlue,
                title: "One-shot dictation",
                body: "Press \(voiceShortcutText) from anywhere, speak, and the cleaned transcript lands in your clipboard — paste it like any other clip."
            ),
            makeFeatureCard(
                symbol: "person.2.wave.2.fill",
                tint: .systemGreen,
                title: "Capture meetings",
                body: "Flip System audio on to record both your mic and the call. Useful when you want a verbatim record of a remote meeting."
            ),
            makeFeatureCard(
                symbol: "doc.text.magnifyingglass",
                tint: .systemOrange,
                title: "Turn transcripts into notes",
                body: "Pipe a saved transcript into BrainCache chat to draft meeting notes, action items, or a summary in seconds."
            ),
        ])
        cards.orientation = .horizontal
        cards.spacing = 14
        cards.distribution = .fillEqually

        let noteLabel = NSTextField(
            wrappingLabelWithString: "System audio capture needs Screen Recording permission. Voice transcription uses your AI provider key — no key, no transcription."
        )
        noteLabel.font = .systemFont(ofSize: 12)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.maximumNumberOfLines = 0

        let body = NSStackView(views: [panelMock, cards, noteLabel])
        body.orientation = .vertical
        body.spacing = 14
        return body
    }

    private func makeActivityCaptureBody() -> NSView {
        let flowMock = makeActivityCaptureFlowMockup()

        let cards = NSStackView(views: [
            makeFeatureCard(
                symbol: "rectangle.dashed.and.paperclip",
                tint: .systemBlue,
                title: "What it captures",
                body: "Click context, app and window names, control roles, plus periodic frontmost-window screenshots. All stored as local files in a folder you pick."
            ),
            makeFeatureCard(
                symbol: "rectangle.connected.to.line.below",
                tint: .systemPurple,
                title: "Connect agents via MCP",
                body: "Through the BrainCache MCP server, an agent like Claude Code or Codex can read your captured workflow history when you ask it to."
            ),
            makeFeatureCard(
                symbol: "person.crop.rectangle.badge.plus",
                tint: .systemOrange,
                title: "Distill yourself",
                body: "Combine captured patterns with computer use so an agent can learn how you actually do the work — and run repeatable tasks the same way."
            ),
        ])
        cards.orientation = .horizontal
        cards.spacing = 14
        cards.distribution = .fillEqually

        let noteLabel = NSTextField(
            wrappingLabelWithString: "Off by default. You pick the folder, password managers and other sensitive apps are excluded, and you can pause or stop recording at any time from the menu bar."
        )
        noteLabel.font = .systemFont(ofSize: 12)
        noteLabel.textColor = .secondaryLabelColor
        noteLabel.maximumNumberOfLines = 0

        let body = NSStackView(views: [flowMock, cards, noteLabel])
        body.orientation = .vertical
        body.spacing = 14
        return body
    }

    private func makeVoicePanelMockup() -> NSView {
        let card = makeCardContainer()

        let frame = NSView()
        frame.translatesAutoresizingMaskIntoConstraints = false
        frame.wantsLayer = true
        frame.layer?.cornerRadius = 14
        frame.layer?.cornerCurve = .continuous
        frame.layer?.masksToBounds = true
        frame.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
        frame.layer?.borderWidth = 1
        frame.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor

        let transcript = MockTypingTextView(lines: [
            "Hi, how are you doing today?",
            "I wanted to share a quick update on the onboarding flow —",
            "the new transcription step is live and the timer is ticking.",
        ])
        transcript.translatesAutoresizingMaskIntoConstraints = false
        frame.addSubview(transcript)

        let waveform = MockLiveWaveformView()
        waveform.translatesAutoresizingMaskIntoConstraints = false
        frame.addSubview(waveform)

        let timer = MockTickingTimerLabel(startSeconds: 53)
        timer.font = .monospacedDigitSystemFont(ofSize: 13, weight: .semibold)
        timer.textColor = .white.withAlphaComponent(0.9)

        let timerRow = NSStackView(views: [
            makeMockGlyph(symbol: "rectangle.portrait.and.arrow.right", tint: .white.withAlphaComponent(0.7), size: 12),
            timer,
        ])
        timerRow.orientation = .horizontal
        timerRow.alignment = .centerY
        timerRow.spacing = 6
        timerRow.translatesAutoresizingMaskIntoConstraints = false
        frame.addSubview(timerRow)

        let micGlyph = makeMockGlyph(symbol: "mic.fill", tint: .white, size: 12)
        let defaultLabel = NSTextField(labelWithString: "Default")
        defaultLabel.font = .systemFont(ofSize: 11, weight: .medium)
        defaultLabel.textColor = .white.withAlphaComponent(0.85)
        let micChevron = makeMockGlyph(symbol: "chevron.up.chevron.down", tint: .white.withAlphaComponent(0.7), size: 9)
        let micCluster = NSStackView(views: [micGlyph, defaultLabel, micChevron])
        micCluster.orientation = .horizontal
        micCluster.alignment = .centerY
        micCluster.spacing = 4

        let sysLabel = NSTextField(labelWithString: "System audio")
        sysLabel.font = .systemFont(ofSize: 11, weight: .medium)
        sysLabel.textColor = .white.withAlphaComponent(0.7)

        let sysSwitch = makeMockSwitch(on: false)

        let globe = makeMockGlyph(symbol: "globe", tint: .white.withAlphaComponent(0.7), size: 11)
        let offLabel = NSTextField(labelWithString: "Off")
        offLabel.font = .systemFont(ofSize: 11, weight: .medium)
        offLabel.textColor = .white.withAlphaComponent(0.7)
        let offChevron = makeMockGlyph(symbol: "chevron.up.chevron.down", tint: .white.withAlphaComponent(0.5), size: 9)
        let translateCluster = NSStackView(views: [globe, offLabel, offChevron])
        translateCluster.orientation = .horizontal
        translateCluster.alignment = .centerY
        translateCluster.spacing = 4

        let stopButton = makeMockPillButton(title: "Stop", background: NSColor.systemRed, textColor: .white)

        let cancelLabel = NSTextField(labelWithString: "Cancel")
        cancelLabel.font = .systemFont(ofSize: 11)
        cancelLabel.textColor = .white.withAlphaComponent(0.85)
        let escTag = makeMockKeyTag(title: "esc")
        let cancelCluster = NSStackView(views: [cancelLabel, escTag])
        cancelCluster.orientation = .horizontal
        cancelCluster.alignment = .centerY
        cancelCluster.spacing = 6

        let spacerA = NSView()
        spacerA.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let spacerB = NSView()
        spacerB.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let bottomBar = NSStackView(views: [
            micCluster, sysLabel, sysSwitch, translateCluster, spacerA, stopButton, cancelCluster, spacerB,
        ])
        bottomBar.orientation = .horizontal
        bottomBar.alignment = .centerY
        bottomBar.spacing = 12
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        frame.addSubview(bottomBar)

        NSLayoutConstraint.activate([
            frame.heightAnchor.constraint(equalToConstant: 200),
            timerRow.topAnchor.constraint(equalTo: frame.topAnchor, constant: 12),
            timerRow.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -16),
            transcript.topAnchor.constraint(equalTo: frame.topAnchor, constant: 14),
            transcript.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: 18),
            transcript.trailingAnchor.constraint(equalTo: timerRow.leadingAnchor, constant: -12),
            transcript.heightAnchor.constraint(equalToConstant: 80),
            waveform.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: 16),
            waveform.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -16),
            waveform.heightAnchor.constraint(equalToConstant: 22),
            waveform.topAnchor.constraint(equalTo: transcript.bottomAnchor, constant: 8),
            bottomBar.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: 16),
            bottomBar.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -16),
            bottomBar.bottomAnchor.constraint(equalTo: frame.bottomAnchor, constant: -14),
        ])

        card.addSubview(frame)
        NSLayoutConstraint.activate([
            frame.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            frame.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            frame.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            frame.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])
        return card
    }

    private func makeActivityCaptureFlowMockup() -> NSView {
        let card = makeCardContainer()

        let youNode = makeFlowNode(symbol: "laptopcomputer", tint: .systemBlue, title: "You at work", subtitle: "Clicks, windows, screenshots")
        let bcNode = makeFlowNode(symbol: "square.stack.3d.up.fill", tint: .systemPurple, title: "BrainCache", subtitle: "Local log + MCP server")
        let agentNode = makeFlowNode(symbol: "sparkles.rectangle.stack.fill", tint: .systemOrange, title: "Claude / Codex", subtitle: "Reads, learns, replays")

        let arrow1 = makeFlowArrow()
        let arrow2 = makeFlowArrow()

        let flow = NSStackView(views: [youNode, arrow1, bcNode, arrow2, agentNode])
        flow.translatesAutoresizingMaskIntoConstraints = false
        flow.orientation = .horizontal
        flow.alignment = .centerY
        flow.spacing = 10
        flow.distribution = .fill

        card.addSubview(flow)
        NSLayoutConstraint.activate([
            flow.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            flow.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            flow.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            flow.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
        ])
        return card
    }

    private func makeLiveChatMockup() -> NSView {
        let card = makeCardContainer()

        let frame = NSView()
        frame.translatesAutoresizingMaskIntoConstraints = false
        frame.wantsLayer = true
        frame.layer?.cornerRadius = 14
        frame.layer?.cornerCurve = .continuous
        frame.layer?.masksToBounds = true
        frame.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        frame.layer?.borderWidth = 1
        frame.layer?.borderColor = NSColor.systemPurple.withAlphaComponent(0.35).cgColor

        let chatTitle = NSTextField(labelWithString: "BrainCache · Chat")
        chatTitle.font = .systemFont(ofSize: 11, weight: .medium)
        chatTitle.textColor = .white.withAlphaComponent(0.6)

        let chatKbd = makeMockKeyTag(title: "\u{2318}\u{21E7}C")

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let header = NSStackView(views: [chatTitle, spacer, chatKbd])
        header.translatesAutoresizingMaskIntoConstraints = false
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        frame.addSubview(header)

        let userBubble = makeChatBubble(
            text: "What's the time complexity of merge sort, and why?",
            isUser: true
        )
        let thinkingPill = makeChatThinkingPill(text: "Searching your notes…")
        let asstBubble = makeChatBubble(
            text: "O(n log n) in time, worst and average. Space is O(n) for the merge buffer. Stable, not in-place.",
            isUser: false
        )

        let bubbleStack = NSStackView(views: [userBubble, thinkingPill, asstBubble])
        bubbleStack.translatesAutoresizingMaskIntoConstraints = false
        bubbleStack.orientation = .vertical
        bubbleStack.alignment = .leading
        bubbleStack.spacing = 8
        frame.addSubview(bubbleStack)

        NSLayoutConstraint.activate([
            frame.heightAnchor.constraint(equalToConstant: 180),
            header.topAnchor.constraint(equalTo: frame.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: 14),
            header.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -14),
            bubbleStack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            bubbleStack.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: 14),
            bubbleStack.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -14),
            bubbleStack.bottomAnchor.constraint(lessThanOrEqualTo: frame.bottomAnchor, constant: -12),
        ])

        card.addSubview(frame)
        NSLayoutConstraint.activate([
            frame.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            frame.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            frame.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            frame.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])
        return card
    }

    private func makeChatBubble(text: String, isUser: Bool) -> NSView {
        let bubble = NSView()
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 12
        bubble.layer?.cornerCurve = .continuous
        if isUser {
            bubble.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.85).cgColor
        } else {
            bubble.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.07).cgColor
            bubble.layer?.borderWidth = 1
            bubble.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        }

        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12)
        label.textColor = isUser ? .white : .white.withAlphaComponent(0.92)
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 7),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: 11),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -11),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -7),
            bubble.widthAnchor.constraint(lessThanOrEqualToConstant: 540),
        ])

        if isUser {
            let wrapper = NSView()
            wrapper.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(bubble)
            NSLayoutConstraint.activate([
                bubble.topAnchor.constraint(equalTo: wrapper.topAnchor),
                bubble.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
                bubble.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor),
                bubble.leadingAnchor.constraint(greaterThanOrEqualTo: wrapper.leadingAnchor, constant: 60),
            ])
            return wrapper
        }
        return bubble
    }

    private func makeChatThinkingPill(text: String) -> NSView {
        let pill = NSView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 10
        pill.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.05).cgColor
        pill.layer?.borderWidth = 1
        pill.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor

        let progress = NSProgressIndicator()
        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.style = .spinning
        progress.controlSize = .small
        progress.isIndeterminate = true
        progress.startAnimation(nil)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .white.withAlphaComponent(0.7)
        label.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [progress, label])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        pill.addSubview(stack)

        NSLayoutConstraint.activate([
            progress.widthAnchor.constraint(equalToConstant: 12),
            progress.heightAnchor.constraint(equalToConstant: 12),
            stack.topAnchor.constraint(equalTo: pill.topAnchor, constant: 5),
            stack.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -5),
        ])
        return pill
    }

    private func makeWritingPanelMockup() -> NSView {
        let card = makeCardContainer()

        let frame = NSView()
        frame.translatesAutoresizingMaskIntoConstraints = false
        frame.wantsLayer = true
        frame.layer?.cornerRadius = 14
        frame.layer?.cornerCurve = .continuous
        frame.layer?.masksToBounds = false
        frame.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.45).cgColor
        frame.layer?.borderWidth = 1
        frame.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.35).cgColor

        // Fake text field with the draft
        let textField = NSView()
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.wantsLayer = true
        textField.layer?.cornerRadius = 8
        textField.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        textField.layer?.borderWidth = 1
        textField.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor

        let draftLabel = NSTextField(wrappingLabelWithString: "hey can u send the q1 report tmrw morning, also pls update the design doc would appreciate it, thx")
        draftLabel.font = .systemFont(ofSize: 12)
        draftLabel.textColor = .white.withAlphaComponent(0.75)
        draftLabel.maximumNumberOfLines = 0
        draftLabel.translatesAutoresizingMaskIntoConstraints = false
        textField.addSubview(draftLabel)
        NSLayoutConstraint.activate([
            draftLabel.topAnchor.constraint(equalTo: textField.topAnchor, constant: 8),
            draftLabel.leadingAnchor.constraint(equalTo: textField.leadingAnchor, constant: 10),
            draftLabel.trailingAnchor.constraint(equalTo: textField.trailingAnchor, constant: -10),
            draftLabel.bottomAnchor.constraint(equalTo: textField.bottomAnchor, constant: -8),
        ])

        // The writing panel popover
        let panel = NSView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.wantsLayer = true
        panel.layer?.cornerRadius = 10
        panel.layer?.cornerCurve = .continuous
        panel.layer?.backgroundColor = NSColor(white: 0.10, alpha: 0.96).cgColor
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = NSColor.systemOrange.withAlphaComponent(0.5).cgColor
        panel.shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.6)
            s.shadowBlurRadius = 16
            s.shadowOffset = NSSize(width: 0, height: -4)
            return s
        }()

        let panelHeader = NSTextField(labelWithString: "BRAINCACHE WRITING")
        panelHeader.font = .systemFont(ofSize: 9.5, weight: .semibold)
        panelHeader.textColor = .white.withAlphaComponent(0.5)

        let promptLabel = NSTextField(labelWithString: "make it more concise and professional")
        promptLabel.font = .systemFont(ofSize: 12)
        promptLabel.textColor = .white
        promptLabel.maximumNumberOfLines = 0
        promptLabel.lineBreakMode = .byWordWrapping

        let suggestedHeader = NSTextField(labelWithString: "SUGGESTED")
        suggestedHeader.font = .systemFont(ofSize: 9, weight: .semibold)
        suggestedHeader.textColor = NSColor.systemPurple.withAlphaComponent(0.85)

        let resultLabel = NSTextField(wrappingLabelWithString: "Hi — could you send the Q1 report tomorrow morning? Also, please update the design doc when you get a chance. Thanks!")
        resultLabel.font = .systemFont(ofSize: 11.5)
        resultLabel.textColor = .white
        resultLabel.maximumNumberOfLines = 0

        let resultCard = NSView()
        resultCard.translatesAutoresizingMaskIntoConstraints = false
        resultCard.wantsLayer = true
        resultCard.layer?.cornerRadius = 7
        resultCard.layer?.backgroundColor = NSColor.systemPurple.withAlphaComponent(0.12).cgColor
        resultCard.layer?.borderWidth = 1
        resultCard.layer?.borderColor = NSColor.systemPurple.withAlphaComponent(0.25).cgColor
        resultLabel.translatesAutoresizingMaskIntoConstraints = false
        resultCard.addSubview(resultLabel)
        NSLayoutConstraint.activate([
            resultLabel.topAnchor.constraint(equalTo: resultCard.topAnchor, constant: 7),
            resultLabel.leadingAnchor.constraint(equalTo: resultCard.leadingAnchor, constant: 9),
            resultLabel.trailingAnchor.constraint(equalTo: resultCard.trailingAnchor, constant: -9),
            resultLabel.bottomAnchor.constraint(equalTo: resultCard.bottomAnchor, constant: -7),
        ])

        let replaceBtn = makeWritingActionPill(title: "Replace", kbd: "\u{2318}\u{21A9}", isPrimary: true)
        let appendBtn  = makeWritingActionPill(title: "Append",  kbd: "\u{2318}\u{2193}", isPrimary: false)
        let copyBtn    = makeWritingActionPill(title: "Copy",    kbd: "\u{2318}C",         isPrimary: false)

        let actionRow = NSStackView(views: [replaceBtn, appendBtn, copyBtn])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = 6

        let panelStack = NSStackView(views: [panelHeader, promptLabel, suggestedHeader, resultCard, actionRow])
        panelStack.translatesAutoresizingMaskIntoConstraints = false
        panelStack.orientation = .vertical
        panelStack.alignment = .leading
        panelStack.spacing = 6
        panelStack.setCustomSpacing(8, after: promptLabel)
        panel.addSubview(panelStack)

        NSLayoutConstraint.activate([
            panelStack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 12),
            panelStack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            panelStack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            panelStack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -10),
        ])

        frame.addSubview(textField)
        frame.addSubview(panel)

        NSLayoutConstraint.activate([
            frame.heightAnchor.constraint(equalToConstant: 240),
            textField.topAnchor.constraint(equalTo: frame.topAnchor, constant: 12),
            textField.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: 16),
            textField.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -16),
            textField.heightAnchor.constraint(greaterThanOrEqualToConstant: 56),
            panel.topAnchor.constraint(equalTo: textField.bottomAnchor, constant: 8),
            panel.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: 28),
            panel.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -28),
            panel.bottomAnchor.constraint(lessThanOrEqualTo: frame.bottomAnchor, constant: -10),
        ])

        card.addSubview(frame)
        NSLayoutConstraint.activate([
            frame.topAnchor.constraint(equalTo: card.topAnchor, constant: 16),
            frame.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 16),
            frame.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -16),
            frame.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -16),
        ])
        return card
    }

    private func makeWritingActionPill(title: String, kbd: String, isPrimary: Bool) -> NSView {
        let pill = NSView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 6
        if isPrimary {
            pill.layer?.backgroundColor = NSColor.systemBlue.withAlphaComponent(0.9).cgColor
            pill.layer?.borderWidth = 1
            pill.layer?.borderColor = NSColor.systemPurple.withAlphaComponent(0.5).cgColor
        } else {
            pill.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
            pill.layer?.borderWidth = 1
            pill.layer?.borderColor = NSColor.white.withAlphaComponent(0.10).cgColor
        }

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = isPrimary ? .white : .white.withAlphaComponent(0.85)

        let kbdTag = NSTextField(labelWithString: kbd)
        kbdTag.font = .monospacedSystemFont(ofSize: 9.5, weight: .bold)
        kbdTag.textColor = isPrimary ? .white.withAlphaComponent(0.9) : .white.withAlphaComponent(0.6)

        let stack = NSStackView(views: [label, kbdTag])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        pill.addSubview(stack)

        NSLayoutConstraint.activate([
            pill.heightAnchor.constraint(equalToConstant: 22),
            stack.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -10),
        ])
        return pill
    }

    private func makeFlowNode(symbol: String, tint: NSColor, title: String, subtitle: String) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.cornerCurve = .continuous
        container.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.04).cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor

        let bubble = NSView()
        bubble.translatesAutoresizingMaskIntoConstraints = false
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 10
        bubble.layer?.cornerCurve = .continuous
        bubble.layer?.backgroundColor = tint.withAlphaComponent(0.22).cgColor

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        icon.imageScaling = .scaleProportionallyDown
        icon.contentTintColor = tint
        bubble.addSubview(icon)

        NSLayoutConstraint.activate([
            bubble.widthAnchor.constraint(equalToConstant: 38),
            bubble.heightAnchor.constraint(equalToConstant: 38),
            icon.centerXAnchor.constraint(equalTo: bubble.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: bubble.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            icon.heightAnchor.constraint(equalToConstant: 18),
        ])

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        titleLabel.alignment = .center

        let subtitleLabel = NSTextField(wrappingLabelWithString: subtitle)
        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.alignment = .center
        subtitleLabel.maximumNumberOfLines = 2

        let stack = NSStackView(views: [bubble, titleLabel, subtitleLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),
        ])
        return container
    }

    private func makeFlowArrow() -> NSView {
        let arrow = NSImageView()
        arrow.translatesAutoresizingMaskIntoConstraints = false
        arrow.image = NSImage(systemSymbolName: "arrow.right", accessibilityDescription: nil)
        arrow.imageScaling = .scaleProportionallyDown
        arrow.contentTintColor = NSColor.white.withAlphaComponent(0.45)
        NSLayoutConstraint.activate([
            arrow.widthAnchor.constraint(equalToConstant: 18),
            arrow.heightAnchor.constraint(equalToConstant: 18),
        ])
        return arrow
    }

    private func makeMockGlyph(symbol: String, tint: NSColor, size: CGFloat) -> NSView {
        let view = NSImageView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        view.imageScaling = .scaleProportionallyDown
        view.contentTintColor = tint
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: size + 2),
            view.heightAnchor.constraint(equalToConstant: size + 2),
        ])
        return view
    }

    private func makeMockSwitch(on: Bool) -> NSView {
        let track = NSView()
        track.translatesAutoresizingMaskIntoConstraints = false
        track.wantsLayer = true
        track.layer?.cornerRadius = 9
        track.layer?.backgroundColor = (on ? NSColor.systemGreen : NSColor.white.withAlphaComponent(0.18)).cgColor

        let knob = NSView()
        knob.translatesAutoresizingMaskIntoConstraints = false
        knob.wantsLayer = true
        knob.layer?.cornerRadius = 7
        knob.layer?.backgroundColor = NSColor.white.cgColor
        track.addSubview(knob)

        NSLayoutConstraint.activate([
            track.widthAnchor.constraint(equalToConstant: 30),
            track.heightAnchor.constraint(equalToConstant: 18),
            knob.widthAnchor.constraint(equalToConstant: 14),
            knob.heightAnchor.constraint(equalToConstant: 14),
            knob.centerYAnchor.constraint(equalTo: track.centerYAnchor),
            on
                ? knob.trailingAnchor.constraint(equalTo: track.trailingAnchor, constant: -2)
                : knob.leadingAnchor.constraint(equalTo: track.leadingAnchor, constant: 2),
        ])
        return track
    }

    private func makeMockPillButton(title: String, background: NSColor, textColor: NSColor) -> NSView {
        let pill = NSView()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 6
        pill.layer?.backgroundColor = background.cgColor

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.textColor = textColor
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            pill.heightAnchor.constraint(equalToConstant: 22),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -14),
        ])
        return pill
    }

    private func makeMockKeyTag(title: String) -> NSView {
        let tag = NSView()
        tag.translatesAutoresizingMaskIntoConstraints = false
        tag.wantsLayer = true
        tag.layer?.cornerRadius = 4
        tag.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
        tag.layer?.borderWidth = 1
        tag.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 10, weight: .medium)
        label.textColor = .white.withAlphaComponent(0.7)
        label.translatesAutoresizingMaskIntoConstraints = false
        tag.addSubview(label)
        NSLayoutConstraint.activate([
            tag.heightAnchor.constraint(equalToConstant: 18),
            label.centerYAnchor.constraint(equalTo: tag.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: tag.leadingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: tag.trailingAnchor, constant: -6),
        ])
        return tag
    }

    private func makeFeatureCard(
        symbol: String,
        tint: NSColor,
        title: String,
        body: String,
        footer: NSView? = nil
    ) -> NSView {
        let card = makeCardContainer()

        let iconBubble = NSView()
        iconBubble.translatesAutoresizingMaskIntoConstraints = false
        iconBubble.wantsLayer = true
        iconBubble.layer?.cornerRadius = 12
        iconBubble.layer?.cornerCurve = .continuous
        iconBubble.layer?.backgroundColor = tint.withAlphaComponent(0.2).cgColor

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = tint
        iconBubble.addSubview(iconView)

        NSLayoutConstraint.activate([
            iconBubble.widthAnchor.constraint(equalToConstant: 44),
            iconBubble.heightAnchor.constraint(equalToConstant: 44),
            iconView.centerXAnchor.constraint(equalTo: iconBubble.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconBubble.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
        ])

        let titleLabel = NSTextField(wrappingLabelWithString: title)
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.maximumNumberOfLines = 0

        let bodyLabel = NSTextField(wrappingLabelWithString: body)
        bodyLabel.font = .systemFont(ofSize: 13)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.maximumNumberOfLines = 0

        let stack = NSStackView(views: [iconBubble, titleLabel, bodyLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12

        if let footer {
            if let footerStack = footer as? NSStackView {
                footerStack.spacing = max(footerStack.spacing, 8)
            }
            stack.addArrangedSubview(footer)
        }

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
        ])
        return card
    }

    private func makeScreenshotShowcaseCard() -> NSView {
        let card = makeCardContainer()

        let imageContainer = NSView()
        imageContainer.translatesAutoresizingMaskIntoConstraints = false
        imageContainer.wantsLayer = true
        imageContainer.layer?.cornerRadius = 14
        imageContainer.layer?.cornerCurve = .continuous
        imageContainer.layer?.masksToBounds = true
        imageContainer.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
        imageContainer.layer?.borderWidth = 1
        imageContainer.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        imageContainer.setContentHuggingPriority(.required, for: .horizontal)
        imageContainer.setContentCompressionResistancePriority(.required, for: .horizontal)

        let imageView = NSImageView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.image = NSImage(named: Self.onboardingScreenshotAssetName)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageContainer.addSubview(imageView)

        NSLayoutConstraint.activate([
            imageContainer.widthAnchor.constraint(equalToConstant: 360),
            imageContainer.heightAnchor.constraint(equalToConstant: 225),
            imageView.topAnchor.constraint(equalTo: imageContainer.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor),
        ])

        let eyebrowLabel = NSTextField(labelWithString: "REAL APP PREVIEW")
        eyebrowLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        eyebrowLabel.textColor = .systemBlue

        let titleLabel = NSTextField(wrappingLabelWithString: "See BrainCache exactly where you'll use it.")
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.maximumNumberOfLines = 0

        let bodyLabel = NSTextField(
            wrappingLabelWithString: "The search panel floats above whatever app you're in, so recovering an earlier clip feels as fast as Spotlight instead of another workspace to manage."
        )
        bodyLabel.font = .systemFont(ofSize: 13)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.maximumNumberOfLines = 0

        let detailList = makeBulletList(items: [
            "Open it with your global shortcut from anywhere.",
            "Start typing immediately to filter your history.",
            "Press Return to paste the selected clip back.",
        ])

        let textStack = NSStackView(views: [eyebrowLabel, titleLabel, bodyLabel, detailList])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 10

        let contentStack = NSStackView(views: [imageContainer, textStack])
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .horizontal
        contentStack.alignment = .top
        contentStack.spacing = 18
        card.addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            contentStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            contentStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            contentStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
        ])

        return card
    }

    private func makeShortcutPill(
        text: String,
        eyebrow eyebrowText: String = "GLOBAL SHORTCUT",
        body bodyText: String = "This is the fastest way to reopen anything you copied a minute ago or last week."
    ) -> NSView {
        let card = makeCardContainer()

        let eyebrow = NSTextField(labelWithString: eyebrowText)
        eyebrow.font = .systemFont(ofSize: 11, weight: .semibold)
        eyebrow.textColor = .secondaryLabelColor

        let valueLabel = NSTextField(labelWithString: text)
        valueLabel.font = .monospacedSystemFont(ofSize: 28, weight: .bold)
        valueLabel.alignment = .center

        let bodyLabel = NSTextField(wrappingLabelWithString: bodyText)
        bodyLabel.font = .systemFont(ofSize: 12)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.alignment = .center
        bodyLabel.maximumNumberOfLines = 0

        let stack = NSStackView(views: [eyebrow, valueLabel, bodyLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
        ])

        return card
    }

    private func makeBulletList(items: [String]) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8

        for item in items {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .firstBaseline
            row.spacing = 8

            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Included")
            icon.imageScaling = .scaleProportionallyDown
            icon.contentTintColor = .systemGreen
            icon.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 14),
                icon.heightAnchor.constraint(equalToConstant: 14),
            ])

            let label = NSTextField(wrappingLabelWithString: item)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.maximumNumberOfLines = 0

            row.addArrangedSubview(icon)
            row.addArrangedSubview(label)
            stack.addArrangedSubview(row)
        }

        return stack
    }

    private func makeCardButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    private func makeInlineButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .inline
        button.font = .systemFont(ofSize: 12, weight: .medium)
        return button
    }

    private func makeCardContainer() -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.cornerRadius = 16
        card.layer?.cornerCurve = .continuous
        card.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        return card
    }

    // MARK: - Actions

    @objc private func handlePrimaryAction() {
        guard let nextStep = Step(rawValue: currentStep.rawValue + 1) else {
            completeOnboarding()
            return
        }
        currentStep = nextStep
        renderCurrentStep()
    }

    @objc private func handleSecondaryAction() {
        if currentStep == .overview {
            completeOnboarding()
            return
        }

        guard let previousStep = Step(rawValue: currentStep.rawValue - 1) else { return }
        currentStep = previousStep
        renderCurrentStep()
    }

    @objc private func openAIPreferences() {
        PreferencesWindowController.shared.show(selecting: .ai)
    }

    @objc private func openOpenAIAPIKeyGuide() {
        _ = NSWorkspace.shared.open(URL(string: Settings.shared.aiProvider.apiKeyURL) ?? Self.openAIAPIKeyGuideURL)
    }

    @objc private func handleAppDidBecomeActive() {
        guard Settings.shared.onboardingState != .completed else { return }
        refreshPermissionCardsIfNeeded()
        window?.makeKeyAndOrderFront(nil)
    }

    func completeOnboarding() {
        stopPermissionPolling()
        Settings.shared.onboardingState = .completed
        window?.close()
        _ = NSApp.setActivationPolicy(.accessory)
        completionHandler?()
        completionHandler = nil
    }

    // MARK: - State updates

    private func updateProgress() {
        stepLabel.stringValue = "Step \(currentStep.rawValue + 1) of \(Step.allCases.count)"

        for (index, segment) in progressSegments.enumerated() {
            let isActive = index == currentStep.rawValue
            let isCompleted = index < currentStep.rawValue
            segment.layer?.backgroundColor = {
                if isActive {
                    return NSColor.systemBlue.cgColor
                }
                if isCompleted {
                    return NSColor.systemBlue.withAlphaComponent(0.55).cgColor
                }
                return NSColor.white.withAlphaComponent(0.10).cgColor
            }()
        }
    }

    private func updateButtons() {
        secondaryButton.title = currentStep == .overview ? "Skip" : "Back"
        let isLastStep = currentStep.rawValue == Step.allCases.count - 1
        primaryButton.title = isLastStep ? "Start Using BrainCache" : "Continue"
    }

    private func refreshPermissionCardsIfNeeded() {
        guard currentStep == .permissions else { return }
        permissionCards.forEach { $0.refresh() }
    }

    private func startPermissionPolling() {
        stopPermissionPolling()
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + 1.5, repeating: 1.5)
        timer.setEventHandler { [weak self] in
            DispatchQueue.main.async { self?.refreshPermissionCardsIfNeeded() }
        }
        timer.resume()
        permissionRefreshTimer = timer
    }

    private func stopPermissionPolling() {
        permissionRefreshTimer?.cancel()
        permissionRefreshTimer = nil
    }

    // MARK: - Helpers

    private func standardWindowButtonsHidden(on window: NSWindow) {
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
    }

    private func pinEdges(_ child: NSView, to parent: NSView) -> [NSLayoutConstraint] {
        [
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor),
        ]
    }
}

private final class PermissionStatusCardView: NSView {

    private let statusProvider: () -> Bool
    private let actionHandler: () -> Void
    private let grantTitle: String

    private let statusIconView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let actionButton: NSButton

    init(
        symbol: String,
        tint: NSColor,
        title: String,
        body: String,
        buttonTitle: String,
        statusProvider: @escaping () -> Bool,
        actionHandler: @escaping () -> Void
    ) {
        self.statusProvider = statusProvider
        self.actionHandler = actionHandler
        self.grantTitle = buttonTitle
        self.actionButton = NSButton(title: buttonTitle, target: nil, action: nil)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 16
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = NSColor.white.withAlphaComponent(0.06).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor

        let iconBubble = NSView()
        iconBubble.translatesAutoresizingMaskIntoConstraints = false
        iconBubble.wantsLayer = true
        iconBubble.layer?.cornerRadius = 12
        iconBubble.layer?.cornerCurve = .continuous
        iconBubble.layer?.backgroundColor = tint.withAlphaComponent(0.2).cgColor

        let iconView = NSImageView()
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.contentTintColor = tint
        iconBubble.addSubview(iconView)

        NSLayoutConstraint.activate([
            iconBubble.widthAnchor.constraint(equalToConstant: 44),
            iconBubble.heightAnchor.constraint(equalToConstant: 44),
            iconView.centerXAnchor.constraint(equalTo: iconBubble.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconBubble.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
        ])

        let titleLabel = NSTextField(wrappingLabelWithString: title)
        titleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        titleLabel.maximumNumberOfLines = 0

        let bodyLabel = NSTextField(wrappingLabelWithString: body)
        bodyLabel.font = .systemFont(ofSize: 13)
        bodyLabel.textColor = .secondaryLabelColor
        bodyLabel.maximumNumberOfLines = 0

        statusIconView.imageScaling = .scaleProportionallyDown
        statusIconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            statusIconView.widthAnchor.constraint(equalToConstant: 14),
            statusIconView.heightAnchor.constraint(equalToConstant: 14),
        ])

        statusLabel.font = .systemFont(ofSize: 12, weight: .semibold)

        let statusRow = NSStackView(views: [statusIconView, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 6

        actionButton.target = self
        actionButton.action = #selector(handleAction)
        actionButton.bezelStyle = .rounded

        let stack = NSStackView(views: [iconBubble, titleLabel, bodyLabel, statusRow, actionButton])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
        ])

        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    @objc private func handleAction() {
        actionHandler()
    }

    func refresh() {
        let granted = statusProvider()
        statusIconView.image = NSImage(
            systemSymbolName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
            accessibilityDescription: granted ? "Granted" : "Needs action"
        )
        statusIconView.contentTintColor = granted ? .systemGreen : .systemOrange
        statusLabel.stringValue = granted ? "Granted" : "Needs action"
        statusLabel.textColor = granted ? .systemGreen : .systemOrange
        actionButton.title = granted ? "Granted ✓" : grantTitle
        actionButton.isEnabled = !granted
    }
}

// MARK: - Animated mock components

private final class MockLiveWaveformView: NSView {

    private let barCount = 60
    private let barSpacing: CGFloat = 3
    private var phase: CGFloat = 0
    private var displayTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    deinit { displayTimer?.invalidate() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startAnimating()
        } else {
            stopAnimating()
        }
    }

    private func startAnimating() {
        guard displayTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.phase += 0.18
            self.needsDisplay = true
        }
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
    }

    private func stopAnimating() {
        displayTimer?.invalidate()
        displayTimer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let bounds = self.bounds
        let totalSpacing = CGFloat(barCount - 1) * barSpacing
        let barWidth = max(1, (bounds.width - totalSpacing) / CGFloat(barCount))
        let centerY = bounds.midY
        let maxHeight = bounds.height

        context.setFillColor(NSColor.white.withAlphaComponent(0.55).cgColor)

        for i in 0..<barCount {
            let x = CGFloat(i) * (barWidth + barSpacing)
            let positionFactor = CGFloat(i) / CGFloat(barCount - 1)

            let primary = sin(phase + positionFactor * 6.0)
            let secondary = sin(phase * 0.7 + positionFactor * 11.0)
            let envelope = 0.6 + 0.4 * sin(phase * 0.3 + positionFactor * 2.0)
            let amplitude = (0.55 + 0.45 * primary * 0.5 + 0.25 * secondary * 0.5) * envelope
            let clamped = max(0.08, min(1.0, abs(amplitude)))

            let height = max(2, clamped * maxHeight)
            let rect = CGRect(x: x, y: centerY - height / 2, width: barWidth, height: height)
            context.fill(rect)
        }
    }
}

private final class MockTypingTextView: NSTextField {

    private let fullLines: [String]
    private var currentLineIndex = 0
    private var currentCharCount = 0
    private var typeTimer: Timer?
    private var caretBlinkTimer: Timer?
    private var caretVisible = true
    private let typingFont = NSFont.systemFont(ofSize: 13, weight: .regular)

    init(lines: [String]) {
        self.fullLines = lines
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBezeled = false
        isEditable = false
        isSelectable = false
        drawsBackground = false
        font = typingFont
        textColor = .white.withAlphaComponent(0.9)
        usesSingleLineMode = false
        cell?.wraps = true
        cell?.isScrollable = false
        maximumNumberOfLines = 0
        attributedStringValue = render()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    deinit {
        typeTimer?.invalidate()
        caretBlinkTimer?.invalidate()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startTyping()
        } else {
            stopTyping()
        }
    }

    private func startTyping() {
        guard typeTimer == nil else { return }
        let typing = Timer(timeInterval: 0.045, repeats: true) { [weak self] _ in
            self?.advanceCharacter()
        }
        RunLoop.main.add(typing, forMode: .common)
        typeTimer = typing

        let blink = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.caretVisible.toggle()
            self.attributedStringValue = self.render()
        }
        RunLoop.main.add(blink, forMode: .common)
        caretBlinkTimer = blink
    }

    private func stopTyping() {
        typeTimer?.invalidate()
        typeTimer = nil
        caretBlinkTimer?.invalidate()
        caretBlinkTimer = nil
    }

    private func advanceCharacter() {
        guard currentLineIndex < fullLines.count else {
            currentLineIndex = 0
            currentCharCount = 0
            attributedStringValue = render()
            return
        }
        let line = fullLines[currentLineIndex]
        if currentCharCount < line.count {
            currentCharCount += 1
        } else {
            currentLineIndex += 1
            currentCharCount = 0
            if currentLineIndex >= fullLines.count {
                Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in
                    guard let self else { return }
                    self.currentLineIndex = 0
                    self.currentCharCount = 0
                    self.attributedStringValue = self.render()
                }
                return
            }
        }
        attributedStringValue = render()
    }

    private func render() -> NSAttributedString {
        let result = NSMutableAttributedString()
        let baseAttrs: [NSAttributedString.Key: Any] = [
            .font: typingFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
        ]
        let dimAttrs: [NSAttributedString.Key: Any] = [
            .font: typingFont,
            .foregroundColor: NSColor.white.withAlphaComponent(0.55),
        ]

        for index in 0..<fullLines.count {
            if index > 0 { result.append(NSAttributedString(string: "\n")) }
            let line = fullLines[index]

            if index < currentLineIndex {
                result.append(NSAttributedString(string: line, attributes: dimAttrs))
            } else if index == currentLineIndex {
                let endOffset = min(currentCharCount, line.count)
                let typed = String(line.prefix(endOffset))
                result.append(NSAttributedString(string: typed, attributes: baseAttrs))
                let caret = caretVisible ? "▌" : " "
                result.append(NSAttributedString(string: caret, attributes: baseAttrs))
            }
        }
        return result
    }
}

private final class MockTickingTimerLabel: NSTextField {

    private var elapsed: Int
    private var tickTimer: Timer?

    init(startSeconds: Int) {
        self.elapsed = startSeconds
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBezeled = false
        isEditable = false
        isSelectable = false
        drawsBackground = false
        stringValue = MockTickingTimerLabel.format(elapsed)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not implemented") }

    deinit { tickTimer?.invalidate() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startTicking()
        } else {
            stopTicking()
        }
    }

    private func startTicking() {
        guard tickTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.elapsed += 1
            self.stringValue = MockTickingTimerLabel.format(self.elapsed)
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    private func stopTicking() {
        tickTimer?.invalidate()
        tickTimer = nil
    }

    private static func format(_ totalSeconds: Int) -> String {
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
