import Foundation
import os

/// Streams 24 kHz mono PCM16 audio to the OpenAI Realtime transcription API
/// over a WebSocket and emits partial / completed transcript callbacks.
///
/// One instance owns one socket. Use two instances when capturing both
/// microphone and system audio so each stream gets its own session.
///
/// Long-session resilience:
/// - Pings every 25 s to keep proxies from idling the socket out; a failed
///   ping triggers a reconnect.
/// - Reconnects with exponential backoff when the socket drops mid-recording.
/// - Proactive rotation: rotates to a fresh socket at
///   ``Settings.voiceSessionMaxAgeSeconds`` to stay ahead of OpenAI's ~30 min
///   per-session cap.
///
/// There is intentionally no "transcript watchdog" — with manual-commit
/// models (e.g. gpt-realtime-whisper, `turn_detection: null`) the server is
/// legitimately silent until commit, so any "no events for N seconds"
/// heuristic produces false positives that wreck recordings.
///
/// All NSLog usage was replaced with `os.Logger` so Console.app shows the
/// full lifecycle (open → configure → ready → close → reconnect → stale-detect)
/// with `.public` interpolation instead of `<private>` redaction.
final class RealtimeTranscriptionClient: NSObject {

    enum State: Equatable {
        case idle
        case connecting
        case ready
        case reconnecting(attempt: Int)
        case stopping
        case stopped
        case failed(String)
    }

    /// Identifies this stream so the UI can label transcript lines.
    enum Source: String {
        case mic
        case system
    }

    let source: Source

    var onPartial: ((String) -> Void)?
    var onCompleted: ((String) -> Void)?
    var onStateChange: ((State) -> Void)?
    var onError: ((Error) -> Void)?

    private let model: String
    private let language: String?
    private let sampleRate: Int

    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private let queue = DispatchQueue(label: "com.braincache.realtime-transcription", qos: .userInitiated)

    private var pingTimer: DispatchSourceTimer?
    private var rotationTimer: DispatchSourceTimer?
    private var audioResponseWatchdogTimer: DispatchSourceTimer?
    private var audioResponseWatchdog = RealtimeAudioResponseWatchdog()
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 12
    private let pingInterval: TimeInterval = 25
    /// Backoff envelope: 1, 2, 4, 8, 16, then capped at 30. With
    /// `maxReconnectAttempts = 12` that's ~5 min of wall-clock retry budget
    /// before we give up, which is enough to survive most OpenAI hiccups
    /// without making the user wait forever on a truly dead connection.
    private let maxBackoffSeconds: TimeInterval = 30

    /// Audio captured between connection drops is dropped (the user's words
    /// during the gap are lost), but the live capture continues so we don't
    /// freeze the UI. We track this so reconnect can re-prime the session.
    private var sessionConfigurationSent = false
    private var sessionConfigured = false
    /// Wall-clock time when `markSessionReady()` last fired. Used to drive
    /// the proactive rotation timer.
    private var sessionReadyAt: Date?

    /// Debug counters surfaced in the log so it's obvious whether audio is
    /// flowing and whether the server is responding.
    private var audioChunksSent = 0
    private var audioBytesSent = 0
    private var lastAudioLogChunkCount = 0

    /// Audio captured before the session reaches `.ready`. Bounded so a long
    /// connect failure can't grow memory unbounded; capped at ~90 s of 24 kHz
    /// PCM16 mono = 4.32 MB. Sized to cover the full reconnect-backoff
    /// envelope (1+2+4+8+16+30+30+… ≈ minutes) so the user doesn't lose
    /// words while we're swapping sockets after a server-side session
    /// expiry or a slow handshake. Old size (1.44 MB / 30 s) matched the
    /// best-case backoff envelope exactly — any slower reconnect silently
    /// dropped audio.
    private var pendingAudio: [Data] = []
    private var pendingAudioBytes = 0
    private let maxPendingAudioBytes = 4_320_000

    /// Audio chunks queued for batched dispatch. Combining a few PCM16 chunks
    /// into one `input_audio_buffer.append` event halves the per-chunk base64 +
    /// JSON + WebSocket overhead at the cost of a small added latency. With
    /// `maxShipBatchDelay` capping the wait, we don't add more than ~120 ms.
    private var pendingShipChunks: [Data] = []
    private var pendingShipBytes = 0
    private var pendingShipFlush: DispatchWorkItem?
    private let maxShipBatch = 3
    private let maxShipBatchDelay: TimeInterval = 0.12

    init(source: Source, model: String, language: String? = nil, sampleRate: Int = 24000) {
        self.source = source
        self.model = model
        self.language = language
        self.sampleRate = sampleRate
        super.init()
    }

    // MARK: - Public API

    /// Opens the WebSocket and configures the transcription session. Subsequent
    /// `sendAudio` calls are buffered locally if the socket isn't ready yet.
    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            guard case .idle = self.state else { return }
            self.connect()
        }
    }

    /// Sends a chunk of 16-bit signed little-endian PCM audio at the configured
    /// sample rate. Call from any thread; the data is hopped onto the socket queue.
    func sendAudio(_ pcm16: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            // Before the session is ready (during the ~200–500 ms handshake
            // or while reconnecting), buffer instead of dropping so the user's
            // first words aren't silently lost.
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

    /// Concatenates queued PCM16 chunks into one base64-encoded
    /// `input_audio_buffer.append` event so we pay the encoding + JSON +
    /// WebSocket overhead once per batch instead of once per chunk.
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
            "type": "input_audio_buffer.append",
            "audio": base64,
        ]
        send(event: event, on: task)
        audioChunksSent += chunkCount
        audioBytesSent += totalBytes
        // Keep this behind verbose logging; otherwise long recordings spend
        // needless time formatting and writing high-frequency telemetry.
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
        // Drain any partial trailing batch immediately so reconnect-buffered
        // audio doesn't sit waiting behind the latency timer.
        if !pendingShipChunks.isEmpty {
            flushShipBatch(on: task)
        }
    }

    /// Politely commits any buffered audio, requests a final transcript, and
    /// closes the socket once the server has acknowledged.
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.task != nil, case .ready = self.state else {
                self.shutdown()
                return
            }
            self.state = .stopping
            // Commit the current buffer so models without VAD can finalize the
            // last in-flight utterance immediately. Flush any batched audio
            // first so trailing chunks reach the server before commit.
            if let task = self.task {
                self.flushShipBatch(on: task)
                self.commitAudioBuffer(on: task)
            }
            // Keep the socket open long enough for the final transcription event.
            self.queue.asyncAfter(deadline: .now() + 4.0) { [weak self] in
                guard let self, case .stopping = self.state else { return }
                self.shutdown()
            }
        }
    }

    /// Drops the socket immediately without waiting for pending transcripts.
    func cancel() {
        queue.async { [weak self] in
            self?.shutdown()
        }
    }

    // MARK: - Connection lifecycle

    private func connect() {
        let key = Settings.shared.openAIAPIKey
        guard !key.isEmpty else {
            log("connect aborted: AI API key is not configured")
            state = .failed("AI API key is not configured.")
            onError?(NSError(domain: "RealtimeTranscriptionClient", code: 401,
                             userInfo: [NSLocalizedDescriptionKey: "AI API key is not configured."]))
            return
        }

        let urlString = "wss://api.openai.com/v1/realtime?intent=transcription"
        guard let url = URL(string: urlString) else { return }
        log("connecting to \(urlString) (apiKey length=\(key.count), model=\(model), sampleRate=\(sampleRate))")

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
        // Guard against the close-handler-and-receiveLoop double-fire:
        // when the socket drops, `urlSession(_:webSocketTask:didCloseWith:)`
        // fires AND the in-flight `task.receive` returns `.failure`. Both
        // call `attemptReconnect`. Without this guard the retry counter
        // burns *two* attempts per real drop, cutting our budget in half.
        if case .reconnecting = state {
            log("attemptReconnect ignored — already reconnecting (reason=\(reason))")
            return
        }

        log("attemptReconnect: \(reason)")
        cancelPing()
        cancelRotation()
        cancelAudioResponseWatchdog()
        audioResponseWatchdog.reset()
        // Drop any chunks staged for the dead socket — the new session will
        // start with its own empty buffer.
        clearPendingShipBatch()
        if let task = task { task.cancel(with: .abnormalClosure, reason: nil) }
        task = nil
        session?.invalidateAndCancel()
        session = nil

        // If the caller already asked us to stop, don't reconnect.
        if case .stopping = state { state = .stopped; return }
        if case .stopped = state { return }

        reconnectAttempts += 1
        guard reconnectAttempts <= maxReconnectAttempts else {
            log("reconnect budget exhausted (\(reconnectAttempts)/\(maxReconnectAttempts)) — failing")
            state = .failed("Lost realtime transcription connection: \(reason)")
            onError?(NSError(domain: "RealtimeTranscriptionClient", code: -1,
                             userInfo: [NSLocalizedDescriptionKey: reason]))
            return
        }

        state = .reconnecting(attempt: reconnectAttempts)
        // 1, 2, 4, 8, 16, then capped at maxBackoffSeconds (30 s).
        let raw = pow(2.0, Double(reconnectAttempts - 1))
        let delay = min(raw, maxBackoffSeconds)
        log("reconnect attempt \(reconnectAttempts)/\(maxReconnectAttempts) in \(String(format: "%.1f", delay)) s")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.connect()
        }
    }

    /// Proactive rotation: close the current session and open a fresh one
    /// without touching the retry budget. Audio sent during the handshake
    /// gap is buffered in `pendingAudio` (90 s capacity) and flushed when
    /// the new session reaches `.ready`. Stays well ahead of OpenAI's
    /// ~30 min server-side session cap.
    private func proactivelyRotate() {
        // If we're already mid-reconnect or shutting down, leave it alone.
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
        if let task = task { task.cancel(with: .normalClosure, reason: nil) }
        task = nil
        session?.invalidateAndCancel()
        session = nil
        sessionConfigurationSent = false
        sessionConfigured = false
        sessionReadyAt = nil
        // Treat this as a clean reconnect — don't consume retry budget,
        // because the rotation is by design rather than a failure.
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
        let event = Self.makeSessionUpdateEvent(
            model: model,
            language: language,
            sampleRate: sampleRate
        )
        log("sending session.update (model=\(model), rate=\(sampleRate))")
        send(event: event, on: task)
        sessionConfigurationSent = true
    }

    private func commitAudioBuffer(on task: URLSessionWebSocketTask) {
        send(event: ["type": "input_audio_buffer.commit"], on: task)
        log("sent buffer.commit")
    }

    /// Returns true when a server-emitted `error` event should be treated as
    /// terminal (auth or handshake failures that won't go away on retry) vs.
    /// transient (session expiry, server-side timeout, mid-session rate
    /// limits — recoverable by opening a new socket).
    ///
    /// Anything that arrives before the session reaches ready is treated as
    /// fatal — the same error will repeat on every reconnect, and the user
    /// is better served by surfacing it now instead of looping silently.
    static func isFatalServerError(code: String, message: String, sessionConfigured: Bool) -> Bool {
        if !sessionConfigured { return true }
        let lowerMessage = message.lowercased()
        let lowerCode = code.lowercased()
        if lowerCode.contains("invalid_api_key") { return true }
        if lowerCode.contains("unauthorized") { return true }
        if lowerCode == "401" { return true }
        if lowerMessage.contains("api key") { return true }
        if lowerMessage.contains("unauthorized") { return true }
        return false
    }

    static func makeSessionUpdateEvent(
        model: String,
        language: String?,
        sampleRate: Int
    ) -> [String: Any] {
        var transcription: [String: Any] = ["model": model]
        if let language, !language.isEmpty {
            transcription["language"] = language
        }
        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if normalizedModel == "gpt-realtime-whisper" {
            transcription["delay"] = "minimal"
        }

        // gpt-realtime-whisper does not support server VAD — the realtime
        // endpoint rejects `turn_detection: server_vad` for that model. Use
        // null for whisper (manual-commit semantics) and server VAD for
        // every other transcription model.
        let turnDetection: Any
        if normalizedModel == "gpt-realtime-whisper" {
            turnDetection = NSNull()
        } else {
            turnDetection = [
                "type": "server_vad",
                "threshold": 0.5,
                "prefix_padding_ms": 300,
                "silence_duration_ms": 500,
            ]
        }

        return [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": [
                    "input": [
                        "format": [
                            "type": "audio/pcm",
                            "rate": sampleRate,
                        ],
                        "transcription": transcription,
                        "turn_detection": turnDetection,
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
                    // Continue the loop only if we're still alive.
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
        case "session.created", "transcription_session.created":
            log("recv \(type)")
            // Some realtime stacks emit a fresh `session.created` if they
            // server-side refresh the session. Without re-configuring, we'd
            // ship audio that the server then drops on the floor. Force a
            // re-configure when we see this after the first ready.
            if sessionConfigured {
                log("re-configuring after server-side session refresh")
                sessionConfigurationSent = false
                sessionConfigured = false
                sessionReadyAt = nil
                cancelRotation()
            }
            configureSession()
        case "session.updated", "transcription_session.updated":
            log("recv \(type)")
            markSessionReady()
        case "input_audio_buffer.speech_started":
            logVerbose("recv speech_started")
        case "input_audio_buffer.speech_stopped":
            logVerbose("recv speech_stopped")
        case "input_audio_buffer.committed":
            logVerbose("recv buffer.committed")
        case "conversation.item.created":
            logVerbose("recv conversation.item.created")
        case "conversation.item.input_audio_transcription.delta":
            if let delta = obj["delta"] as? String, !delta.isEmpty {
                audioResponseWatchdog.noteTextResponse()
                logVerbose("recv delta: \(delta.count) chars")
                DispatchQueue.main.async { [weak self] in
                    self?.onPartial?(delta)
                }
            } else {
                logVerbose("recv delta: <empty>")
            }
        case "conversation.item.input_audio_transcription.completed":
            let transcript = (obj["transcript"] as? String) ?? ""
            logVerbose("recv completed: \(transcript.count) chars")
            if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                audioResponseWatchdog.noteTextResponse()
                DispatchQueue.main.async { [weak self] in
                    self?.onCompleted?(transcript)
                }
            }
        case "conversation.item.input_audio_transcription.failed":
            let err = obj["error"] as? [String: Any]
            log("recv transcription.failed: \(err ?? [:])")
            let message = err?["message"] as? String ?? "Realtime transcription failed."
            DispatchQueue.main.async { [weak self] in
                self?.onError?(NSError(domain: "RealtimeTranscriptionClient", code: -2,
                                       userInfo: [NSLocalizedDescriptionKey: message]))
            }
        case "error":
            let error = obj["error"] as? [String: Any]
            let message = error?["message"] as? String ?? "Realtime API error"
            let code = error?["code"] as? String ?? ""
            let eventID = error?["event_id"] as? String ?? ""
            log("recv error: code=\(code) eventID=\(eventID) message=\(message)")
            if case .stopping = state { return }

            // Server-emitted errors during an active session are usually
            // session-lifecycle events (expiry, server-side timeout, transient
            // rate-limit) — the same fix the close-handler already does for
            // dropped sockets. Reconnect with backoff so a long recording
            // survives the ~1 hr server session cap. Only auth/handshake
            // failures stay fatal: those won't go away on retry.
            if Self.isFatalServerError(code: code, message: message, sessionConfigured: sessionConfigured) {
                state = .failed(message)
                let nsCode = code.contains("invalid_api_key") || message.lowercased().contains("api key") ? 401 : -3
                onError?(NSError(domain: "RealtimeTranscriptionClient", code: nsCode,
                                 userInfo: [NSLocalizedDescriptionKey: message]))
                shutdown()
            } else {
                log("treating as recoverable server error; attempting reconnect")
                attemptReconnect(reason: message)
            }
        default:
            // Log unknown events with a payload preview so unexpected server
            // shapes are debuggable.
            log("recv unhandled type=\(type) raw=\(text.prefix(300))")
        }
    }

    // MARK: - Keepalive

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

    /// Proactive rotation. OpenAI caps a single realtime session at ~30 min
    /// server-side; we rotate to a fresh socket at `voiceSessionMaxAgeSeconds`
    /// (default 25 min) so the user never hits that cap mid-sentence.
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
        log("audio response watchdog fired: active audio for \(Int(stall.activeAge)) s, no transcript text for \(Int(stall.silentAge)) s")
        attemptReconnect(reason: "active audio without transcript response for \(Int(stall.silentAge)) s")
    }

    // MARK: - Logging

    private var oncePool = Set<String>()

    private static let logger = Logger(subsystem: "com.braincache.realtime", category: "transcription")

    private func log(_ message: String) {
        let line = "[RealtimeTranscription:\(source.rawValue)] \(message)"
        Self.logger.log("\(line, privacy: .public)")
    }

    private func logVerbose(_ message: String) {
        Self.logger.debug("[RealtimeTranscription:\(self.source.rawValue)] \(message, privacy: .public)")
    }

    private func logOnce(_ message: String, key: String) {
        guard !oncePool.contains(key) else { return }
        oncePool.insert(key)
        log(message)
    }
}

extension RealtimeTranscriptionClient: URLSessionWebSocketDelegate {
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
            // Caller-initiated close; don't reconnect.
            if case .stopping = self.state { self.state = .stopped; return }
            if case .stopped = self.state { return }
            self.attemptReconnect(reason: reasonString)
        }
    }
}
