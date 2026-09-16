import Foundation
import os

/// Streams 24 kHz mono PCM16 audio to the OpenAI Realtime *translation* API
/// (`/v1/realtime/translations`) and emits translated transcript deltas in the
/// configured target language.
///
/// Mirrors `RealtimeTranscriptionClient` so `VoiceTranscriptionService` can use
/// either via the `RealtimeAudioStreamingClient` protocol. Differences vs the
/// transcription client:
///
/// - URL is `wss://api.openai.com/v1/realtime/translations?model=...`.
/// - Session config sets `session.audio.output.language` instead of an input
///   transcription model.
/// - Audio append events use `session.input_audio_buffer.append`.
/// - Translated text arrives on `session.output_transcript.delta` (and a
///   `.done` event marks segment finals). The `session.output_audio.delta`
///   stream is intentionally ignored — we only surface text.
///
/// Resilience features (mirrored from `RealtimeTranscriptionClient`):
/// - Proactive 25 min rotation to stay ahead of OpenAI's session cap.
/// - Re-configures on a mid-flight `session.created` (server-side refresh).
/// - Reconnect guarded against double-fire from `didCloseWith` + receiveLoop.
/// - Ping every 25 s; ping failure triggers a reconnect.
final class RealtimeTranslationClient: NSObject, RealtimeAudioStreamingClient {

    typealias State = RealtimeTranscriptionClient.State
    typealias Source = RealtimeTranscriptionClient.Source

    let source: Source

    var onPartial: ((String) -> Void)?
    var onCompleted: ((String) -> Void)?
    var onStateChange: ((State) -> Void)?
    var onError: ((Error) -> Void)?

    private let model: String
    private let targetLanguage: String
    private let sampleRate: Int

    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private let queue = DispatchQueue(label: "com.braincache.realtime-translation", qos: .userInitiated)

    private var pingTimer: DispatchSourceTimer?
    private var rotationTimer: DispatchSourceTimer?
    private var audioResponseWatchdogTimer: DispatchSourceTimer?
    private var audioResponseWatchdog = RealtimeAudioResponseWatchdog()
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 12
    private let pingInterval: TimeInterval = 25
    private let maxBackoffSeconds: TimeInterval = 30

    private var sessionConfigurationSent = false
    private var sessionConfigured = false
    private var sessionReadyAt: Date?

    private var audioChunksSent = 0
    private var audioBytesSent = 0
    private var lastAudioLogChunkCount = 0

    /// Translated text emitted since the last segment boundary. The
    /// translation API streams deltas continuously; we treat each
    /// `output_transcript.done` event (or stop()) as a segment boundary so
    /// `onCompleted` callbacks fire with whole sentences instead of words.
    private var pendingFinal = ""

    private var pendingAudio: [Data] = []
    private var pendingAudioBytes = 0
    /// ~90 s at 24 kHz mono PCM16 = 4.32 MB. See the matching note in
    /// `RealtimeTranscriptionClient` — sized to cover slow reconnects without
    /// silently dropping audio.
    private let maxPendingAudioBytes = 4_320_000

    private var pendingShipChunks: [Data] = []
    private var pendingShipBytes = 0
    private var pendingShipFlush: DispatchWorkItem?
    private let maxShipBatch = 3
    private let maxShipBatchDelay: TimeInterval = 0.12

    init(source: Source, model: String, targetLanguage: String, sampleRate: Int = 24000) {
        self.source = source
        self.model = model
        self.targetLanguage = targetLanguage
        self.sampleRate = sampleRate
        super.init()
    }

    // MARK: - Public API

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            guard case .idle = self.state else { return }
            self.connect()
        }
    }

    func sendAudio(_ pcm16: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            guard case .ready = self.state, let task = self.task else {
                if self.pendingAudioBytes + pcm16.count <= self.maxPendingAudioBytes {
                    self.pendingAudio.append(pcm16)
                    self.pendingAudioBytes += pcm16.count
                } else {
                    self.logOnce("pending audio buffer full — dropping chunks until socket ready",
                                 key: "drop-buffer-full")
                }
                return
            }
            self.audioResponseWatchdog.noteOutgoingAudio(pcm16)
            self.shipAudio(pcm16, on: task)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.task != nil, case .ready = self.state else {
                self.flushPendingFinalLocked()
                self.shutdown()
                return
            }
            self.state = .stopping
            if let task = self.task {
                self.flushShipBatch(on: task)
            }
            // Translation API streams continuously — there's no commit event.
            // Give the server a short window to flush trailing deltas.
            self.queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                guard let self, case .stopping = self.state else { return }
                self.flushPendingFinalLocked()
                self.shutdown()
            }
        }
    }

    func cancel() {
        queue.async { [weak self] in
            self?.shutdown()
        }
    }

    // MARK: - Connection lifecycle

    private func connect() {
        let key = Settings.shared.openAIAPIKey
        guard !key.isEmpty else {
            log("connect aborted: OpenAI API key is not configured")
            state = .failed("OpenAI API key is not configured.")
            onError?(NSError(domain: "RealtimeTranslationClient", code: 401,
                             userInfo: [NSLocalizedDescriptionKey: "OpenAI API key is not configured."]))
            return
        }

        let escapedModel = model.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? model
        let urlString = "wss://api.openai.com/v1/realtime/translations?model=\(escapedModel)"
        guard let url = URL(string: urlString) else { return }
        log("connecting to \(urlString) (apiKey length=\(key.count), targetLanguage=\(targetLanguage), sampleRate=\(sampleRate))")

        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = TimeInterval.greatestFiniteMagnitude
        config.waitsForConnectivity = true

        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        self.session = session
        self.task = task
        self.sessionConfigurationSent = false
        self.sessionConfigured = false
        self.sessionReadyAt = nil

        if case .reconnecting = state {} else {
            state = .connecting
        }

        task.resume()
        receiveLoop()
        schedulePing()
    }

    private func shutdown() {
        cancelPing()
        cancelRotation()
        cancelAudioResponseWatchdog()
        audioResponseWatchdog.reset()
        clearPendingShipBatch()
        if let task = task {
            task.cancel(with: .normalClosure, reason: nil)
        }
        task = nil
        session?.invalidateAndCancel()
        session = nil
        sessionConfigurationSent = false
        sessionConfigured = false
        sessionReadyAt = nil
        if case .stopping = state {
            state = .stopped
        } else if case .failed = state {
            // keep failure state
        } else {
            state = .stopped
        }
    }

    private func attemptReconnect(reason: String) {
        // Same double-fire guard as RealtimeTranscriptionClient: both the
        // close handler and the in-flight receiveLoop will call this when
        // the socket dies, and without the guard we burn two retries per drop.
        if case .reconnecting = state {
            log("attemptReconnect ignored — already reconnecting (reason=\(reason))")
            return
        }

        log("attemptReconnect: \(reason)")
        cancelPing()
        cancelRotation()
        cancelAudioResponseWatchdog()
        audioResponseWatchdog.reset()
        clearPendingShipBatch()
        if let task = task { task.cancel(with: .abnormalClosure, reason: nil) }
        task = nil
        session?.invalidateAndCancel()
        session = nil

        // pendingFinal accumulates translated deltas since the last segment
        // boundary. Those deltas were already shipped to onPartial and live
        // in the service's transcript; carrying them across a reconnect would
        // corrupt the next `output_transcript.done` fallback path.
        pendingFinal = ""

        if case .stopping = state { state = .stopped; return }
        if case .stopped = state { return }

        reconnectAttempts += 1
        guard reconnectAttempts <= maxReconnectAttempts else {
            log("reconnect budget exhausted (\(reconnectAttempts)/\(maxReconnectAttempts)) — failing")
            state = .failed("Lost realtime translation connection: \(reason)")
            onError?(NSError(domain: "RealtimeTranslationClient", code: -1,
                             userInfo: [NSLocalizedDescriptionKey: reason]))
            return
        }

        state = .reconnecting(attempt: reconnectAttempts)
        let raw = pow(2.0, Double(reconnectAttempts - 1))
        let delay = min(raw, maxBackoffSeconds)
        log("reconnect attempt \(reconnectAttempts)/\(maxReconnectAttempts) in \(String(format: "%.1f", delay)) s")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }

    /// See `RealtimeTranscriptionClient.proactivelyRotate`.
    private func proactivelyRotate() {
        switch state {
        case .reconnecting, .stopping, .stopped, .failed, .connecting:
            return
        case .ready, .idle:
            break
        }
        log("proactive rotation: closing socket after \(Int(sessionAge())) s of .ready")
        cancelPing()
        cancelRotation()
        cancelAudioResponseWatchdog()
        audioResponseWatchdog.reset()
        clearPendingShipBatch()
        pendingFinal = ""
        if let task = task { task.cancel(with: .normalClosure, reason: nil) }
        task = nil
        session?.invalidateAndCancel()
        session = nil
        sessionConfigurationSent = false
        sessionConfigured = false
        sessionReadyAt = nil
        state = .reconnecting(attempt: 0)
        queue.async { [weak self] in
            self?.connect()
        }
    }

    private func sessionAge() -> TimeInterval {
        guard let readyAt = sessionReadyAt else { return 0 }
        return Date().timeIntervalSince(readyAt)
    }

    // MARK: - Session config

    private func configureSession() {
        guard let task = task else { return }
        guard !sessionConfigurationSent else { return }
        let event = Self.makeSessionUpdateEvent(targetLanguage: targetLanguage)
        log("sending session.update (targetLanguage=\(targetLanguage))")
        send(event: event, on: task)
        sessionConfigurationSent = true
    }

    /// Per OpenAI's realtime translation docs, target language is set on
    /// `session.audio.output.language`. The session is implicitly typed by
    /// the `/v1/realtime/translations` endpoint, so no `type` field is needed.
    static func makeSessionUpdateEvent(targetLanguage: String) -> [String: Any] {
        return [
            "type": "session.update",
            "session": [
                "audio": [
                    "output": [
                        "language": targetLanguage,
                    ],
                ],
            ],
        ]
    }

    private func markSessionReady() {
        guard !sessionConfigured else { return }
        sessionConfigured = true
        reconnectAttempts = 0
        sessionReadyAt = Date()
        state = .ready
        log("state -> ready")
        flushPendingAudio()
        scheduleRotation()
        scheduleAudioResponseWatchdog()
    }

    // MARK: - Ship audio (batched)

    private func shipAudio(_ pcm16: Data, on task: URLSessionWebSocketTask) {
        pendingShipChunks.append(pcm16)
        pendingShipBytes += pcm16.count

        if pendingShipChunks.count >= maxShipBatch {
            flushShipBatch(on: task)
            return
        }

        if pendingShipFlush == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pendingShipFlush = nil
                guard case .ready = self.state, let task = self.task else { return }
                self.flushShipBatch(on: task)
            }
            pendingShipFlush = work
            queue.asyncAfter(deadline: .now() + maxShipBatchDelay, execute: work)
        }
    }

    private func flushShipBatch(on task: URLSessionWebSocketTask) {
        guard !pendingShipChunks.isEmpty else { return }
        pendingShipFlush?.cancel()
        pendingShipFlush = nil

        let combined: Data
        if pendingShipChunks.count == 1 {
            combined = pendingShipChunks[0]
        } else {
            var buffer = Data(capacity: pendingShipBytes)
            for chunk in pendingShipChunks { buffer.append(chunk) }
            combined = buffer
        }
        let chunkCount = pendingShipChunks.count
        let totalBytes = pendingShipBytes
        pendingShipChunks.removeAll(keepingCapacity: true)
        pendingShipBytes = 0

        let base64 = combined.base64EncodedString()
        let event: [String: Any] = [
            "type": "session.input_audio_buffer.append",
            "audio": base64,
        ]
        send(event: event, on: task)
        audioChunksSent += chunkCount
        audioBytesSent += totalBytes
        if audioChunksSent - lastAudioLogChunkCount >= 10 || audioChunksSent == chunkCount {
            lastAudioLogChunkCount = audioChunksSent
            logVerbose("sent audio batch (\(chunkCount) chunks, \(totalBytes) bytes; total=\(audioBytesSent) bytes)")
        }
    }

    private func clearPendingShipBatch() {
        pendingShipFlush?.cancel()
        pendingShipFlush = nil
        pendingShipChunks.removeAll(keepingCapacity: false)
        pendingShipBytes = 0
    }

    private func flushPendingAudio() {
        guard let task = task, !pendingAudio.isEmpty else { return }
        log("flushing \(pendingAudio.count) buffered audio chunks (\(pendingAudioBytes) bytes)")
        for chunk in pendingAudio {
            shipAudio(chunk, on: task)
        }
        pendingAudio.removeAll(keepingCapacity: false)
        pendingAudioBytes = 0
        if !pendingShipChunks.isEmpty {
            flushShipBatch(on: task)
        }
    }

    // MARK: - Send / receive

    private func send(event: [String: Any], on task: URLSessionWebSocketTask) {
        guard let data = try? JSONSerialization.data(withJSONObject: event),
              let json = String(data: data, encoding: .utf8) else { return }
        task.send(.string(json)) { [weak self] error in
            if let error {
                self?.queue.async {
                    self?.log("send error: \(error.localizedDescription)")
                }
            }
        }
    }

    private func receiveLoop() {
        guard let task = task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error):
                self.queue.async {
                    guard self.task === task else {
                        self.log("ignoring receive failure from stale socket: \(error.localizedDescription)")
                        return
                    }
                    self.attemptReconnect(reason: error.localizedDescription)
                }
            case .success(let message):
                self.queue.async {
                    guard self.task === task else {
                        self.log("ignoring message from stale socket")
                        return
                    }
                    self.handle(message: message)
                    if self.task != nil {
                        self.receiveLoop()
                    }
                }
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) {
        let text: String
        switch message {
        case .string(let s): text = s
        case .data(let d): text = String(data: d, encoding: .utf8) ?? ""
        @unknown default: return
        }
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else {
            log("recv: failed to parse JSON (\(text.prefix(200)))")
            return
        }

        switch type {
        case "session.created":
            log("recv \(type)")
            if sessionConfigured {
                log("re-configuring after server-side session refresh")
                sessionConfigurationSent = false
                sessionConfigured = false
                sessionReadyAt = nil
                cancelRotation()
            }
            configureSession()
        case "session.updated":
            log("recv \(type)")
            markSessionReady()

        // Translated text deltas — what the user sees. Some server builds use
        // `session.output_transcript.delta`; others may use the bare
        // `output_transcript.delta` form. Handle both.
        case "session.output_transcript.delta", "output_transcript.delta":
            if let delta = obj["delta"] as? String, !delta.isEmpty {
                audioResponseWatchdog.noteTextResponse()
                pendingFinal += delta
                DispatchQueue.main.async { [weak self] in
                    self?.onPartial?(delta)
                }
            }

        case "session.output_transcript.done", "output_transcript.done":
            // Segment boundary — promote whatever we've accumulated to a
            // "completed" callback. Prefer the server-provided full transcript
            // if it's there; otherwise use what we accumulated.
            let transcript = (obj["transcript"] as? String) ?? pendingFinal
            pendingFinal = ""
            let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                audioResponseWatchdog.noteTextResponse()
                DispatchQueue.main.async { [weak self] in
                    self?.onCompleted?(trimmed)
                }
            }

        // Source-language transcript — we ignore for the UI per the user's
        // ask (translated text only) but keep a debug log so issues are
        // diagnosable from the console.
        case "session.input_transcript.delta", "input_transcript.delta":
            if let delta = obj["delta"] as? String, !delta.isEmpty {
                logVerbose("recv input delta: \(delta.count) chars")
            }
        case "session.input_transcript.done", "input_transcript.done":
            logVerbose("recv input done")

        // Translated audio — the user explicitly opted to discard it. We log
        // once at non-trivial size so it's obvious the server is producing
        // audio we're throwing away.
        case "session.output_audio.delta", "output_audio.delta":
            logOnce("recv translated audio (discarded — text-only mode)", key: "discarded-audio")

        case "session.output_audio.done", "output_audio.done":
            break

        case "input_audio_buffer.speech_started",
             "session.input_audio_buffer.speech_started":
            logVerbose("recv speech_started")
        case "input_audio_buffer.speech_stopped",
             "session.input_audio_buffer.speech_stopped":
            logVerbose("recv speech_stopped")

        case "error":
            let error = obj["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "Realtime translation error"
            let code = error?["code"] as? String ?? ""
            let eventID = error?["event_id"] as? String ?? ""
            log("recv error: code=\(code) eventID=\(eventID) message=\(message)")
            if case .stopping = state { return }

            // See `RealtimeTranscriptionClient` for rationale — session
            // expiry / server timeout / transient rate-limit errors are
            // recoverable by reconnecting, so they shouldn't end a long
            // recording. Only auth/handshake failures stay fatal.
            if RealtimeTranscriptionClient.isFatalServerError(code: code, message: message, sessionConfigured: sessionConfigured) {
                state = .failed(message)
                let nsCode = code.contains("invalid_api_key") || message.lowercased().contains("api key") ? 401 : -3
                onError?(NSError(domain: "RealtimeTranslationClient", code: nsCode,
                                 userInfo: [NSLocalizedDescriptionKey: message]))
                shutdown()
            } else {
                log("treating as recoverable server error; attempting reconnect")
                attemptReconnect(reason: message)
            }

        default:
            log("recv unhandled type=\(type) raw=\(text.prefix(300))")
        }
    }

    private func flushPendingFinalLocked() {
        let trimmed = pendingFinal.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingFinal = ""
        guard !trimmed.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onCompleted?(trimmed)
        }
    }

    // MARK: - Keepalive / rotation

    private func schedulePing() {
        cancelPing()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pingInterval, repeating: pingInterval)
        timer.setEventHandler { [weak self] in
            guard let self, let task = self.task else { return }
            task.sendPing { [weak self] error in
                if let error {
                    self?.queue.async {
                        self?.attemptReconnect(reason: "ping failed: \(error.localizedDescription)")
                    }
                }
            }
        }
        timer.resume()
        pingTimer = timer
    }

    private func cancelPing() {
        pingTimer?.cancel()
        pingTimer = nil
    }

    private func scheduleRotation() {
        cancelRotation()
        let maxAge = Settings.shared.voiceSessionMaxAgeSeconds
        guard maxAge > 0 else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + TimeInterval(maxAge), repeating: .never)
        timer.setEventHandler { [weak self] in
            self?.proactivelyRotate()
        }
        timer.resume()
        rotationTimer = timer
        log("rotation timer armed for \(maxAge) s from now")
    }

    private func cancelRotation() {
        rotationTimer?.cancel()
        rotationTimer = nil
    }

    private func scheduleAudioResponseWatchdog() {
        cancelAudioResponseWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in
            self?.checkAudioResponseWatchdog()
        }
        timer.resume()
        audioResponseWatchdogTimer = timer
    }

    private func cancelAudioResponseWatchdog() {
        audioResponseWatchdogTimer?.cancel()
        audioResponseWatchdogTimer = nil
    }

    private func checkAudioResponseWatchdog() {
        guard case .ready = state else { return }
        guard let stall = audioResponseWatchdog.stalled(sessionReadyAt: sessionReadyAt) else { return }
        log("audio response watchdog fired: active audio for \(Int(stall.activeAge)) s, no translated text for \(Int(stall.silentAge)) s")
        attemptReconnect(reason: "active audio without translated response for \(Int(stall.silentAge)) s")
    }

    // MARK: - Logging

    private var oncePool = Set<String>()

    private static let logger = Logger(subsystem: "com.braincache.realtime", category: "translation")

    private func log(_ message: String) {
        let line = "[RealtimeTranslation:\(source.rawValue)] \(message)"
        Self.logger.log("\(line, privacy: .public)")
    }

    private func logVerbose(_ message: String) {
        Self.logger.debug("[RealtimeTranslation:\(self.source.rawValue)] \(message, privacy: .public)")
    }

    private func logOnce(_ message: String, key: String) {
        guard !oncePool.contains(key) else { return }
        oncePool.insert(key)
        log(message)
    }
}

extension RealtimeTranslationClient: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didOpenWithProtocol protocol: String?) {
        queue.async { [weak self] in
            self?.log("WebSocket opened")
            self?.configureSession()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonString: String
        if let reason, let s = String(data: reason, encoding: .utf8), !s.isEmpty {
            reasonString = s
        } else {
            reasonString = "code=\(closeCode.rawValue)"
        }
        queue.async { [weak self] in
            guard let self else { return }
            self.log("WebSocket closed: \(reasonString)")
            guard self.task === webSocketTask else {
                self.log("ignoring close from stale socket")
                return
            }
            if case .stopping = self.state { self.state = .stopped; return }
            if case .stopped = self.state { return }
            self.attemptReconnect(reason: reasonString)
        }
    }
}
