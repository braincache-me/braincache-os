import AppKit
import Foundation
import Network
import os

/// Owns the live voice-transcription session: drives the recorder, opens one
/// realtime WebSocket per audio source (mic + optional system audio), and
/// surfaces partial / final transcripts to the UI as they arrive.
final class VoiceTranscriptionService {

    static let shared = VoiceTranscriptionService()

    /// What `finalize()` should do with the finished transcript.
    enum FinalizeIntent: Equatable {
        /// Default: save the clip and paste into the previously frontmost app.
        case paste
        /// AI Assist mode: save the clip but skip the paste — the controller
        /// will hand the transcript to the AI window instead.
        case skipPaste
        /// Save the raw transcript, run it through an LLM for grammar /
        /// transcription cleanup, then paste the cleaned text. If the LLM
        /// call fails for any reason, the raw transcript is pasted as a
        /// fallback so the dictation is never lost.
        case rewriteAndPaste
    }

    /// Reset to `.paste` after every finalize. Set by `stopAndTranscribe(intent:)`.
    private var pendingFinalizeIntent: FinalizeIntent = .paste

    enum State: Equatable {
        case idle
        case recording
        case transcribing
        case completed(String)
        case error(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.recording, .recording), (.transcribing, .transcribing):
                return true
            case (.completed(let a), .completed(let b)):
                return a == b
            case (.error(let a), .error(let b)):
                return a == b
            default:
                return false
            }
        }
    }

    /// Snapshot of what the panel should currently render. The mic and system
    /// transcripts are kept separate so the UI can label or column them.
    struct LiveTranscript {
        enum Source: String {
            case mic = "Mic"
            case system = "System"
        }

        struct Entry: Equatable {
            var source: Source
            var timestamp: TimeInterval
            var text: String
            var isFinal: Bool
        }

        var mic: String = ""
        var micPartial: String = ""
        var system: String = ""
        var systemPartial: String = ""
        var entries: [Entry] = []

        /// Combined plain text used when inserting into the clipboard store
        /// and when feeding the transcript to AI. Format matches the on-screen
        /// renderer in `VoiceRecordingPanelController.renderTranscript` so
        /// what the user sees, what is pasted, and what is sent to the model
        /// are byte-for-byte identical.
        var combined: String {
            let timeline = entries
                .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .sorted { $0.timestamp < $1.timestamp }
            if !timeline.isEmpty {
                let hasSystem = timeline.contains(where: { $0.source == .system })
                if hasSystem {
                    return timeline
                        .map { "[\(Self.formatTimestamp($0.timestamp)) \($0.source.rawValue)] \($0.text.trimmingCharacters(in: .whitespacesAndNewlines))" }
                        .joined(separator: "\n")
                }
                return timeline
                    .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .joined(separator: " ")
            }

            let m = mic.trimmingCharacters(in: .whitespacesAndNewlines)
            let s = system.trimmingCharacters(in: .whitespacesAndNewlines)
            if m.isEmpty && s.isEmpty { return "" }
            if s.isEmpty { return m }
            if m.isEmpty { return s }
            return "[Mic] \(m)\n\n[Sys] \(s)"
        }

        static func formatTimestamp(_ seconds: TimeInterval) -> String {
            let total = max(0, Int(seconds.rounded()))
            let minutes = total / 60
            let seconds = total % 60
            return String(format: "%d:%02d", minutes, seconds)
        }
    }

    private(set) var state: State = .idle
    private(set) var transcript = LiveTranscript()

    var onStateChange: ((State) -> Void)?
    var audioLevelCallback: ((Float) -> Void)?
    var systemAudioLevelCallback: ((Float) -> Void)?
    /// Fires whenever any partial or final delta updates the live transcript.
    var onTranscriptUpdate: ((LiveTranscript) -> Void)?
    /// Fires whenever an underlying realtime client transitions state — used
    /// by the panel to surface "Reconnecting…" so the user knows the dropout
    /// is being recovered rather than the recording being silently broken.
    /// Always delivered on the main queue.
    var onClientStateChange: ((RealtimeTranscriptionClient.Source, RealtimeTranscriptionClient.State) -> Void)?

    let recorder = VoiceTranscriptionRecorder()
    var clipStore: ClipStore?
    var pasteService: PasteService?
    var clipboardMonitor: ClipboardMonitor?

    private var micClient: RealtimeAudioStreamingClient?
    private var systemClient: RealtimeAudioStreamingClient?
    private var retiredSystemClients: [RealtimeAudioStreamingClient] = []
    private var includesSystemAudio = false
    private var capturedSystemAudioInSession = false
    private var accumulatedSystemAudioDuration: TimeInterval = 0
    private var systemAudioStartedAt: Date?
    private var recordingDurationSeconds: TimeInterval = 0
    private var finalizationWorkItem: DispatchWorkItem?
    private var recordingStartedAt: Date?

    /// When the most recent transcript delta arrived for each source. Used to
    /// detect speaker pauses by gap between packets — if no text has arrived
    /// for a source in `utteranceSilenceThreshold` seconds and a new delta
    /// shows up, we treat it as a new dialogue turn and open a fresh entry
    /// (with a fresh timestamp) so the saved transcript reads as alternating
    /// blocks rather than two giant per-source paragraphs.
    private var lastDeltaArrival: [RealtimeTranscriptionClient.Source: Date] = [:]
    /// How many times we've client-chunked a source's stream into multiple
    /// entries during the current OpenAI buffer. Reset when a `completed`
    /// event flushes the buffer. Lets `completeTranscript` know not to
    /// overwrite per-chunk text with the buffer-level final transcript
    /// (which would collapse all chunks back into one block).
    private var clientChunkSplits: [RealtimeTranscriptionClient.Source: Int] = [:]
    private let utteranceSilenceThreshold: TimeInterval = 2.0

    private var firstChunkLogged = false

    // MARK: Crash-safe transcript drafts
    //
    // The live transcript is flushed into a single clip every
    // `draftFlushInterval` seconds (and on sleep / power-off / quit) so a
    // dead battery mid-meeting loses seconds of text, not the whole session.
    // The final save at stop time reuses the same clip — no duplicates.
    private var draftPersister: TranscriptDraftPersister?
    private var draftFlushTimer: Timer?
    static let draftFlushInterval: TimeInterval = 5
    private var powerObservers: [NSObjectProtocol] = []

    // MARK: Media recording (audio / window video file)

    /// Writes the session to disk (`.m4a`, or `.mov` when a window is
    /// attached) independently of the realtime transcription stream. Driven
    /// by the panel's "Save recording" checkbox; always stopped with the
    /// session so a file can never outlive its recording.
    let mediaRecorder = VoiceMediaRecorder()
    /// Clip pointing at the media file, inserted the moment recording starts
    /// so the file is discoverable in history even after a crash.
    private var mediaClipId: Int64?

    enum MediaStopReason: Equatable {
        case userRequested
        case sessionEnded
        case sourceLost(appName: String)
        case failed(message: String)
    }

    struct MediaStopEvent {
        let result: VoiceMediaRecorder.Result?
        let reason: MediaStopReason
    }

    /// Fires on the main queue whenever the media recording ends, for any
    /// reason. `result` is `nil` when nothing was kept on disk.
    var onMediaRecordingStopped: ((MediaStopEvent) -> Void)?

    var isMediaRecording: Bool { mediaRecorder.isRecording }
    var mediaRecordingURL: URL? { mediaRecorder.outputURL }
    /// The window being recorded to video, while a window recording is live.
    var mediaRecordingWindow: CapturableWindow? {
        mediaRecorder.isRecording ? mediaRecorder.mode.window : nil
    }

    /// macOS sleep/wake observer. When the machine wakes, any in-flight
    /// `URLSessionWebSocketTask` can be in a zombie half-open state — we
    /// don't get an immediate error, but the server has long since dropped
    /// the connection. Forcing a fresh socket pair on wake is the safe move.
    private var wakeObserver: NSObjectProtocol?

    /// Network path monitor. When Wi-Fi flips, an Ethernet cable comes out,
    /// or the machine roams between networks, the existing TCP stays open
    /// but stale. We force a reconnect on the next satisfied path so the
    /// new route is used.
    private var pathMonitor: NWPathMonitor?
    private var lastPathStatus: NWPath.Status = .satisfied
    /// `NWPathMonitor.pathUpdateHandler` fires once on registration with the
    /// monitor's initial path snapshot. We want to use that to seed
    /// `lastPathStatus`, not treat it as a real network transition — the
    /// recorder's sockets were just opened against the same network. This
    /// flag suppresses action on the very first delivery.
    private var pathMonitorPrimed = false

    private static let logger = Logger(subsystem: "com.braincache.realtime", category: "service")

    private init() {
        recorder.audioLevelCallback = { [weak self] level in
            self?.audioLevelCallback?(level)
        }
        recorder.systemAudioLevelCallback = { [weak self] level in
            self?.systemAudioLevelCallback?(level)
        }
        recorder.audioChunkHandler = { [weak self] data, source in
            guard let self else { return }
            if !self.firstChunkLogged {
                self.firstChunkLogged = true
                self.log("first audio chunk captured (source=\(source), bytes=\(data.count))")
            }
            switch source {
            case .mic: self.micClient?.sendAudio(data)
            case .system: self.systemClient?.sendAudio(data)
            }
        }
        recorder.systemAudioErrorHandler = { [weak self] error in
            self?.handleSystemAudioError(error)
        }
        mediaRecorder.onSourceLost = { [weak self] window, result in
            self?.finishMediaRecording(result: result, reason: .sourceLost(appName: window.appName))
        }
        mediaRecorder.onWriterFailure = { [weak self] error, result in
            self?.finishMediaRecording(result: result, reason: .failed(message: error.localizedDescription))
        }
    }

    // MARK: - Public API

    func startRecording(includeSystemAudio: Bool) {
        guard state == .idle else { return }

        guard VoiceTranscriptionRecorder.micPermissionGranted else {
            // First call after install: status is `.notDetermined` and the OS
            // shows the TCC prompt. After a denial (or if macOS lost the entry),
            // `requestAccess` resolves immediately without prompting — in that
            // case `AccessibilityChecker.requestMicrophoneAccess` opens
            // Privacy → Microphone so the user can flip the switch manually.
            AccessibilityChecker.requestMicrophoneAccess { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.startRecording(includeSystemAudio: includeSystemAudio)
                } else {
                    let status = AccessibilityChecker.microphoneAuthorizationStatus
                    let message: String
                    switch status {
                    case .denied, .restricted:
                        message = "Microphone access is blocked. Enable BrainCache in System Settings → Privacy & Security → Microphone, then try again."
                    default:
                        message = "Microphone access denied. Grant permission in System Settings → Privacy & Security → Microphone."
                    }
                    self.setState(.error(message))
                }
            }
            return
        }

        guard Settings.shared.isAIEnabled else {
            setState(.error("AI API key is not configured. Add one in Preferences → AI."))
            return
        }

        guard !includeSystemAudio || AccessibilityChecker.isScreenRecordingGranted else {
            _ = AccessibilityChecker.openScreenRecordingSettings()
            setState(.error("Screen Recording permission is required for Sys audio. Enable BrainCache in System Settings, then quit and reopen the app."))
            return
        }

        // Reset live transcript and connect sockets before opening the audio taps.
        transcript = LiveTranscript()
        onTranscriptUpdate?(transcript)
        includesSystemAudio = includeSystemAudio
        capturedSystemAudioInSession = includeSystemAudio
        accumulatedSystemAudioDuration = 0
        firstChunkLogged = false
        lastDeltaArrival.removeAll()
        clientChunkSplits.removeAll()
        recordingStartedAt = Date()
        systemAudioStartedAt = includeSystemAudio ? recordingStartedAt : nil

        let translationEnabled = Settings.shared.translationEnabled
        let modelForLog = translationEnabled
            ? Settings.shared.translationModel
            : Settings.shared.transcriptionModel
        log("starting (model=\(modelForLog), translation=\(translationEnabled), includeSystemAudio=\(includeSystemAudio))")
        let mic = makeClient(source: .mic)
        micClient = mic
        mic.start()

        if includeSystemAudio {
            let sys = makeClient(source: .system)
            systemClient = sys
            sys.start()
        }

        recorder.includeSystemAudio = includeSystemAudio
        do {
            try recorder.startRecording()
            installSystemEventObservers()
            startDraftPersistence()
            setState(.recording)
        } catch {
            log("recorder.startRecording threw: \(error.localizedDescription)")
            tearDownClients()
            includesSystemAudio = false
            capturedSystemAudioInSession = false
            accumulatedSystemAudioDuration = 0
            systemAudioStartedAt = nil
            recordingStartedAt = nil
            setState(.error(error.localizedDescription))
        }
    }

    var isSystemAudioEnabled: Bool {
        includesSystemAudio
    }

    /// Toggles only the system-audio half of an active recording. Returns an
    /// error message when the request cannot be applied; the mic session keeps
    /// running so users don't lose the recording.
    @discardableResult
    func setSystemAudioEnabled(_ enabled: Bool) -> String? {
        guard case .recording = state else { return nil }
        guard enabled != includesSystemAudio else { return nil }

        if enabled {
            return enableSystemAudioDuringRecording()
        } else {
            disableSystemAudioDuringRecording()
            return nil
        }
    }

    /// Tears down the active mic/system realtime clients and spins up new
    /// ones using the *current* `Settings.translationEnabled` /
    /// `translationTargetLanguage` values, without disturbing the audio
    /// recorder. Used when the user switches translation mode mid-recording
    /// so the next words flow through the new endpoint.
    ///
    /// Brief gap (~200–500 ms) while the new socket handshakes — incoming
    /// PCM is buffered locally inside the new client and shipped once it's
    /// ready, so audio isn't lost. Everything the server already confirmed
    /// is preserved: in-flight partials are finalized into the transcript
    /// before the old clients are torn down, so a mode switch (or a
    /// sleep/wake / network reconnect, which take this same path) never
    /// loses the text the user has already spoken.
    func restartLiveClients() {
        guard case .recording = state else { return }

        // Fold any in-flight partials into the persisted transcript first.
        // Once we cancel the sockets the server's pending `completed` events
        // will never arrive, so unfinalized deltas would otherwise be lost.
        if !transcript.micPartial.isEmpty {
            finalizePartial(source: .mic)
        }
        if !transcript.systemPartial.isEmpty {
            finalizePartial(source: .system)
        }

        micClient?.cancel()
        systemClient?.cancel()
        micClient = nil
        systemClient = nil

        // Keep the accumulated transcript (mic/system text + entries). Just
        // notify subscribers so any UI re-render now reflects the finalized
        // state, and reset per-client bookkeeping so the new clients open
        // fresh entries instead of trying to extend the now-finalized ones.
        onTranscriptUpdate?(transcript)
        firstChunkLogged = false
        lastDeltaArrival.removeAll()
        clientChunkSplits.removeAll()

        let mic = makeClient(source: .mic)
        micClient = mic
        mic.start()

        if includesSystemAudio {
            let sys = makeClient(source: .system)
            systemClient = sys
            sys.start()
        }

        log("live clients restarted (translation=\(Settings.shared.translationEnabled), targetLanguage=\(Settings.shared.translationTargetLanguage))")
    }

    /// Tears down the active mic realtime client + audio engine and spins up
    /// fresh ones so the most recently selected mic device takes effect on
    /// the current session. System audio capture and its transcript are left
    /// untouched. Mirror of ``restartLiveClients`` for the mic half — used
    /// when the user picks a different input device mid-recording.
    func restartMicCapture() {
        guard case .recording = state else { return }

        micClient?.cancel()
        micClient = nil

        // Drop in-flight mic partial — old-mic deltas don't compose with
        // new-mic ones. Final mic text and the system half are preserved.
        transcript.micPartial = ""
        onTranscriptUpdate?(transcript)
        firstChunkLogged = false
        lastDeltaArrival[.mic] = nil
        clientChunkSplits[.mic] = nil

        let mic = makeClient(source: .mic)
        micClient = mic
        mic.start()

        do {
            try recorder.restartMicCapture()
            log("mic capture restarted with new input device")
        } catch {
            log("mic restart failed: \(error.localizedDescription)")
            mic.cancel()
            micClient = nil
            cancel()
            setState(.error("Failed to switch microphone: \(error.localizedDescription)"))
        }
    }

    func stopAndTranscribe(intent: FinalizeIntent = .paste) {
        guard state == .recording else { return }
        pendingFinalizeIntent = intent

        stopMediaRecording(reason: .sessionEnded)
        stopDraftFlushTimer()
        recordingDurationSeconds = recorder.stopRecording()
        let systemAudioDurationSeconds = finishSystemAudioDuration()

        // Skip very short recordings without sending anything to the server.
        guard recordingDurationSeconds >= 0.3 else {
            tearDownClients()
            removeSystemEventObservers()
            endDraftPersistence()
            includesSystemAudio = false
            capturedSystemAudioInSession = false
            accumulatedSystemAudioDuration = 0
            systemAudioStartedAt = nil
            recordingStartedAt = nil
            setState(.idle)
            return
        }

        // Tell the sockets to commit and close. Final transcripts that arrive in
        // the next ~600 ms will continue updating `transcript` via callbacks.
        micClient?.stop()
        systemClient?.stop()

        setState(.transcribing)

        // Record per-minute cost for each active stream. Translation sessions
        // are billed under the translation model name (cost lookup will fall
        // back to a default per-minute rate if the price table doesn't yet
        // know the translate model).
        let model = Settings.shared.translationEnabled
            ? Settings.shared.translationModel
            : Settings.shared.transcriptionModel
        OpenAIClient.shared.recordTranscriptionCost(model: model, durationSeconds: recordingDurationSeconds)
        if systemAudioDurationSeconds >= 0.3 {
            OpenAIClient.shared.recordTranscriptionCost(model: model, durationSeconds: systemAudioDurationSeconds)
        }

        finalizationWorkItem = nil
        finalize()
    }

    func cancel() {
        finalizationWorkItem?.cancel()
        finalizationWorkItem = nil
        stopMediaRecording(reason: .sessionEnded)
        if recorder.isRecording { recorder.cancelRecording() }
        // `cancel` is only ever reached from error-recovery paths (never a
        // user "discard"), so fold in-flight partials into the persisted
        // draft rather than throwing away what was captured.
        if case .recording = state {
            if !transcript.micPartial.isEmpty { finalizePartial(source: .mic) }
            if !transcript.systemPartial.isEmpty { finalizePartial(source: .system) }
            flushDraftTranscript(isFinal: true)
        }
        endDraftPersistence()
        tearDownClients()
        removeSystemEventObservers()
        includesSystemAudio = false
        capturedSystemAudioInSession = false
        accumulatedSystemAudioDuration = 0
        systemAudioStartedAt = nil
        transcript = LiveTranscript()
        lastDeltaArrival.removeAll()
        clientChunkSplits.removeAll()
        recordingStartedAt = nil
        onTranscriptUpdate?(transcript)
        setState(.idle)
    }

    var recordingDuration: TimeInterval {
        recorder.recordingDuration
    }

    /// Wall-clock timestamp of the current (or last) recording session's start.
    /// Used by AI Assist to time-filter clips captured during the recording
    /// window. Nil while idle / between sessions.
    var recordingStartTime: Date? { recordingStartedAt }

    // MARK: - Realtime client wiring

    private func makeClient(source: RealtimeTranscriptionClient.Source) -> RealtimeAudioStreamingClient {
        // Realtime WebSocket sessions exist only on OpenAI. Every other
        // provider transcribes through `ChunkedTranscriptionClient`, which
        // exposes the same surface but posts buffered WAV chunks to an omni
        // chat model instead of streaming PCM to a socket.
        let client: RealtimeAudioStreamingClient
        if Settings.shared.isOpenAIProvider {
            if Settings.shared.translationEnabled {
                client = RealtimeTranslationClient(
                    source: source,
                    model: Settings.shared.translationModel,
                    targetLanguage: Settings.shared.translationTargetLanguage
                )
            } else {
                client = RealtimeTranscriptionClient(source: source, model: Settings.shared.transcriptionModel)
            }
        } else {
            client = ChunkedTranscriptionClient(
                source: source,
                model: Settings.shared.transcriptionModel,
                targetLanguage: Settings.shared.translationEnabled
                    ? Settings.shared.translationTargetLanguage
                    : nil
            )
        }
        client.onPartial = { [weak self] delta in
            guard let self else { return }
            self.appendPartial(delta, source: source)
            self.onTranscriptUpdate?(self.transcript)
        }
        client.onCompleted = { [weak self] transcript in
            guard let self else { return }
            self.completeTranscript(transcript, source: source)
            self.onTranscriptUpdate?(self.transcript)
        }
        client.onStateChange = { [weak self] clientState in
            guard let self else { return }
            DispatchQueue.main.async {
                self.onClientStateChange?(source, clientState)
            }
        }
        client.onError = { [weak self] error in
            guard let self else { return }
            DispatchQueue.main.async {
                switch self.state {
                case .recording, .transcribing:
                    self.log("\(source) realtime error: \(error.localizedDescription)")
                    // After all reconnect attempts are exhausted the live
                    // transcript still holds everything the server confirmed
                    // before the drop — save it as a clip so a 1 hr recording
                    // doesn't evaporate when the socket finally gives up.
                    self.abortPreservingTranscript(error: error)
                default:
                    break
                }
            }
        }
        return client
    }

    /// Terminal-failure cleanup. Folds any in-flight partials into the final
    /// transcript, persists whatever has been captured so far as a clip, and
    /// transitions to `.error`. Used when a realtime client surfaces an
    /// unrecoverable error mid-recording — we'd rather give the user back the
    /// 40 minutes they already spoke than lose it because minute 41 dropped.
    private func abortPreservingTranscript(error: Error) {
        finalizationWorkItem?.cancel()
        finalizationWorkItem = nil

        stopMediaRecording(reason: .sessionEnded)
        stopDraftFlushTimer()
        if recorder.isRecording {
            _ = recorder.stopRecording()
        }

        if !transcript.micPartial.isEmpty {
            finalizePartial(source: .mic)
        }
        if !transcript.systemPartial.isEmpty {
            finalizePartial(source: .system)
        }
        onTranscriptUpdate?(transcript)

        let combined = transcript.combined.trimmingCharacters(in: .whitespacesAndNewlines)
        if !combined.isEmpty {
            saveTranscriptClip(text: combined)
        }
        endDraftPersistence()

        tearDownClients()
        removeSystemEventObservers()
        includesSystemAudio = false
        capturedSystemAudioInSession = false
        accumulatedSystemAudioDuration = 0
        systemAudioStartedAt = nil
        recordingStartedAt = nil
        transcript = LiveTranscript()
        lastDeltaArrival.removeAll()
        clientChunkSplits.removeAll()
        onTranscriptUpdate?(transcript)

        let suffix = combined.isEmpty ? "" : " (partial transcript saved to clips)"
        setState(.error(error.localizedDescription + suffix))
    }

    private func enableSystemAudioDuringRecording() -> String? {
        guard AccessibilityChecker.isScreenRecordingGranted else {
            _ = AccessibilityChecker.openScreenRecordingSettings()
            return "Screen Recording permission is required for Sys audio. Enable BrainCache in System Settings, then quit and reopen the app."
        }

        let sys = makeClient(source: .system)
        systemClient = sys
        sys.start()

        do {
            try recorder.startSystemAudioCaptureIfNeeded()
            includesSystemAudio = true
            capturedSystemAudioInSession = true
            systemAudioStartedAt = Date()
            mediaRecorder.setIncludesSystemAudio(true)
            log("system audio enabled during active recording")
            return nil
        } catch {
            systemClient = nil
            sys.cancel()
            log("failed to enable system audio: \(error.localizedDescription)")
            return systemAudioErrorMessage(for: error)
        }
    }

    private func disableSystemAudioDuringRecording() {
        accumulateSystemAudioDuration()
        includesSystemAudio = false
        recorder.stopSystemAudioCaptureIfNeeded()
        mediaRecorder.setIncludesSystemAudio(false)

        if let sys = systemClient {
            systemClient = nil
            retireSystemClient(sys, gracefully: true)
        }
        log("system audio disabled during active recording")
    }

    private func retireSystemClient(_ client: RealtimeAudioStreamingClient, gracefully: Bool) {
        retiredSystemClients.append(client)
        client.onError = { error in
            VoiceTranscriptionService.shared.log("retired system realtime error: \(error.localizedDescription)")
        }
        client.onStateChange = { [weak self, weak client] state in
            DispatchQueue.main.async {
                guard let self, let client else { return }
                switch state {
                case .stopped, .failed:
                    self.retiredSystemClients.removeAll { $0 === client }
                default:
                    break
                }
            }
        }
        if gracefully {
            client.stop()
        } else {
            client.cancel()
        }
    }

    private func accumulateSystemAudioDuration() {
        guard let startedAt = systemAudioStartedAt else { return }
        accumulatedSystemAudioDuration += Date().timeIntervalSince(startedAt)
        systemAudioStartedAt = nil
    }

    private func finishSystemAudioDuration() -> TimeInterval {
        accumulateSystemAudioDuration()
        return accumulatedSystemAudioDuration
    }

    private func handleSystemAudioError(_ error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let shouldSurface: Bool
            switch self.state {
            case .recording:
                shouldSurface = true
            default:
                shouldSurface = self.recorder.isRecording && self.includesSystemAudio
            }
            guard shouldSurface else { return }

            self.log("system audio capture error: \(error.localizedDescription)")
            self.cancel()
            self.setState(.error(self.systemAudioErrorMessage(for: error)))
        }
    }

    private func systemAudioErrorMessage(for error: Error) -> String {
        if let recorderError = error as? VoiceTranscriptionRecorder.RecorderError,
           let description = recorderError.errorDescription {
            return description
        }
        return "System audio capture failed: \(error.localizedDescription)"
    }

    private func appendPartial(_ delta: String, source: RealtimeTranscriptionClient.Source) {
        guard !delta.isEmpty else { return }
        let liveSource = liveTranscriptSource(for: source)

        // Detect a speaker pause: if the gap since the last delta on this
        // source is large, the speaker stopped and resumed (or another
        // speaker took the floor in between). That gap is the natural
        // boundary for a new dialogue entry — close out the in-flight
        // partial so it gets its own timestamped block, and start a fresh
        // entry with NOW as the new turn's timestamp.
        let now = Date()
        let pausedLongEnough: Bool = {
            guard let last = lastDeltaArrival[source] else { return false }
            return now.timeIntervalSince(last) > utteranceSilenceThreshold
        }()
        lastDeltaArrival[source] = now

        if pausedLongEnough,
           let idx = transcript.entries.lastIndex(where: { $0.source == liveSource && !$0.isFinal }) {
            transcript.entries[idx].isFinal = true
            switch source {
            case .mic: transcript.micPartial = ""
            case .system: transcript.systemPartial = ""
            }
            clientChunkSplits[source, default: 0] += 1
        }

        // Append deltas as-is. The Realtime API tokenises with BPE — a single
        // word can arrive as several deltas (e.g. "lockdown" + "s",
        // "202" + "0") with no leading space on continuations, and tokens
        // that belong after a space already carry one (" the", " went").
        // Inserting our own space at word-character boundaries would break
        // multi-token words and numbers.
        switch source {
        case .mic: transcript.micPartial += delta
        case .system: transcript.systemPartial += delta
        }

        if let idx = transcript.entries.lastIndex(where: { $0.source == liveSource && !$0.isFinal }) {
            transcript.entries[idx].text += delta
        } else {
            // Drop a leading space on the first delta of a new entry — the
            // panel renderer joins entries with " " already.
            let entryText = delta.hasPrefix(" ") ? String(delta.dropFirst()) : delta
            transcript.entries.append(
                LiveTranscript.Entry(
                    source: liveSource,
                    timestamp: currentTranscriptTimestamp(),
                    text: entryText,
                    isFinal: false
                )
            )
        }
    }

    private func completeTranscript(_ piece: String, source: RealtimeTranscriptionClient.Source) {
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let liveSource = liveTranscriptSource(for: source)

        switch source {
        case .mic:
            appendFinal(trimmed, to: \.mic)
            transcript.micPartial = ""
        case .system:
            appendFinal(trimmed, to: \.system)
            transcript.systemPartial = ""
        }

        // If we already split this source into multiple entries via pause
        // detection, the `completed` event's text is the concatenation of
        // every chunk we've seen — overwriting the open partial with it
        // would duplicate the earlier chunks. Just finalize the open
        // partial(s) and trust the per-chunk text. For models that emit
        // one `completed` per utterance (server VAD), splits stays at 0
        // and we still take the authoritative server text.
        let splits = clientChunkSplits[source] ?? 0
        clientChunkSplits[source] = 0

        let openPartials = transcript.entries.indices.filter {
            transcript.entries[$0].source == liveSource && !transcript.entries[$0].isFinal
        }

        if splits > 0 {
            for idx in openPartials {
                transcript.entries[idx].isFinal = true
            }
            if openPartials.isEmpty {
                transcript.entries.append(
                    LiveTranscript.Entry(
                        source: liveSource,
                        timestamp: currentTranscriptTimestamp(),
                        text: trimmed,
                        isFinal: true
                    )
                )
            }
        } else if let idx = openPartials.last {
            transcript.entries[idx].text = trimmed
            transcript.entries[idx].isFinal = true
        } else {
            transcript.entries.append(
                LiveTranscript.Entry(
                    source: liveSource,
                    timestamp: currentTranscriptTimestamp(),
                    text: trimmed,
                    isFinal: true
                )
            )
        }
    }

    private func finalizePartial(source: RealtimeTranscriptionClient.Source) {
        let partial: String
        switch source {
        case .mic: partial = transcript.micPartial
        case .system: partial = transcript.systemPartial
        }
        completeTranscript(partial, source: source)
    }

    private func liveTranscriptSource(for source: RealtimeTranscriptionClient.Source) -> LiveTranscript.Source {
        switch source {
        case .mic: return .mic
        case .system: return .system
        }
    }

    private func currentTranscriptTimestamp() -> TimeInterval {
        Date().timeIntervalSince(recordingStartedAt ?? Date())
    }

    private func appendFinal(_ piece: String, to keyPath: WritableKeyPath<LiveTranscript, String>) {
        let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var current = transcript[keyPath: keyPath]
        if !current.isEmpty { current += " " }
        current += trimmed
        transcript[keyPath: keyPath] = current
    }

    private func tearDownClients() {
        micClient?.cancel()
        systemClient?.cancel()
        retiredSystemClients.forEach { $0.cancel() }
        micClient = nil
        systemClient = nil
        retiredSystemClients.removeAll()
    }

    // MARK: - Finalize

    private func finalize() {
        finalizationWorkItem = nil

        // Fold any leftover partial deltas into the final transcript so we
        // don't lose words the server hadn't committed yet at close time.
        if !transcript.micPartial.isEmpty {
            finalizePartial(source: .mic)
        }
        if !transcript.systemPartial.isEmpty {
            finalizePartial(source: .system)
        }
        onTranscriptUpdate?(transcript)

        let combined = transcript.combined.trimmingCharacters(in: .whitespacesAndNewlines)
        tearDownClients()
        removeSystemEventObservers()

        guard !combined.isEmpty else {
            endDraftPersistence()
            setState(.error("No speech detected."))
            pendingFinalizeIntent = .paste
            includesSystemAudio = false
            capturedSystemAudioInSession = false
            accumulatedSystemAudioDuration = 0
            systemAudioStartedAt = nil
            recordingStartedAt = nil
            return
        }

        let intent = pendingFinalizeIntent
        pendingFinalizeIntent = .paste
        switch effectiveFinalizeIntent(intent) {
        case .paste:
            insertAndPaste(text: combined)
            completeFinalize(with: combined)
        case .skipPaste:
            saveTranscriptClip(text: combined)
            completeFinalize(with: combined)
        case .rewriteAndPaste:
            // Save the raw transcript first so it's persisted even if the
            // rewrite call hangs or the user quits before paste fires. The
            // LLM-cleaned text is pasted; the raw text remains in clips.
            saveTranscriptClip(text: combined)
            rewriteAndPaste(rawText: combined)
        }
        endDraftPersistence()
    }

    /// Final transition for the `.paste` / `.skipPaste` paths and the
    /// terminal step of the `.rewriteAndPaste` path. Flips to `.completed`,
    /// clears the recording start marker, then drops back to `.idle` after a
    /// brief moment so the panel can show the success state.
    private func completeFinalize(with finalText: String) {
        setState(.completed(finalText))
        recordingStartedAt = nil
        capturedSystemAudioInSession = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, case .completed = self.state else { return }
            self.setState(.idle)
        }
    }

    private func effectiveFinalizeIntent(_ intent: FinalizeIntent) -> FinalizeIntent {
        Self.effectiveFinalizeIntent(intent, capturedSystemAudio: capturedSystemAudioInSession)
    }

    static func effectiveFinalizeIntent(_ intent: FinalizeIntent, capturedSystemAudio: Bool) -> FinalizeIntent {
        guard capturedSystemAudio else { return intent }
        return .skipPaste
    }

    // MARK: - Rewrite & Paste

    /// System prompt used for the Option+Shift+Space cleanup pass. The goal is
    /// narrow: fix transcription artefacts without changing meaning. Edit the
    /// underlying text in `Prompts.json` rather than here.
    private static var rewriteSystemPrompt: String { Prompts.shared.voiceRewrite.system }

    private func rewriteAndPaste(rawText: String) {
        let model = Settings.shared.voiceRewriteModel
        let messages: [OpenAIClient.ChatMessage] = [
            OpenAIClient.ChatMessage(role: "system", content: Self.rewriteSystemPrompt),
            OpenAIClient.ChatMessage(role: "user", content: rawText),
        ]

        Task { [weak self] in
            guard let self else { return }
            let pasteText: String
            do {
                let response = try await OpenAIClient.shared.chatCompletion(
                    model: model,
                    messages: messages,
                    usageCategory: .chat
                )
                let cleaned = response.choices.first?.message.content
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if cleaned.isEmpty {
                    self.log("voice rewrite returned empty text — falling back to raw transcript")
                    pasteText = rawText
                } else {
                    pasteText = cleaned
                }
            } catch {
                // Fail open: paste what the user actually said rather than
                // leave them with nothing after a 30-second dictation.
                self.log("voice rewrite failed (\(error.localizedDescription)) — falling back to raw transcript")
                pasteText = rawText
            }

            await MainActor.run {
                self.pasteRewrittenText(pasteText)
                self.completeFinalize(with: pasteText)
            }
        }
    }

    private func pasteRewrittenText(_ text: String) {
        let hash = Hashing.sha256(data: Data(text.utf8))
        let record = ClipRecord(
            id: nil,
            contentType: ClipboardContentType.text.rawValue,
            textContent: text,
            dataHash: hash,
            mediaFileName: nil,
            fileURL: nil,
            sourceApp: ClipRecord.audioTranscriptSourceApp,
            byteSize: text.utf8.count,
            createdAt: Date().timeIntervalSince1970,
            lastUsedAt: nil,
            isPinned: false,
            isIndexed: false,
            tags: nil,
            imageDescription: nil,
            aiProcessed: 0,
            aiProcessedAt: nil
        )

        let targetBundleID = AppDetector.shared.lastFrontmostApp
        clipboardMonitor?.suppressNextCapture(hash: hash)
        pasteService?.paste(record: record, targetBundleID: targetBundleID)
    }

    // MARK: - Insert & Paste

    private func insertAndPaste(text: String) {
        let hash = Hashing.sha256(data: Data(text.utf8))
        let record = ClipRecord(
            id: nil,
            contentType: ClipboardContentType.text.rawValue,
            textContent: text,
            dataHash: hash,
            mediaFileName: nil,
            fileURL: nil,
            sourceApp: ClipRecord.audioTranscriptSourceApp,
            byteSize: text.utf8.count,
            createdAt: Date().timeIntervalSince1970,
            lastUsedAt: nil,
            isPinned: false,
            isIndexed: false,
            tags: nil,
            imageDescription: nil,
            aiProcessed: 0,
            aiProcessedAt: nil
        )

        saveTranscriptClip(text: text, hash: hash)

        let targetBundleID = AppDetector.shared.lastFrontmostApp
        clipboardMonitor?.suppressNextCapture(hash: hash)
        pasteService?.paste(record: record, targetBundleID: targetBundleID)
    }

    /// Save-only path used by `.skipPaste` finalize intent (AI Assist).
    /// The transcript still ends up in the clip store so users can find and
    /// reuse it later, but isn't pasted into the previously frontmost app.
    private func saveTranscriptClip(text: String, hash: String? = nil) {
        guard let store = clipStore else { return }
        let clipId: Int64?
        if let persister = draftPersister {
            // Reuse the clip the periodic flush has been updating — the
            // final text lands in the same row, so history shows one entry.
            clipId = persister.flush(text: text, isFinal: true)
        } else {
            let h = hash ?? Hashing.sha256(data: Data(text.utf8))
            do {
                let entry = ClipboardEntry(
                    contentType: .text,
                    textContent: text,
                    dataHash: h,
                    sourceApp: ClipRecord.audioTranscriptSourceApp,
                    byteSize: text.utf8.count
                )
                clipId = try store.insert(entry: entry)
            } catch {
                log("failed to save clip: \(error)")
                clipId = nil
            }
        }
        if let clipId {
            AIIndexingPipeline.shared.enqueue(clipId: clipId)
        }
        triggerAutoSummariseIfNeeded(text: text)
    }

    // MARK: - Crash-safe draft persistence

    private func startDraftPersistence() {
        draftPersister = makeDraftPersister()
        startDraftFlushTimer()
    }

    private func makeDraftPersister() -> TranscriptDraftPersister? {
        guard let store = clipStore else { return nil }
        return TranscriptDraftPersister(
            insert: { text in
                let entry = ClipboardEntry(
                    contentType: .text,
                    textContent: text,
                    dataHash: Hashing.sha256(data: Data(text.utf8)),
                    sourceApp: ClipRecord.audioTranscriptSourceApp,
                    byteSize: text.utf8.count
                )
                return try store.insert(entry: entry)
            },
            update: { clipId, text, isFinal in
                try store.updateTextContent(id: clipId, text: text, resetAIProcessing: isFinal)
            },
            log: { [weak self] message in self?.log(message) }
        )
    }

    private func startDraftFlushTimer() {
        draftFlushTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: Self.draftFlushInterval, repeats: true) { [weak self] _ in
            self?.flushDraftTranscript()
        }
        timer.tolerance = 1
        draftFlushTimer = timer
    }

    private func stopDraftFlushTimer() {
        draftFlushTimer?.invalidate()
        draftFlushTimer = nil
    }

    private func endDraftPersistence() {
        stopDraftFlushTimer()
        draftPersister = nil
    }

    /// Persists the live transcript — including in-flight partial text — into
    /// the session's draft clip. No-op when nothing changed since the last
    /// flush. Safe to call from any lifecycle hook.
    func flushDraftTranscript(isFinal: Bool = false) {
        guard case .recording = state, let persister = draftPersister else { return }
        persister.flush(text: transcript.combined, isFinal: isFinal)
    }

    /// Id of the clip currently holding the draft transcript (nil until the
    /// first non-empty flush). Exposed for the UI / tests.
    var draftTranscriptClipId: Int64? { draftPersister?.clipId }

    // MARK: - Media recording

    /// Starts writing the live session to a file in
    /// `Settings.voiceRecordingsFolderURL`. When `window` is given the file is
    /// a `.mov` with that window's video; otherwise an `.m4a`. System audio
    /// is included whenever the session is capturing it. Returns an error
    /// message on failure, `nil` on success.
    @discardableResult
    func startMediaRecording(window: CapturableWindow?, micDeviceUID: String?) -> String? {
        guard case .recording = state else {
            return "Start a recording before saving it to a file."
        }
        guard !mediaRecorder.isRecording else { return nil }

        let configuration = VoiceMediaRecorder.Configuration(
            mode: window.map { .window($0) } ?? .audioOnly,
            includeSystemAudio: includesSystemAudio,
            micDeviceUID: micDeviceUID,
            outputDirectory: Settings.shared.voiceRecordingsFolderURL
        )
        do {
            let url = try mediaRecorder.start(configuration: configuration)
            mediaClipId = insertMediaFileClip(url: url)
            log("media recording started → \(url.lastPathComponent)")
            return nil
        } catch {
            if case VoiceMediaRecorder.RecorderError.screenRecordingPermissionDenied = error {
                _ = AccessibilityChecker.openScreenRecordingSettings()
            }
            log("media recording failed to start: \(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    /// Finalises the media file. No-op when nothing is being recorded.
    func stopMediaRecording(reason: MediaStopReason = .userRequested) {
        guard mediaRecorder.isRecording else { return }
        mediaRecorder.stop { [weak self] result in
            self?.finishMediaRecording(result: result, reason: reason)
        }
    }

    private func finishMediaRecording(result: VoiceMediaRecorder.Result?, reason: MediaStopReason) {
        let clipId = mediaClipId
        mediaClipId = nil
        if result == nil, let clipId, let store = clipStore {
            // Nothing usable was kept on disk — drop the pointer clip too.
            try? store.deleteById(clipId)
        }
        switch result {
        case .some(let saved):
            log("media recording stopped (\(reason)) → \(saved.url.lastPathComponent), \(Int(saved.duration)) s")
        case .none:
            log("media recording stopped (\(reason)) with nothing to keep")
        }
        onMediaRecordingStopped?(MediaStopEvent(result: result, reason: reason))
    }

    private func insertMediaFileClip(url: URL) -> Int64? {
        guard let store = clipStore else { return nil }
        let path = url.path
        let data = Data(path.utf8)
        let entry = ClipboardEntry(
            contentType: .file,
            textContent: path,
            dataHash: Hashing.sha256(data: data),
            rawData: data,
            fileURL: url,
            sourceApp: ClipRecord.audioTranscriptSourceApp,
            byteSize: data.count
        )
        do {
            return try store.insert(entry: entry)
        } catch {
            log("failed to save media file clip: \(error)")
            return nil
        }
    }

    /// Send the freshly-saved transcript to the chat panel for summarisation
    /// when the user has opted in, the transcript is long enough, and the
    /// recording captured system audio — auto-notes target meetings/calls,
    /// not mic-only dictation. Requires an API key — without one the chat
    /// panel just shows the configure-key notice, which is the same UX as
    /// opening the panel manually.
    private func triggerAutoSummariseIfNeeded(text: String) {
        guard Settings.shared.transcriptionAutoSummariseEnabled,
              Settings.shared.isAIEnabled,
              capturedSystemAudioInSession,
              text.count >= Settings.Defaults.transcriptionAutoSummariseMinChars else { return }
        DispatchQueue.main.async {
            ChatPanelController.shared.summariseTranscript(text)
        }
    }

    // MARK: - System event observers

    /// Installs sleep/wake + network-path observers while a recording is
    /// active. On either signal, we force the realtime clients to start a
    /// fresh socket via ``restartLiveClients`` — the existing client's TCP
    /// can be in a zombie half-open state and won't recover on its own.
    private func installSystemEventObservers() {
        // Already installed (re-entry from restartLiveClients during a path
        // change burst). Don't stack observers.
        if wakeObserver != nil { return }

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.log("system woke from sleep — restarting realtime clients")
            self.restartLiveClientsIfRecording()
        }

        // Flush the draft transcript before the machine sleeps, powers off,
        // or the app quits — the periodic timer won't get another tick.
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.willPowerOffNotification] {
            powerObservers.append(workspaceCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                self?.flushDraftTranscript()
            })
        }
        powerObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.flushDraftTranscript(isFinal: true)
            self?.mediaRecorder.stop()
        })

        pathMonitorPrimed = false
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            DispatchQueue.main.async {
                let was = self.lastPathStatus
                self.lastPathStatus = path.status
                // First delivery is the monitor's initial snapshot — seed
                // `lastPathStatus` and stop. The sockets we just opened are
                // already on this path; treating it as a transition would
                // cause an immediate, needless restart.
                if !self.pathMonitorPrimed {
                    self.pathMonitorPrimed = true
                    return
                }
                // Only react to satisfied transitions where we previously
                // had a working path go away. Brief flips that don't break
                // the existing socket are not actionable.
                if was != .satisfied && path.status == .satisfied {
                    self.log("network path became satisfied — restarting realtime clients")
                    self.restartLiveClientsIfRecording()
                } else if was == .satisfied && path.status != .satisfied {
                    self.log("network path lost (status=\(String(describing: path.status))) — clients will reconnect when path returns")
                }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.braincache.voice-path-monitor"))
        pathMonitor = monitor
    }

    private func removeSystemEventObservers() {
        if let token = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            wakeObserver = nil
        }
        for token in powerObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(token)
            NotificationCenter.default.removeObserver(token)
        }
        powerObservers.removeAll()
        pathMonitor?.cancel()
        pathMonitor = nil
        lastPathStatus = .satisfied
    }

    private func restartLiveClientsIfRecording() {
        guard case .recording = state else { return }
        restartLiveClients()
    }

    // MARK: - Private

    private func setState(_ newState: State) {
        state = newState
        onStateChange?(newState)
    }

    private func log(_ message: String) {
        let line = "[VoiceTranscription] \(message)"
        Self.logger.log("\(line, privacy: .public)")
    }
}
