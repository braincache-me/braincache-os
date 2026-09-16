import Foundation

struct AICostHistoryEntry: Codable, Equatable {
    var chatCostUSD: Double
    var indexingCostUSD: Double
    var transcriptionCostUSD: Double

    var totalCostUSD: Double { chatCostUSD + indexingCostUSD + transcriptionCostUSD }

    static let zero = AICostHistoryEntry(chatCostUSD: 0, indexingCostUSD: 0, transcriptionCostUSD: 0)

    mutating func addCost(_ costUSD: Double, category: AIUsageCategory) {
        switch category {
        case .chat:
            chatCostUSD += costUSD
        case .indexing:
            indexingCostUSD += costUSD
        case .transcription:
            transcriptionCostUSD += costUSD
        }
    }

    init(chatCostUSD: Double, indexingCostUSD: Double, transcriptionCostUSD: Double = 0) {
        self.chatCostUSD = chatCostUSD
        self.indexingCostUSD = indexingCostUSD
        self.transcriptionCostUSD = transcriptionCostUSD
    }

    enum CodingKeys: String, CodingKey {
        case chatCostUSD, indexingCostUSD, transcriptionCostUSD
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chatCostUSD = try container.decode(Double.self, forKey: .chatCostUSD)
        indexingCostUSD = try container.decode(Double.self, forKey: .indexingCostUSD)
        transcriptionCostUSD = try container.decodeIfPresent(Double.self, forKey: .transcriptionCostUSD) ?? 0
    }
}

/// Format used when pasting a clip back into the target application.
/// `.plain` strips formatting (writes only `.string` to the pasteboard);
/// `.rich` preserves the original HTML / RTF payload.
enum PasteMode: String, CaseIterable {
    case plain
    case rich
}

/// What to do when a meeting is detected (mic activity from another app).
enum ActivityCaptureAudioMode: String, CaseIterable {
    /// Do nothing — log only the start/stop signal via mic monitor is ignored entirely.
    case off
    /// Record raw mic + system audio to an .m4a file under `recordings/`.
    case audio
    /// Stream mic + system audio to OpenAI Realtime and save the resulting
    /// transcript text under `transcripts/`.
    case transcript
}

/// Typed UserDefaults accessors for app-wide settings.
final class Settings {

    enum OnboardingState: Int {
        case unknown = 0
        case pending = 1
        case completed = 2

        static func resolvedForLaunch(current: OnboardingState, hasExistingData: Bool) -> OnboardingState {
            switch current {
            case .unknown:
                return hasExistingData ? .completed : .pending
            case .pending, .completed:
                return current
            }
        }
    }

    static let shared = Settings()
    private static var sharedSuiteName: String { BuildVariant.settingsSuiteName }
    private static let keychainServiceName = "com.clipvault.openai"
    private static let didMigrateSharedDefaultsKey = "didMigrateLegacyDefaultsToSharedSuite"

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private let defaults: UserDefaults
    private let secretStore: SecretStore

    init(defaults: UserDefaults = .standard) {
        if defaults === UserDefaults.standard && !Self.isRunningTests {
            let sharedDefaults = UserDefaults(suiteName: Self.sharedSuiteName) ?? .standard
            self.defaults = sharedDefaults
            self.secretStore = KeychainSecretStore(service: Self.keychainServiceName)
            Self.migrateLegacyDefaultsIfNeeded(from: .standard, to: sharedDefaults)
            migrateLegacyOpenAIAPIKeyIfNeeded(from: .standard)
        } else {
            self.defaults = defaults
            self.secretStore = UserDefaultsSecretStore(defaults: defaults)
        }
        seedCurrentCostHistoryIfNeeded()
    }

    // MARK: - Hotkey

    /// Carbon key code for the global hotkey. Default: 9 (V on US keyboard).
    var hotkeyKeyCode: Int {
        get {
            guard defaults.object(forKey: Keys.hotkeyKeyCode) != nil else {
                return Defaults.hotkeyKeyCode
            }
            return defaults.integer(forKey: Keys.hotkeyKeyCode)
        }
        set { defaults.set(newValue, forKey: Keys.hotkeyKeyCode) }
    }

    /// CGEventFlags raw value for the global hotkey modifiers.
    /// Default: command + shift.
    var hotkeyModifiers: UInt64 {
        get {
            if defaults.object(forKey: Keys.hotkeyModifiers) == nil {
                return Defaults.hotkeyModifiers
            }
            return UInt64(bitPattern: Int64(defaults.integer(forKey: Keys.hotkeyModifiers)))
        }
        set { defaults.set(Int(Int64(bitPattern: newValue)), forKey: Keys.hotkeyModifiers) }
    }

    // MARK: - History

    /// Maximum number of clips to keep. Default: 5000.
    var maxHistoryCount: Int {
        get {
            guard defaults.object(forKey: Keys.maxHistoryCount) != nil else {
                return Defaults.maxHistoryCount
            }
            return defaults.integer(forKey: Keys.maxHistoryCount)
        }
        set { defaults.set(newValue, forKey: Keys.maxHistoryCount) }
    }

    /// Auto-purge clips older than this many days. Default: 90.
    var autoPurgeAgeDays: Int {
        get {
            guard defaults.object(forKey: Keys.autoPurgeAgeDays) != nil else {
                return Defaults.autoPurgeAgeDays
            }
            return defaults.integer(forKey: Keys.autoPurgeAgeDays)
        }
        set { defaults.set(newValue, forKey: Keys.autoPurgeAgeDays) }
    }

    // MARK: - Paste Mode

    /// Default paste behavior for clips that carry rich formatting (HTML/RTF).
    /// The opposite mode can be invoked on demand by holding Shift when
    /// confirming the paste. Default: `.plain`.
    var defaultPasteMode: PasteMode {
        get {
            if let raw = defaults.string(forKey: Keys.defaultPasteMode),
               let mode = PasteMode(rawValue: raw) {
                return mode
            }
            return Defaults.defaultPasteMode
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.defaultPasteMode) }
    }

    // MARK: - Exclusions

    /// Bundle identifiers of apps whose clipboard activity is ignored.
    var excludedBundleIDs: [String] {
        get { defaults.stringArray(forKey: Keys.excludedBundleIDs) ?? [] }
        set { defaults.set(newValue, forKey: Keys.excludedBundleIDs) }
    }

    // MARK: - Launch at Login

    /// Defaults to `true` — the app registers itself as a login item on first
    /// launch (see `AppDelegate.registerLaunchAtLoginIfNeeded`). Turning the
    /// Preferences checkbox off writes an explicit `false`.
    var launchAtLogin: Bool {
        get { defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.launchAtLogin) }
    }

    /// `true` once launch-at-login has been explicitly set (by the first-launch
    /// registration or the user toggling the checkbox). Used to make the
    /// default-on registration a one-time action, so disabling the login item
    /// in System Settings is not overridden on the next launch.
    var isLaunchAtLoginConfigured: Bool {
        defaults.object(forKey: Keys.launchAtLogin) != nil
    }

    // MARK: - Onboarding

    var onboardingState: OnboardingState {
        get {
            OnboardingState(rawValue: defaults.integer(forKey: Keys.onboardingState)) ?? .unknown
        }
        set { defaults.set(newValue.rawValue, forKey: Keys.onboardingState) }
    }

    // MARK: - AI / OpenAI

    /// OpenAI API key used for classification, embedding, and chat features.
    var openAIAPIKey: String {
        get { secretStore.string(forKey: Keys.openAIAPIKey) ?? "" }
        set {
            if newValue.isEmpty {
                secretStore.removeValue(forKey: Keys.openAIAPIKey)
                defaults.removeObject(forKey: Keys.openAIAPIKey)
            } else {
                secretStore.set(newValue, forKey: Keys.openAIAPIKey)
            }
        }
    }

    /// Returns true when an OpenAI API key has been configured.
    var isAIEnabled: Bool { !openAIAPIKey.isEmpty }

    // MARK: - AI Skill Bridge

    /// Enables the read-only localhost bridge used by exported AI skills.
    var aiSkillBridgeEnabled: Bool {
        get { defaults.bool(forKey: Keys.aiSkillBridgeEnabled) }
        set { defaults.set(newValue, forKey: Keys.aiSkillBridgeEnabled) }
    }

    /// IPv4 loopback port for the read-only AI skill bridge.
    var aiSkillBridgePort: Int {
        get { defaults.integer(forKey: Keys.aiSkillBridgePort) }
        set { defaults.set(newValue, forKey: Keys.aiSkillBridgePort) }
    }

    /// Bearer token required by every AI skill bridge request.
    var aiSkillBridgeToken: String {
        get { secretStore.string(forKey: Keys.aiSkillBridgeToken) ?? "" }
        set {
            if newValue.isEmpty {
                secretStore.removeValue(forKey: Keys.aiSkillBridgeToken)
                defaults.removeObject(forKey: Keys.aiSkillBridgeToken)
            } else {
                secretStore.set(newValue, forKey: Keys.aiSkillBridgeToken)
                defaults.removeObject(forKey: Keys.aiSkillBridgeToken)
            }
        }
    }

    // MARK: - AI Model Selection

    var chatModel: String {
        get { defaults.string(forKey: Keys.chatModel) ?? Defaults.chatModel }
        set { defaults.set(newValue, forKey: Keys.chatModel) }
    }

    var classificationModel: String {
        get { defaults.string(forKey: Keys.classificationModel) ?? Defaults.classificationModel }
        set { defaults.set(newValue, forKey: Keys.classificationModel) }
    }

    var visionModel: String {
        get { defaults.string(forKey: Keys.visionModel) ?? Defaults.visionModel }
        set { defaults.set(newValue, forKey: Keys.visionModel) }
    }

    var embeddingModel: String {
        get { defaults.string(forKey: Keys.embeddingModel) ?? Defaults.embeddingModel }
        set { defaults.set(newValue, forKey: Keys.embeddingModel) }
    }

    var transcriptionModel: String {
        get { defaults.string(forKey: Keys.transcriptionModel) ?? Defaults.transcriptionModel }
        set { defaults.set(newValue, forKey: Keys.transcriptionModel) }
    }

    /// Chat model used to clean up a freshly-recorded transcript before
    /// pasting (Option+Shift+Space flow). Falls back to the chat model so
    /// users get a sensible default the first time they trigger it.
    var voiceRewriteModel: String {
        get { defaults.string(forKey: Keys.voiceRewriteModel) ?? Defaults.voiceRewriteModel }
        set { defaults.set(newValue, forKey: Keys.voiceRewriteModel) }
    }

    // MARK: - Realtime Translation

    /// When true, voice recording streams source audio to the realtime
    /// translation endpoint and the live transcript shows translated text in
    /// `translationTargetLanguage`. When false, normal transcription is used.
    var translationEnabled: Bool {
        get { defaults.bool(forKey: Keys.translationEnabled) }
        set { defaults.set(newValue, forKey: Keys.translationEnabled) }
    }

    /// ISO 639-1 code (e.g. "en", "es") of the language the translator should
    /// emit. Validated against `Defaults.translationLanguages`.
    var translationTargetLanguage: String {
        get { defaults.string(forKey: Keys.translationTargetLanguage) ?? Defaults.translationTargetLanguage }
        set { defaults.set(newValue, forKey: Keys.translationTargetLanguage) }
    }

    /// Realtime translation model. Defaults to OpenAI's gpt-realtime-translate.
    var translationModel: String {
        get { defaults.string(forKey: Keys.translationModel) ?? Defaults.translationModel }
        set { defaults.set(newValue, forKey: Keys.translationModel) }
    }

    var cachedModelList: [String] {
        get { defaults.stringArray(forKey: Keys.cachedModelList) ?? [] }
        set { defaults.set(newValue, forKey: Keys.cachedModelList) }
    }

    // MARK: - Voice media recordings

    /// Folder where the voice panel's "Save recording" files land. Empty
    /// string (default) resolves to `~/Movies/BrainCache Recordings`
    /// (`… (Dev)` for the dev build variant).
    var voiceRecordingsFolderPath: String {
        get { defaults.string(forKey: Keys.voiceRecordingsFolderPath) ?? "" }
        set { defaults.set(newValue, forKey: Keys.voiceRecordingsFolderPath) }
    }

    var voiceRecordingsFolderURL: URL {
        Self.voiceRecordingsFolderURL(configuredPath: voiceRecordingsFolderPath)
    }

    static func voiceRecordingsFolderURL(
        configuredPath: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        isProd: Bool = BuildVariant.isProd
    ) -> URL {
        let trimmed = configuredPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath, isDirectory: true)
        }
        let name = isProd ? "BrainCache Recordings" : "BrainCache Recordings (Dev)"
        return homeDirectory
            .appendingPathComponent("Movies", isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
    }

    // MARK: - Voice Realtime Robustness

    /// Maximum age of a single realtime WebSocket session before the client
    /// proactively rotates to a fresh one. OpenAI caps a realtime session at
    /// roughly 30 minutes server-side; rotating at 25 min keeps us comfortably
    /// inside that window. Set to 0 to disable proactive rotation entirely.
    /// Range 0 or 600…3000 s.
    var voiceSessionMaxAgeSeconds: Int {
        get {
            guard defaults.object(forKey: Keys.voiceSessionMaxAgeSeconds) != nil else {
                return Defaults.voiceSessionMaxAgeSeconds
            }
            let v = defaults.integer(forKey: Keys.voiceSessionMaxAgeSeconds)
            if v == 0 { return 0 }
            return max(600, min(3000, v))
        }
        set {
            if newValue == 0 {
                defaults.set(0, forKey: Keys.voiceSessionMaxAgeSeconds)
            } else {
                defaults.set(max(600, min(3000, newValue)), forKey: Keys.voiceSessionMaxAgeSeconds)
            }
        }
    }

    // MARK: - Voice Hotkey

    var voiceHotkeyKeyCode: Int {
        get {
            guard defaults.object(forKey: Keys.voiceHotkeyKeyCode) != nil else {
                return Defaults.voiceHotkeyKeyCode
            }
            return defaults.integer(forKey: Keys.voiceHotkeyKeyCode)
        }
        set { defaults.set(newValue, forKey: Keys.voiceHotkeyKeyCode) }
    }

    var voiceHotkeyModifiers: UInt64 {
        get {
            if defaults.object(forKey: Keys.voiceHotkeyModifiers) == nil {
                return Defaults.voiceHotkeyModifiers
            }
            return UInt64(bitPattern: Int64(defaults.integer(forKey: Keys.voiceHotkeyModifiers)))
        }
        set { defaults.set(Int(Int64(bitPattern: newValue)), forKey: Keys.voiceHotkeyModifiers) }
    }

    // MARK: - Voice Rewrite Hotkey (record → AI cleanup → paste)

    var voiceRewriteHotkeyKeyCode: Int {
        get {
            guard defaults.object(forKey: Keys.voiceRewriteHotkeyKeyCode) != nil else {
                return Defaults.voiceRewriteHotkeyKeyCode
            }
            return defaults.integer(forKey: Keys.voiceRewriteHotkeyKeyCode)
        }
        set { defaults.set(newValue, forKey: Keys.voiceRewriteHotkeyKeyCode) }
    }

    var voiceRewriteHotkeyModifiers: UInt64 {
        get {
            if defaults.object(forKey: Keys.voiceRewriteHotkeyModifiers) == nil {
                return Defaults.voiceRewriteHotkeyModifiers
            }
            return UInt64(bitPattern: Int64(defaults.integer(forKey: Keys.voiceRewriteHotkeyModifiers)))
        }
        set { defaults.set(Int(Int64(bitPattern: newValue)), forKey: Keys.voiceRewriteHotkeyModifiers) }
    }

    // MARK: - AI Rewrite Hotkey (focused-text rewrite, no voice)

    var aiRewriteHotkeyKeyCode: Int {
        get {
            guard defaults.object(forKey: Keys.aiRewriteHotkeyKeyCode) != nil else {
                return Defaults.aiRewriteHotkeyKeyCode
            }
            return defaults.integer(forKey: Keys.aiRewriteHotkeyKeyCode)
        }
        set { defaults.set(newValue, forKey: Keys.aiRewriteHotkeyKeyCode) }
    }

    var aiRewriteHotkeyModifiers: UInt64 {
        get {
            if defaults.object(forKey: Keys.aiRewriteHotkeyModifiers) == nil {
                return Defaults.aiRewriteHotkeyModifiers
            }
            return UInt64(bitPattern: Int64(defaults.integer(forKey: Keys.aiRewriteHotkeyModifiers)))
        }
        set { defaults.set(Int(Int64(bitPattern: newValue)), forKey: Keys.aiRewriteHotkeyModifiers) }
    }

    // MARK: - Chat Hotkey

    /// Carbon key code for the global chat hotkey. Default: 8 (C on US keyboard).
    var chatHotkeyKeyCode: Int {
        get {
            guard defaults.object(forKey: Keys.chatHotkeyKeyCode) != nil else {
                return Defaults.chatHotkeyKeyCode
            }
            return defaults.integer(forKey: Keys.chatHotkeyKeyCode)
        }
        set { defaults.set(newValue, forKey: Keys.chatHotkeyKeyCode) }
    }

    /// CGEventFlags raw value for the chat hotkey modifiers. Default: command + shift.
    var chatHotkeyModifiers: UInt64 {
        get {
            if defaults.object(forKey: Keys.chatHotkeyModifiers) == nil {
                return Defaults.chatHotkeyModifiers
            }
            return UInt64(bitPattern: Int64(defaults.integer(forKey: Keys.chatHotkeyModifiers)))
        }
        set { defaults.set(Int(Int64(bitPattern: newValue)), forKey: Keys.chatHotkeyModifiers) }
    }

    // MARK: - Chat Configuration

    /// Maximum number of prior conversation messages included in LLM context. Default: 20.
    var chatContextMessageLimit: Int {
        get {
            guard defaults.object(forKey: Keys.chatContextMessageLimit) != nil else {
                return Defaults.chatContextMessageLimit
            }
            return defaults.integer(forKey: Keys.chatContextMessageLimit)
        }
        set { defaults.set(newValue, forKey: Keys.chatContextMessageLimit) }
    }

    // MARK: - Agentic RAG Configuration

    /// Maximum number of tool-call iterations the agentic RAG loop may run. Default: 3. Range: 1–5.
    var agenticMaxIterations: Int {
        get {
            guard defaults.object(forKey: Keys.agenticMaxIterations) != nil else {
                return Defaults.agenticMaxIterations
            }
            return max(1, min(5, defaults.integer(forKey: Keys.agenticMaxIterations)))
        }
        set { defaults.set(max(1, min(5, newValue)), forKey: Keys.agenticMaxIterations) }
    }

    /// When true, uses the agentic multi-round tool-call pipeline; otherwise classic single-shot RAG. Default: true.
    var agenticSearchEnabled: Bool {
        get {
            guard defaults.object(forKey: Keys.agenticSearchEnabled) != nil else {
                return Defaults.agenticSearchEnabled
            }
            return defaults.bool(forKey: Keys.agenticSearchEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.agenticSearchEnabled) }
    }

    // MARK: - RAG Configuration

    /// Number of candidate clips retrieved for RAG context. Default: 20. Range: 5–50.
    var ragTopK: Int {
        get {
            guard defaults.object(forKey: Keys.ragTopK) != nil else {
                return Defaults.ragTopK
            }
            return max(5, min(50, defaults.integer(forKey: Keys.ragTopK)))
        }
        set { defaults.set(max(5, min(50, newValue)), forKey: Keys.ragTopK) }
    }

    /// Maximum characters included in the RAG context block. Default: 24000. Range: 4000–128000.
    var ragMaxContextChars: Int {
        get {
            guard defaults.object(forKey: Keys.ragMaxContextChars) != nil else {
                return Defaults.ragMaxContextChars
            }
            return max(4_000, min(128_000, defaults.integer(forKey: Keys.ragMaxContextChars)))
        }
        set { defaults.set(max(4_000, min(128_000, newValue)), forKey: Keys.ragMaxContextChars) }
    }

    /// Maximum output tokens in the LLM response. Default: 512. Range: 128–32000.
    var ragMaxOutputTokens: Int {
        get {
            guard defaults.object(forKey: Keys.ragMaxOutputTokens) != nil else {
                return Defaults.ragMaxOutputTokens
            }
            return max(128, min(32_000, defaults.integer(forKey: Keys.ragMaxOutputTokens)))
        }
        set { defaults.set(max(128, min(32_000, newValue)), forKey: Keys.ragMaxOutputTokens) }
    }

    /// Reasoning effort sent to reasoning-capable chat models (gpt-5.x and
    /// similar). Forwarded as `reasoning_effort` in the chat completions
    /// request body. Applies to both Ask AI and Chat. Allowed values:
    /// "low", "medium", "high", "xhigh". Default: "medium".
    var reasoningEffort: String {
        get {
            let raw = defaults.string(forKey: Keys.reasoningEffort) ?? Defaults.reasoningEffort
            return Self.validReasoningEfforts.contains(raw) ? raw : Defaults.reasoningEffort
        }
        set {
            let normalized = Self.validReasoningEfforts.contains(newValue)
                ? newValue
                : Defaults.reasoningEffort
            defaults.set(normalized, forKey: Keys.reasoningEffort)
        }
    }

    static let validReasoningEfforts: [String] = ["low", "medium", "high", "xhigh"]

    /// System prompt sent to the model on every Ask AI request.
    /// Editable from Preferences → AI so users can tune behaviour
    /// (tone, output length, persona, refusal behaviour, etc.) without
    /// changing code.
    var aiAssistSystemPrompt: String {
        get { defaults.string(forKey: Keys.aiAssistSystemPrompt) ?? Defaults.aiAssistSystemPrompt }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                defaults.removeObject(forKey: Keys.aiAssistSystemPrompt)
            } else {
                defaults.set(newValue, forKey: Keys.aiAssistSystemPrompt)
            }
        }
    }

    // MARK: - Ask AI Tools

    /// When true, Ask AI requests include OpenAI's built-in `web_search` tool
    /// so the model can fetch latest information / do quick research. Default: false.
    var askAIWebSearchEnabled: Bool {
        get {
            guard defaults.object(forKey: Keys.askAIWebSearchEnabled) != nil else {
                return Defaults.askAIWebSearchEnabled
            }
            return defaults.bool(forKey: Keys.askAIWebSearchEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.askAIWebSearchEnabled) }
    }

    /// When true, Ask AI registers the `search_claude_code_history` tool that
    /// greps the local Claude Code CLI session logs (~/.claude). Default: false.
    var claudeCodeHistoryToolEnabled: Bool {
        get {
            guard defaults.object(forKey: Keys.claudeCodeHistoryToolEnabled) != nil else {
                return Defaults.claudeCodeHistoryToolEnabled
            }
            return defaults.bool(forKey: Keys.claudeCodeHistoryToolEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.claudeCodeHistoryToolEnabled) }
    }

    /// When true, Ask AI registers the `search_codex_history` tool that greps
    /// the local Codex CLI session logs (~/.codex). Default: false.
    var codexHistoryToolEnabled: Bool {
        get {
            guard defaults.object(forKey: Keys.codexHistoryToolEnabled) != nil else {
                return Defaults.codexHistoryToolEnabled
            }
            return defaults.bool(forKey: Keys.codexHistoryToolEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.codexHistoryToolEnabled) }
    }

    /// When true, finished mic / system-audio transcriptions of at least
    /// `Defaults.transcriptionAutoSummariseMinChars` characters are automatically
    /// sent to the chat panel for summarisation. Default: false.
    var transcriptionAutoSummariseEnabled: Bool {
        get {
            guard defaults.object(forKey: Keys.transcriptionAutoSummariseEnabled) != nil else {
                return Defaults.transcriptionAutoSummariseEnabled
            }
            return defaults.bool(forKey: Keys.transcriptionAutoSummariseEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.transcriptionAutoSummariseEnabled) }
    }

    /// Prompt prepended to the transcript when summarising mic / system-audio
    /// recordings. Empty string falls back to `Defaults.transcriptionSummarisationPrompt`
    /// at read time so the user always sees a sensible default in the input.
    var transcriptionSummarisationPrompt: String {
        get {
            let stored = defaults.string(forKey: Keys.transcriptionSummarisationPrompt) ?? ""
            return stored.isEmpty ? Defaults.transcriptionSummarisationPrompt : stored
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                defaults.removeObject(forKey: Keys.transcriptionSummarisationPrompt)
            } else {
                defaults.set(newValue, forKey: Keys.transcriptionSummarisationPrompt)
            }
        }
    }

    // MARK: - Writing Assistant

    /// System prompt for the smart rewrite shortcut. Empty string falls back to
    /// the bundled default at read time. Editable in Preferences → Writing.
    var writingRewritePrompt: String {
        get {
            let stored = defaults.string(forKey: Keys.writingRewritePrompt) ?? ""
            return stored.isEmpty ? Defaults.writingRewritePrompt : stored
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                defaults.removeObject(forKey: Keys.writingRewritePrompt)
            } else {
                defaults.set(newValue, forKey: Keys.writingRewritePrompt)
            }
        }
    }

    /// Model used by the smart rewrite shortcut. Defaults to the chat model.
    var writingRewriteModel: String {
        get { defaults.string(forKey: Keys.writingRewriteModel) ?? Defaults.writingRewriteModel }
        set { defaults.set(newValue, forKey: Keys.writingRewriteModel) }
    }

    /// Upper bound for smart rewrite response length. The rewrite service still
    /// scales shorter inputs down, but never asks for more than this many tokens.
    /// Default: 4096. Range: 256–32000.
    var writingRewriteMaxOutputTokens: Int {
        get {
            guard defaults.object(forKey: Keys.writingRewriteMaxOutputTokens) != nil else {
                return Defaults.writingRewriteMaxOutputTokens
            }
            return max(256, min(32_000, defaults.integer(forKey: Keys.writingRewriteMaxOutputTokens)))
        }
        set { defaults.set(max(256, min(32_000, newValue)), forKey: Keys.writingRewriteMaxOutputTokens) }
    }

    // MARK: - AI Cost Tracking

    /// ISO date string "yyyy-MM-dd" for the current cost-tracking day.
    var costTrackingDate: String {
        get { defaults.string(forKey: Keys.costTrackingDate) ?? "" }
        set { defaults.set(newValue, forKey: Keys.costTrackingDate) }
    }

    /// Input tokens sent to the API today.
    var tokensInputToday: Int {
        get { defaults.integer(forKey: Keys.tokensInputToday) }
        set { defaults.set(newValue, forKey: Keys.tokensInputToday) }
    }

    /// Output tokens received from the API today.
    var tokensOutputToday: Int {
        get { defaults.integer(forKey: Keys.tokensOutputToday) }
        set { defaults.set(newValue, forKey: Keys.tokensOutputToday) }
    }

    /// Cached input tokens reused from the prompt cache today across all AI calls.
    var tokensCachedInputToday: Int {
        get { defaults.integer(forKey: Keys.tokensCachedInputToday) }
        set { defaults.set(newValue, forKey: Keys.tokensCachedInputToday) }
    }

    /// Chat input tokens sent today.
    var chatTokensInputToday: Int {
        get { defaults.integer(forKey: Keys.chatTokensInputToday) }
        set { defaults.set(newValue, forKey: Keys.chatTokensInputToday) }
    }

    /// Chat cached input tokens reused today.
    var chatTokensCachedInputToday: Int {
        get { defaults.integer(forKey: Keys.chatTokensCachedInputToday) }
        set { defaults.set(newValue, forKey: Keys.chatTokensCachedInputToday) }
    }

    /// Chat output tokens received today.
    var chatTokensOutputToday: Int {
        get { defaults.integer(forKey: Keys.chatTokensOutputToday) }
        set { defaults.set(newValue, forKey: Keys.chatTokensOutputToday) }
    }

    /// Total estimated chat cost for the current day in USD.
    var chatCostTodayUSD: Double {
        get { defaults.double(forKey: Keys.chatCostTodayUSD) }
        set { defaults.set(newValue, forKey: Keys.chatCostTodayUSD) }
    }

    /// Indexing input tokens sent today.
    var indexingTokensInputToday: Int {
        get { defaults.integer(forKey: Keys.indexingTokensInputToday) }
        set { defaults.set(newValue, forKey: Keys.indexingTokensInputToday) }
    }

    /// Indexing cached input tokens reused today.
    var indexingTokensCachedInputToday: Int {
        get { defaults.integer(forKey: Keys.indexingTokensCachedInputToday) }
        set { defaults.set(newValue, forKey: Keys.indexingTokensCachedInputToday) }
    }

    /// Indexing output tokens received today.
    var indexingTokensOutputToday: Int {
        get { defaults.integer(forKey: Keys.indexingTokensOutputToday) }
        set { defaults.set(newValue, forKey: Keys.indexingTokensOutputToday) }
    }

    /// Total estimated indexing cost for the current day in USD.
    var indexingCostTodayUSD: Double {
        get { defaults.double(forKey: Keys.indexingCostTodayUSD) }
        set { defaults.set(newValue, forKey: Keys.indexingCostTodayUSD) }
    }

    /// Total estimated transcription cost for the current day in USD.
    var transcriptionCostTodayUSD: Double {
        get { defaults.double(forKey: Keys.transcriptionCostTodayUSD) }
        set { defaults.set(newValue, forKey: Keys.transcriptionCostTodayUSD) }
    }

    /// Cumulative estimated transcription cost in USD.
    var transcriptionCostTotalUSD: Double {
        get { defaults.double(forKey: Keys.transcriptionCostTotalUSD) }
        set { defaults.set(newValue, forKey: Keys.transcriptionCostTotalUSD) }
    }

    /// Cumulative input tokens across all sessions.
    var tokensTotalInput: Int {
        get { defaults.integer(forKey: Keys.tokensTotalInput) }
        set { defaults.set(newValue, forKey: Keys.tokensTotalInput) }
    }

    /// Cumulative output tokens across all sessions.
    var tokensTotalOutput: Int {
        get { defaults.integer(forKey: Keys.tokensTotalOutput) }
        set { defaults.set(newValue, forKey: Keys.tokensTotalOutput) }
    }

    /// Cumulative cached input tokens across all sessions.
    var tokensTotalCachedInput: Int {
        get { defaults.integer(forKey: Keys.tokensTotalCachedInput) }
        set { defaults.set(newValue, forKey: Keys.tokensTotalCachedInput) }
    }

    /// Cumulative chat input tokens across all sessions.
    var chatTokensTotalInput: Int {
        get { defaults.integer(forKey: Keys.chatTokensTotalInput) }
        set { defaults.set(newValue, forKey: Keys.chatTokensTotalInput) }
    }

    /// Cumulative chat cached input tokens across all sessions.
    var chatTokensTotalCachedInput: Int {
        get { defaults.integer(forKey: Keys.chatTokensTotalCachedInput) }
        set { defaults.set(newValue, forKey: Keys.chatTokensTotalCachedInput) }
    }

    /// Cumulative chat output tokens across all sessions.
    var chatTokensTotalOutput: Int {
        get { defaults.integer(forKey: Keys.chatTokensTotalOutput) }
        set { defaults.set(newValue, forKey: Keys.chatTokensTotalOutput) }
    }

    /// Cumulative estimated chat cost in USD.
    var chatCostTotalUSD: Double {
        get { defaults.double(forKey: Keys.chatCostTotalUSD) }
        set { defaults.set(newValue, forKey: Keys.chatCostTotalUSD) }
    }

    /// Cumulative indexing input tokens across all sessions.
    var indexingTokensTotalInput: Int {
        get { defaults.integer(forKey: Keys.indexingTokensTotalInput) }
        set { defaults.set(newValue, forKey: Keys.indexingTokensTotalInput) }
    }

    /// Cumulative indexing cached input tokens across all sessions.
    var indexingTokensTotalCachedInput: Int {
        get { defaults.integer(forKey: Keys.indexingTokensTotalCachedInput) }
        set { defaults.set(newValue, forKey: Keys.indexingTokensTotalCachedInput) }
    }

    /// Cumulative indexing output tokens across all sessions.
    var indexingTokensTotalOutput: Int {
        get { defaults.integer(forKey: Keys.indexingTokensTotalOutput) }
        set { defaults.set(newValue, forKey: Keys.indexingTokensTotalOutput) }
    }

    /// Cumulative estimated indexing cost in USD.
    var indexingCostTotalUSD: Double {
        get { defaults.double(forKey: Keys.indexingCostTotalUSD) }
        set { defaults.set(newValue, forKey: Keys.indexingCostTotalUSD) }
    }

    var aiDailyCostHistoryData: Data {
        get { defaults.data(forKey: Keys.aiDailyCostHistoryData) ?? Data() }
        set { defaults.set(newValue, forKey: Keys.aiDailyCostHistoryData) }
    }

    var aiMonthlyCostHistoryData: Data {
        get { defaults.data(forKey: Keys.aiMonthlyCostHistoryData) ?? Data() }
        set { defaults.set(newValue, forKey: Keys.aiMonthlyCostHistoryData) }
    }

    func recordAICostHistory(category: AIUsageCategory, costUSD: Double, date: Date = Date()) {
        let dayKey = Self.dayString(for: date)
        var daily = loadCostHistory(from: aiDailyCostHistoryData)
        var dayEntry = daily[dayKey] ?? .zero
        dayEntry.addCost(costUSD, category: category)
        daily[dayKey] = dayEntry
        aiDailyCostHistoryData = encodeCostHistory(prune(daily, maxEntries: 180))

        let monthKey = Self.monthString(for: date)
        var monthly = loadCostHistory(from: aiMonthlyCostHistoryData)
        var monthEntry = monthly[monthKey] ?? .zero
        monthEntry.addCost(costUSD, category: category)
        monthly[monthKey] = monthEntry
        aiMonthlyCostHistoryData = encodeCostHistory(prune(monthly, maxEntries: 36))
    }

    func recentDailyCostHistory(limit: Int = 7) -> [(key: String, value: AICostHistoryEntry)] {
        sortedCostHistory(loadCostHistory(from: aiDailyCostHistoryData), limit: limit)
    }

    func recentMonthlyCostHistory(limit: Int = 6) -> [(key: String, value: AICostHistoryEntry)] {
        sortedCostHistory(loadCostHistory(from: aiMonthlyCostHistoryData), limit: limit)
    }

    func clearAICostHistory() {
        aiDailyCostHistoryData = Data()
        aiMonthlyCostHistoryData = Data()
    }

    /// Returns today's date formatted as "yyyy-MM-dd" for cost reset tracking.
    static func todayString() -> String {
        dayString(for: Date())
    }

    static func dayString(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return fmt.string(from: date)
    }

    static func monthString(for date: Date) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM"
        return fmt.string(from: date)
    }

    // MARK: - Activity Capture

    /// Whether the UI activity recorder is enabled. Default: false.
    var activityCaptureEnabled: Bool {
        get {
            guard defaults.object(forKey: Keys.activityCaptureEnabled) != nil else {
                return Defaults.activityCaptureEnabled
            }
            return defaults.bool(forKey: Keys.activityCaptureEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.activityCaptureEnabled) }
    }

    /// Whether the UI activity recorder is temporarily paused. Default: false.
    var activityCapturePaused: Bool {
        get {
            guard defaults.object(forKey: Keys.activityCapturePaused) != nil else {
                return Defaults.activityCapturePaused
            }
            return defaults.bool(forKey: Keys.activityCapturePaused)
        }
        set { defaults.set(newValue, forKey: Keys.activityCapturePaused) }
    }

    /// Whether screenshot capture is enabled (effective only when activityCaptureEnabled is true). Default: true.
    var activityCaptureScreenshotsEnabled: Bool {
        get {
            guard defaults.object(forKey: Keys.activityCaptureScreenshotsEnabled) != nil else {
                return Defaults.activityCaptureScreenshotsEnabled
            }
            return defaults.bool(forKey: Keys.activityCaptureScreenshotsEnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.activityCaptureScreenshotsEnabled)
            NotificationCenter.default.post(name: .activityCaptureSettingsDidChange, object: nil)
        }
    }

    /// Whether click-region OCR is enabled. When true, the recorder captures a
    /// small region around each click, runs Vision text recognition, and stores
    /// the most relevant text as `nearbyText` on the event. Default: true.
    var activityCaptureClickOCREnabled: Bool {
        get {
            guard defaults.object(forKey: Keys.activityCaptureClickOCREnabled) != nil else {
                return Defaults.activityCaptureClickOCREnabled
            }
            return defaults.bool(forKey: Keys.activityCaptureClickOCREnabled)
        }
        set {
            defaults.set(newValue, forKey: Keys.activityCaptureClickOCREnabled)
            NotificationCenter.default.post(name: .activityCaptureSettingsDidChange, object: nil)
        }
    }

    /// JPEG compression quality for activity screenshots. Default: 0.7. Range: 0.3–1.0.
    var activityCaptureJPEGQuality: Double {
        get {
            guard defaults.object(forKey: Keys.activityCaptureJPEGQuality) != nil else {
                return Defaults.activityCaptureJPEGQuality
            }
            return max(0.3, min(1.0, defaults.double(forKey: Keys.activityCaptureJPEGQuality)))
        }
        set {
            defaults.set(max(0.3, min(1.0, newValue)), forKey: Keys.activityCaptureJPEGQuality)
            NotificationCenter.default.post(name: .activityCaptureSettingsDidChange, object: nil)
        }
    }

    /// Screenshot scale factor. Default: 1. Valid values: 1 or 2.
    var activityCaptureScale: Int {
        get {
            guard defaults.object(forKey: Keys.activityCaptureScale) != nil else {
                return Defaults.activityCaptureScale
            }
            let raw = defaults.integer(forKey: Keys.activityCaptureScale)
            return raw == 2 ? 2 : 1
        }
        set {
            defaults.set(newValue == 2 ? 2 : 1, forKey: Keys.activityCaptureScale)
            NotificationCenter.default.post(name: .activityCaptureSettingsDidChange, object: nil)
        }
    }

    /// Fallback screenshot interval in seconds. Default: 60. Valid values: 0 (Never), 30, 60, 120, 300.
    var activityCaptureFallbackIntervalSeconds: Int {
        get {
            guard defaults.object(forKey: Keys.activityCaptureFallbackIntervalSeconds) != nil else {
                return Defaults.activityCaptureFallbackIntervalSeconds
            }
            return defaults.integer(forKey: Keys.activityCaptureFallbackIntervalSeconds)
        }
        set {
            defaults.set(newValue, forKey: Keys.activityCaptureFallbackIntervalSeconds)
            NotificationCenter.default.post(name: .activityCaptureSettingsDidChange, object: nil)
        }
    }

    /// Idle threshold in seconds before an idle-resume screenshot is taken. Default: 30. Valid values: 15, 30, 60.
    var activityCaptureIdleThresholdSeconds: Int {
        get {
            guard defaults.object(forKey: Keys.activityCaptureIdleThresholdSeconds) != nil else {
                return Defaults.activityCaptureIdleThresholdSeconds
            }
            return defaults.integer(forKey: Keys.activityCaptureIdleThresholdSeconds)
        }
        set {
            defaults.set(newValue, forKey: Keys.activityCaptureIdleThresholdSeconds)
            NotificationCenter.default.post(name: .activityCaptureSettingsDidChange, object: nil)
        }
    }

    /// Auto-delete activity logs older than this many days. Default: 0 (Never). Valid values: 0, 30, 60, 90.
    var activityCaptureRetentionDays: Int {
        get {
            guard defaults.object(forKey: Keys.activityCaptureRetentionDays) != nil else {
                return Defaults.activityCaptureRetentionDays
            }
            return defaults.integer(forKey: Keys.activityCaptureRetentionDays)
        }
        set { defaults.set(newValue, forKey: Keys.activityCaptureRetentionDays) }
    }

    /// Security-scoped bookmark data for the activity log root folder.
    var activityCaptureLogRootBookmark: Data? {
        get { defaults.data(forKey: Keys.activityCaptureLogRootBookmark) }
        set {
            if let data = newValue {
                defaults.set(data, forKey: Keys.activityCaptureLogRootBookmark)
            } else {
                defaults.removeObject(forKey: Keys.activityCaptureLogRootBookmark)
            }
        }
    }

    /// Plain path string for the activity log root folder (fallback when bookmark fails).
    var activityCaptureLogRootPath: String? {
        get { defaults.string(forKey: Keys.activityCaptureLogRootPath) }
        set {
            if let path = newValue {
                defaults.set(path, forKey: Keys.activityCaptureLogRootPath)
            } else {
                defaults.removeObject(forKey: Keys.activityCaptureLogRootPath)
            }
        }
    }

    /// Bundle IDs of apps excluded from activity screenshot capture.
    var activityCaptureExcludedBundleIDs: [String] {
        get {
            defaults.stringArray(forKey: Keys.activityCaptureExcludedBundleIDs)
                ?? Defaults.activityCaptureExcludedBundleIDs
        }
        set {
            defaults.set(newValue, forKey: Keys.activityCaptureExcludedBundleIDs)
            NotificationCenter.default.post(name: .activityCaptureExclusionsDidChange, object: nil)
        }
    }

    /// What to do when meeting mic activity is detected. Default: `.off`.
    /// Reads the legacy `activityCaptureAudioEnabled` Bool as a fallback so users
    /// who previously had recording enabled stay on `.audio` after upgrade.
    var activityCaptureAudioMode: ActivityCaptureAudioMode {
        get {
            if let raw = defaults.string(forKey: Keys.activityCaptureAudioMode),
               let mode = ActivityCaptureAudioMode(rawValue: raw) {
                return mode
            }
            // Migration: honor the legacy bool key if present.
            if defaults.object(forKey: Keys.activityCaptureAudioEnabled) != nil {
                return defaults.bool(forKey: Keys.activityCaptureAudioEnabled) ? .audio : .off
            }
            return Defaults.activityCaptureAudioMode
        }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.activityCaptureAudioMode)
            // Keep the legacy bool roughly in sync so any old reader stays consistent.
            defaults.set(newValue != .off, forKey: Keys.activityCaptureAudioEnabled)
            NotificationCenter.default.post(name: .activityCaptureSettingsDidChange, object: nil)
        }
    }

    /// Seconds to wait after another app releases the mic before stopping the
    /// in-flight meeting recording. Acts as a debounce so a brief mute or a
    /// short meeting-pause doesn't end the recording. Default: 45 seconds.
    var activityCaptureMicReleaseDelay: Int {
        get {
            guard defaults.object(forKey: Keys.activityCaptureMicReleaseDelay) != nil else {
                return Defaults.activityCaptureMicReleaseDelay
            }
            return max(5, min(300, defaults.integer(forKey: Keys.activityCaptureMicReleaseDelay)))
        }
        set {
            defaults.set(max(5, min(300, newValue)), forKey: Keys.activityCaptureMicReleaseDelay)
            NotificationCenter.default.post(name: .activityCaptureSettingsDidChange, object: nil)
        }
    }

    // MARK: - Conversation Limits

    /// Maximum number of conversations retained before auto-cleanup purges the oldest. Default: 100.
    var maxConversationCount: Int {
        get {
            guard defaults.object(forKey: Keys.maxConversationCount) != nil else {
                return Defaults.maxConversationCount
            }
            return max(10, min(500, defaults.integer(forKey: Keys.maxConversationCount)))
        }
        set { defaults.set(max(10, min(500, newValue)), forKey: Keys.maxConversationCount) }
    }

    private static func migrateLegacyDefaultsIfNeeded(from source: UserDefaults, to target: UserDefaults) {
        guard !target.bool(forKey: didMigrateSharedDefaultsKey) else { return }

        for key in Keys.migratableValues {
            guard target.object(forKey: key) == nil else { continue }
            guard let value = source.object(forKey: key) else { continue }
            target.set(value, forKey: key)
        }

        target.set(true, forKey: didMigrateSharedDefaultsKey)
    }

    private func migrateLegacyOpenAIAPIKeyIfNeeded(from source: UserDefaults) {
        if let current = secretStore.string(forKey: Keys.openAIAPIKey), !current.isEmpty {
            source.removeObject(forKey: Keys.openAIAPIKey)
            return
        }

        guard let legacyKey = source.string(forKey: Keys.openAIAPIKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !legacyKey.isEmpty else {
            return
        }

        secretStore.set(legacyKey, forKey: Keys.openAIAPIKey)
        source.removeObject(forKey: Keys.openAIAPIKey)
    }

    private func loadCostHistory(from data: Data) -> [String: AICostHistoryEntry] {
        guard !data.isEmpty,
              let decoded = try? JSONDecoder().decode([String: AICostHistoryEntry].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func encodeCostHistory(_ history: [String: AICostHistoryEntry]) -> Data {
        (try? JSONEncoder().encode(history)) ?? Data()
    }

    private func prune(
        _ history: [String: AICostHistoryEntry],
        maxEntries: Int
    ) -> [String: AICostHistoryEntry] {
        guard history.count > maxEntries else { return history }
        let keepKeys = history.keys.sorted(by: >).prefix(maxEntries)
        return Dictionary(uniqueKeysWithValues: keepKeys.compactMap { key in
            history[key].map { (key, $0) }
        })
    }

    private func sortedCostHistory(
        _ history: [String: AICostHistoryEntry],
        limit: Int
    ) -> [(key: String, value: AICostHistoryEntry)] {
        history
            .sorted { $0.key > $1.key }
            .prefix(limit)
            .map { (key: $0.key, value: $0.value) }
    }

    private func seedCurrentCostHistoryIfNeeded() {
        let todayEntry = AICostHistoryEntry(
            chatCostUSD: chatCostTodayUSD,
            indexingCostUSD: indexingCostTodayUSD
        )

        if todayEntry.totalCostUSD > 0 {
            let todayKey = Self.todayString()
            var daily = loadCostHistory(from: aiDailyCostHistoryData)
            if daily[todayKey] == nil {
                daily[todayKey] = todayEntry
                aiDailyCostHistoryData = encodeCostHistory(prune(daily, maxEntries: 180))
            }

            let monthKey = Self.monthString(for: Date())
            var monthly = loadCostHistory(from: aiMonthlyCostHistoryData)
            if monthly[monthKey] == nil {
                monthly[monthKey] = todayEntry
                aiMonthlyCostHistoryData = encodeCostHistory(prune(monthly, maxEntries: 36))
            }
        }
    }

    // MARK: - Meeting detection

    /// Watch for other apps using the microphone and offer to record the
    /// meeting (menu-bar bubble). macOS 14+ only. Default: on.
    var meetingDetectionEnabled: Bool {
        get {
            guard defaults.object(forKey: Keys.meetingDetectionEnabled) != nil else {
                return Defaults.meetingDetectionEnabled
            }
            return defaults.bool(forKey: Keys.meetingDetectionEnabled)
        }
        set { defaults.set(newValue, forKey: Keys.meetingDetectionEnabled) }
    }

    /// "Not now" suppresses the meeting bubble until this date. Nil = never
    /// snoozed.
    var meetingPromptSnoozeUntil: Date? {
        get {
            let timestamp = defaults.double(forKey: Keys.meetingPromptSnoozeUntil)
            guard timestamp > 0 else { return nil }
            return Date(timeIntervalSince1970: timestamp)
        }
        set {
            defaults.set(newValue?.timeIntervalSince1970 ?? 0,
                         forKey: Keys.meetingPromptSnoozeUntil)
        }
    }

    /// How long "Not now" keeps the bubble away, in minutes. Default: 60.
    var meetingPromptSnoozeMinutes: Int {
        get {
            guard defaults.object(forKey: Keys.meetingPromptSnoozeMinutes) != nil else {
                return Defaults.meetingPromptSnoozeMinutes
            }
            return defaults.integer(forKey: Keys.meetingPromptSnoozeMinutes)
        }
        set { defaults.set(newValue, forKey: Keys.meetingPromptSnoozeMinutes) }
    }

    // MARK: - Keys & Defaults

    enum Keys {
        static let hotkeyKeyCode     = "hotkeyKeyCode"
        static let hotkeyModifiers   = "hotkeyModifiers"
        static let maxHistoryCount   = "maxHistoryCount"
        static let autoPurgeAgeDays  = "autoPurgeAgeDays"
        static let excludedBundleIDs = "excludedBundleIDs"
        static let defaultPasteMode  = "defaultPasteMode"
        static let launchAtLogin     = "launchAtLogin"
        static let onboardingState   = "onboardingState"
        static let openAIAPIKey      = "openAIAPIKey"
        static let aiSkillBridgeEnabled = "aiSkillBridgeEnabled"
        static let aiSkillBridgePort = "aiSkillBridgePort"
        static let aiSkillBridgeToken = "aiSkillBridgeToken"
        static let chatModel            = "chatModel"
        static let classificationModel  = "classificationModel"
        static let visionModel          = "visionModel"
        static let embeddingModel       = "embeddingModel"
        static let transcriptionModel   = "transcriptionModel"
        static let translationEnabled         = "translationEnabled"
        static let translationTargetLanguage  = "translationTargetLanguage"
        static let translationModel           = "translationModel"
        static let cachedModelList      = "cachedModelList"
        static let voiceHotkeyKeyCode   = "voiceHotkeyKeyCode"
        static let voiceHotkeyModifiers = "voiceHotkeyModifiers"
        static let voiceRewriteHotkeyKeyCode   = "voiceRewriteHotkeyKeyCode"
        static let voiceRewriteHotkeyModifiers = "voiceRewriteHotkeyModifiers"
        static let aiRewriteHotkeyKeyCode      = "aiRewriteHotkeyKeyCode"
        static let aiRewriteHotkeyModifiers    = "aiRewriteHotkeyModifiers"
        static let voiceRewriteModel    = "voiceRewriteModel"
        static let voiceSessionMaxAgeSeconds         = "voiceSessionMaxAgeSeconds"
        static let chatHotkeyKeyCode    = "chatHotkeyKeyCode"
        static let chatHotkeyModifiers  = "chatHotkeyModifiers"
        static let chatContextMessageLimit = "chatContextMessageLimit"
        static let agenticMaxIterations    = "agenticMaxIterations"
        static let agenticSearchEnabled    = "agenticSearchEnabled"
        static let ragTopK              = "ragTopK"
        static let ragMaxContextChars   = "ragMaxContextChars"
        static let ragMaxOutputTokens   = "ragMaxOutputTokens"
        static let reasoningEffort      = "reasoningEffort"
        static let aiAssistSystemPrompt = "aiAssistSystemPrompt"
        static let askAIWebSearchEnabled = "askAIWebSearchEnabled"
        static let claudeCodeHistoryToolEnabled = "claudeCodeHistoryToolEnabled"
        static let codexHistoryToolEnabled = "codexHistoryToolEnabled"
        static let transcriptionAutoSummariseEnabled = "transcriptionAutoSummariseEnabled"
        static let transcriptionSummarisationPrompt  = "transcriptionSummarisationPrompt"
        static let writingRewritePrompt       = "writingRewritePrompt"
        static let writingRewriteModel        = "writingRewriteModel"
        static let writingRewriteMaxOutputTokens = "writingRewriteMaxOutputTokens"
        static let maxConversationCount = "maxConversationCount"
        static let costTrackingDate  = "costTrackingDate"
        static let tokensInputToday  = "tokensInputToday"
        static let tokensOutputToday = "tokensOutputToday"
        static let tokensCachedInputToday = "tokensCachedInputToday"
        static let chatTokensInputToday = "chatTokensInputToday"
        static let chatTokensCachedInputToday = "chatTokensCachedInputToday"
        static let chatTokensOutputToday = "chatTokensOutputToday"
        static let chatCostTodayUSD = "chatCostTodayUSD"
        static let indexingTokensInputToday = "indexingTokensInputToday"
        static let indexingTokensCachedInputToday = "indexingTokensCachedInputToday"
        static let indexingTokensOutputToday = "indexingTokensOutputToday"
        static let indexingCostTodayUSD = "indexingCostTodayUSD"
        static let transcriptionCostTodayUSD = "transcriptionCostTodayUSD"
        static let transcriptionCostTotalUSD = "transcriptionCostTotalUSD"
        static let tokensTotalInput  = "tokensTotalInput"
        static let tokensTotalOutput = "tokensTotalOutput"
        static let tokensTotalCachedInput = "tokensTotalCachedInput"
        static let chatTokensTotalInput = "chatTokensTotalInput"
        static let chatTokensTotalCachedInput = "chatTokensTotalCachedInput"
        static let chatTokensTotalOutput = "chatTokensTotalOutput"
        static let chatCostTotalUSD = "chatCostTotalUSD"
        static let indexingTokensTotalInput = "indexingTokensTotalInput"
        static let indexingTokensTotalCachedInput = "indexingTokensTotalCachedInput"
        static let indexingTokensTotalOutput = "indexingTokensTotalOutput"
        static let indexingCostTotalUSD = "indexingCostTotalUSD"
        static let aiDailyCostHistoryData = "aiDailyCostHistoryData"
        static let aiMonthlyCostHistoryData = "aiMonthlyCostHistoryData"

        // Activity Capture
        static let activityCaptureEnabled = "activityCaptureEnabled"
        static let activityCapturePaused = "activityCapturePaused"
        static let activityCaptureScreenshotsEnabled = "activityCaptureScreenshotsEnabled"
        static let activityCaptureClickOCREnabled = "activityCaptureClickOCREnabled"
        static let activityCaptureJPEGQuality = "activityCaptureJPEGQuality"
        static let activityCaptureScale = "activityCaptureScale"
        static let activityCaptureFallbackIntervalSeconds = "activityCaptureFallbackIntervalSeconds"
        static let activityCaptureIdleThresholdSeconds = "activityCaptureIdleThresholdSeconds"
        static let activityCaptureRetentionDays = "activityCaptureRetentionDays"
        static let activityCaptureLogRootBookmark = "activityCaptureLogRootBookmark"
        static let activityCaptureLogRootPath = "activityCaptureLogRootPath"
        static let activityCaptureExcludedBundleIDs = "activityCaptureExcludedBundleIDs"
        static let activityCaptureAudioEnabled = "activityCaptureAudioEnabled"
        static let activityCaptureAudioMode = "activityCaptureAudioMode"
        static let activityCaptureMicReleaseDelay = "activityCaptureMicReleaseDelay"

        // Voice media recordings
        static let voiceRecordingsFolderPath = "voiceRecordingsFolderPath"

        // Meeting detection
        static let meetingDetectionEnabled = "meetingDetectionEnabled"
        static let meetingPromptSnoozeUntil = "meetingPromptSnoozeUntil"
        static let meetingPromptSnoozeMinutes = "meetingPromptSnoozeMinutes"

        static let migratableValues: [String] = [
            hotkeyKeyCode,
            hotkeyModifiers,
            maxHistoryCount,
            autoPurgeAgeDays,
            excludedBundleIDs,
            defaultPasteMode,
            launchAtLogin,
            onboardingState,
            aiSkillBridgeEnabled,
            aiSkillBridgePort,
            chatModel,
            classificationModel,
            visionModel,
            embeddingModel,
            translationEnabled,
            translationTargetLanguage,
            translationModel,
            cachedModelList,
            voiceSessionMaxAgeSeconds,
            voiceRewriteHotkeyKeyCode,
            voiceRewriteHotkeyModifiers,
            aiRewriteHotkeyKeyCode,
            aiRewriteHotkeyModifiers,
            voiceRewriteModel,
            chatHotkeyKeyCode,
            chatHotkeyModifiers,
            chatContextMessageLimit,
            agenticMaxIterations,
            agenticSearchEnabled,
            ragTopK,
            ragMaxContextChars,
            ragMaxOutputTokens,
            reasoningEffort,
            aiAssistSystemPrompt,
            askAIWebSearchEnabled,
            claudeCodeHistoryToolEnabled,
            codexHistoryToolEnabled,
            transcriptionAutoSummariseEnabled,
            transcriptionSummarisationPrompt,
            writingRewritePrompt,
            writingRewriteModel,
            writingRewriteMaxOutputTokens,
            maxConversationCount,
            costTrackingDate,
            tokensInputToday,
            tokensOutputToday,
            tokensCachedInputToday,
            chatTokensInputToday,
            chatTokensCachedInputToday,
            chatTokensOutputToday,
            chatCostTodayUSD,
            indexingTokensInputToday,
            indexingTokensCachedInputToday,
            indexingTokensOutputToday,
            indexingCostTodayUSD,
            tokensTotalInput,
            tokensTotalOutput,
            tokensTotalCachedInput,
            chatTokensTotalInput,
            chatTokensTotalCachedInput,
            chatTokensTotalOutput,
            chatCostTotalUSD,
            indexingTokensTotalInput,
            indexingTokensTotalCachedInput,
            indexingTokensTotalOutput,
            indexingCostTotalUSD,
            aiDailyCostHistoryData,
            aiMonthlyCostHistoryData,
            meetingDetectionEnabled,
            meetingPromptSnoozeUntil,
            meetingPromptSnoozeMinutes
        ]
    }

    enum Defaults {
        /// Carbon key code for V.
        static let hotkeyKeyCode: Int = 9
        /// command (0x100000) + shift (0x20000) in CGEventFlags raw value.
        static let hotkeyModifiers: UInt64 = 0x100000 | 0x20000
        static let maxHistoryCount: Int = 5000
        static let autoPurgeAgeDays: Int = 90
        static let defaultPasteMode: PasteMode = .plain
        /// Carbon key code for C.
        static let chatHotkeyKeyCode: Int = 8
        /// command (0x100000) + shift (0x20000).
        static let chatHotkeyModifiers: UInt64 = 0x100000 | 0x20000
        static let chatModel: String = "gpt-5.4-nano"
        static let classificationModel: String = "gpt-5.4-nano"
        static let visionModel: String = "gpt-5.4-mini"
        static let embeddingModel: String = "text-embedding-3-small"
        static let transcriptionModel: String = "gpt-realtime-whisper"
        static let translationModel: String = "gpt-realtime-translate"
        static let translationTargetLanguage: String = "en"

        /// Languages currently accepted by the realtime translation endpoint.
        /// Tuple is (ISO 639-1 code, English display name).
        static let translationLanguages: [(code: String, name: String)] = [
            ("zh", "Chinese"),
            ("en", "English"),
            ("fr", "French"),
            ("de", "German"),
            ("hi", "Hindi"),
            ("id", "Indonesian"),
            ("it", "Italian"),
            ("ja", "Japanese"),
            ("ko", "Korean"),
            ("pt", "Portuguese"),
            ("ru", "Russian"),
            ("es", "Spanish"),
        ]
        /// Carbon key code for Space.
        static let voiceHotkeyKeyCode: Int = 49
        /// option (0x080000).
        static let voiceHotkeyModifiers: UInt64 = 0x080000
        /// Carbon key code for Space — Option+Shift+Space mirrors the
        /// dictation hotkey but routes the transcript through an LLM
        /// for grammar/transcription cleanup before pasting.
        static let voiceRewriteHotkeyKeyCode: Int = 49
        /// option (0x080000) + shift (0x020000).
        static let voiceRewriteHotkeyModifiers: UInt64 = 0x080000 | 0x020000
        /// Carbon key code for R — Option+Shift+R triggers the focused-text AI
        /// rewrite (Writing Assistant).
        static let aiRewriteHotkeyKeyCode: Int = 15
        /// option (0x080000) + shift (0x020000).
        static let aiRewriteHotkeyModifiers: UInt64 = 0x080000 | 0x020000
        /// Mirrors `chatModel` — the rewrite uses the same default chat model
        /// out of the box; users can override it to a smaller/cheaper one in
        /// Preferences → AI.
        static let voiceRewriteModel: String = chatModel
        /// Proactively rotate the realtime socket at this age. Keeps long
        /// recordings off the ~30 min server-side cap. See
        /// ``Settings.voiceSessionMaxAgeSeconds``. 25 min default.
        static let voiceSessionMaxAgeSeconds: Int = 25 * 60
        static let chatContextMessageLimit: Int = 20
        static let agenticMaxIterations: Int = 3
        static let agenticSearchEnabled: Bool = true
        static let ragTopK: Int = 20
        static let ragMaxContextChars: Int = 24_000
        static let ragMaxOutputTokens: Int = 512
        static let reasoningEffort: String = "medium"
        /// Default user-prompt template prepended to every Ask AI request,
        /// before the framing string and the conversation transcript. Empty
        /// by default — the hardcoded system prompt already covers tone /
        /// format expectations, so users only add text here when they want
        /// standing instructions or extra context. Editable in Preferences → AI.
        static var aiAssistSystemPrompt: String { Prompts.shared.aiAssist.defaultUserPrefix }
        /// Ask AI tools are opt-in — web search costs tokens and the history
        /// tools read local agent logs, so the user enables each explicitly.
        static let askAIWebSearchEnabled: Bool = false
        static let claudeCodeHistoryToolEnabled: Bool = false
        static let codexHistoryToolEnabled: Bool = false
        /// Auto-summarisation is opt-in — the user must enable it explicitly.
        static let transcriptionAutoSummariseEnabled: Bool = false
        /// Minimum transcript length (characters) before auto-summarisation kicks in.
        static let transcriptionAutoSummariseMinChars: Int = 1000
        /// Default summarisation prompt — shown as the initial value of the
        /// prompt input in Preferences → AI. Editable per user.
        static var transcriptionSummarisationPrompt: String {
            Prompts.shared.transcriptionSummarisation.defaultPrompt
        }

        // Writing Assistant
        static var writingRewritePrompt: String { Prompts.shared.writingAssistant.rewriteSystem }
        /// Mirror `chatModel` so the rewrite shortcut has a sensible default.
        static var writingRewriteModel: String { chatModel }
        static let writingRewriteMaxOutputTokens: Int = 4096

        static let maxConversationCount: Int = 100

        // Activity Capture
        static let activityCaptureEnabled: Bool = false
        static let activityCapturePaused: Bool = false
        static let activityCaptureScreenshotsEnabled: Bool = true
        static let activityCaptureClickOCREnabled: Bool = true
        static let activityCaptureJPEGQuality: Double = 0.7
        static let activityCaptureScale: Int = 1
        static let activityCaptureFallbackIntervalSeconds: Int = 60
        static let activityCaptureIdleThresholdSeconds: Int = 30
        static let activityCaptureRetentionDays: Int = 0
        static let activityCaptureAudioEnabled: Bool = true
        static let activityCaptureAudioMode: ActivityCaptureAudioMode = .off
        static let activityCaptureMicReleaseDelay: Int = 45
        static let activityCaptureExcludedBundleIDs: [String] = [
            // Password managers
            "com.agilebits.onepassword7",
            "com.agilebits.onepassword-osx",
            "com.bitwarden.desktop",
            "com.dashlane.dashlane",
            "com.lastpass.lastpassmacdesktop",
            "com.keepassium.macos",
            "org.keepassx.keepassxc",
            "com.apple.Passwords",
            // Banking / finance
            "com.apple.Safari",  // excluded conservatively; users can remove
            // Sensitive utilities
            "com.apple.keychainaccess",
            "com.apple.systempreferences",
            // BrainCache itself
            "com.TalkFlow.BrainCache"
        ]

        // Meeting detection
        static let meetingDetectionEnabled: Bool = true
        static let meetingPromptSnoozeMinutes: Int = 60
    }
}
